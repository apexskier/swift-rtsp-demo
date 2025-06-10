//
//  RTSPClientConnection.swift
//  Encoder Demo
//
//  Created by Geraint Davies on 24/01/2013.
//  Copyright (c) 2013 GDCL http://www.gdcl.co.uk/license.htm
//

import CoreFoundation
import Foundation

// Helper functions for network byte order
private func tonet_short(_ p: UnsafeMutablePointer<UInt8>, _ s: UInt16) {
    p[0] = UInt8((s >> 8) & 0xff)
    p[1] = UInt8(s & 0xff)
}
private func tonet_long(_ p: UnsafeMutablePointer<UInt8>, _ l: UInt32) {
    p[0] = UInt8((l >> 24) & 0xff)
    p[1] = UInt8((l >> 16) & 0xff)
    p[2] = UInt8((l >> 8) & 0xff)
    p[3] = UInt8(l & 0xff)
}

// Base64 encoding helpers (manual)
private let Base64Mapping = Array(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
)
private let max_packet_size = 1200

private func encodeLong(_ val: UInt32, nPad: Int) -> String {
    var ch = [UInt8](repeating: 0, count: 4)
    let cch = 4 - nPad
    for i in 0..<cch {
        let shift = 6 * (cch - (i + 1))
        let bits = Int((val >> shift) & 0x3f)
        ch[i] = Base64Mapping[bits]
    }
    for i in 0..<nPad {
        ch[cch + i] = UInt8(ascii: "=")
    }
    return String(bytes: ch, encoding: .utf8) ?? ""
}
private func encodeToBase64(_ data: Data) -> String {
    var s = ""
    let p = [UInt8](data)
    var idx = 0
    var cBytes = data.count
    while cBytes >= 3 {
        let val = (UInt32(p[idx]) << 16) | (UInt32(p[idx + 1]) << 8) | UInt32(p[idx + 2])
        s += encodeLong(val, nPad: 0)
        idx += 3
        cBytes -= 3
    }
    if cBytes > 0 {
        let nPad: Int
        let val: UInt32
        if cBytes == 1 {
            nPad = 2
            val = UInt32(p[idx]) << 4
        } else {
            nPad = 1
            val = (UInt32(p[idx]) << 8 | UInt32(p[idx + 1])) << 2
        }
        s += encodeLong(val, nPad: nPad)
    }
    return s
}

private enum ServerState {
    case idle, setup, playing
}

// MARK: - RTSPClientConnection

final class RTSPClientConnection: NSObject {
    // MARK: - Properties

    private var s: CFSocket?
    private weak var server: RTSPServer?
    private var rls: CFRunLoopSource?
    private var addrRTP: CFData?
    private var sRTP: CFSocket?
    private var addrRTCP: CFData?
    private var sRTCP: CFSocket?
    private var session: String?
    private var state: ServerState = .idle
    private var packets: Int64 = 0
    private var bytesSent: Int64 = 0
    private var ssrc: UInt32 = 0
    private var bFirst: Bool = false

    // time mapping using NTP
    private var ntpBase: UInt64 = 0
    private var rtpBase: UInt64 = 0
    private var ptsBase: Double = 0

    // RTCP stats
    private var packetsReported: Int64 = 0
    private var bytesReported: Int64 = 0
    private var sentRTCP: Date?

    // reader reports
    private var recvRTCP: CFSocket?
    private var rlsRTCP: CFRunLoopSource?

    // MARK: - Creation

    static func createWithSocket(
        _ s: CFSocketNativeHandle,
        server: RTSPServer
    ) -> RTSPClientConnection? {
        let conn = RTSPClientConnection()
        if conn.initWithSocket(s, server: server) {
            return conn
        }
        return nil
    }

    private func initWithSocket(_ sock: CFSocketNativeHandle, server: RTSPServer) -> Bool {
        self.state = .idle
        self.server = server
        var info = CFSocketContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        self.s = CFSocketCreateWithNative(
            nil,
            sock,
            CFSocketCallBackType.dataCallBack.rawValue,
            RTSPClientConnection.onSocket,
            &info
        )
        guard let s = self.s else { return false }
        self.rls = CFSocketCreateRunLoopSource(nil, s, 0)
        if let rls = self.rls {
            CFRunLoopAddSource(CFRunLoopGetMain(), rls, .commonModes)
        }
        return true
    }

    // MARK: - Socket Callbacks

    private static let onSocket: CFSocketCallBack = { (s, callbackType, address, data, info) in
        guard let info else {
            fatalError("CFSocket context info is nil")
        }
        let conn = Unmanaged<RTSPClientConnection>.fromOpaque(info).takeUnretainedValue()
        switch callbackType {
        case .dataCallBack:
            conn.onSocketData(data: data)
        default:
            print("unexpected socket event")
        }
    }

