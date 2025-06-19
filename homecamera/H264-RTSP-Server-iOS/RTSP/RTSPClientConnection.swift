import Combine
import CoreFoundation
import Foundation
import Network

private let base64Mapping = Array(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
)
private let maxPacketSize = 1200
private let rtpHeaderSize = 12

private enum ServerState {
    case idle, setup, playing
}

struct RTSPSessionInterleaved {
    let channelRTP: UInt8
    let channelRTCP: UInt8
}

struct RTSPSessionUDP {
    let addressRTP: CFData
    let socketRTP: CFSocket
    let addressRTCP: CFData
    let socketRTCP: CFSocket
}

private enum RTSPSession {
    case udp(RTSPSessionUDP)
    case interleaved(RTSPSessionInterleaved)

    func tearDown() {
        switch self {
        case .interleaved:
            break
        case .udp(let session):
            CFSocketInvalidate(session.socketRTP)
            CFSocketInvalidate(session.socketRTCP)
        }
    }
}

@Observable
class RTSPClientConnection {
    private(set) var socket: CFSocket?
    private var address: CFData?
    private var sessionConnection: RTSPSession?
    private weak var server: RTSPServer?
    private var rls: CFRunLoopSource?
    private var session: String?
    private var state: ServerState = .idle
    private var packets: Int = 0  // TODO: this should be randomized to start // https://en.wikipedia.org/wiki/Real-time_Transport_Protocol
    private var bytesSent: Int = 0
    private var ssrc: UInt32 = 0
    private var bFirst: Bool = true
    private var ntpBase: UInt64 = 0
    private var rtpBase: UInt64 = 0
    private var ptsBase: Double = 0
    private var packetsReported: Int = 0
    private var bytesReported: Int = 0
    private var sentRTCP: Date?
    private var recvRTCP: CFSocket?
    private var rlsRTCP: CFRunLoopSource?
    private let clock = 90000  // RTP clock rate for H264
    private let serverPort: UInt16 = 6971
    private(set) var sourceDescription: String? = nil

    public var receiverReports = PassthroughSubject<RRPacket.Block, Never>()

