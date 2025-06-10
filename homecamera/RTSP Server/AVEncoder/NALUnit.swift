//
//  NALUnit.swift
//
//  Basic parsing of H.264 NAL Units
//
//  Swift port by Copilot, based on original by Geraint Davies, March 2004
//  Copyright (c) GDCL 2004-2008 http://www.gdcl.co.uk/license.htm
//

import Foundation

// MARK: - NALUnit

class NALUnit {
    enum NALType: Int {
        case NAL_Slice = 1
        case NAL_PartitionA = 2
        case NAL_PartitionB = 3
        case NAL_PartitionC = 4
        case NAL_IDR_Slice = 5
        case NAL_SEI = 6
        case NAL_Sequence_Params = 7
        case NAL_Picture_Params = 8
        case NAL_AUD = 9
    }

    private(set) var pStartCodeStart: UnsafePointer<UInt8>?
    private(set) var pStart: UnsafePointer<UInt8>?
    private(set) var cBytes: Int = 0

    // bitstream access
    private var idx: Int = 0
    private var nBits: Int = 0
    private var byte: UInt8 = 0
    private var cZeros: Int = 0

    init() {
        self.pStart = nil
        self.cBytes = 0
    }

    init(pStart: UnsafePointer<UInt8>?, len: Int) {
        self.pStart = pStart
        self.pStartCodeStart = pStart
        self.cBytes = len
        self.ResetBitstream()
    }

    func copy(from: NALUnit) {
        self.pStart = from.pStart
        self.cBytes = from.cBytes
        self.ResetBitstream()
    }

    func type() -> NALType? {
        guard let pStart else { return nil }
        return NALType(rawValue: Int(pStart.pointee & 0x1F))
    }

    func length() -> Int { cBytes }
    func start() -> UnsafePointer<UInt8>? { pStart }

    // bitwise access
    func ResetBitstream() {
        idx = 0
        nBits = 0
        cZeros = 0
    }

    func Skip(_ nBits: Int) {
        var nBits = nBits
        if nBits < self.nBits {
            self.nBits -= nBits
        } else {
            nBits -= self.nBits
            while nBits >= 8 {
                _ = self.GetBYTE()
                nBits -= 8
            }
            if nBits > 0 {
                self.byte = self.GetBYTE()
                self.nBits = 8
                self.nBits -= nBits
            }
        }
    }

    // get next byte, removing emulation prevention bytes
    func GetBYTE() -> UInt8 {
        guard let pStart = pStart, idx < cBytes else { return 0 }
        let b = pStart[idx]
        idx += 1

        if b == 0 {
            cZeros += 1
            if idx < cBytes, cZeros == 2, pStart[idx] == 0x03 {
                idx += 1
                cZeros = 0
            }
        } else {
            cZeros = 0
        }
        return b
    }

    func GetBit() -> UInt32 {
        if nBits == 0 {
            byte = GetBYTE()
            nBits = 8
        }
        nBits -= 1
        return UInt32(byte >> nBits) & 0x1
    }

    func GetWord(_ nBits: Int) -> UInt32 {
        var nBits = nBits
        var u: UInt32 = 0
        while nBits > 0 {
            u <<= 1
            u |= GetBit()
            nBits -= 1
        }
        return u
    }

    func GetUE() -> UInt32 {
        // Exp-Golomb entropy coding: leading zeros, then a one, then
        // the data bits. The number of leading zeros is the number of
        // data bits, counting up from that number of 1s as the base.
        // That is, if you see
        //      0001010
        // You have three leading zeros, so there are three data bits (010)
        // counting up from a base of 111: thus 111 + 010 = 1001 = 9

        var cZeros = 0
        while GetBit() == 0 {
            if NoMoreBits() { return 0 }
            cZeros += 1
        }
        return GetWord(cZeros) + ((1 << cZeros) - 1)
    }

    func GetSE() -> Int32 {
        // same as UE but signed.
        // basically the unsigned numbers are used as codes to indicate signed numbers in pairs
        // in increasing value. Thus the encoded values
        //      0, 1, 2, 3, 4
        // mean
        //      0, 1, -1, 2, -2 etc

        let UE = GetUE()
        let bPositive = UE & 1
        var SE: Int32 = Int32((UE + 1) >> 1)
        if bPositive == 0 {
            SE = ~SE + 1 // negative
        }
        return Int32(SE)
    }

    func NoMoreBits() -> Bool {
        return idx >= cBytes && nBits == 0
    }