    private static let onRTCP: CFSocketCallBack = { (s, callbackType, address, data, info) in
        guard let info else {
            fatalError("CFSocket context info is nil")
        }
        let conn = Unmanaged<RTSPClientConnection>.fromOpaque(info).takeUnretainedValue()
        switch callbackType {
        case .dataCallBack:
            conn.onRTCP(data: data)
        default:
            print("unexpected socket event")
        }
    }

    // MARK: - Main Socket Data Handler

    private func onSocketData(data: UnsafeRawPointer?) {
        guard let data = data else { return }
        let cfData = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue()
        if CFDataGetLength(cfData) == 0 {
            tearDown()
            if let s = self.s {
                CFSocketInvalidate(s)
                self.s = nil
            }
            server?.shutdownConnection(self)
            return
        }
        guard let msg = RTSPMessage.create(with: cfData) else { return }
        print("CLIENT -> SERVER")
        print("> " + msg.description.split(separator: "\r\n").joined(separator: "\n> "))
        var response: String?
        let cmd = msg.command.lowercased()
        switch cmd {
        case "options":
            response =
                msg.createResponse(code: 200, text: "OK")
                + "Server: AVEncoderDemo/1.0\r\n"
                + "Public: DESCRIBE, SETUP, TEARDOWN, PLAY, OPTIONS\r\n\r\n"
        case "describe":
            let sdp = makeSDP()
            let date = DateFormatter.localizedString(
                from: Date(),
                dateStyle: .long,
                timeStyle: .long
            )
            let dlocaladdr = CFSocketCopyAddress(s!)
            let localaddr = CFDataGetBytePtr(dlocaladdr)
            var ipString = "127.0.0.1"
            if let localaddr {
                let sockaddr = UnsafeRawPointer(localaddr).assumingMemoryBound(to: sockaddr_in.self)
                ipString = String(cString: inet_ntoa(sockaddr.pointee.sin_addr))
            }
            response =
                msg.createResponse(code: 200, text: "OK")
                + "Content-base: rtsp://\(ipString)/\r\n"
                + "Date: \(date)\r\nContent-Type: application/sdp\r\nContent-Length: \(sdp.count)\r\n\r\n"
                + sdp
        case "setup":
            guard let transport = msg.valueForOption("transport") else { break }
            let props = transport.components(separatedBy: ";")
            var ports: [String]? = nil
            for s in props {
                if s.count > 14, s.hasPrefix("client_port=") {
                    let val = String(s.dropFirst(12))
                    ports = val.components(separatedBy: "-")
                    break
                }
            }
            if let ports, ports.count == 2,
                let portRTP = Int(ports[0]),
                let portRTCP = Int(ports[1])
            {
                if let sessionName = createSession(portRTP: portRTP, portRTCP: portRTCP) {
                    response =
                        msg.createResponse(code: 200, text: "OK")
                        + "Session: \(sessionName)\r\nTransport: RTP/AVP;unicast;client_port=\(portRTP)-\(portRTCP);server_port=6970-6971\r\n\r\n"
                }
            }
            if response == nil {
                response = msg.createResponse(code: 451, text: "Need better error string here")
            }
        case "play":
            objc_sync_enter(self)
            if state != .setup {
                response = msg.createResponse(code: 451, text: "Wrong state")
            } else {
                state = .playing
                bFirst = true
                response =
                    msg.createResponse(code: 200, text: "OK")
                    + "Session: \(session ?? "")\r\n\r\n"
            }
            objc_sync_exit(self)
        case "teardown":
            tearDown()
            response = msg.createResponse(code: 200, text: "OK")
        default:
            print("RTSP method \(cmd) not handled")
            response = msg.createResponse(code: 451, text: "Method not recognised")
        }
        if let response, let dataResponse = response.data(using: .utf8) {
            print("SERVER -> CLIENT")
            print("> " + response.split(separator: "\r\n").joined(separator: "\n> "))
            let e = CFSocketSendData(s, nil, dataResponse as CFData, 2)
            if e != .success {
                print("send \(e.rawValue)")
            }
        }
    }

    // MARK: - SDP/Session

