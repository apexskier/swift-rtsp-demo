import Foundation
import AVKit

// RTSPMessage: Parses RTSP requests and generates responses
struct RTSPMessage {
    private var lines: [String] = []
    var command: String
    var sequence: Int

    init?(data: Data) {
        guard let msg = String(data: data, encoding: .utf8) else {
            print("msg parse error: invalid UTF-8")
            return nil
        }
        self.lines = msg.components(separatedBy: "\r\n")
        // Must have at least request and one header
        guard lines.count >= 2 else {
            print("msg parse error")
            return nil
        }
        let lineOne = lines[0].components(separatedBy: " ")
        guard let request = lineOne.first else {
            print("msg parse error: no request")
            return nil
        }
        self.command = request
        guard let strSeq = RTSPMessage.extractValue(for: "CSeq", in: lines) else {
            print("no cseq")
            return nil
        }
        guard let cseq = Int(strSeq) else {
            print("invalid cseq value")
            return nil
        }
        self.sequence = cseq
    }

    // Find the value for a given RTSP header option (case-insensitive)
    func valueForOption(_ option: String) -> String? {
        RTSPMessage.extractValue(for: option, in: lines)
    }

    private static func extractValue(for option: String, in lines: [String]) -> String? {
        for i in 1..<lines.count {
            let line = lines[i]
            let comps = line.components(separatedBy: ":")
            if comps.count == 2 {
                if comps[0].caseInsensitiveCompare(option) == .orderedSame {
                    return comps[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    // Create a response string for the given code and description
    func createResponse(code: Int, text desc: String) -> [String] {
        ["RTSP/1.0 \(code) \(desc)", "CSeq: \(sequence)"]
    }

    // Objective-C factory method
    static func createWithData(_ data: CFData) -> RTSPMessage? {
        RTSPMessage(data: data as Data)
    }
}

extension RTSPMessage: CustomDebugStringConvertible {
    var debugDescription: String {
        lines.joined(separator: "\n")
    }
}