    func IsRefPic() -> Bool {
        guard let pStart = pStart else { return false }
        return (pStart[0] & 0x60) != 0
    }
}

// MARK: - SeqParamSet

class SeqParamSet {
    private(set) var FrameBits: Int = 0
    private(set) var cx: Int = 0
    private(set) var cy: Int = 0
    private(set) var bFrameOnly: Bool = true
    private(set) var Profile: Int = 0
    private(set) var Level: Int = 0
    private(set) var Compatibility: UInt8 = 0
    private(set) var pocType: Int = 0
    private(set) var pocLSBBits: Int = 0
    private var nalu: NALUnit = NALUnit()

    func Parse(_ pnalu: NALUnit) -> Bool {
        guard pnalu.type() == .NAL_Sequence_Params else { return false }
        pnalu.ResetBitstream()
        pnalu.Skip(8) // type
        self.Profile = Int(pnalu.GetWord(8))
        self.Compatibility = UInt8(pnalu.GetWord(8))
        self.Level = Int(pnalu.GetWord(8))
        _ = pnalu.GetUE() // seq_param_id

        if [100, 110, 122, 244, 44, 83, 86, 118, 128].contains(Profile) {
            let chroma_fmt = Int(pnalu.GetUE())
            if chroma_fmt == 3 { pnalu.Skip(1) }
            _ = pnalu.GetUE() // bit_depth_luma_minus8
            _ = pnalu.GetUE() // bit_depth_chroma_minus8
            pnalu.Skip(1)
            let seq_scaling_matrix_present = pnalu.GetBit()
            if seq_scaling_matrix_present != 0 {
                let max_scaling_lists = chroma_fmt == 3 ? 12 : 8
                for i in 0..<max_scaling_lists {
                    if pnalu.GetBit() != 0 {
                        let size = i < 6 ? 16 : 64
                        for _ in 0..<size { _ = pnalu.GetSE() }
                    }
                }
            }
        }

        let log2_frame_minus4 = Int(pnalu.GetUE())
        FrameBits = log2_frame_minus4 + 4
        pocType = Int(pnalu.GetUE())
        if pocType == 0 {
            let log2_minus4 = Int(pnalu.GetUE())
            pocLSBBits = log2_minus4 + 4
        } else if pocType == 1 {
            pnalu.Skip(1)
            _ = pnalu.GetSE()
            _ = pnalu.GetSE()
            let num_ref_in_cycle = Int(pnalu.GetUE())
            for _ in 0..<num_ref_in_cycle { _ = pnalu.GetSE() }
        } else if pocType != 2 { return false }
        _ = pnalu.GetUE()
        _ = pnalu.GetBit()
        let mbs_width = Int(pnalu.GetUE())
        let mbs_height = Int(pnalu.GetUE())
        cx = (mbs_width + 1) * 16
        cy = (mbs_height + 1) * 16
        if cx > 2000 || cy > 2000 { return false }
        bFrameOnly = pnalu.GetBit() != 0
        if !bFrameOnly { pnalu.Skip(1) }
        pnalu.Skip(1)
        if !bFrameOnly { cy *= 2 }
        nalu.copy(from: pnalu)
        return true
    }

    func EncodedWidth() -> Int { cx }
    func EncodedHeight() -> Int { cy }
    func Interlaced() -> Bool { return !bFrameOnly }
    func POCLSBBits() -> Int { pocLSBBits }
    func POCType() -> Int { pocType }
}

// MARK: - SliceHeader

class SliceHeader {
    private(set) var framenum: Int = 0
    private(set) var bField: Bool = false
    private(set) var bBottom: Bool = false
    private(set) var pocDelta: Int = 0
    private(set) var poc_lsb: Int = 0

    func Parse(_ pnalu: NALUnit, sps: SeqParamSet, bDeltaPresent: Bool) -> Bool {
        switch pnalu.type() {
        case .NAL_IDR_Slice, .NAL_Slice, .NAL_PartitionA: break
        default: return false
        }
        pnalu.ResetBitstream()
        pnalu.Skip(8)
        _ = pnalu.GetUE() // first mb in slice
        _ = pnalu.GetUE() // slice type
        _ = pnalu.GetUE() // pic param set id
        framenum = Int(pnalu.GetWord(sps.FrameBits))
        bField = false
        bBottom = false
        if sps.Interlaced() {
            bField = pnalu.GetBit() != 0
            if bField { bBottom = pnalu.GetBit() != 0 }
        }
        if pnalu.type() == .NAL_IDR_Slice { _ = pnalu.GetUE() }
        poc_lsb = 0
        if sps.POCType() == 0 {
            poc_lsb = Int(pnalu.GetWord(sps.POCLSBBits()))
            pocDelta = 0
            if bDeltaPresent && !bField {
                pocDelta = Int(pnalu.GetSE())
            }
        }
        return true
    }

