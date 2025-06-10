//
//  RTSPServer.swift
//  Encoder Demo
//
//  Created by Geraint Davies on 17/01/2013.
//  Copyright (c) 2013 GDCL http://www.gdcl.co.uk/license.htm
//


import Darwin
import Foundation
import CoreFoundation
import Network

// TODO: use built-in
@inline(__always)
func htons(_ value: UInt16) -> UInt16 {
    (value << 8) | (value >> 8)
}

final class RTSPServer: NSObject {

    // MARK: - Properties

    private var listener: CFSocket?
    private var connections: [RTSPClientConnection] = []
    private var configData: Data
    @objc dynamic var bitrate: Int

    // MARK: - Setup

    static func setupListener(_ configData: Data) -> RTSPServer? {
        let obj = RTSPServer(configData: configData)
        guard obj.initListener() else {
            return nil
        }
        return obj
    }

    private init(configData: Data) {
        self.configData = configData
        self.bitrate = 0
        super.init()
    }

    private func initListener() -> Bool {
        var info = CFSocketContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil, release: nil, copyDescription: nil
        )

        listener = CFSocketCreate(
            nil,
            PF_INET,
            SOCK_STREAM,
            IPPROTO_TCP,
            CFSocketCallBackType.acceptCallBack.rawValue,
            { (s, callbackType, address, data, info) in
                let server = Unmanaged<RTSPServer>.fromOpaque(info!).takeUnretainedValue()
                switch callbackType {
                case .acceptCallBack:
                    if let data = data {
                        let pHandle = data.bindMemory(to: CFSocketNativeHandle.self, capacity: 1)
                        server.onAccept(pHandle.pointee)
                    }
                default:
                    print("unexpected socket event")
                }
            },
            &info
        )

        guard let listener = listener else { return false }

        // Set SO_REUSEADDR
        var t: Int32 = 1
        setsockopt(CFSocketGetNative(listener), SOL_SOCKET, SO_REUSEADDR, &t, socklen_t(MemoryLayout<Int32>.size))

        // Prepare sockaddr_in
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(htons(554))
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let addrData = Data(bytes: &addr, count: MemoryLayout<sockaddr_in>.size) as CFData
        let bindResult = CFSocketSetAddress(listener, addrData)
        if bindResult != .success {
            print("bind error \(bindResult.rawValue)")
        }

        // Add to runloop
        let rls = CFSocketCreateRunLoopSource(nil, listener, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), rls, .commonModes)

        return true
    }

    // MARK: - Public API

    func getConfigData() -> Data {
        return configData
    }

    func onVideoData(_ data: [Data], time pts: Double) {
        objc_sync_enter(self)
        for conn in connections {
            conn.onVideoData(data, time: pts)
        }
        objc_sync_exit(self)
    }

    func shutdownConnection(_ conn: AnyObject) {
        objc_sync_enter(self)
        print("Client disconnected")
        connections.removeAll { $0 === conn as AnyObject }
        objc_sync_exit(self)
    }

    func shutdownServer() {
        objc_sync_enter(self)
        for conn in connections {
            conn.shutdown()
        }
        connections.removeAll()
        if let listener = listener {
            CFSocketInvalidate(listener)
            self.listener = nil
        }
        objc_sync_exit(self)
    }

    // MARK: - Accept Callback

    private func onAccept(_ childHandle: CFSocketNativeHandle) {
        if let conn = RTSPClientConnection.createWithSocket(childHandle, server: self) {
            objc_sync_enter(self)
            print("Client connected")
            connections.append(conn)
            objc_sync_exit(self)
        }
    }

    // MARK: - IP Address

    static func getIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                let interface = ptr!.pointee
                let name = String(cString: interface.ifa_name)
                if name == "en0", interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                    let sa = unsafeBitCast(interface.ifa_addr, to: UnsafePointer<sockaddr_in>.self)
                    address = String(cString: inet_ntoa(sa.pointee.sin_addr))
                    break
                }
                ptr = interface.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
}
