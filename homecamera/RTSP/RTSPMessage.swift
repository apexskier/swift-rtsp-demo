import AVKit
import Foundation

// RTSPMessage: Parses RTSP requests and generates responses
// RFC 2326
struct RTSPMessage {
    let command: String
    private let sequence: Int
    let headers: [String: String]
    let body: String?
    let length: Int

    init?(_ data: Data) {
        guard let range = data.firstRange(of: "\r\n\r\n".utf8) else {
            print("msg parse error: no end of headers")
            return nil
        }

        guard let msg = String(data: data[data.startIndex..<range.lowerBound], encoding: .utf8)
        else {
            print("msg headers parse error: invalid UTF-8")
            return nil
        }
        var msgLines = msg.components(separatedBy: "\r\n")
        guard msgLines.count > 1,
            let request = msgLines.removeFirst().components(separatedBy: " ").first
        else {
            print("msg parse error: no request line")
            return nil
        }
        self.command = request
        self.headers = [String: String](
            uniqueKeysWithValues: msgLines.compactMap({ line -> (String, String)? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else {
                    print("msg parse error: invalid header line \(line)")
                    return nil
                }
                return (parts[0].lowercased(), parts[1].trimmingCharacters(in: .whitespaces))
            })
        )

        guard let strSeq = headers["cseq"] else {
            print("no cseq")
            return nil
        }
        guard let cseq = Int(strSeq) else {
            print("invalid cseq value")
            return nil
        }
        self.sequence = cseq

        if let strContentLen = headers["content-length"],
            let contentLength = Int(strContentLen)
        {
            self.body = String(
                data: data[range.upperBound..<range.upperBound.advanced(by: contentLength)],
                encoding: .utf8
            )
            self.length = (range.upperBound - data.startIndex) + contentLength
        } else {
            self.body = nil
            self.length = range.upperBound - data.startIndex
        }
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
}

extension RTSPMessage: CustomDebugStringConvertible {
    var debugDescription: String {
        headers.map { "\($0.key): \($0.value)" }
            .joined(separator: "\n") + "\n" + (body ?? "")
    }
}