    init?(socketHandle: CFSocketNativeHandle, server: RTSPServer) {
        self.server = server
        var context = CFSocketContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        self.socket = CFSocketCreateWithNative(
            nil,
            socketHandle,
            CFSocketCallBackType.acceptCallBack.rawValue
                | CFSocketCallBackType.dataCallBack.rawValue,
            { (s, callbackType, address, data, info) in
                guard let info else { return }
                let conn = Unmanaged<RTSPClientConnection>.fromOpaque(info).takeUnretainedValue()
                switch callbackType {
                case .acceptCallBack:
                    conn.address = address
                case .dataCallBack:
                    if let data {
                        conn.onSocketData(
                            Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data
                        )
                    }
                default:
                    print("unexpected socket event")
                }
            },
            &context
        )
        guard let socket else { return nil }
        self.rls = CFSocketCreateRunLoopSource(nil, socket, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), self.rls, .commonModes)
        self.state = .idle
    }

    private var partialPacket: (data: Data, left: UInt16)?

    private func onSocketData(_ allData: Data) {
        if allData.isEmpty {
            shutdown()
            server?.shutdownConnection(self)
            return
        }

        if case .interleaved = sessionConnection {
            var ptr = allData.startIndex

            while ptr < allData.endIndex {  // '$' indicates an RTSP interleaved frame
                // possibilities here
                // - complete RTSP packet
                // - complete RTCP packet
                // - RTCP packet header, with remainder of data in next packet
                // - RTSP packet followed by RTCP packet
                // - multiple RTCP packets

                let data = allData[ptr...]
                if ptr > 0 {
                    print("processing additional data")
                }

                if var partialPacket {
                    partialPacket.data.append(contentsOf: data)
                    if data.count < Int(partialPacket.left) {
                        partialPacket.left -= UInt16(data.count)
                    } else {
                        onRTCP(partialPacket.data)
                        self.partialPacket = nil
                    }
                    ptr += data.count
                } else if data[data.startIndex] == 0x24 {  // '$' indicates an RTSP interleaved frame
                    // let channel = data[1]  // channel number
                    let length = data.read(at: data.startIndex + 2, as: UInt16.self).bigEndian
                    let remainingDataCount = data.count - 4
                    let interleavedData = data[data.startIndex.advanced(by: 4)...]
                    if remainingDataCount < length {
                        partialPacket = (interleavedData, length - UInt16(interleavedData.count))
                    } else {
                        // ASSUMING RTCP
                        onRTCP(interleavedData)
                    }
                    ptr += 4 + Int(length)
                } else {
                    // RTSP packet
                    let len = handleRTSPPacket(data)
                    ptr += len
                    // if remaining data, could be a RTCP packet
                }
            }
        } else {
            let len = handleRTSPPacket(allData)
            if len < allData.count {
                print("additional data after RTSP packet")
            }
        }
    }

    private func handleRTSPPacket(_ data: Data) -> Int {
        guard let msg = RTSPMessage(data) else { return 0 }
        var response = [String]()
        let cmd = msg.command.lowercased()
        // print(
        //     """
        //     C->S: (\(session ?? "no session"))
        //     > \(msg.debugDescription.split(separator: "\n").joined(separator: "\n> "))
        //     """
        // )
        switch cmd {
        case "options":
            response = msg.createResponse(code: 200, text: "OK")
            response.append("Server: AVEncoderDemo/1.0")
            response.append("Public: DESCRIBE, SETUP, TEARDOWN, PLAY, OPTIONS")
        case "describe":
            response = msg.createResponse(code: 200, text: "OK")
            let date = DateFormatter.localizedString(
                from: Date(),
                dateStyle: .long,
                timeStyle: .long
            )
            if let socket, let localaddr = CFSocketCopyAddress(socket) as? Data {
                let ipString = localaddr.withUnsafeBytes {
                    (ptr: UnsafeRawBufferPointer) -> String in
                    let sockaddr = ptr.baseAddress!.assumingMemoryBound(to: sockaddr_in.self)
                    return String(cString: inet_ntoa(sockaddr.pointee.sin_addr))
                }
                response.append("Content-base: rtsp://\(ipString)/")
            }
            let sdp = makeSDP()
            response += [
                "Date: \(date)",
                "Content-Type: application/sdp",
                "Content-Length: \((sdp.joined(separator: "\r\n") + "\r\n\r\n").lengthOfBytes(using: .utf8))",
                "",
            ]
            response += sdp
        case "setup":
            if let transport = msg.headers["transport"] {
                let props = transport.components(separatedBy: ";")
                var ports: [String]? = nil
                for s in props {
                    if s.hasPrefix("client_port=") {
                        let val = String(s.dropFirst(12))
                        ports = val.components(separatedBy: "-")
                        break
                    }
                }

                if let ports, ports.count == 2,
                    let portRTP = Int(ports[0]),
                    let portRTCP = Int(ports[1])
                {
                    createSession(portRTP: portRTP, portRTCP: portRTCP)
                    if let session {
                        response = msg.createResponse(code: 200, text: "OK")
                        response += [
                            "Session: \(session)",
                            "Transport: RTP/AVP;unicast;client_port=\(portRTP)-\(portRTCP);server_port=6970-\(serverPort)",
                        ]
                    }
                }

                if response.isEmpty {
                    for s in props {
                        if s.hasPrefix("interleaved=") {
                            let val = String(s.dropFirst(12))
                            let channels = val.components(separatedBy: "-")
                                .compactMap({ UInt8($0) })
                            if let channelRTP = channels.first {
                                let channelRTCP =
                                    channels.count > 1 ? channels[1] : (channelRTP + 1)

                                createInterleavedSession(
                                    channelRTP: channelRTP,
                                    channelRTCP: channelRTCP
                                )

                                if let session {
                                    response = msg.createResponse(code: 200, text: "OK")
                                    response += [
                                        "Session: \(session)",
                                        "Transport: RTP/AVP/TCP;unicast;interleaved=0-1",
                                    ]
                                }
                                break
                            }
                        }
                    }
                }
            }
            if response.isEmpty {
                response = msg.createResponse(code: 451, text: "Need better error string here")
            }
        case "play":
            if let session, state == .setup {
                state = .playing
                bFirst = true
                response = msg.createResponse(code: 200, text: "OK")
                response.append("Session: \(session)")
            } else {
                response = msg.createResponse(code: 451, text: "Wrong state")
            }
        case "teardown":
            tearDown()
            response = msg.createResponse(code: 200, text: "OK")
        default:
            print("RTSP method \(cmd) not handled")
            response = msg.createResponse(code: 451, text: "Method not recognised")
        }
        if !response.isEmpty,
            let responseData = (response.joined(separator: "\r\n") + "\r\n\r\n").data(using: .utf8),
            let socket
        {
            // print(
            //     """
            //     S->C: (\(session ?? "no session"))
            //     > \(response.joined(separator: "\n> "))
            //     """
            // )
            CFSocketSendData(socket, nil, responseData as CFData, 2)
        }
        return msg.length
    }

    private func makeSDP() -> [String] {
        guard let server else { return [] }

        let config = server.configData

        guard let avcC = AVCCHeader(header: config) else { return [] }

        guard let seqParams = SeqParamSet(avcC.sps) else {
            fatalError("Failed to parse SPS from avcC")
        }

        let cx = seqParams.cx
        let cy = seqParams.cy

        let profileLevelID = String(
            format: "%02x%02x%02x",
            seqParams.profile,
            seqParams.compatibility,
            seqParams.level
        )

        let spsBase64 = avcC.sps.data.base64EncodedString()
        let ppsBase64 = avcC.pps.data.base64EncodedString()

        let verid = UInt32.random(in: UInt32.min...UInt32.max)

        guard let socket else { return [] }
        guard let dlocaladdr = CFSocketCopyAddress(socket) else {
            fatalError("No peer address for socket")
        }
        let localaddr = dlocaladdr as Data
        let ipString = localaddr.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> String in
            let sockaddr = ptr.load(as: sockaddr_in.self)
            return String(cString: inet_ntoa(sockaddr.sin_addr))
        }
        let packets = (server.bitrate / (maxPacketSize * 8)) + 1
        return [
            "v=0",
            "o=- \(verid) \(verid) IN IP4 \(ipString)",
            "s=Live stream from iOS",
            "c=IN IP4 0.0.0.0",
            "t=0 0",
            "a=control:*",
            "m=video 0 RTP/AVP 96",
            "b=TIAS:\(server.bitrate)",
            "a=maxprate:\(packets).0000",
            "a=control:streamid=1",
            "a=rtpmap:96 H264/\(clock)",
            "a=mimetype:string;\"video/H264\"",
            "a=framesize:96 \(cx)-\(cy)",
            "a=Width:integer;\(cx)",
            "a=Height:integer;\(cy)",
            "a=fmtp:96 packetization-mode=1;profile-level-id=\(profileLevelID);sprop-parameter-sets=\(spsBase64),\(ppsBase64)",
        ]
    }

    private func createSession(portRTP: Int, portRTCP: Int) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        guard let socket else { return }

        guard let data = CFSocketCopyPeerAddress(socket) else {
            fatalError("No peer address for socket")
        }
        var paddr = (data as Data).read(as: sockaddr_in.self)

        paddr.sin_port = in_port_t(UInt16(portRTP).bigEndian)
        guard let addrRTP = CFDataCreate(nil, &paddr, MemoryLayout<sockaddr_in>.size) else {
            fatalError("Failed to create RTP address")
        }
        guard let socketRTP = CFSocketCreate(nil, PF_INET, SOCK_DGRAM, IPPROTO_UDP, 0, nil, nil)
        else {
            fatalError("Failed to create RTP socket")
        }

        paddr.sin_port = in_port_t(UInt16(portRTCP).bigEndian)
        guard let addrRTCP = CFDataCreate(nil, &paddr, MemoryLayout<sockaddr_in>.size) else {
            fatalError("Failed to create RTCP address")
        }
        guard let socketRTCP = CFSocketCreate(nil, PF_INET, SOCK_DGRAM, IPPROTO_UDP, 0, nil, nil)
        else {
            fatalError("Failed to create RTCP socket")
        }

        self.sessionConnection = .udp(
            RTSPSessionUDP(
                addressRTP: addrRTP,
                socketRTP: socketRTP,
                addressRTCP: addrRTCP,
                socketRTCP: socketRTCP
            )
        )

        flagValidSession()

        print(
            "Started session \(self.session ?? "INVALID") with RTP port \(portRTP) and RTCP port \(portRTCP)"
        )
    }

    private func createInterleavedSession(channelRTP: UInt8, channelRTCP: UInt8) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        guard socket != nil else { return }

        self.sessionConnection = .interleaved(
            .init(channelRTP: channelRTP, channelRTCP: channelRTCP)
        )

        flagValidSession()

        print("Started interleaved session \(self.session ?? "INVALID")")
    }

    private func flagValidSession() {
        // reader reports received here
        var info = CFSocketContext()
        info.info = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        self.recvRTCP = CFSocketCreate(
            nil,
            PF_INET,
            SOCK_DGRAM,
            IPPROTO_UDP,
            CFSocketCallBackType.dataCallBack.rawValue,
            { (s, callbackType, address, data, info) in
                guard let info else { return }
                let conn = Unmanaged<RTSPClientConnection>.fromOpaque(info).takeUnretainedValue()
                switch callbackType {
                case .dataCallBack:
                    if let data {
                        conn.onRTCP(
                            Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data
                        )
                    }
                default:
                    print("unexpected socket event")
                }
            },
            &info
        )

        var addr = sockaddr_in()
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(serverPort.bigEndian)  // htons
        let dataAddr = Data(bytes: &addr, count: MemoryLayout<sockaddr_in>.size) as CFData
        CFSocketSetAddress(self.recvRTCP, dataAddr)

        self.rlsRTCP = CFSocketCreateRunLoopSource(nil, self.recvRTCP, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), self.rlsRTCP, .commonModes)

        // flag that setup is valid
        let sessionid = UInt32.random(in: UInt32.min...UInt32.max)
        self.session = "\(sessionid)"
        self.state = .setup
        self.ssrc = UInt32.random(in: UInt32.min...UInt32.max)
        self.packets = 0
        self.bytesSent = 0
        self.rtpBase = 0

        self.sentRTCP = nil
        self.packetsReported = 0
        self.bytesReported = 0
    }

    // MARK: - Video Data
    func onVideoData(_ data: [Data], time pts: Double) {
        guard state == .playing else { return }
        let maxSinglePacket = maxPacketSize - rtpHeaderSize
        let maxFragmentPacket = maxSinglePacket - 2
        for (i, nalu) in data.enumerated() {
            var countBytes = nalu.count
            let bLast = (i == data.count - 1)
            if bFirst {
                if (nalu[0] & 0x1f) != 5 {
                    continue
                }
                bFirst = false
                print("Playback starting at first IDR")
            }
            if countBytes < maxSinglePacket {
                var packet = Data(count: maxPacketSize)

                writeHeader(&packet, marker: bLast, time: pts)
                packet.replaceSubrange(packet.startIndex.advanced(by: rtpHeaderSize)..., with: nalu)
                sendPacket(
                    packet[
                        packet
                            .startIndex..<packet.startIndex.advanced(by: countBytes + rtpHeaderSize)
                    ]
                )
            } else {
                var pointerNalu = nalu.startIndex
                let naluHeader = nalu[pointerNalu]
                pointerNalu += 1
                countBytes -= 1
                var bStart = true

                while countBytes > 0 {
                    var packet = Data(count: maxPacketSize)

                    let countThis = min(countBytes, maxFragmentPacket)
                    let bEnd = countThis == countBytes
                    writeHeader(&packet, marker: bLast && bEnd, time: pts)

                    packet[packet.startIndex + rtpHeaderSize] = (naluHeader & 0xe0) + 28  // FU_A type
                    var fuHeader = naluHeader & 0x1f
                    if bStart {
                        fuHeader |= 0x80
                        bStart = false
                    } else if bEnd {
                        fuHeader |= 0x40
                    }
                    packet[packet.startIndex + rtpHeaderSize + 1] = fuHeader
                    packet[
                        packet.startIndex + rtpHeaderSize
                            + 2..<(packet.startIndex + rtpHeaderSize + 2 + countThis)
                    ] =
                        nalu[pointerNalu..<(pointerNalu + countThis)]
                    sendPacket(
                        packet[
                            packet
                                .startIndex..<packet.startIndex.advanced(
                                    by: countThis + rtpHeaderSize + 2
                                )
                        ]
                    )

                    pointerNalu += countThis
                    countBytes -= countThis
                }
            }
        }
    }

    private func writeHeader(_ packet: inout Data, marker bMarker: Bool, time pts: Double) {
        packet[packet.startIndex] = 0b10000000  // v=2
        packet[packet.startIndex.advanced(by: 1)] = bMarker ? (0b1100000 | 0b10000000) : 0b1100000

        packet.replace(at: 2, with: UInt16(truncatingIfNeeded: packets).bigEndian)

        while rtpBase == 0 {
            rtpBase = UInt64(UInt32.random(in: UInt32.min...UInt32.max))
            ptsBase = pts
            let now = Date()
            // ntp is based on 1900. There's a known fixed offset from 1900 to 1970.
            let ref = Date(timeIntervalSince1970: -2_208_988_800)
            let interval = now.timeIntervalSince(ref)
            ntpBase = UInt64(interval * Double(1 << 32))
        }
        let rtp = UInt64((pts - ptsBase) * Double(clock)) + rtpBase
        packet.replace(at: packet.startIndex.advanced(by: 4), with: UInt32(rtp).bigEndian)

        packet.replace(at: packet.startIndex.advanced(by: 8), with: ssrc.bigEndian)
    }

    // interleaved RFC 2326 10.12
    private static func interleavePacket(
        _ packet: Data,
        channel: UInt8
    ) -> Data {
        var wrapped = Data(count: packet.count + 4)
        wrapped[wrapped.startIndex] = 0x24  // '$'
        wrapped[wrapped.startIndex.advanced(by: 1)] = channel
        wrapped.replace(
            at: wrapped.startIndex.advanced(by: 2),
            with: UInt16(packet.count).bigEndian
        )
        wrapped.replaceSubrange(wrapped.startIndex.advanced(by: 4)..., with: packet)
        return wrapped
    }

    private func sendPacket(_ packet: Data) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        guard let sessionConnection else { return }

        switch sessionConnection {
        case .udp(let udpSession):
            CFSocketSendData(udpSession.socketRTP, udpSession.addressRTP, packet as CFData, 0)
        case .interleaved(let interleavedSession):
            CFSocketSendData(
                socket,
                address,
                Self.interleavePacket(
                    packet,
                    channel: interleavedSession.channelRTP
                ) as CFData,
                0
            )
        }

        packets += 1
        bytesSent += packet.count

        let now = Date()
        if sentRTCP == nil || now.timeIntervalSince(sentRTCP!) >= 1 {
            var buf = Data(capacity: 7 * MemoryLayout<UInt32>.size)
            buf += [
                0x80,  // version
                200,  // type == SR
                0,  // empty
                6,  // length (count of uint32_t minus 1)
            ]
            buf.append(value: ssrc.bigEndian)
            buf.append(value: UInt64(ntpBase).bigEndian)
            buf.append(value: UInt32(rtpBase).bigEndian)
            buf.append(value: UInt32(packets - packetsReported).bigEndian)
            buf.append(value: UInt32(bytesSent - bytesReported).bigEndian)

            switch sessionConnection {
            case .udp(let udpSession):
                CFSocketSendData(udpSession.socketRTCP, udpSession.addressRTCP, buf as CFData, 0)
            case .interleaved(let interleavedSession):
                CFSocketSendData(
                    socket,
                    address,
                    Self.interleavePacket(
                        buf,
                        channel: interleavedSession.channelRTCP
                    ) as CFData,
                    0
                )
            }

            sentRTCP = now
            packetsReported = packets
            bytesReported = bytesSent
        }
    }

    private func onRTCP(_ data: Data) {
        var ptr = data.startIndex
        while ptr < data.endIndex {
            // print(
            //     """
            //     C->S: RTCP (\(session ?? "no session"))
            //     """
            // )

            if let message = RTCPMessage(data: data[ptr...], clock: clock) {
                ptr += Int(message.byteLength)

                switch message.packet {
                case .receiverReport(let rRPacket):
                    rRPacket.blocks.forEach({ receiverReports.send($0) })
                case .sourceDescription(let sDESPacket):
                    sourceDescription = sDESPacket.chunks.first?.text
                case .goodbye:
                    break
                default:
                    print("RTCP packet type \(message.type) not handled")
                }
            } else {
                print("RTCP packet parsing failed")
            }
        }
    }

    private func tearDown() {
        sessionConnection?.tearDown()
        sessionConnection = nil
        if let recvRTCP {
            CFSocketInvalidate(recvRTCP)
            self.recvRTCP = nil
        }
        session = nil
    }

    func shutdown() {
        tearDown()
        if let socket {
            CFSocketInvalidate(socket)
            self.socket = nil
        }
    }
}
