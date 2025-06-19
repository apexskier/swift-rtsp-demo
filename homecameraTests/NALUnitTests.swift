// NALUnitTests.swift
// Unit tests for NALUnit and related structs using swift-testing

import Foundation
import Testing

struct NALUnitTests {
    @Test
    func testNALTypeParsing() throws {
        let bytes: [UInt8] = [5]
        #expect(NALUnit(data: Data(bytes)).type() == .idrSlice)
    }

    @Test
    func testInitWithData() throws {
        let bytes: [UInt8] = [0x67, 0x42, 0x00, 0x1e]  // SPS NALU
        let nalu = NALUnit(data: Data(bytes))
        #expect(nalu.type() == .sequenceParams)
    }

    @Test
    func testGetBYTEEmulationPrevention() throws {
        // 0x00 0x00 0x03 0x01 should skip the 0x03
        let bytes: [UInt8] = [0x00, 0x00, 0x03, 0x01]
        let nalu = NALUnit(data: Data(bytes))
        #expect(nalu.getBYTE() == 0x00)
        #expect(nalu.getBYTE() == 0x00)
        #expect(nalu.getBYTE() == 0x01)  // 0x03 skipped
    }

    @Test
    func testGetBitAndGetWord() throws {
        let bytes: [UInt8] = [0b10110000]
        let nalu = NALUnit(data: Data(bytes))
        #expect(nalu.getBit() == 1)
        #expect(nalu.getBit() == 0)
        #expect(nalu.getWord(2) == 0b11)
        #expect(nalu.getWord(2) == 0)
    }

    @Test
    func testGetUEandSE() throws {
        // 0b00010000: 3 leading zeros, then 1, then 000
        let bytes: [UInt8] = [0b00010000]
        let nalu = NALUnit(data: Data(bytes))
        nalu.resetBitstream()
        nalu.skip(0)
        #expect(nalu.getUE() == 7)  // 3 zeros: 2^3-1 + 0 = 7
    }

    @Test
    func testSeqParamSetInit() throws {
        // This is a minimal fake SPS NALU for test purposes
        let bytes: [UInt8] = [0x67, 0x42, 0x00, 0x1e, 0x89, 0x8b, 0x60]
        let nalu = NALUnit(data: Data(bytes))
        let sps = SeqParamSet(nalu)
        #expect(sps != nil)
    }

    @Test
    func testAVCCHeaderInit() throws {
        // Minimal avcC header: [0,0,0,1,0xFF,1,0,4,0x67,0x42,0x00,0x1e,1,0,4,0x68,0xce,0x06,0xe2]
        let data = Data([
            0, 0, 0, 1, 0xFF, 1, 0, 4, 0x67, 0x42, 0x00, 0x1e, 1, 0, 4, 0x68, 0xce, 0x06, 0xe2,
        ])
        let avcc = AVCCHeader(header: data)
        #expect(avcc != nil)
    }

    @Test
    func testPOCState() throws {
        // This is a minimal test, real NALUs needed for full coverage
        let bytes: [UInt8] = [0x65, 0x88, 0x84]
        let nalu = NALUnit(data: Data(bytes))
        let avccData = Data([
            0, 0, 0, 1, 0xFF, 1, 0, 4, 0x67, 0x42, 0x00, 0x1e, 1, 0, 4, 0x68, 0xce, 0x06, 0xe2,
        ])
        let avcc = AVCCHeader(header: avccData)
        let poc = POCState()
        if let avcc {
            poc.setHeader(avcc)
            let pocValue = poc.getPOC(nal: nalu)
            #expect(pocValue != nil)
        }
    }
}
