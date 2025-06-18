import AVFoundation
import Foundation

// Typealiases for handler blocks
public typealias EncoderHandler = (_ data: [Data], _ pts: Double) -> Void
public typealias ParamHandler = (_ params: Data) -> Void

// store the calculated POC with a frame ready for timestamp assessment
// (recalculating POC out of order will get an incorrect result)
private struct EncodedFrame {
    let poc: Int
    let frame: [Data]
}

func to_host(_ x: Data) -> UInt32 {
    x.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
}

class AVEncoder {
    // MARK: - Properties

    // initial writer, used to obtain SPS/PPS from header
    private var headerWriter: VideoEncoder?

    // main encoder/writer
    private var writer: VideoEncoder?

    // writer output file (input to our extractor) and monitoring
    private var inputFile: FileHandle?
    private var readQueue: DispatchQueue?
    private var readSource: DispatchSourceRead?

    // index of current file name
    private var swapping = false
    private var currentFile = 1
    private var height = 0
    private var width = 0

    // param set data
    private(set) var avcC: Data?
    private var lengthSize = 0

    // POC
    private var pocState = POCState()
    private var prevPOC = 0

    // location of mdat
    private var foundMDAT = false
    private var posMDAT: UInt64 = 0
    private var bytesToNextAtom = 0
    private var needParams = false

    // tracking if NALU is next frame
    private var prevNalIdc = 0
    private var prevNalType = 0
    // array of NSData comprising a single frame. each data is one nalu with no start code
    private var pendingNALU: [Data]? = nil

    // FIFO for frame times
    private var times: [Double] = []

    // FIFO for frames awaiting time assigment
    private var frames: [EncodedFrame] = []

    private var outputBlock: EncoderHandler?
    private var paramsBlock: ParamHandler?

    // estimate bitrate over first second
    private(set) var bitspersecond = 0
    private var firstpts: Double = -1

    // MARK: - Constants
    private let outputFileSwitchPoint: UInt64 = 50 * 1024 * 1024  // 50 MB switch point
    private let maxFilenameIndex = 5  // filenames "capture1.mp4" wraps at capture5.mp4

    // MARK: - Public API

    init(height: Int, width: Int) {
        self.height = height
        self.width = width
        let path = NSTemporaryDirectory().appending("params.mp4")
        headerWriter = VideoEncoder(path: path, height: height, width: width)
        times = []
        times.reserveCapacity(10)
        currentFile = 1
        writer = VideoEncoder(path: makeFilename(), height: height, width: width)
    }

    func encode(
        withBlock block: @escaping EncoderHandler,
        onParams paramsHandler: @escaping ParamHandler
    ) {
        outputBlock = block
        paramsBlock = paramsHandler
        needParams = true
        pendingNALU = nil
        firstpts = -1
        bitspersecond = 0
    }

    func encode(frame sampleBuffer: CMSampleBuffer) {
        objc_sync_enter(self)
        if needParams {
            // the avcC record is needed for decoding and it's not written to the file until
            // completion. We get round that by writing the first frame to two files; the first
            // file (containing only one frame) is then finished, so we can extract the avcC record.
            // Only when we've got that do we start reading from the main file.
            needParams = false
            if headerWriter?.encodeFrame(sampleBuffer) == true {
                headerWriter?
                    .finishWithCompletionHandler { [weak self] in
                        self?.onParamsCompletion()
                    }
            }
        }
        objc_sync_exit(self)
        let prestime = sampleBuffer.presentationTimeStamp
        let dPTS = Double(prestime.value) / Double(prestime.timescale)
        objc_sync_enter(times)
        times.append(dPTS)
        objc_sync_exit(times)
        objc_sync_enter(self)
        // switch output files when we reach a size limit
        // to avoid runaway storage use.
        if !swapping {
            let offset = try? inputFile?.offset()
            let st = try? inputFile?.seekToEnd()
            if let offset {
                try? inputFile?.seek(toOffset: offset)
            }
            if let st, st > outputFileSwitchPoint {
                swapping = true
                let oldVideo = writer
                // construct a new writer to the next filename
                currentFile += 1
                if currentFile > maxFilenameIndex { currentFile = 1 }
                print("Swap to file \(currentFile)")
                writer = VideoEncoder(path: makeFilename(), height: height, width: width)
                // to do this seamlessly requires a few steps in the right order
                // first, suspend the read source
                readSource?.cancel()
                // execute the next step as a block on the same queue, to be sure the suspend is done
                readQueue?
                    .async { [weak self] in
                        // finish the file, writing moov, before reading any more from the file
                        // since we don't yet know where the mdat ends
                        self?.readSource = nil
                        oldVideo?
                            .finishWithCompletionHandler {
                                self?.swapFiles(oldVideo?.path ?? "")
                            }
                    }
            }
        }
        _ = writer?.encodeFrame(sampleBuffer)
        objc_sync_exit(self)
    }

