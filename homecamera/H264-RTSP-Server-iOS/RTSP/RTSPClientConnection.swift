import CoreFoundation
import Foundation
import Network

// MARK: - Utility Functions
private func tonetShort(_ s: UInt16) -> [UInt8] {
    [
        UInt8((s >> 8) & 0xff),
        UInt8(s & 0xff),
    ]
}

private func tonetLong(_ l: UInt32) -> [UInt8] {
    [
        UInt8((l >> 24) & 0xff),
        UInt8((l >> 16) & 0xff),
        UInt8((l >> 8) & 0xff),
        UInt8(l & 0xff),
    ]
}

private let base64Mapping = Array(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
)
private let maxPacketSize = 1200

private func encodeLong(_ val: UInt32, nPad: Int) -> String {
    var ch = [UInt8](repeating: 0, count: 4)
    let cch = 4 - nPad
    for i in 0..<cch {
        let shift = 6 * (cch - (i + 1))
        let bits = (val >> shift) & 0x3f
        ch[i] = base64Mapping[Int(bits)]
    }
    for i in 0..<nPad {
        ch[cch + i] = UInt8(Character("=").asciiValue!)
    }
    return String(bytes: ch, encoding: .utf8) ?? ""
}

private func encodeToBase64(_ data: Data) -> String {
    var s = ""
    var idx = 0
    let bytes = [UInt8](data)
    var cBytes = data.count
    while cBytes >= 3 {
        let val =
            (UInt32(bytes[idx]) << 16) + (UInt32(bytes[idx + 1]) << 8) + UInt32(bytes[idx + 2])
        s += encodeLong(val, nPad: 0)
        idx += 3
        cBytes -= 3
    }
    if cBytes > 0 {
        var nPad: Int
        var val: UInt32
        if cBytes == 1 {
            // pad 8 bits to 2 x 6 and add 2 ==
            nPad = 2
            val = UInt32(bytes[idx]) << 4
        } else {
            // must be two bytes -- pad 16 bits to 3 x 6 and add one =
            nPad = 1
            val = (UInt32(bytes[idx]) << 8) + UInt32(bytes[idx + 1])
            val = val << 2
        }
        s += encodeLong(val, nPad: nPad)
    }
    return s
}

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

class RTSPClientConnection {
    private var socket: CFSocket?
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

    // MARK: - Initializer
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
                        conn.onSocketData(Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue())
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

    // MARK: - Data Handling
    func onSocketData(_ data: CFData) {
        if CFDataGetLength(data) == 0 {
            tearDown()
            if let socket {
                CFSocketInvalidate(socket)
                self.socket = nil
            }
            server?.shutdownConnection(self)
            return
        }
        guard let msg = RTSPMessage.createWithData(data) else { return }
        var response = [String]()
        let cmd = msg.command.lowercased()
        print(
            """
            C->S:
            > \(msg.debugDescription.split(separator: "\n").joined(separator: "\n> "))
            """
        )
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
            if let transport = msg.valueForOption("transport") {
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
            print(
                """
                S->C:
                > \(response.joined(separator: "\n> "))
                """
            )
            CFSocketSendData(socket, nil, responseData as CFData, 2)
        }
    }

