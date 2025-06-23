import Combine
import CoreFoundation
import Foundation
import Network

private let maxPacketSize = 1200
private let rtpHeaderSize = 12
// 2_208_988_800 is a fixed offset from 1900 to 1970.
private let date1900 = Date(timeIntervalSince1970: -2_208_988_800)

private enum RTSPSessionState {
    case setup, playing
}

protocol RTSPSessionProto {
    func sendRTP(_ packet: Data)
    func sendRTCP(_ packet: Data)
    func tearDown()
    func transportDescription() -> String
}

struct RTPSessionInterleaved: RTSPSessionProto {
    let channelRTP: UInt8
    let channelRTCP: UInt8
    let socket: CFSocket
    let address: CFData

    func sendRTP(_ packet: Data) {
        CFSocketSendData(
            socket,
            address,
            Self.interleavePacket(packet, channel: channelRTP) as CFData,
            0
        )
    }

    func sendRTCP(_ packet: Data) {
        CFSocketSendData(
            socket,
            address,
            Self.interleavePacket(packet, channel: channelRTCP) as CFData,
            0
        )
    }

    func tearDown() {
        print("Tearing down \(self)")
    }

    func transportDescription() -> String {
        "RTP/AVP/TCP;unicast;interleaved=\(channelRTP)-\(channelRTCP)"
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
}

extension RTPSessionInterleaved: CustomDebugStringConvertible {
    var debugDescription: String {
        "RTPSessionInterleaved(channelRTP: \(channelRTP), channelRTCP: \(channelRTCP))"
    }
}

final class RTPSessionUDP: RTSPSessionProto {
    private let addressRTP: CFData
    private let socketRTP: CFSocket
    private let addressRTCP: CFData
    private let socketRTCP: CFSocket
    private var recvRTP: CFSocket?
    private var recvRTCP: CFSocket?
    private var rlsRTP: CFRunLoopSource?
    private var rlsRTCP: CFRunLoopSource?
    private let inboundAddressRTP: CFData?
    private var inboundAddressRTCP: CFData?

    // SessionWrapper is a persistent class used to allow calling out to the session for inbound traffic
    class SessionWrapper {
        weak var session: RTPSession?
    }

    var sessionWrapper = SessionWrapper()

    init(socket: CFSocket, rtp: UInt16, rtcp: UInt16) {
        guard let data = CFSocketCopyPeerAddress(socket) else {
            fatalError("No peer address for socketInbound")
        }
        var paddr = (data as Data).read(as: sockaddr_in.self)

        // RTP server -> client socket, UDP
        // reader reports received here
        paddr.sin_port = in_port_t(rtp.bigEndian)
        guard let addrRTP = CFDataCreate(nil, &paddr, MemoryLayout<sockaddr_in>.size) else {
            fatalError("Failed to create RTP address")
        }
        guard let socketRTP = CFSocketCreate(nil, PF_INET, SOCK_DGRAM, IPPROTO_UDP, 0, nil, nil)
        else {
            fatalError("Failed to create RTP socketInbound")
        }

        // RTCP server -> client socket, UDP
        paddr.sin_port = in_port_t(rtcp.bigEndian)
        guard let addrRTCP = CFDataCreate(nil, &paddr, MemoryLayout<sockaddr_in>.size) else {
            fatalError("Failed to create RTCP address")
        }
        guard
            let socketRTCP = CFSocketCreate(nil, PF_INET, SOCK_DGRAM, IPPROTO_UDP, 0, nil, nil)
        else {
            fatalError("Failed to create RTCP socket")
        }

        // RTP client -> server socket, UDP
        // reader reports received here
        var context = CFSocketContext()
        context.info = UnsafeMutableRawPointer(
            Unmanaged.passUnretained(sessionWrapper).toOpaque()
        )
        self.recvRTP = CFSocketCreate(
            nil,
            PF_INET,
            SOCK_DGRAM,
            IPPROTO_UDP,
            CFSocketCallBackType.dataCallBack.rawValue,
            { (s, callbackType, address, data, info) in
                guard let info else { return }
                let sessionWrapper = Unmanaged<SessionWrapper>.fromOpaque(info)
                    .takeUnretainedValue()
                switch callbackType {
                case .dataCallBack:
                    if let data {
                        sessionWrapper.session?
                            .onRTP(
                                Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data
                            )
                    }
                default:
                    print("unexpected socket event on receive RTP socket")
                }
            },
            &context
        )

        var addr = sockaddr_in()
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // random port
        let dataAddr = Data(bytes: &addr, count: MemoryLayout<sockaddr_in>.size) as CFData
        guard CFSocketSetAddress(self.recvRTP, dataAddr) == .success else {
            CFSocketInvalidate(self.recvRTP)
            fatalError("Failed to bind RTP socket")
        }

        guard let boundAddress = CFSocketCopyAddress(self.recvRTP) else {
            CFSocketInvalidate(self.recvRTP)
            fatalError("Failed to copy bound address for RTP socket")
        }

        self.inboundAddressRTP = boundAddress

        self.rlsRTP = CFSocketCreateRunLoopSource(nil, self.recvRTP, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), self.rlsRTP, .commonModes)