    func shutdown() {
        objc_sync_enter(self)
        readSource = nil
        headerWriter?.finishWithCompletionHandler { [weak self] in self?.headerWriter = nil }
        writer?.finishWithCompletionHandler { [weak self] in self?.writer = nil }
        // !! wait for these to finish before returning and delete temp files
        objc_sync_exit(self)
    }

    var bitsPerSecond: Int { bitspersecond }

    // MARK: - Private
    private func makeFilename() -> String {
        let filename = "capture\(currentFile).mp4"
        return NSTemporaryDirectory().appending(filename)
    }

    private func onParamsCompletion() {
        guard let headerWriter, let writer else {
            return
        }
        guard parseParams(headerWriter.path) else {
            return
        }
        if let avcC {
            paramsBlock?(avcC)
        }
        self.headerWriter = nil
        swapping = false
        inputFile = try? FileHandle(forReadingFrom: URL(fileURLWithPath: writer.path))
        guard let inputFile else {
            return
        }
        readQueue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier!).avencoder.read")
        readSource = DispatchSource.makeReadSource(
            fileDescriptor: inputFile.fileDescriptor,
            queue: readQueue
        )
        readSource?.setEventHandler { [weak self] in self?.onFileUpdate() }
        readSource?.resume()
    }

    private func parseParams(_ path: String) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return false
        }
        defer { try? file.close() }
        let s = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        var movie = MP4Atom(at: 0, size: Int64(s), type: MP4AtomType("file"), inFile: file)
        guard var moov = movie.child(ofType: "moov") else { return false }
        var trak: MP4Atom? = nil
        repeat {
            trak = moov.nextChild()
            if var t = trak, t.type == MP4AtomType("trak") {
                if let tkhd = t.child(ofType: "tkhd") {
                    let verflags = tkhd.read(size: 4)
                    if verflags.count == 4, (verflags[3] & 1) != 0 { break } else { continue }
                }
            }
        } while trak != nil
        var stsd: MP4Atom? = nil
        if var trak {
            if var media = trak.child(ofType: "mdia"),
                var minf = media.child(ofType: "minf"),
                var stbl = minf.child(ofType: "stbl")
            {
                stsd = stbl.child(ofType: "stsd")
            }
        }
        if var stsd = stsd,
            var avc1 = stsd.child(ofType: "avc1", startAt: 8),
            let esd = avc1.child(ofType: "avcC", startAt: 78)
        {
            // this is the avcC record that we are looking for
            avcC = esd.read(size: Int(esd.length))
            if let avcC, avcC.count > 4 {
                // extract size of length field
                lengthSize = Int((avcC[4] & 3) + 1)
                guard let avc = AVCCHeader(header: avcC) else {
                    return false
                }
                pocState.setHeader(avc)
                return true
            }
        }
        return false
    }

    private func swapFiles(_ oldPath: String) {
        guard let inputFile else { return }
        // save current position
        let pos = inputFile.offsetInFile

        // re-read mdat length
        inputFile.seek(toFileOffset: posMDAT)
        let hdr = inputFile.readData(ofLength: 4)
        let lenMDAT = to_host(hdr)

        // extract nalus from saved position to mdat end
        let posEnd = posMDAT + UInt64(lenMDAT)
        let cRead = UInt32(posEnd - pos)
        inputFile.seek(toFileOffset: pos)
        readAndDeliver(cRead)

        // close and remove file
        try? inputFile.close()
        foundMDAT = false
        bytesToNextAtom = 0
        try? FileManager.default.removeItem(atPath: oldPath)

        // open new file and set up dispatch source
        if let writer {
            self.inputFile = try? FileHandle(forReadingFrom: URL(fileURLWithPath: writer.path))
            if let inputFile = self.inputFile {
                readSource = DispatchSource.makeReadSource(
                    fileDescriptor: inputFile.fileDescriptor,
                    queue: readQueue
                )
                readSource?.setEventHandler { [weak self] in self?.onFileUpdate() }
                readSource?.resume()
            }
        }
        swapping = false
    }

    private func readAndDeliver(_ cReady: UInt32) {
        guard let inputFile else { return }

        // Identify the individual NALUs and extract them
        var cReady = cReady
        while cReady > lengthSize {
            guard let lenField = try? inputFile.read(upToCount: lengthSize) else {
                continue
            }
            cReady -= UInt32(lengthSize)
            let lenNALU = to_host(lenField)
            if lenNALU > cReady {
                // whole NALU not present -- seek back to start of NALU and wait for more
                inputFile.seek(toFileOffset: inputFile.offsetInFile - 4)
                break
            }
            let nalu = inputFile.readData(ofLength: Int(lenNALU))
            cReady -= lenNALU
            onNALU(nalu)
        }
    }

    private func onFileUpdate() {
        guard let inputFile, let writer else { return }

        // called whenever there is more data to read in the main encoder output file.

        let offset = try! inputFile.offset()
        // let st = try! inputFile.seekToEnd()
        // try! inputFile.seek(toOffset: offset)
        guard
            let st = try? FileManager.default.attributesOfItem(atPath: writer.path)[.size]
                as? UInt64
        else {
            return
        }
        let cReady = Int(st - offset)

        // locate the mdat atom if needed
        while !foundMDAT && cReady > 8 {
            if bytesToNextAtom == 0 {
                let hdr = inputFile.readData(ofLength: 8)
                let lenAtom = to_host(hdr)
                let nameAtom = to_host(hdr.advanced(by: 4))
                if nameAtom == MP4AtomType("mdat") {
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
            }
        }
        if !foundMDAT { return }

        // the mdat must be just encoded video.
        readAndDeliver(UInt32(cReady))
    }

    private func deliverFrame(_ frame: [Data], withTime pts: Double) {
        if firstpts < 0 { firstpts = pts }
        if (pts - firstpts) < 1 {
            let bytes = frame.reduce(0) { $0 + $1.count }
            bitspersecond += bytes * 8
        }
        outputBlock?(frame, pts)
    }

    private func processStoredFrames() {
        // first has the last timestamp and rest use up timestamps from the start
        for (n, f) in frames.enumerated() {
            let index = n == 0 ? frames.count - 1 : n - 1
            var pts: Double = 0
            objc_sync_enter(times)
            if times.count > 0 { pts = times[index] }
            objc_sync_exit(times)
            deliverFrame(f.frame, withTime: pts)
        }
        objc_sync_enter(times)
        times.removeFirst(frames.count)
        objc_sync_exit(times)
        frames.removeAll()
    }

    private func onEncodedFrame() {
        var poc = 0
        if let pendingNALU {
            for d in pendingNALU {
                let nal = NALUnit(data: d)
                if let value = pocState.getPOC(nal: nal) {
                    poc = value
                    break
                }
            }
        }
        if poc == 0 {
            processStoredFrames()
            var pts: Double = 0
            objc_sync_enter(times)
            if let first = times.first {
                pts = first
                times.removeFirst()
            }
            objc_sync_exit(times)
            if let pendingNALU {
                deliverFrame(pendingNALU, withTime: pts)
            }
            prevPOC = 0
        } else {
            let f = EncodedFrame(poc: poc, frame: pendingNALU ?? [])
            if poc > prevPOC {
                // all pending frames come before this, so share out the
                // timestamps in order of POC
                processStoredFrames()
                prevPOC = poc
            }
            frames.append(f)
        }
    }

    // combine multiple NALUs into a single frame, and in the process, convert to BSF
    // by adding 00 00 01 startcodes before each NALU.
    private func onNALU(_ nalu: Data) {
        let idc = Int(nalu[0] & 0x60)
        let naltype = Int(nalu[0] & 0x1f)
        if pendingNALU != nil {
            let nal = NALUnit(data: nalu)
            // we have existing data —is this the same frame?
            // typically there are a couple of NALUs per frame in iOS encoding.
            // This is not general-purpose: it assumes that arbitrary slice ordering is not allowed.
            var bNew = false

            // sei and param sets go with following nalu
            if prevNalType < 6 {
                if naltype >= 6 {
                    bNew = true
                } else if (idc != prevNalIdc) && ((idc == 0) || (prevNalIdc == 0)) {
                    bNew = true
                } else if (naltype != prevNalType) && (naltype == 5) {
                    bNew = true
                } else if (naltype >= 1) && (naltype <= 5) {
                    nal.skip(8)
                    if nal.getUE() == 0 {
                        bNew = true
                    }
                }
            }
            if bNew {
                onEncodedFrame()
                self.pendingNALU = nil
            }
        }
        prevNalType = naltype
        prevNalIdc = idc
        if pendingNALU == nil {
            pendingNALU = []
            pendingNALU?.reserveCapacity(2)
        }
        pendingNALU?.append(nalu)
    }
}
