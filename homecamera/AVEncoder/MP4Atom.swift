import Foundation

typealias MP4AtomType = UInt32

extension MP4AtomType {
    init(_ string: String) {
        assert(string.count == 4, "MP4AtomType must be initialized with a 4-character string")
        // big endian encoding of a 4-character string as UInt32
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
        return try! file.read(upToCount: size)!
    }

    // Get the next child atom, or nil if none
    mutating func nextChild() -> MP4Atom? {
        guard nextChildOffset <= length - 8 else {
            return nil
        }

        try? file.seek(toOffset: offset + nextChildOffset)
        guard let data = try? file.read(upToCount: 8) else {
            print("Failed to read data at offset \(offset + nextChildOffset)")
            return nil
        }
        var cHeader = 8
        guard data.count == 8 else { return nil }
        var len = Int64(data.read(as: UInt32.self).bigEndian)
        let fourcc = data.read(at: data.startIndex + 4, as: UInt32.self).bigEndian
        if len == 1 {
            // 64-bit extended length
            cHeader += 8
            guard let data = try? file.read(upToCount: 8) else {
                print("Failed to read extended length data at offset \(offset + nextChildOffset)")
                return nil
            }
            len =
                (Int64(data.read(as: UInt32.self).bigEndian) << 32)
                + Int64(data.read(at: data.startIndex + 4, as: UInt32.self).bigEndian)
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