        // RTCP client -> server socket, UDP
        // reader reports received here
        self.recvRTCP = CFSocketCreate(
            nil,
            PF_INET,
            SOCK_DGRAM,
            IPPROTO_UDP,
            CFSocketCallBackType.dataCallBack.rawValue,
            { (s, callbackType, address, data, info) in
                guard let info else { return }
                let sessionWrapper = Unmanaged<SessionWrapper>.fromOpaque(info)
                    .takeUnretainedValue()
                switch callbackType {
                case .dataCallBack:
                    if let data {
                        // TODO: does this receive multiple RTCP packets in a single frame or not?
                        sessionWrapper.session?
                            .onRTCP(
                                Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data
                            )
                    }
                default:
                    print("unexpected socket event on receive RTCP socket")
                }
            },
            &context
        )

        guard CFSocketSetAddress(self.recvRTCP, dataAddr) == .success else {
            CFSocketInvalidate(self.recvRTCP)
            fatalError("Failed to bind RTCP socket")
        }

        guard let boundAddress = CFSocketCopyAddress(self.recvRTCP) else {
            CFSocketInvalidate(self.recvRTCP)
            fatalError("Failed to copy bound address for RTCP socket")
        }

        self.inboundAddressRTCP = boundAddress

        self.rlsRTCP = CFSocketCreateRunLoopSource(nil, self.recvRTCP, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), self.rlsRTCP, .commonModes)

        self.addressRTP = addrRTP
        self.socketRTP = socketRTP
        self.addressRTCP = addrRTCP
        self.socketRTCP = socketRTCP
    }

    func sendRTP(_ packet: Data) {
        CFSocketSendData(socketRTP, addressRTP, packet as CFData, 0)
    }

    func sendRTCP(_ packet: Data) {
        CFSocketSendData(
            socketRTCP,
            addressRTCP,
            packet as CFData,
            0
        )
    }

    func tearDown() {
        print("Tearing down \(self)")
        CFSocketInvalidate(socketRTP)
        CFSocketInvalidate(socketRTCP)
        CFSocketInvalidate(recvRTCP)
    }

    func transportDescription() -> String {
        let rtpPort = (addressRTP as Data)
            .withUnsafeBytes({
                $0.load(as: sockaddr_in.self)
            })
            .sin_port.bigEndian
        let rtcpPort = (addressRTCP as Data)
            .withUnsafeBytes({
                $0.load(as: sockaddr_in.self)
            })
            .sin_port.bigEndian
        guard
            let inboundRtpPort = (inboundAddressRTP as? Data)?
                .withUnsafeBytes({
                    $0.load(as: sockaddr_in.self)
                })
                .sin_port.bigEndian,
            let inboundRtcpPort = (inboundAddressRTCP as? Data)?
                .withUnsafeBytes({
                    $0.load(as: sockaddr_in.self)
                })
                .sin_port.bigEndian
        else {
            fatalError("No inbound address for RTP/RTCP")
        }

        return
            "RTP/AVP;unicast;client_port=\(rtpPort)-\(rtcpPort);server_port=\(inboundRtpPort)-\(inboundRtcpPort)"
    }
}

