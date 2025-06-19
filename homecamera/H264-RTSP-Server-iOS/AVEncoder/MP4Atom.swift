import Foundation

typealias MP4AtomType = UInt32

extension MP4AtomType {
    init(_ string: String) {
        self = string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

// MP4Atom: Represents an atom/box in an MP4 file, with child navigation and data reading
struct MP4Atom {
    private let file: FileHandle
    private let offset: UInt64
    let length: Int64
    let type: UInt32
    private var nextChildOffset: UInt64 = 0

    init(at offset: UInt64, size: Int64, type: UInt32, inFile handle: FileHandle) {
        self.file = handle
        self.offset = offset
        self.length = size
        self.type = type
    }

    // Read data at offset from atom start
    func read(at offset: UInt64 = 0, size: Int) -> Data {
        try? file.seek(toOffset: self.offset + offset)
        return file.readData(ofLength: size)
    }

    // Get the next child atom, or nil if none
    mutating func nextChild() -> MP4Atom? {
        guard nextChildOffset <= length - 8 else {
            return nil
        }

        try? file.seek(toOffset: offset + nextChildOffset)
        var data = file.readData(ofLength: 8)
        var cHeader = 8
        guard data.count == 8 else { return nil }
        let p = [UInt8](data)
        var len = Int64(toHost(p))
        let fourcc = toHost(Array(p[4..<8]))
        if len == 1 {
            // 64-bit extended length
            cHeader += 8
            data = file.readData(ofLength: 8)
            let extp = [UInt8](data)
            len = (Int64(toHost(Array(extp[0..<4]))) << 32) + Int64(toHost(Array(extp[4..<8])))
        } else if len == 0 {
            // whole remaining parent space
            len = length - Int64(nextChildOffset)
        }
        if fourcc == MP4AtomType("uuid") {
            cHeader += 16
        }
        if (len < 0) || ((len + Int64(nextChildOffset)) > length) {
            return nil
        }
        let childOffset = nextChildOffset + UInt64(cHeader)
        nextChildOffset += UInt64(len)
        let childLen = len - Int64(cHeader)
        return MP4Atom(at: offset + childOffset, size: childLen, type: fourcc, inFile: file)
    }

    // Find the first child of a given type, starting at offset
    mutating func child(ofType fourcc: UInt32, startAt offset: UInt64 = 0) -> MP4Atom? {
        nextChildOffset = offset
        var child: MP4Atom? = nil
        repeat {
            child = nextChild()
        } while child != nil && child!.type != fourcc
        return child
    }

    mutating func child(ofType fourcc: String, startAt offset: UInt64 = 0) -> MP4Atom? {
        child(ofType: MP4AtomType(fourcc), startAt: offset)
    }
}

// TODO: remove
// Helper: Convert 4 big-endian bytes to UInt32
fileprivate func toHost(_ p: [UInt8]) -> UInt32 {
    precondition(p.count >= 4)
    return (UInt32(p[0]) << 24) | (UInt32(p[1]) << 16) | (UInt32(p[2]) << 8) | UInt32(p[3])
}
