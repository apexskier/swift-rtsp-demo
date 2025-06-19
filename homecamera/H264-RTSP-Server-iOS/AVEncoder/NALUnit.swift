// NALUnit.swift
//
// Basic parsing of H.264 NAL Units
//
// Ported from C++ by Geraint Davies, March 2004
// Swift port by Cameron Little, 2025
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

    init() {
        self.start = nil
        self.length = 0
    }

    init(start: UnsafePointer<UInt8>, length: Int) {
        self.start = start
        self.startCodeStart = start
        self.length = length
        self.resetBitstream()
    }

    convenience init(data: Data, offset: Int = 0, length: Int? = nil) {
        let bytes = data.withUnsafeBytes {
            $0.baseAddress!.assumingMemoryBound(to: UInt8.self)
        }
        self.init(start: bytes.advanced(by: offset), length: length ?? data.count)
    }

    func type() -> NALType {
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
        guard let start, idx < self.length else { return 0 }
        let b = start.advanced(by: idx).pointee
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
}

// MARK: - SeqParamSet

public struct SeqParamSet {
    let frameBits: Int
    private(set) var cx: Int
    private(set) var cy: Int
    let interlaced: Bool
    let profile: Int
    let level: Int
    let compatibility: UInt8
    let pocType: Int
    let pocLSBBits: Int

    public init?(_ nalu: NALUnit) {
        guard nalu.type() == .sequenceParams else { return nil }

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
                            nalu.scalingList(size: 16)
                        } else {
                            nalu.scalingList(size: 64)
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
            pocLSBBits = 0
            nalu.skip(1)  // delta always zero
            _ = nalu.getSE()  // nsp_offset
            _ = nalu.getSE()  // nsp_top_to_bottom
            let numRefInCycle = Int(nalu.getUE())
            for _ in 0..<numRefInCycle {
                _ = nalu.getSE()  // sf_offset
            }
        } else if pocType != 2 {
            return nil
        } else {
            // else for POCtype == 2, no additional data in stream
            pocLSBBits = 0
        }

        _ = nalu.getUE()  // num_ref_frames
        _ = nalu.getBit()  // gaps_allowed

        let mbsWidth = Int(nalu.getUE())
        let mbsHeight = Int(nalu.getUE())
        cx = (mbsWidth + 1) * 16
        cy = (mbsHeight + 1) * 16

        // smoke test validation of sps
        if cx > 2000 || cy > 2000 { return nil }

        // if this is false, then sizes are field sizes and need adjusting
        interlaced = nalu.getBit() == 0
        if interlaced {
            nalu.skip(1)  // adaptive frame/field
        }
        nalu.skip(1)  // direct 8x8

        if interlaced {
            // adjust heights from field to frame
            cy *= 2
        }

        // .. rest are not interesting yet
    }
}

extension NALUnit {
    fileprivate func scalingList(size: Int) {
        var lastScale = 8
        var nextScale = 8
        for _ in 0..<size {
            if nextScale != 0 {
                let delta = getSE()
                nextScale = (lastScale + delta + 256) % 256
            }
            lastScale = (nextScale == 0) ? lastScale : nextScale
        }
    }
}

// MARK: - SliceHeader

private struct SliceHeader {
    let framenum: Int
    private let bField: Bool
    private let bBottom: Bool
    let pocDelta: Int
    let pocLSB: Int

    public init?(_ nalu: NALUnit, sps: SeqParamSet, deltaPresent: Bool) {
        switch nalu.type() {
        case .idrSlice, .slice, .partitionA:
            // all these begin with a slice header
            break
        default:
            return nil
        }

        // slice header has the 1-byte type, then one UE value,
        // then the frame number.
        nalu.resetBitstream()
        nalu.skip(8)  // NALU type
        _ = nalu.getUE()  // first mb in slice
        _ = nalu.getUE()  // slice type
        _ = nalu.getUE()  // pic param set id

        framenum = Int(nalu.getWord(sps.frameBits))

        var bField = false
        var bBottom = false
        if sps.interlaced {
            bField = nalu.getBit() != 0
            if bField { bBottom = nalu.getBit() != 0 }
        }
        if nalu.type() == .idrSlice {
            _ = nalu.getUE()  // idr_pic_id
        }
        if sps.pocType == 0 {
            pocLSB = Int(nalu.getWord(sps.pocLSBBits))
            if deltaPresent && !bField {
                pocDelta = nalu.getSE()
            } else {
                pocDelta = 0
            }
        } else {
            pocLSB = 0
            pocDelta = 0
        }

        self.bField = bField
        self.bBottom = bBottom
    }
}

// MARK: - avcCHeader

public struct AVCCHeader {
    let lengthSize: Int
    let sps: NALUnit
    let pps: NALUnit

    public init?(header data: Data) {
        guard data.count >= 8 else { return nil }
        lengthSize = Int(data[4] & 3) + 1
        let cSeq = Int(data[5] & 0x1f)
        var p = 6
        var sps: NALUnit?
        for i in 0..<cSeq {
            if p + 2 > data.count { return nil }
            let cThis = Int(data[p] << 8 | data[p + 1])
            p += 2
            if p + cThis > data.count { return nil }
            if i == 0 {
                sps = NALUnit(data: data, offset: p, length: cThis)
            }
            p = p.advanced(by: cThis)
        }
        if p + 3 >= data.count { return nil }
        let cPPS = data[p]
        if cPPS > 0 {
            let cThis = Int(data[p + 1] << 8 | data[p + 2])
            p += 3
            pps = NALUnit(data: data, offset: p, length: cThis)
        } else {
            return nil
        }
        if let sps {
            self.sps = sps
        } else {
            return nil
        }
    }
}

// MARK: - POCState

public final class POCState {
    private var prevLSB: Int = 0
    private var prevMSB: Int = 0
    private var sps: SeqParamSet?
    private var deltaPresent: Bool = false
    private(set) var frameNum: Int = 0
    private(set) var lastlsb: Int = 0

    public func setHeader(_ avc: AVCCHeader) {
        self.sps = SeqParamSet(avc.sps)
        let pps = avc.pps
        pps.resetBitstream()
        _ = pps.getUE()  // ppsid
        _ = pps.getUE()  // spsid
        pps.skip(1)
        deltaPresent = pps.getBit() != 0
    }

    public func getPOC(nal: NALUnit) -> Int? {
        guard let sps, let slice = SliceHeader(nal, sps: sps, deltaPresent: deltaPresent) else {
            return nil
        }

        frameNum = slice.framenum
        var prevMSB = self.prevMSB
        var prevLSB = self.prevLSB
        if nal.type() == .idrSlice {
            prevLSB = 0
            prevMSB = 0
        }
        let lsb = slice.pocLSB
        var msb = prevMSB
        let maxLSB = 1 << sps.pocLSBBits
        if (lsb < prevLSB) && ((prevLSB - lsb) >= (maxLSB / 2)) {
            msb = prevMSB + maxLSB
        } else if (lsb > prevLSB) && ((lsb - prevLSB) > (maxLSB / 2)) {
            msb = prevMSB - maxLSB
        }
        if nal.isRefPic() {
            self.prevLSB = lsb
            self.prevMSB = msb
        }
        lastlsb = lsb
        return msb + lsb
    }
}