    private func makeSDP() -> String {
        guard let config = server?.getConfigData() else { return "" }
        let avcC = config.withUnsafeBytes {
            avcCHeader(
                header: $0.baseAddress!.assumingMemoryBound(to: UInt8.self),
                cBytes: config.count
            )
        }
        let seqParams = SeqParamSet()
        _ = seqParams.Parse(avcC.sps)
        let cx = seqParams.EncodedWidth()
        let cy = seqParams.EncodedHeight()
        let profile_level_id = String(
            format: "%02x%02x%02x",
            seqParams.Profile,
            seqParams.Compatibility,
            seqParams.Level
        )
        let sps = encodeToBase64(Data(bytes: avcC.sps.start()!, count: avcC.sps.length()))
        let pps = encodeToBase64(Data(bytes: avcC.pps.start()!, count: avcC.pps.length()))
        let verid = UInt32.random(in: 0..<UInt32.max)
        let dlocaladdr = CFSocketCopyAddress(s!)
        let localaddr = CFDataGetBytePtr(dlocaladdr)
        var ipString = "127.0.0.1"
        if let localaddr = localaddr {
            let sockaddr = UnsafeRawPointer(localaddr).assumingMemoryBound(to: sockaddr_in.self)
            ipString = String(cString: inet_ntoa(sockaddr.pointee.sin_addr))
        }
        let bitrate = server?.bitrate ?? 0
        let packets = bitrate / (max_packet_size * 8) + 1
        var sdp =
            "v=0\r\no=- \(verid) \(verid) IN IP4 \(ipString)\r\ns=Live stream from iOS\r\nc=IN IP4 0.0.0.0\r\nt=0 0\r\na=control:*\r\n"
        sdp +=
            "m=video 0 RTP/AVP 96\r\nb=TIAS:\(bitrate)\r\na=maxprate:\(packets).0000\r\na=control:streamid=1\r\n"
        sdp +=
            "a=rtpmap:96 H264/90000\r\na=mimetype:string;\"video/H264\"\r\na=framesize:96 \(cx)-\(cy)\r\na=Width:integer;\(cx)\r\na=Height:integer;\(cy)\r\n"
        sdp +=
            "a=fmtp:96 packetization-mode=1;profile-level-id=\(profile_level_id);sprop-parameter-sets=\(sps),\(pps)\r\n"
        return sdp
    }

    private func createSession(portRTP: Int, portRTCP: Int) -> String? {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        guard let s = self.s else { return nil }
        guard let data = CFSocketCopyPeerAddress(s) else { return nil }
        let paddr = UnsafeMutablePointer<sockaddr_in>.allocate(capacity: 1)
        defer { paddr.deallocate() }
        memcpy(paddr, CFDataGetBytePtr(data), MemoryLayout<sockaddr_in>.size)
        paddr.pointee.sin_port = in_port_t(htons(UInt16(portRTP)))
        self.addrRTP = CFDataCreate(
            nil,
            UnsafePointer<UInt8>(OpaquePointer(paddr)),
            MemoryLayout<sockaddr_in>.size
        )
        self.sRTP = CFSocketCreate(nil, PF_INET, SOCK_DGRAM, IPPROTO_UDP, 0, nil, nil)
        paddr.pointee.sin_port = in_port_t(htons(UInt16(portRTCP)))
        self.addrRTCP = CFDataCreate(
            nil,
            UnsafePointer<UInt8>(OpaquePointer(paddr)),
            MemoryLayout<sockaddr_in>.size
        )
        self.sRTCP = CFSocketCreate(nil, PF_INET, SOCK_DGRAM, IPPROTO_UDP, 0, nil, nil)
        var info = CFSocketContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        self.recvRTCP = CFSocketCreate(
            nil,
            PF_INET,
            SOCK_DGRAM,
            IPPROTO_UDP,
            CFSocketCallBackType.dataCallBack.rawValue,
            RTSPClientConnection.onRTCP,
            &info
        )
        var addr = sockaddr_in()
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(htons(6971))
        let dataAddr = CFDataCreate(
            nil,
            UnsafeRawPointer(&addr).assumingMemoryBound(to: UInt8.self),
            MemoryLayout<sockaddr_in>.size
        )
        CFSocketSetAddress(self.recvRTCP, dataAddr)
        self.rlsRTCP = CFSocketCreateRunLoopSource(nil, self.recvRTCP, 0)
        if let rlsRTCP = self.rlsRTCP {
            CFRunLoopAddSource(CFRunLoopGetMain(), rlsRTCP, .commonModes)
        }
        let sessionid = UInt32.random(in: 0..<UInt32.max)
        self.session = "\(sessionid)"
        self.state = .setup
        self.ssrc = UInt32.random(in: 0..<UInt32.max)
        self.packets = 0
        self.bytesSent = 0
        self.rtpBase = 0
        self.sentRTCP = nil
        self.packetsReported = 0
        self.bytesReported = 0
        return self.session
    }

    // MARK: - Video Data

