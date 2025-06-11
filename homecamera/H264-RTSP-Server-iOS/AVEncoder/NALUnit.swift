// NALUnit.swift
//
// Basic parsing of H.264 NAL Units
//
// Ported from C++ by Geraint Davies, March 2004
// Swift port by [Your Name], 2025
//
// Copyright (c) GDCL 2004-2008 http://www.gdcl.co.uk/license.htm

import Foundation

// MARK: - NALUnit

public final class NALUnit {
    public enum NALType: UInt8 {
        case slice = 1
        case partitionA = 2
        case partitionB = 3
        case partitionC = 4
        case idrSlice = 5
        case sei = 6
        case sequenceParams = 7
        case pictureParams = 8
        case aud = 9
        case unknown = 0

        init(byte: UInt8) {
            self = NALType(rawValue: byte & 0x1F) ?? .unknown
        }
    }

    private(set) var start: UnsafePointer<UInt8>?
    private(set) var startCodeStart: UnsafePointer<UInt8>?
    private(set) var length: Int = 0

    // Bitstream access
    private var idx: Int = 0
    private var nBits: Int = 0
    private var byte: UInt8 = 0
    private var cZeros: Int = 0

    public init() {
        self.start = nil
        self.length = 0
    }

    public init(start: UnsafePointer<UInt8>, length: Int) {
        self.start = start
        self.startCodeStart = start
        self.length = length
        self.resetBitstream()
    }

    public func parse(
        _ buffer: UnsafePointer<UInt8>,
        space: Int,
        lengthSize: Int,
        isEnd: Bool
    ) -> Bool {
        // if we get the start code but not the whole NALU, we can return false but still have the length property valid
        self.length = 0
        self.resetBitstream()
        if lengthSize > 0 {
            self.startCodeStart = buffer
            if lengthSize > space { return false }
            self.length = 0
            var len: Int = 0
            var p = buffer
            for _ in 0..<lengthSize {
                len <<= 8
                len += Int(p.pointee)
                p = p.advanced(by: 1)
            }
            if (len + lengthSize) <= space {
                self.start = p
                self.length = len
                return true
            }
        } else {
            // not length-delimited: look for start codes
            var pBegin: UnsafePointer<UInt8>? = nil
            var pBuffer = buffer
            var cSpace = space
            if getStartCode(&pBegin, &pBuffer, &cSpace) {
                self.start = pBuffer
                self.startCodeStart = pBegin
                if getStartCode(&pBegin, &pBuffer, &cSpace) {
                    self.length =
                        pBegin.map { Int(bitPattern: $0) - Int(bitPattern: self.start!) } ?? 0
                    return true
                } else if isEnd {
                    self.length = cSpace
                    return true
                }
            }
        }
        return false
    }

    public func type() -> NALType {
        guard let start = self.start else { return .unknown }
        return NALType(byte: start.pointee)
    }

    public func resetBitstream() {
        self.idx = 0
        self.nBits = 0
        self.cZeros = 0
    }

    public func skip(_ nBits: Int) {
        var nBits = nBits
        if nBits < self.nBits {
            self.nBits -= nBits
        } else {
            nBits -= self.nBits
            while nBits >= 8 {
                _ = getBYTE()
                nBits -= 8
            }
            if nBits > 0 {
                self.byte = getBYTE()
                self.nBits = 8
                self.nBits -= nBits
            }
        }
    }

    // get the next byte, removing emulation prevention bytes
    public func getBYTE() -> UInt8 {
        guard let start = self.start, idx < self.length else { return 0 }
        var b = start.advanced(by: idx).pointee
        idx += 1
        // to avoid start-code emulation, a byte 0x03 is inserted after any 00 00 pair. Discard that here.
        if b == 0 {
            cZeros += 1
            if idx < self.length && cZeros == 2 && start.advanced(by: idx).pointee == 0x03 {
                idx += 1
                cZeros = 0
            }
        } else {
            cZeros = 0
        }
        return b
    }

    public func getBit() -> UInt {
        if nBits == 0 {
            byte = getBYTE()
            nBits = 8
        }
        nBits -= 1
        return UInt((byte >> nBits) & 0x1)
    }

    public func getWord(_ nBits: Int) -> UInt {
        var u: UInt = 0
        var nBits = nBits
        while nBits > 0 {
            u <<= 1
            u |= getBit()
            nBits -= 1
        }
        return u
    }

    public func getUE() -> UInt {
        // Exp-Golomb entropy coding: leading zeros, then a one, then the data bits.
        var cZeros = 0
        while getBit() == 0 {
            if noMoreBits() { return 0 }
            cZeros += 1
        }
        return getWord(cZeros) + ((1 << cZeros) - 1)
    }

    public func getSE() -> Int {
        // same as UE but signed.
        let ue = getUE()
        let bPositive = (ue & 1) != 0
        var se = Int((ue + 1) >> 1)
        if !bPositive { se = -se }
        return se
    }

    public func noMoreBits() -> Bool {
        return idx >= length && nBits == 0
    }

    public func isRefPic() -> Bool {
        guard let start = self.start else { return false }
        return (start.pointee & 0x60) != 0
    }