extension RTPSessionUDP: CustomDebugStringConvertible {
    var debugDescription: String {
        let rtpPort = (addressRTP as Data)
            .withUnsafeBytes({
                $0.load(as: sockaddr_in.self)
            })
            .sin_port.bigEndian
        let rtcpPort = (addressRTCP as Data)
            .withUnsafeBytes({
                $0.load(as: sockaddr_in.self)
            })
            .sin_port.bigEndian

        return "RTPSessionUDP(rtpPort: \(rtpPort), rtcpPort: \(rtcpPort))"
    }
}

final class RTPSession {
    let ssrc = UInt32.random(in: UInt32.min...UInt32.max)
    var packets = 0
    let sequenceNumber = UInt16.random(in: UInt16.min...UInt16.max)
    var bytesSent = 0
    var rtpBase: UInt64 = 0
    var ptsBase: Double = 0
    var ntpBase: UInt64 = 0
    private(set) var sourceDescription: String? = nil
    var sentRTCP: Date? = nil
    var packetsReported = 0
    var bytesReported = 0

    fileprivate var sessionConnection: RTSPSessionProto
    var receiverReports: PassthroughSubject<RRPacket.Block, Never>

    private let selfQueue = DispatchQueue(
        label: "\(Bundle.main.bundleIdentifier!).RTSPClientConnection.self"
    )

    fileprivate init(
        sessionConnection: RTSPSessionProto,
        receiverReports: PassthroughSubject<RRPacket.Block, Never>
    ) {
        self.sessionConnection = sessionConnection
        self.receiverReports = receiverReports
    }

    // RFC 3550, 5.1
    func writeHeader(
        _ packet: inout Data,
        marker bMarker: Bool,
        time pts: Double,
        payloadType: UInt8,
        clock: Int
    ) {
        assert(payloadType < 0b01111111, "Payload type must be less than 7 bits")
        packet[packet.startIndex] = 0b10_000000  // v=2, no padding, no extension, no CSRCs
        let marker: UInt8 = bMarker ? 0b10000000 : 0
        packet[packet.startIndex.advanced(by: 1)] = payloadType | marker

        packet.replace(
            at: 2,
            with: UInt16(truncatingIfNeeded: Int(sequenceNumber) + packets).bigEndian
        )

        if rtpBase == 0 {
            rtpBase = UInt64(UInt32.random(in: 1...UInt32.max))

            ptsBase = pts

            // ntp is based on 1900
            let interval = Date.now.timeIntervalSince(date1900)
            ntpBase = UInt64(interval * Double(1 << 32))
        }
        let rtp = UInt64((pts - ptsBase) * Double(clock)) + rtpBase
        print("\(rtp), \(self.sessionConnection)")
        packet.replace(
            at: packet.startIndex.advanced(by: 4),
            with: UInt32(truncatingIfNeeded: rtp).bigEndian
        )

        packet.replace(at: packet.startIndex.advanced(by: 8), with: ssrc.bigEndian)
    }

    func sendPacket(_ packet: Data) {
        selfQueue.sync {
            sessionConnection.sendRTP(packet)

            packets += 1
            bytesSent += packet.count

            let now = Date.now
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

                sessionConnection.sendRTCP(buf)

                sentRTCP = now
                packetsReported = packets
                bytesReported = bytesSent
            }
        }
    }

    func onRTP(_ data: Data) {
        // two packets like this are sent on connection by VLC macos UDP
        if data.elementsEqual([UInt8]([0xCE, 0xFA, 0xED, 0xFE])) {
            print("ignoring unknown RTCP packet: CEFAEDFE")
            return
        }
        print("C->S: RTP (\(sessionConnection.transportDescription()))")
    }

    func onRTCP(_ data: Data) {
        var ptr = data.startIndex
        while ptr < data.endIndex {
            // print(
            //     """
            //     C->S: RTCP (\(session ?? "no session"))
            //     """
            // )

            if let message = RTCPMessage(data: data[ptr...]) {
                ptr += Int(message.byteLength)

                switch message.packet {
                case .receiverReport(let rRPacket):
                    for block in rRPacket.blocks {
                        receiverReports.send(block)
                    }
                case .sourceDescription(let sDESPacket):
                    sourceDescription = sDESPacket.chunks.first?.text
                case .goodbye:
                    break
                default:
                    print("RTCP packet type \(message.type) not handled")
                }
            } else {
                print("RTCP packet parsing failed")
                return
            }
        }
    }

    func tearDown() {
        sessionConnection.tearDown()
    }

    func transportDescription() -> String {
        sessionConnection.transportDescription()
    }
}

