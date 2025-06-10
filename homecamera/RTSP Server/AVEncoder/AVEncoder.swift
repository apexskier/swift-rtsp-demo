//
//  AVEncoder.swift
//  Encoder Demo
//
//  Created by Geraint Davies on 14/01/2013.
//  Copyright (c) 2013 GDCL http://www.gdcl.co.uk/license.htm
//

import Foundation
import AVFoundation

typealias EncoderHandler = (_ data: [Data], _ pts: Double) -> Int
typealias ParamHandler = (_ params: Data) -> Int

private let OUTPUT_FILE_SWITCH_POINT: UInt64 = 50 * 1024 * 1024 // 50 MB
private let MAX_FILENAME_INDEX = 5

// MARK: - EncodedFrame

private class EncodedFrame {
    let poc: Int
    let frame: [Data]
    init(nalus: [Data], poc: Int) {
        self.poc = poc
        self.frame = nalus
    }
}

// MARK: - AVEncoder

final class AVEncoder: NSObject {
    // MARK: - Properties

    private var headerWriter: VideoEncoder?
    private var writer: VideoEncoder?
    private var inputFile: FileHandle?
    private var readQueue: DispatchQueue?
    private var readSource: DispatchSourceRead?

    private var swapping: Bool = false
    private var currentFile: Int = 1
    private var height: Int = 0
    private var width: Int = 0

    private var avcC: Data?
    private var lengthSize: Int = 0

    private var pocState = POCState()
    private var prevPOC: Int = 0

    private var foundMDAT: Bool = false
    private var posMDAT: UInt64 = 0
    private var bytesToNextAtom: Int = 0
    private var needParams: Bool = false

    private var prevNalIDC: Int = 0
    private var prevNalType: Int = 0
    private var pendingNALU: [Data]?
    private var times: [Double] = []
    private var frames: [EncodedFrame] = []

    private var outputBlock: EncoderHandler?
    private var paramsBlock: ParamHandler?

    private(set) var bitspersecond: Int = 0
    private var firstPTS: Double = -1

    // MARK: - Factory

    static func encoder(forHeight height: Int, andWidth width: Int) -> AVEncoder {
        let enc = AVEncoder()
        enc.initForHeight(height, andWidth: width)
        return enc
    }

    // MARK: - Init

    private func makeFilename() -> String {
        let filename = "capture\(currentFile).mp4"
        return (NSTemporaryDirectory() as NSString).appendingPathComponent(filename)
    }

    private func initForHeight(_ height: Int, andWidth width: Int) {
        self.height = height
        self.width = width
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("params.mp4")
        self.headerWriter = VideoEncoder.encoder(forPath: path, height: height, width: width)
        self.times = []
        self.currentFile = 1
        self.writer = VideoEncoder.encoder(forPath: makeFilename(), height: height, width: width)
    }

    // MARK: - API

    func encode(withBlock block: @escaping EncoderHandler, onParams paramsHandler: @escaping ParamHandler) {
        self.outputBlock = block
        self.paramsBlock = paramsHandler
        self.needParams = true
        self.pendingNALU = nil
        self.firstPTS = -1
        self.bitspersecond = 0
    }

    func encodeFrame(_ sampleBuffer: CMSampleBuffer) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        if needParams {
            needParams = false
            if headerWriter?.encodeFrame(sampleBuffer) == true {
                headerWriter?.finish { [weak self] in
                    self?.onParamsCompletion()
                }
            }
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dPTS = Double(pts.value) / Double(pts.timescale)
        times.append(dPTS)

        // Switch output files when we reach a size limit
        if !swapping, let inputFile = inputFile {
            let st_size = (try? inputFile.seekToEnd()) ?? 0
            if st_size > OUTPUT_FILE_SWITCH_POINT {
                swapping = true
                let oldVideo = writer
                currentFile += 1
                if currentFile > MAX_FILENAME_INDEX { currentFile = 1 }
                writer = VideoEncoder.encoder(forPath: makeFilename(), height: height, width: width)

                readSource?.cancel()
                readQueue?.async { [weak self] in
                    guard let self = self else { return }
                    self.readSource = nil
                    oldVideo?.finish {
                        self.swapFiles(oldPath: oldVideo?.path ?? "")
                    }
                }
            }
        }
        _ = writer?.encodeFrame(sampleBuffer)
    }

    func getConfigData() -> Data? {
        return avcC
    }