    // MARK: - Private
    private func getStartCode(
        _ pBegin: inout UnsafePointer<UInt8>?,
        _ pStart: inout UnsafePointer<UInt8>,
        _ cRemain: inout Int
    ) -> Bool {
        // start code is any number of 00 followed by 00 00 01
        // We need to record the first 00 in pBegin and the first byte following the startcode in pStart.
        // if no start code is found, pStart and cRemain should be unchanged.
        var pThis = pStart
        var cBytes = cRemain
        pBegin = nil
        while cBytes >= 4 {
            if pThis[0] == 0 {
                if pBegin == nil { pBegin = pThis }
                if pThis[1] == 0 && pThis[2] == 1 {
                    pStart = pThis.advanced(by: 3)
                    cRemain = cBytes - 3
                    return true
                }
            } else {
                pBegin = nil
            }
            cBytes -= 1
            pThis = pThis.advanced(by: 1)
        }
        return false
    }
}

// MARK: - SeqParamSet

public final class SeqParamSet {
    private(set) var frameBits: Int = 0
    private(set) var cx: Int = 0
    private(set) var cy: Int = 0
    private(set) var interlaced: Bool = false
    private(set) var profile: Int = 0
    private(set) var level: Int = 0
    private(set) var compatibility: UInt8 = 0
    private(set) var pocType: Int = 0
    private(set) var pocLSBBits: Int = 0
    private(set) var nalu: NALUnit = NALUnit()

    public init() {}

    public func parse(_ nalu: NALUnit) -> Bool {
        guard nalu.type() == .sequenceParams else { return false }

        // with the UE/SE type encoding, we must decode all the values
        // to get through to the ones we want
        nalu.resetBitstream()
        nalu.skip(8)  // type

        profile = Int(nalu.getWord(8))
        compatibility = UInt8(nalu.getWord(8))
        level = Int(nalu.getWord(8))
        _ = nalu.getUE()  // seq_param_id

        if [100, 110, 122, 244, 44, 83, 86, 118, 128].contains(profile) {
            let chromaFmt = Int(nalu.getUE())
            if chromaFmt == 3 { nalu.skip(1) }
            _ = nalu.getUE()  // bit_depth_luma_minus8
            _ = nalu.getUE()  // bit_depth_chroma_minus8
            nalu.skip(1)
            let seqScalingMatrixPresent = nalu.getBit() != 0
            if seqScalingMatrixPresent {
                // Y, Cr, Cb for 4x4 intra and inter, then 8x8 (just Y unless chroma_fmt is 3)
                let maxScalingLists = (chromaFmt == 3) ? 12 : 8
                for i in 0..<maxScalingLists {
                    if nalu.getBit() != 0 {
                        if i < 6 {
                            scalingList(size: 16, nalu: nalu)
                        } else {
                            scalingList(size: 64, nalu: nalu)
                        }
                    }
                }
            }
        }

        let log2FrameMinus4 = Int(nalu.getUE())
        frameBits = log2FrameMinus4 + 4
        pocType = Int(nalu.getUE())
        if pocType == 0 {
            let log2Minus4 = Int(nalu.getUE())
            pocLSBBits = log2Minus4 + 4
        } else if pocType == 1 {
            nalu.skip(1)  // delta always zero
            _ = nalu.getSE()  // nsp_offset
            _ = nalu.getSE()  // nsp_top_to_bottom
            let numRefInCycle = Int(nalu.getUE())
            for _ in 0..<numRefInCycle {
                _ = nalu.getSE()  // sf_offset
            }
        } else if pocType != 2 {
            return false
        }
        // else for POCtype == 2, no additional data in stream

        _ = nalu.getUE()  // num_ref_frames
        _ = nalu.getBit()  // gaps_allowed

        let mbsWidth = Int(nalu.getUE())
        let mbsHeight = Int(nalu.getUE())
        cx = (mbsWidth + 1) * 16
        cy = (mbsHeight + 1) * 16

        // smoke test validation of sps
        if cx > 2000 || cy > 2000 { return false }

        // if this is false, then sizes are field sizes and need adjusting
        interlaced = nalu.getBit() == 0
        if interlaced {
            nalu.skip(1)  // adaptive frame/field
        }
        nalu.skip(1) // direct 8x8

        if interlaced {
            // adjust heights from field to frame
            cy *= 2
        }

        // .. rest are not interesting yet
        self.nalu = nalu
        return true
    }

    private func scalingList(size: Int, nalu: NALUnit) {
        var lastScale = 8
        var nextScale = 8
        for _ in 0..<size {
            if nextScale != 0 {
                let delta = nalu.getSE()
                nextScale = (lastScale + delta + 256) % 256
            }
            lastScale = (nextScale == 0) ? lastScale : nextScale
        }
    }
}

// MARK: - SliceHeader

public final class SliceHeader {
    private(set) var framenum: Int = 0
    private(set) var bField: Bool = false
    private(set) var bBottom: Bool = false
    private(set) var pocDelta: Int = 0
    private(set) var pocLSB: Int = 0