    // MARK: - SDP Creation
    func makeSDP() -> [String] {
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

        let spsData = Data(bytes: avcC.sps.start!, count: avcC.sps.length)
        let spsBase64 = spsData.base64EncodedString()
        let ppsData = Data(bytes: avcC.pps.start!, count: avcC.pps.length)
        let ppsBase64 = ppsData.base64EncodedString()

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

    // MARK: - Session Creation
    func createSession(portRTP: Int, portRTCP: Int) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        guard let socket else { return }

        guard let data = CFSocketCopyPeerAddress(socket) else {
            fatalError("No peer address for socket")
        }
        var paddr = (data as Data).withUnsafeBytes { $0.load(as: sockaddr_in.self) }

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

    func createInterleavedSession(channelRTP: UInt8, channelRTCP: UInt8) {
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
                        conn.onRTCP(Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue())
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
        let rtpHeaderSize = 12
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
                var packet = Data(repeating: 0, count: maxPacketSize)
                writeHeader(&packet, marker: bLast, time: pts)
                packet.replaceSubrange(rtpHeaderSize..., with: nalu)
                sendPacket(packet: packet, length: countBytes + rtpHeaderSize)
            } else {
                var pointerNalu = nalu.startIndex
                let naluHeader = nalu[pointerNalu]
                pointerNalu += 1
                countBytes -= 1
                var bStart = true

                while countBytes > 0 {
                    var packet = Data(repeating: 0, count: maxPacketSize)
                    let cThis = min(countBytes, maxFragmentPacket)
                    let bEnd = cThis == countBytes
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
                            + 2..<(packet.startIndex + rtpHeaderSize + 2 + cThis)
                    ] =
                        nalu[pointerNalu..<(pointerNalu + cThis)]
                    sendPacket(packet: packet, length: cThis + rtpHeaderSize + 2)

                    pointerNalu += cThis
                    countBytes -= cThis
                }
            }
        }
    }

    // MARK: - RTP Header
    private func writeHeader(_ packet: inout Data, marker bMarker: Bool, time pts: Double) {
        packet[packet.startIndex] = 0b10000000  // v=2
        packet[packet.startIndex.advanced(by: 1)] = bMarker ? (0b1100000 | 0b10000000) : 0b1100000

        let seq = UInt16(packets & 0xffff)
        let seqBytes = tonetShort(seq)
        packet.replaceSubrange(2..<4, with: seqBytes)

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
        let rtpBytes = tonetLong(UInt32(truncatingIfNeeded: rtp))
        packet.replaceSubrange(4..<8, with: rtpBytes)

        let ssrcBytes = tonetLong(ssrc)
        packet.replaceSubrange(8..<12, with: ssrcBytes)
    }

    private static func interleavePacket(
        _ packet: Data,
        channel: UInt8,
        length: UInt16? = nil
    ) -> Data {
        // interleaved RFC 2326 10.12
        var wrapped = Data(count: packet.count + 4)
        wrapped[0] = 0x24  // '$'
        wrapped[1] = channel
        wrapped.replaceSubrange(2..<4, with: tonetShort(length ?? UInt16(packet.count)))
        wrapped.replaceSubrange(4..., with: packet)
        return wrapped
    }

    // MARK: - RTP/RTCP Packet Sending
    func sendPacket(packet: Data, length: Int) {
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
                    channel: interleavedSession.channelRTP,
                    length: UInt16(length)
                ) as CFData,
                0
            )
        }

        packets += 1
        bytesSent += length

        let now = Date()
        if sentRTCP == nil || now.timeIntervalSince(sentRTCP!) >= 1 {
            var buf = Data(capacity: 7 * MemoryLayout<UInt32>.size)
            buf += [
                0x80,  // version
                200,  // type == SR
                0,  // empty
                6,  // length (count of uint32_t minus 1)
            ]
            buf += tonetLong(ssrc)
            withUnsafeBytes(of: UInt64(ntpBase).bigEndian) { ptr in
                buf += ptr
            }
            buf += tonetLong(UInt32(rtpBase))
            buf += tonetLong(UInt32(packets - packetsReported))
            buf += tonetLong(UInt32(bytesSent - bytesReported))

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

    // MARK: - RTCP
    func onRTCP(_ data: CFData) {
        // RTCP receive handler (not implemented)
        print("RTCP packet received")
        _ = RTCPMessage(data: data as Data, clock: clock)
    }

    // MARK: - Teardown
    func tearDown() {
        sessionConnection?.tearDown()
        sessionConnection = nil
        if let recvRTCP {
            CFSocketInvalidate(recvRTCP)
            self.recvRTCP = nil
        }
        session = nil
    }

    // MARK: - Shutdown
    func shutdown() {
        tearDown()
        if let socket {
            CFSocketInvalidate(socket)
            self.socket = nil
        }
    }
}