@Observable
class RTSPClientConnection {
    private(set) var socketInbound: CFSocket?
    private weak var server: RTSPServer?
    private var rls: CFRunLoopSource?
    private var bFirst: Bool = true
    private let videoClock = 90000  // H264 clock frequency
    private(set) var sourceDescription: String? = nil
    private let selfQueue = DispatchQueue(
        label: "\(Bundle.main.bundleIdentifier!).RTSPClientConnection.self"
    )

    final class RTSPSession {
        fileprivate var state: RTSPSessionState = .setup
        var rtpSessions = [String: RTPSession]()
    }

    // map of RTSP Sesssion IDs to map of Stream IDs to RTPSession objects
    private var sessions = [String: RTSPSession]()

    private let videoPayloadType: UInt8 = 96
    private let videoStreamId = "streamid=1"

    public var receiverReports = PassthroughSubject<RRPacket.Block, Never>()

    init?(socketHandle: CFSocketNativeHandle, server: RTSPServer) {
        self.server = server

        // client -> server RTSP socket
        var context = CFSocketContext()
        context.info = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        self.socketInbound = CFSocketCreateWithNative(
            nil,
            socketHandle,
            CFSocketCallBackType.dataCallBack.rawValue,
            { (_, callbackType, address, data, info) in
                guard let info, let address else { return }

                let conn = Unmanaged<RTSPClientConnection>.fromOpaque(info).takeUnretainedValue()
                switch callbackType {
                case .dataCallBack:
                    if let data {
                        conn.onSocketData(
                            Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data,
                            address: address
                        )
                    }
                default:
                    print("unexpected socket event")
                }
            },
            &context
        )

        var t: Int32 = 1
        setsockopt(
            socketHandle,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &t,
            socklen_t(MemoryLayout<Int32>.size)
        )
        self.rls = CFSocketCreateRunLoopSource(nil, socketInbound, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), self.rls, .commonModes)
    }

    private var partialPacket: (data: Data, channel: UInt8, left: UInt16)?

    private func onInterleaved(channel: UInt8, data: Data) {
        for (_, rtspSession) in sessions {
            if rtspSession.state == .playing {
                for (_, rtpSession) in rtspSession.rtpSessions {
                    if let interleavedRtpSessionConnection = rtpSession
                        .sessionConnection as? RTPSessionInterleaved
                    {
                        switch channel {
                        case interleavedRtpSessionConnection.channelRTP:
                            rtpSession.onRTP(data)
                        case interleavedRtpSessionConnection.channelRTCP:
                            rtpSession.onRTCP(data)
                        default:
                            continue
                        }
                    }
                }
            }
        }
    }

    private func onSocketData(_ allData: Data, address: CFData) {
        if allData.isEmpty {
            shutdown()
            server?.shutdownConnection(self)
            return
        }

        var ptr = allData.startIndex
        while ptr < allData.endIndex {
            // possibilities here
            // - complete RTSP packet
            // - complete RTCP packet
            // - RTCP packet header, with remainder of data in next packet
            // - RTSP packet followed by RTCP packet
            // - multiple RTCP packets

            let data = allData[ptr...]

            if var partialPacket {
                // so far I've only seen interleaved packets as partial, so assume that
                partialPacket.data.append(contentsOf: data)
                if data.count < Int(partialPacket.left) {
                    partialPacket.left -= UInt16(data.count)
                } else {
                    onInterleaved(channel: partialPacket.channel, data: partialPacket.data)
                    self.partialPacket = nil
                }
                ptr += data.count
            } else if data[data.startIndex] == 0x24 {  // '$' indicates an RTSP interleaved frame
                let channel = data[data.startIndex + 1]  // channel number
                let length = data.read(at: data.startIndex + 2, as: UInt16.self).bigEndian
                let remainingDataCount = data.count - 4
                let interleavedData = data[data.startIndex.advanced(by: 4)...]
                if remainingDataCount < length {
                    partialPacket = (
                        interleavedData, channel, length - UInt16(interleavedData.count)
                    )
                } else {
                    onInterleaved(channel: channel, data: interleavedData)
                }
                ptr += 4 + Int(length)
            } else {
                // RTSP packet
                let len = handleRTSPPacket(data, address: address)
                ptr += len
            }
        }
    }

    private func handleRTSPPacket(_ data: Data, address: CFData) -> Int {
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
            if let localaddr = CFSocketCopyAddress(socketInbound) as? Data {
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
            if let firstParam = msg.commandParameters.first,
                let url = URL(string: firstParam)
            {
                let rtspSession =
                    msg.headers["session"] ?? "\(UInt32.random(in: UInt32.min...UInt32.max))"
                if sessions[rtspSession] == nil {
                    sessions[rtspSession] = .init()
                }
                guard let rtpSessions = sessions[rtspSession] else {
                    fatalError("No RTSP session found for \(rtspSession)")
                }

                let streamId = url.path().trimmingPrefix("/")
                if streamId != videoStreamId {
                    print("unknown stream id in setup: \(url.path())")
                    response = msg.createResponse(code: 404, text: "Stream ID not recognised")
                } else if rtpSessions.rtpSessions[String(streamId)] != nil {
                    response = msg.createResponse(code: 455, text: "Method not valid in this state")
                } else if let session = self.createRTPSession(msg: msg, address: address) {
                    rtpSessions.rtpSessions[String(streamId)] = session
                    print(
                        "Created RTPSession for stream \(streamId) in session \(rtspSession), \(session.sessionConnection)"
                    )
                    response = msg.createResponse(code: 200, text: "OK")
                    response += [
                        "Session: \(rtspSession)",
                        "Transport: \(session.transportDescription())",
                    ]
                }
            }
            if response.isEmpty {
                response = msg.createResponse(code: 451, text: "Need better error string here")
            }
        case "play":
            if let rtspSessionId = msg.headers["session"] {
                if let rtspSession = sessions[rtspSessionId] {
                    if rtspSession.state == .setup {
                        rtspSession.state = .playing
                        bFirst = true
                        response = msg.createResponse(code: 200, text: "OK")
                        print("Playing session \(rtspSessionId)")
                    } else {
                        response = msg.createResponse(code: 455, text: "Wrong state")
                        response.append("Allow: DESCRIBE, OPTIONS, SETUP")
                    }
                } else {
                    response = msg.createResponse(code: 454, text: "Session not found")
                }
            } else {
                response = msg.createResponse(code: 451, text: "Missing session header")
            }
        case "teardown":
            if let rtspSessionId = msg.headers["session"] {
                tearDown(rtspSessionId: rtspSessionId)
                response = msg.createResponse(code: 200, text: "OK")
            } else {
                response = msg.createResponse(code: 451, text: "Missing session header")
            }
        default:
            print("RTSP method \(cmd) not handled")
            response = msg.createResponse(code: 405, text: "Method not recognised")
            response.append("Allow: DESCRIBE, SETUP, TEARDOWN, PLAY, OPTIONS")
        }
        if !response.isEmpty,
            let responseData = (response.joined(separator: "\r\n") + "\r\n\r\n").data(using: .utf8)
        {
            // print(
            //     """
            //     S->C: (\(session ?? "no session"))
            //     > \(response.joined(separator: "\n> "))
            //     """
            // )
            CFSocketSendData(socketInbound, nil, responseData as CFData, 2)
        }
        return msg.length
    }

    private func createRTPSession(msg: RTSPMessage, address: CFData) -> RTPSession? {
        guard let socketInbound, let transport = msg.headers["transport"] else {
            return nil
        }

        let props = transport.components(separatedBy: ";")

        // first try to find a UDP transport
        if let ports = props.first(where: { $0.hasPrefix("client_port=") })?
            .dropFirst(12)
            .components(separatedBy: "-"), ports.count == 2,
            let portRTP = UInt16(ports[0]),
            let portRTCP = UInt16(ports[1])
        {
            let sessionConnection = RTPSessionUDP(
                socket: socketInbound,
                rtp: portRTP,
                rtcp: portRTCP
            )
            let session = RTPSession(
                sessionConnection: sessionConnection,
                receiverReports: receiverReports
            )
            sessionConnection.sessionWrapper.session = session
            return session
        }

        // then try to find an interleaved transport
        if let channels = props.first(where: { $0.hasPrefix("interleaved=") })?
            .dropFirst(12)
            .components(separatedBy: "-")
            .compactMap(UInt8.init),
            let channelRTP = channels.first
        {
            return RTPSession(
                sessionConnection: RTPSessionInterleaved(
                    channelRTP: channelRTP,
                    channelRTCP: channels.count > 1 ? channels[1] : (channelRTP + 1),
                    socket: socketInbound,
                    address: address
                ),
                receiverReports: receiverReports
            )
        }

        print("No suitable transport found in RTSP SETUP")
        return nil
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

        guard let dlocaladdr = CFSocketCopyAddress(socketInbound) else {
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
            "m=video 0 RTP/AVP \(videoPayloadType)",
            "b=TIAS:\(server.bitrate)",
            "a=maxprate:\(packets).0000",
            "a=control:\(videoStreamId)",
            "a=rtpmap:\(videoPayloadType) H264/\(videoClock)",
            "a=mimetype:string;\"video/H264\"",
            "a=framesize:\(videoPayloadType) \(cx)-\(cy)",
            "a=Width:integer;\(cx)",
            "a=Height:integer;\(cy)",
            "a=fmtp:\(videoPayloadType) packetization-mode=1;profile-level-id=\(profileLevelID);sprop-parameter-sets=\(spsBase64),\(ppsBase64)",
        ]
    }

    func onVideoData(_ data: [Data], time pts: Double) {
        for (rtspSessionId, rtspSession) in sessions {
            guard rtspSession.state == .playing,
                let rtpSession = rtspSession.rtpSessions[videoStreamId]
            else { continue }
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
                    print("Playback starting at first IDR \(rtspSessionId)")
                }
                if countBytes < maxSinglePacket {
                    var packet = Data(count: maxPacketSize)

                    rtpSession.writeHeader(
                        &packet,
                        marker: bLast,
                        time: pts,
                        payloadType: videoPayloadType,
                        clock: videoClock
                    )
                    packet.replaceSubrange(
                        packet.startIndex.advanced(by: rtpHeaderSize)...,
                        with: nalu
                    )
                    rtpSession.sendPacket(
                        packet[
                            packet
                                .startIndex..<packet.startIndex.advanced(
                                    by: countBytes + rtpHeaderSize
                                )
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
                        rtpSession.writeHeader(
                            &packet,
                            marker: bLast && bEnd,
                            time: pts,
                            payloadType: videoPayloadType,
                            clock: videoClock
                        )

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
                        rtpSession.sendPacket(
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
    }

    private func tearDown(rtspSessionId: String) {
        guard let rtspSession = sessions[rtspSessionId] else {
            return
        }
        print("Tearing down RTSP session \(rtspSessionId)")
        for (_, rtpSession) in rtspSession.rtpSessions {
            rtpSession.tearDown()
        }
        sessions.removeValue(forKey: rtspSessionId)
    }

    func shutdown() {
        for rtspSessionId in sessions.keys {
            tearDown(rtspSessionId: rtspSessionId)
        }
        CFSocketInvalidate(socketInbound)
    }
}
