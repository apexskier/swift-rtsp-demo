import CoreFoundation
import CoreServices
import Foundation
import Network

@Observable
class RTSPServer {
    private var listener: CFSocket?
    private(set) var connections: [RTSPClientConnection] = []
    private(set) var configData: Data
    var bitrate: Int = 0
    let port: UInt16 = 554
    private let selfQueue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier!).RTSPServer.self")

    init?(configData: Data) {
        self.configData = configData
        var context = CFSocketContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        listener = CFSocketCreate(
            nil,
            PF_INET,
            SOCK_STREAM,
            IPPROTO_TCP,
            CFOptionFlags(CFSocketCallBackType.acceptCallBack.rawValue),
            { (s, callbackType, address, data, info) in
                guard let info = info else { return }
                let server = Unmanaged<RTSPServer>.fromOpaque(info).takeUnretainedValue()
                switch callbackType {
                case .acceptCallBack:
                    if let pH = data?.assumingMemoryBound(to: CFSocketNativeHandle.self) {
                        server.onAccept(childHandle: pH.pointee)
                    }
                default:
                    print("unexpected socket event")
                }
            },
            &context
        )
        guard let listener else { return nil }
        // must set SO_REUSEADDR in case a client is still holding this address
        var t: Int32 = 1
        setsockopt(
            CFSocketGetNative(listener),
            SOL_SOCKET,
            SO_REUSEADDR,
            &t,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let dataAddr = Data(bytes: &addr, count: MemoryLayout<sockaddr_in>.size)
        let cfDataAddr = dataAddr as CFData
        let e = CFSocketSetAddress(listener, cfDataAddr)
        if e != .success {
            print("bind error \(e.rawValue)")
            return nil
        }
        let rls = CFSocketCreateRunLoopSource(nil, listener, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), rls, .commonModes)
    }

    private func onAccept(childHandle: CFSocketNativeHandle) {
        guard let conn = RTSPClientConnection(socketHandle: childHandle, server: self) else {
            return
        }
        selfQueue.sync {
            print("Client connected")
            connections.append(conn)
        }
    }

    func onVideoData(_ data: [Data], time: Double) {
        selfQueue.sync {
            for conn in connections {
                conn.onVideoData(data, time: time)
            }
        }
    }

    func shutdownConnection(_ conn: RTSPClientConnection) {
        selfQueue.sync {
            print("Client disconnected")
            if let idx = connections.firstIndex(where: { $0 === conn }) {
                connections.remove(at: idx)
            }
        }
    }

    func shutdownServer() {
        selfQueue.sync {
            for conn in connections {
                conn.shutdown()
            }
            connections.removeAll(keepingCapacity: true)
            if let listener {
                CFSocketInvalidate(listener)
                self.listener = nil
            }
        }
    }

    static func getIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                let interface = ptr!.pointee
                let name = String(cString: interface.ifa_name)
                if name == "en0", interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                    var addr = interface.ifa_addr.pointee
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        &addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    address = String(cString: hostname)
                    break
                }
                ptr = interface.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
}
