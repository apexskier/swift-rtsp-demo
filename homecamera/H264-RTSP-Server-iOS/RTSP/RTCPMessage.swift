//
//  RTCPMessage.swift
//  homecamera
//
//  Created by Cameron Little on 2025-06-16.
//

import Foundation

/// Type of an RTCP packet
/// RTCP packet types registered with IANA. See: https://www.iana.org/assignments/rtp-parameters/rtp-parameters.xhtml#rtp-parameters-4
enum PacketType: UInt8, RawRepresentable {
    case unsupported = 0
    case senderReport = 200  // RFC 3550, 6.4.1
    case receiverReport = 201  // RFC 3550, 6.4.2
    case sourceDescription = 202  // RFC 3550, 6.5
    case goodbye = 203  // RFC 3550, 6.6
    case applicationDefined = 204  // RFC 3550, 6.7
    case transportSpecificFeedback = 205  // RFC 4585, 6051
    case payloadSpecificFeedback = 206  // RFC 4585, 6.3
    case extendedReport = 207  // RFC 3611
}

extension PacketType: CustomDebugStringConvertible {
    var debugDescription: String {
        switch self {
        case .unsupported:
            return "Unsupported"
        case .senderReport:
            return "SR"
        case .receiverReport:
            return "RR"
        case .sourceDescription:
            return "SDES"
        case .goodbye:
            return "BYE"
        case .applicationDefined:
            return "APP"
        case .transportSpecificFeedback:
            return "TSFB"
        case .payloadSpecificFeedback:
            return "PSFB"
        case .extendedReport:
            return "XR"
        }
    }
}

enum SDESItemType: UInt8, RawRepresentable {
    case cname = 1  // RFC3 550, 6.5.1
    case name = 2  // RFC3 550, 6.5.2
    case email = 3  // RFC3 550, 6.5.3
    case phone = 4  // RFC3 550, 6.5.4
    case loc = 5  // RFC3 550, 6.5.5
    case tool = 6  // RFC3 550, 6.5.6
    case note = 7  // RFC3 550, 6.5.7
    case privateItem = 8  // RFC3 550, 6.5.8
}

extension SDESItemType: CustomDebugStringConvertible {
    var debugDescription: String {
        switch self {
        case .cname:
            return "CNAME"
        case .name:
            return "NAME"
        case .email:
            return "EMAIL"
        case .phone:
            return "PHONE"
        case .loc:
            return "LOC"
        case .tool:
            return "TOOL"
        case .note:
            return "NOTE"
        case .privateItem:
            return "PRIV"
        }
    }
}

struct RRPacket {
    init?(count: UInt8, data: Data) {
        var ptr = data.startIndex
        for i in 0..<count {
            let ssrc_r = data.read(at: ptr, as: UInt32.self).bigEndian
            let fractionLost = Double(data.read(at: ptr + 4, as: UInt8.self).bigEndian) / 256.0
            let t0 = data.read(at: ptr + 5, as: UInt8.self).bigEndian
            let t1 = data.read(at: ptr + 6, as: UInt8.self).bigEndian
            let t2 = data.read(at: ptr + 7, as: UInt8.self).bigEndian
            // > The total number of RTP data packets from source SSRC_n that have
            // > been lost since the beginning of reception.  This number is
            // > defined to be the number of packets expected less the number of
            // > packets actually received, where the number of packets received
            // > includes any which are late or duplicates.  Thus, packets that
            // > arrive late are not counted as lost, and the loss may be negative
            // > if there are duplicates.  The number of packets expected is
            // > defined to be the extended last sequence number received, as
            // > defined next, less the initial sequence number received.  This may
            // > be calculated as shown in Appendix A.3.
            let totalLost: UInt32 = UInt32(t2) | UInt32(t1) << 8 | UInt32(t0) << 16

            let lastSequenceNumber = data.read(at: ptr + 8, as: UInt32.self).bigEndian
            let jitter =
                Double(data.read(at: ptr + 12, as: UInt32.self).bigEndian) / Double(90000)
            let lastSenderReport = data.read(at: ptr + 16, as: UInt32.self).bigEndian
            let delay = data.read(at: ptr + 20, as: UInt32.self).bigEndian

            print(
                """
                Receiver Report \(i + 1):
                -fractionLost: \(fractionLost)
                -jitter: \(jitter) seconds
                """
            )
            ptr += 24
        }
    }
}

struct SDESPacket {
    init?(count: UInt8, data: Data) {
        var ptr = data.startIndex
        // RFC 3550 6.5
        for i in 0..<count {
            let chunkSsrc = data.read(at: ptr, as: UInt32.self).bigEndian
            let chunkType = data.read(at: ptr + 4, as: UInt8.self)
            let chunkLength = data.read(at: ptr + 5, as: UInt8.self)
            let text = String(
                data: data[(ptr + 6)..<(ptr + 6 + Int(chunkLength))],
                encoding: .utf8
            )

            print(
                """
                SSRC/CSRC chunk \(i):
                -SSRC: \(chunkSsrc)
                -Type: \(chunkType)
                -Length: \(chunkLength)
                -Text: \(text ?? "")
                """
            )
            var ptrAdj = 6 + Int(chunkLength)
            // pad ptrAdj to 32 bits
            if ptrAdj % 4 != 0 {
                ptrAdj += 4 - (ptrAdj % 4)
            }
            ptr += ptrAdj
        }
    }
}

struct RTCPMessage {
    let type: PacketType
    let ssrc: UInt32
    let byteLength: UInt16

    init?(data: Data, clock: Int) {
        var ptr = data.startIndex
        guard data[ptr] & 0b11000000 == 0b10000000 else {  // version should be 2
            print("RTCP packet version is not 2")
            return nil
        }
        let padding = data[ptr] & 0b00100000 != 0
        let count = data[ptr] & 0b00011111
        guard let packetType = PacketType(rawValue: data[ptr + 1]) else {
            print("Unsupported RTCP packet type: \(data[ptr + 1])")
            return nil
        }
        self.type = packetType
        let length = data.read(at: ptr + 2, as: UInt16.self).bigEndian
        byteLength = (length + 1) * 4
        ssrc = data.read(at: ptr + 4, as: UInt32.self).bigEndian

        ptr += 4

        print(packetType.debugDescription)
        switch packetType {
        case .receiverReport:
            RRPacket(count: count, data: data[ptr...])
        case .sourceDescription:
            SDESPacket(count: count, data: data[ptr...])
        default:
            return nil
        }
    }
}
