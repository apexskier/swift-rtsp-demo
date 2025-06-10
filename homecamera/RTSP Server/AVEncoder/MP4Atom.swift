//
//  MP4Atom.swift
//  Encoder Demo
//
//  Created by Geraint Davies on 15/01/2013.
//  Copyright (c) 2013 GDCL http://www.gdcl.co.uk/license.htm
//

import CoreFoundation
import Foundation

final class MP4Atom {
    private var file: FileHandle
    private var offset: Int64
    private(set) var length: Int64
    private(set) var type: UInt32
    private var nextChildPtr: Int64 = 0

    // MARK: - Initializer

    private init(file: FileHandle, offset: Int64, length: Int64, type: UInt32) {
        self.file = file
        self.offset = offset
        self.length = length
        self.type = type
        self.nextChildPtr = 0
    }

    // MARK: - Factory

    static func atomAt(
        offset: Int64,
        size: Int,
        type fourcc: UInt32,
        inFile handle: FileHandle
    ) -> MP4Atom? {
        let atom = MP4Atom(file: handle, offset: offset, length: Int64(size), type: fourcc)
        return atom
    }

    // MARK: - Interface

    func readAt(offset: Int64, size: Int) -> Data? {
        do {
            try file.seek(toOffset: UInt64(self.offset + offset))
            return file.readData(ofLength: size)
        } catch {
            return nil
        }
    }

    @discardableResult
    func setChildOffset(_ offset: Int64) -> Bool {
        nextChildPtr = offset
        return true
    }

    func nextChild() -> MP4Atom? {
        if nextChildPtr <= (length - 8) {
            do {
                try file.seek(toOffset: UInt64(offset + nextChildPtr))
                guard let data = try? file.read(upToCount: 8),
                    data.count == 8
                else { return nil }
                var cHeader = 8
                let len = toHost(data[0...3])
                let fourcc = toHost(data[4...7])
                var atomLen = Int64(len)
                let atomType = UInt32(fourcc)

                if atomLen == 1 {
                    // 64-bit extended length
                    cHeader += 8
                    guard let extData = try? file.read(upToCount: 8),
                        extData.count == 8
                    else { return nil }
                    let hi = toHost(extData[0...3])
                    let lo = toHost(extData[4...7])
                    atomLen = (Int64(hi) << 32) + Int64(lo)
                } else if atomLen == 0 {
                    // whole remaining parent space
                    atomLen = length - nextChildPtr
                }

                if atomType == fourCC("uuid") {
                    cHeader += 16
                }
                if atomLen < 0 || (atomLen + nextChildPtr) > length {
                    return nil
                }
                let atomOffset = nextChildPtr + Int64(cHeader)
                nextChildPtr += atomLen
                let contentLen = atomLen - Int64(cHeader)
                return MP4Atom.atomAt(
                    offset: atomOffset + offset,
                    size: Int(contentLen),
                    type: atomType,
                    inFile: file
                )
            } catch {
                return nil
            }
        }
        return nil
    }

    func childOfType(_ fourcc: UInt32, startAt offset: Int64) -> MP4Atom? {
        setChildOffset(offset)
        var child: MP4Atom?
        repeat {
            child = nextChild()
        } while child != nil && child?.type != fourcc
        return child
    }

    // MARK: - Helpers

    private func toHost(_ data: Data) -> UInt32 {
        // Big-endian UInt32
        var value: UInt32 = 0
        for b in data {
            value = (value << 8) | UInt32(b)
        }
        return value
    }

    private func fourCC(_ str: String) -> UInt32 {
        var result: UInt32 = 0
        for c in str.utf8.prefix(4) {
            result = (result << 8) | UInt32(c)
        }
        return result
    }
}