    func onVideoData(_ data: [Data], time pts: Double) {
        objc_sync_enter(self)
        let inPlaying = self.state == .playing
        objc_sync_exit(self)
        if !inPlaying { return }

        let rtp_header_size = 12
        let max_single_packet = max_packet_size - rtp_header_size
        let max_fragment_packet = max_single_packet - 2
        var packet = [UInt8](repeating: 0, count: max_packet_size)

        let nNALUs = data.count
        for i in 0..<nNALUs {
            let nalu = data[i]
            var cBytes = nalu.count
            let bLast = (i == nNALUs - 1)
            let pSource = [UInt8](nalu)
            if bFirst {
                if (pSource[0] & 0x1f) != 5 {
                    continue
                }
                bFirst = false
                print("Playback starting at first IDR")
            }
            if cBytes < max_single_packet {
                writeHeader(&packet, marker: bLast, time: pts)
                packet.withUnsafeMutableBufferPointer { buffer in
                    nalu.copyBytes(to: buffer.baseAddress! + rtp_header_size, count: cBytes)
                }
                sendPacket(packet, length: cBytes + rtp_header_size)
            } else {
                var NALU_Header = pSource[0]
                var sourceIdx = 1
                cBytes -= 1
                var bStart = true
                while cBytes > 0 {
                    let cThis = min(cBytes, max_fragment_packet)
                    let bEnd = (cThis == cBytes)
                    writeHeader(&packet, marker: bLast && bEnd, time: pts)
                    var pDest = rtp_header_size
                    packet[pDest] = (NALU_Header & 0xe0) + 28  // FU_A type
                    var fu_header = NALU_Header & 0x1f
                    if bStart {
                        fu_header |= 0x80
                        bStart = false
                    } else if bEnd {
                        fu_header |= 0x40
                    }
                    packet[pDest + 1] = fu_header
                    pDest += 2
                    for j in 0..<cThis {
                        packet[pDest + j] = pSource[sourceIdx + j]
                    }
                    sendPacket(packet, length: pDest + cThis)
                    sourceIdx += cThis
                    cBytes -= cThis
                }
            }
        }
    }

    private func writeHeader(_ packet: inout [UInt8], marker bMarker: Bool, time pts: Double) {
        packet[0] = 0x80
        packet[1] = bMarker ? 96 | 0x80 : 96
        let seq = UInt16(truncatingIfNeeded: packets)
        tonet_short(&packet + 2, seq)
        while rtpBase == 0 {
            rtpBase = UInt64.random(in: 0..<UInt64.max)
            ptsBase = pts
            let now = Date()
            // ntp is based on 1900. There's a known fixed offset from 1900 to 1970.
            let ref = Date(timeIntervalSince1970: -2_208_988_800)
            let interval = now.timeIntervalSince(ref)
            ntpBase = UInt64(interval * Double(1 << 32))
        }
        var ptsVal = pts - ptsBase
        var rtp: UInt64 = UInt64(ptsVal * 90000)
        rtp += rtpBase
        tonet_long(&packet + 4, UInt32(truncatingIfNeeded: rtp))
        tonet_long(&packet + 8, ssrc)
    }

    private func sendPacket(_ packet: [UInt8], length cBytes: Int) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        if let sRTP = sRTP, let addrRTP = addrRTP {
            let data = CFDataCreate(nil, packet, cBytes)
            CFSocketSendData(sRTP, addrRTP, data, 0)
        }
        packets += 1
        bytesSent += Int64(cBytes)
        let now = Date()
        if sentRTCP == nil || now.timeIntervalSince(sentRTCP!) >= 1 {
            var buf = [UInt8](repeating: 0, count: 7 * MemoryLayout<UInt32>.size)
            buf[0] = 0x80
            buf[1] = 200
            tonet_short(&buf + 2, 6)
            tonet_long(&buf + 4, ssrc)
            tonet_long(&buf + 8, UInt32(ntpBase >> 32))
            tonet_long(&buf + 12, UInt32(ntpBase))
            tonet_long(&buf + 16, UInt32(rtpBase))
            tonet_long(&buf + 20, UInt32(packets - packetsReported))
            tonet_long(&buf + 24, UInt32(bytesSent - bytesReported))
            let lenRTCP = 28
            if let sRTCP = sRTCP, let addrRTCP = addrRTCP {
                let dataRTCP = CFDataCreate(nil, buf, lenRTCP)
                CFSocketSendData(sRTCP, addrRTCP, dataRTCP, 0)
            }
            sentRTCP = now
            packetsReported = packets
            bytesReported = bytesSent
        }
    }

    private func onRTCP(data: UnsafeRawPointer?) {
        // RTCP receive logic placeholder
    }

    private func tearDown() {
        objc_sync_enter(self)
        if let sRTP = sRTP {
            CFSocketInvalidate(sRTP)
            self.sRTP = nil
        }
        if let sRTCP = sRTCP {
            CFSocketInvalidate(sRTCP)
            self.sRTCP = nil
        }
        if let recvRTCP = recvRTCP {
            CFSocketInvalidate(recvRTCP)
            self.recvRTCP = nil
        }
        session = nil
        objc_sync_exit(self)
    }

    func shutdown() {
        tearDown()
        objc_sync_enter(self)
        if let s = s {
            CFSocketInvalidate(s)
            self.s = nil
        }
        objc_sync_exit(self)
    }
}