    func shutdown() {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        readSource = nil
        headerWriter?.finish { [weak self] in self?.headerWriter = nil }
        writer?.finish { [weak self] in self?.writer = nil }
        // Wait for these to finish before removing temp files
    }

    // MARK: - Internal Logic

    private func onParamsCompletion() {
        guard let headerPath = headerWriter?.path else { return }
        if parseParams(headerPath) {
            paramsBlock?(avcC ?? Data())
            headerWriter = nil
            swapping = false
            if let writerPath = writer?.path {
                inputFile = FileHandle(forReadingAtPath: writerPath)
                readQueue = DispatchQueue(label: "uk.co.gdcl.avencoder.read")
                if let fd = inputFile?.fileDescriptor {
                    readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
                    readSource?.setEventHandler { [weak self] in
                        self?.onFileUpdate()
                    }
                    readSource?.resume()
                }
            }
        }
    }

    // MARK: - MP4 Parsing

    private func parseParams(_ path: String) -> Bool {
        guard let file = FileHandle(forReadingAtPath: path) else { return false }
        var statbuf = stat()
        fstat(file.fileDescriptor, &statbuf)
        let size = Int(statbuf.st_size)
        guard let movie = MP4Atom.atomAt(offset: 0, size: size, type: fourCC("file"), inFile: file),
              let moov = movie.childOfType(fourCC("moov"), startAt: 0) else {
            return false
        }
        var trak: MP4Atom? = nil
        repeat {
            trak = moov.nextChild()
            if let t = trak, t.type == fourCC("trak") {
                if let tkhd = t.childOfType(fourCC("tkhd"), startAt: 0),
                   let verflags = tkhd.readAt(offset: 0, size: 4) {
                    let p = [UInt8](verflags)
                    if (p[3] & 1) != 0 {
                        break
                    }
                }
            }
        } while trak != nil

        var stsd: MP4Atom? = nil
        if let trak = trak,
           let media = trak.childOfType(fourCC("mdia"), startAt: 0),
           let minf = media.childOfType(fourCC("minf"), startAt: 0),
           let stbl = minf.childOfType(fourCC("stbl"), startAt: 0) {
            stsd = stbl.childOfType(fourCC("stsd"), startAt: 0)
        }

        if let stsd = stsd,
           let avc1 = stsd.childOfType(fourCC("avc1"), startAt: 8),
           let esd = avc1.childOfType(fourCC("avcC"), startAt: 78),
           let avcCdata = esd.readAt(offset: 0, size: Int(esd.length)) {
            self.avcC = avcCdata
            let p = [UInt8](avcCdata)
            self.lengthSize = Int((p[4] & 3) + 1)
            let avcHeader = avcCdata.withUnsafeBytes { ptr in
                avcCHeader(header: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), cBytes: avcCdata.count)
            }
            pocState.SetHeader(avcHeader)
            return true
        }
        return false
    }

    // MARK: - Swapping and File Delivery

    private func swapFiles(oldPath: String) {
        guard let inputFile = inputFile else { return }
        let pos = inputFile.offsetInFile
        inputFile.seek(toFileOffset: posMDAT)
        let hdr = inputFile.readData(ofLength: 4)
        let p = [UInt8](hdr)
        let lenMDAT = to_host(p)
        let posEnd = posMDAT + UInt64(lenMDAT)
        let cRead = UInt32(posEnd - pos)
        inputFile.seek(toFileOffset: pos)
        readAndDeliver(cRead: cRead)

        inputFile.closeFile()
        foundMDAT = false
        bytesToNextAtom = 0
        try? FileManager.default.removeItem(atPath: oldPath)

        if let writerPath = writer?.path {
            self.inputFile = FileHandle(forReadingAtPath: writerPath)
            if let fd = self.inputFile?.fileDescriptor, let queue = readQueue {
                readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                readSource?.setEventHandler { [weak self] in
                    self?.onFileUpdate()
                }
                readSource?.resume()
            }
        }
        swapping = false
    }

    private func readAndDeliver(cRead: UInt32) {
        guard let inputFile = inputFile else { return }
        var cReady = cRead
        while cReady > lengthSize {
            let lenField = inputFile.readData(ofLength: lengthSize)
            cReady -= UInt32(lengthSize)
            let p = [UInt8](lenField)
            let lenNALU = to_host(p)
            if UInt32(lenNALU) > cReady {
                inputFile.seek(toFileOffset: inputFile.offsetInFile - 4)
                break
            }
            let nalu = inputFile.readData(ofLength: lenNALU)
            cReady -= UInt32(lenNALU)
            onNALU(nalu)
        }
    }

    private func onFileUpdate() {
        guard let inputFile = inputFile else { return }
        var statbuf = stat()
        fstat(inputFile.fileDescriptor, &statbuf)
        var cReady = Int(statbuf.st_size - Int64(inputFile.offsetInFile))
        while !foundMDAT && cReady > 8 {
            if bytesToNextAtom == 0 {
                let hdr = inputFile.readData(ofLength: 8)
                cReady -= 8
                let p = [UInt8](hdr)
                let lenAtom = to_host(Array(p[0...3]))
                let nameAtom = to_host(Array(p[4...7]))
                if nameAtom == fourCC("mdat") {
                    foundMDAT = true
                    posMDAT = inputFile.offsetInFile - 8
                } else {
                    bytesToNextAtom = Int(lenAtom) - 8
                }
            }
            if bytesToNextAtom > 0 {
                let cThis = min(cReady, bytesToNextAtom)
                bytesToNextAtom -= cThis
                inputFile.seek(toFileOffset: inputFile.offsetInFile + UInt64(cThis))
                cReady -= cThis
            }
        }
        if !foundMDAT { return }
        readAndDeliver(cRead: UInt32(cReady))
    }

    // MARK: - Frame Delivery

    private func deliverFrame(_ frame: [Data], withTime pts: Double) {
        if firstPTS < 0 { firstPTS = pts }
        if (pts - firstPTS) < 1 {
            let bytes = frame.reduce(0) { $0 + $1.count }
            bitspersecond += (bytes * 8)
        }
        outputBlock?(frame, pts)
    }

    private func processStoredFrames() {
        var n = 0
        for f in frames {
            let index: Int
            if n == 0 {
                index = frames.count - 1
            } else {
                index = n - 1
            }
            var pts: Double = 0
            if !times.isEmpty, index < times.count {
                pts = times[index]
            }
            deliverFrame(f.frame, withTime: pts)
            n += 1
        }
        if !frames.isEmpty {
            times.removeFirst(min(times.count, frames.count))
        }
        frames.removeAll()
    }

    private func onEncodedFrame() {
        var poc = 0
        for d in pendingNALU ?? [] {
            d.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                let p = buf.bindMemory(to: UInt8.self).baseAddress!
                let nal = NALUnit(pStart: p, len: d.count)
                if pocState.GetPOC(nal, pPOC: &poc) { return }
            }
        }
        if poc == 0 {
            processStoredFrames()
            var pts: Double = 0
            if !times.isEmpty {
                pts = times[0]
                times.removeFirst()
            }
            deliverFrame(pendingNALU ?? [], withTime: pts)
            prevPOC = 0
        } else {
            let f = EncodedFrame(nalus: pendingNALU ?? [], poc: poc)
            if poc > prevPOC {
                processStoredFrames()
                prevPOC = poc
            }
            frames.append(f)
        }
    }

    private func onNALU(_ nalu: Data) {
        let pNal = [UInt8](nalu)
        let idc = pNal[0] & 0x60
        let naltype = pNal[0] & 0x1f

        if let _ = pendingNALU {
            let nal = nalu.withUnsafeBytes {
                NALUnit(pStart: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), len: nalu.count)
            }
            var bNew = false
            if prevNalType < 6 {
                if naltype >= 6 {
                    bNew = true
                } else if (idc != prevNalIDC) && ((idc == 0) || (prevNalIDC == 0)) {
                    bNew = true
                } else if (naltype != prevNalType) && (naltype == 5) {
                    bNew = true
                } else if (naltype >= 1) && (naltype <= 5) {
                    nal.Skip(8)
                    let first_mb = nal.GetUE()
                    if first_mb == 0 { bNew = true }
                }
            }
            if bNew {
                onEncodedFrame()
                pendingNALU = nil
            }
        }
        prevNalType = Int(naltype)
        prevNalIDC = Int(idc)
        if pendingNALU == nil {
            pendingNALU = []
        }
        pendingNALU?.append(nalu)
    }
}

// MARK: - Utility Functions

private func to_host(_ p: [UInt8]) -> Int {
    guard p.count >= 4 else { return 0 }
    return (Int(p[0]) << 24) | (Int(p[1]) << 16) | (Int(p[2]) << 8) | Int(p[3])
}

private func fourCC(_ str: String) -> UInt32 {
    var result: UInt32 = 0
    for c in str.utf8.prefix(4) {
        result = (result << 8) | UInt32(c)
    }
    return result
}