    func FrameNum() -> Int { framenum }
    func IsField() -> Bool { bField }
    func IsBottom() -> Bool { bBottom }
    func Delta() -> Int { pocDelta }
    func POCLSB() -> Int { poc_lsb }
}

// MARK: - SEIMessage

class SEIMessage {
    private(set) var type: Int
    private(set) var length: Int
    private(set) var idxPayload: Int
    private var pnalu: NALUnit

    init(pnalu: NALUnit) {
        self.pnalu = pnalu
        var pIdx = 1 // skip nalu type

        var t = 0
        let start = pnalu.start()!
        while start[pIdx] == 0xff { t += 255; pIdx += 1 }
        t += Int(start[pIdx]); pIdx += 1
        self.type = t

        var l = 0
        while start[pIdx] == 0xff { l += 255; pIdx += 1 }
        l += Int(start[pIdx]); pIdx += 1
        self.length = l
        self.idxPayload = pIdx
    }

    func Payload() -> UnsafePointer<UInt8>? {
        guard let s = pnalu.start() else { return nil }
        return s.advanced(by: idxPayload)
    }
}

// MARK: - avcCHeader

class avcCHeader {
    private(set) var lengthSize: Int = 0
    private(set) var sps: NALUnit = NALUnit()
    private(set) var pps: NALUnit = NALUnit()

    init(header: UnsafePointer<UInt8>, cBytes: Int) {
        if cBytes < 8 { return }
        let pEnd = header.advanced(by: cBytes)
        lengthSize = Int(header[4] & 3) + 1
        var hdr = header
        let cSeq = Int(header[5] & 0x1f)
        hdr = hdr.advanced(by: 6)
        for i in 0..<cSeq {
            if hdr.advanced(by: 2) > pEnd { return }
            let cThis = Int(hdr[0]) << 8 | Int(hdr[1])
            hdr = hdr.advanced(by: 2)
            if hdr.advanced(by: cThis) > pEnd { return }
            if i == 0 {
                sps = NALUnit(pStart: hdr, len: cThis)
            }
            hdr = hdr.advanced(by: cThis)
        }
        if hdr.advanced(by: 3) >= pEnd { return }
        let cPPS = Int(hdr[0])
        if cPPS > 0 {
            let cThis = Int(hdr[1]) << 8 | Int(hdr[2])
            hdr = hdr.advanced(by: 3)
            pps = NALUnit(pStart: hdr, len: cThis)
        }
    }
}

// MARK: - POCState

class POCState {
    private var prevLSB: Int = 0
    private var prevMSB: Int = 0
    private var avc: avcCHeader?
    private var sps: SeqParamSet = SeqParamSet()
    private var deltaPresent: Bool = false
    private(set) var frameNum: Int = 0
    private(set) var lastlsb: Int = 0

    func SetHeader(_ avc: avcCHeader) {
        self.avc = avc
        if let spsNal = avc.sps as NALUnit? {
            if !sps.Parse(spsNal) {
                fatalError("Invalid SPS in AVC header")
            }
        }
        let pps = avc.pps
        pps.ResetBitstream()
        _ = pps.GetUE()
        _ = pps.GetUE()
        pps.Skip(1)
        deltaPresent = pps.GetBit() != 0
    }

    func GetPOC(_ nal: NALUnit, pPOC: inout Int) -> Bool {
        let maxlsb = 1 << (sps.POCLSBBits())
        let slice = SliceHeader()
        if slice.Parse(nal, sps: sps, bDeltaPresent: deltaPresent) {
            frameNum = slice.FrameNum()
            var prevMSB = self.prevMSB
            var prevLSB = self.prevLSB
            if nal.type() == .NAL_IDR_Slice { prevLSB = 0; prevMSB = 0 }
            let lsb = slice.POCLSB()
            var MSB = prevMSB
            if (lsb < prevLSB) && ((prevLSB - lsb) >= (maxlsb / 2)) {
                MSB = prevMSB + maxlsb
            } else if (lsb > prevLSB) && ((lsb - prevLSB) > (maxlsb / 2)) {
                MSB = prevMSB - maxlsb
            }
            if nal.IsRefPic() {
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
