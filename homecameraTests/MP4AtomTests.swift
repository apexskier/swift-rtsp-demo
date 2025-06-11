import Testing
import Foundation

struct MP4AtomTests {
    @Test
    func testAtomAtAndInit() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = Data([0x00, 0x00, 0x00, 0x08, 0x6d, 0x64, 0x61, 0x74]) // 8 bytes, type 'mdat'
        try data.write(to: tempURL)
        let handle = try FileHandle(forReadingFrom: tempURL)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: tempURL) }
        let atom = try #require(MP4Atom(at: 0, size: 8, type: 0x6d646174, inFile: handle))
        #expect(atom.type == 0x6d646174)
        #expect(atom.length == 8)
        let child = try #require(atom.child(ofType: 0x6d646174, startAt: 0))
        #expect(child.type == 0x6d646174)
        #expect(child.length == 0)
    }

    @Test
    func testReadAt() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        try data.write(to: tempURL)
        let fileHandle = try? FileHandle(forReadingFrom: tempURL)
        let handle = try #require(fileHandle)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: tempURL) }
        let atom = try #require(MP4Atom(at: 0, size: 8, type: 0x6d646174, inFile: handle))
        #expect(atom.read(at: 2, size: 4) == Data([0x03, 0x04, 0x05, 0x06]))
    }

    @Test
    func testSetChildOffset() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: tempURL.path, contents: Data(count: 8))
        let handle = try FileHandle(forReadingFrom: tempURL)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: tempURL) }
        let atom = try #require(MP4Atom(at: 0, size: 8, type: 0x6d646174, inFile: handle))
        let nextChild = try #require(atom.nextChild())
        #expect(nextChild.type == 0)
        #expect(nextChild.length == 0)
        atom.setChildOffset(4)
        #expect(atom.nextChild() == nil)
    }

    @Test
    func testChildOfTypeReturnsNilIfNotFound() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: tempURL.path, contents: Data(count: 8))
        let handle = try FileHandle(forReadingFrom: tempURL)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: tempURL) }
        let atom = try #require(MP4Atom(at: 0, size: 8, type: 0x6d646174, inFile: handle))
        let child = atom.child(ofType: 0x666f6f20, startAt: 0)
        #expect(child == nil)
    }
}
