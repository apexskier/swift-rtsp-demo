import CoreFoundation
import CoreServices
import Foundation
import Network
import Security

@Observable
class RTSPServer {
    struct Auth: Equatable {
        let username: String
        let password: String
    }

    private var listener: CFSocket?
    private(set) var connections: [RTSPClientConnection] = []
    private(set) var configData: Data
    private(set) var audioSampleRate: Int
    var bitrate: Int = 0
    // primary RTSP server port
    let port: UInt16 = 554
    private let selfQueue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier!).RTSPServer.self")
    var auth: Auth? {
        didSet {
            if let auth {
                auth.saveToKeychain()
            } else {
                Auth.deleteFromKeychain()
            }
            selfQueue.sync {
                for conn in connections {
                    conn.shutdown()
                }
            }
        }
    }

    init?(configData: Data, audioSampleRate: Int) {
        self.configData = configData
        self.audioSampleRate = audioSampleRate
        // primary RTSP server socket, TCP 554
        var context = CFSocketContext()
        context.info = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
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
                        server.onAccept(childHandle: pH.pointee, address: address)
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
        self.auth = Auth.loadFromKeychain()
    }

    func announce() {
        selfQueue.sync {
            for conn in connections {
                conn.announce()
            }
        }
    }

    private func onAccept(childHandle: CFSocketNativeHandle, address: CFData?) {
        guard
            let conn = RTSPClientConnection(
                socketHandle: childHandle,
                address: address,
                server: self
            )
        else {
            return
        }
        selfQueue.sync {
            print("Client connected: \(conn)")
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

    func onAudioData(_ data: Data, pts: Double) {
        selfQueue.sync {
            for conn in connections {
                conn.onAudioData(data, pts: pts)
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

extension RTSPServer.Auth {
    private static let service = "\(Bundle.main.bundleIdentifier!).BasicAuth.Service"
    private static let account = "\(Bundle.main.bundleIdentifier!).BasicAuth.Account"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func loadFromKeychain() -> Self? {
        let query: [String: Any] = baseQuery.merging([
            kSecReturnData as String: true,
        ]) { $1 }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
            let username = dict["username"],
            let password = dict["password"]
        else { return nil }
        return RTSPServer.Auth(username: username, password: password)
    }

    func saveToKeychain() {
        let dict = ["username": username, "password": password]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        SecItemDelete(Self.baseQuery as CFDictionary)
        let addQuery: [String: Any] = Self.baseQuery.merging([kSecValueData as String: data]) { $1 }
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func deleteFromKeychain() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
