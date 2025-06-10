//
//  RTSPMessage.swift
//  Encoder Demo
//
//  Created by Geraint Davies on 24/01/2013.
//  Copyright (c) 2013 GDCL http://www.gdcl.co.uk/license.htm
//

import Foundation

final class RTSPMessage {

    // MARK: - Properties

    private var lines: [String] = []
    private(set) var command: String = ""
    private(set) var sequence: Int = 0

    // MARK: - Initializer

    private init?(data: Data) {
        guard let msg = String(data: data, encoding: .utf8) else { return nil }
        self.lines = msg.components(separatedBy: "\r\n")
        guard lines.count >= 2 else {
            print("msg parse error")
            return nil
        }
        let lineone = lines[0].components(separatedBy: " ")
        guard lineone.count >= 1 else { return nil }
        self.command = lineone[0]

        guard let strSeq = valueForOption("CSeq"), let seq = Int(strSeq) else {
            print("no cseq")
            return nil
        }
        self.sequence = seq
    }

    // MARK: - Factory

    static func create(with data: CFData) -> RTSPMessage? {
        return RTSPMessage(data: data as Data)
    }

    // MARK: - Methods

    func valueForOption(_ option: String) -> String? {
        for i in 1..<lines.count {
            let line = lines[i]
            let comps = line.components(separatedBy: ":")
            if comps.count == 2 {
                if comps[0].caseInsensitiveCompare(option) == .orderedSame {
                    let val = comps[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    return val
                }
            }
        }
        return nil
    }

    func createResponse(code: Int, text desc: String) -> String {
        "RTSP/1.0 \(code) \(desc)\r\nCSeq: \(self.sequence)\r\n"
    }
}

extension RTSPMessage: CustomStringConvertible {
    var description: String {
        return lines.joined(separator: "\r\n")
    }
}