    public func parse(_ nalu: NALUnit, sps: SeqParamSet, deltaPresent: Bool) -> Bool {
        switch nalu.type() {
        case .idrSlice, .slice, .partitionA:
            // all these begin with a slice header
            break
        default:
            return false
        }

        // slice header has the 1-byte type, then one UE value,
        // then the frame number.
        nalu.resetBitstream()
        nalu.skip(8)  // NALU type
        _ = nalu.getUE()  // first mb in slice
        _ = nalu.getUE()  // slice type
        _ = nalu.getUE()  // pic param set id

        framenum = Int(nalu.getWord(sps.frameBits))

        bField = false
        bBottom = false
        if sps.interlaced {
            bField = nalu.getBit() != 0
            if bField { bBottom = nalu.getBit() != 0 }
        }
        if nalu.type() == .idrSlice {
            _ = nalu.getUE() // idr_pic_id
        }
        pocLSB = 0
        if sps.pocType == 0 {
            pocLSB = Int(nalu.getWord(sps.pocLSBBits))
            pocDelta = 0
            if deltaPresent && !bField {
                pocDelta = nalu.getSE()
            }
        }

        return true
    }
}

// MARK: - SEIMessage

public final class SEIMessage {
    private let nalu: NALUnit
    private let type: Int
    private let length: Int
    private let idxPayload: Int

    public init(nalu: NALUnit) {
        self.nalu = nalu
        var p = nalu.start?.advanced(by: 1) ?? UnsafePointer<UInt8>(bitPattern: 0)!
        var t = 0
        while p.pointee == 0xff {
            t += 255
            p = p.advanced(by: 1)
        }
        t += Int(p.pointee)
        p = p.advanced(by: 1)
        var l = 0
        while p.pointee == 0xff {
            l += 255
            p = p.advanced(by: 1)
        }
        l += Int(p.pointee)
        p = p.advanced(by: 1)
        self.type = t
        self.length = l
        self.idxPayload = Int(p - (nalu.start ?? p))
    }
    
    public func payload() -> UnsafePointer<UInt8>? {
        guard let start = nalu.start else { return nil }
        return start.advanced(by: idxPayload)
    }
}

// MARK: - avcCHeader

public final class avcCHeader {
    private(set) var lengthSize: Int = 0
    private(set) var sps: NALUnit = NALUnit()
    private(set) var pps: NALUnit = NALUnit()

    public init(header: UnsafePointer<UInt8>, cBytes: Int) {
        guard cBytes >= 8 else { return }
        let pEnd = header.advanced(by: cBytes)
        lengthSize = Int(header[4] & 3) + 1
        let cSeq = Int(header[5] & 0x1f)
        var p = header.advanced(by: 6)
        for i in 0..<cSeq {
            guard p.advanced(by: 2) <= pEnd else { return }
            let cThis = Int(p[0]) << 8 | Int(p[1])
            p = p.advanced(by: 2)
            guard p.advanced(by: cThis) <= pEnd else { return }
            if i == 0 {
                sps = NALUnit(start: p, length: cThis)
            }
            p = p.advanced(by: cThis)
        }
        guard p.advanced(by: 3) < pEnd else { return }
        let cPPS = Int(p[0])
        if cPPS > 0 {
            let cThis = Int(p[1]) << 8 | Int(p[2])
            p = p.advanced(by: 3)
            pps = NALUnit(start: p, length: cThis)
        }
    }
}

// MARK: - POCState

public final class POCState {
    private var prevLSB: Int = 0
    private var prevMSB: Int = 0
    private var avc: avcCHeader?
    private var sps: SeqParamSet = SeqParamSet()
    private var deltaPresent: Bool = false
    private(set) var frameNum: Int = 0
    private(set) var lastlsb: Int = 0

    public init() {}

    public func setHeader(_ avc: avcCHeader) {
        self.avc = avc
        _ = sps.parse(avc.sps)
        let pps = avc.pps
        pps.resetBitstream()
        _ = pps.getUE()  // ppsid
        _ = pps.getUE()  // spsid
        pps.skip(1)
        deltaPresent = pps.getBit() != 0
    }

    public func getPOC(nal: NALUnit, pPOC: inout Int) -> Bool {
        guard self.avc != nil else { return false }
        let maxlsb = 1 << sps.pocLSBBits
        let slice = SliceHeader()
        if slice.parse(nal, sps: sps, deltaPresent: deltaPresent) {
            frameNum = slice.framenum
            var prevMSB = self.prevMSB
            var prevLSB = self.prevLSB
            if nal.type() == .idrSlice {
                prevLSB = 0
                prevMSB = 0
            }
            let lsb = slice.pocLSB
            var MSB = prevMSB
            if (lsb < prevLSB) && ((prevLSB - lsb) >= (maxlsb / 2)) {
                MSB = prevMSB + maxlsb
            } else if (lsb > prevLSB) && ((lsb - prevLSB) > (maxlsb / 2)) {
                MSB = prevMSB - maxlsb
            }
            if nal.isRefPic() {
                self.prevLSB = lsb
                self.prevMSB = MSB
            }
            pPOC = MSB + lsb
            lastlsb = lsb
            return true
        }
        return false
    }
}
