import XCTest
@testable import Svga

final class ZipReaderTests: XCTestCase {

    func testReadsStoredEntry() throws {
        let payload = "hello world".data(using: .utf8)!
        let zip = try buildStoredZip(name: "greeting.txt", payload: payload)
        let entries = try ZipReader.entries(from: zip)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "greeting.txt")
        XCTAssertEqual(entries[0].data, payload)
    }

    func testRejectsPathTraversalEntries() throws {
        let zip = try buildStoredZip(name: "../etc/passwd", payload: Data([0x00]))
        let entries = try ZipReader.entries(from: zip)
        XCTAssertTrue(entries.isEmpty)
    }

    func testRejectsCorruptArchive() {
        XCTAssertThrowsError(try ZipReader.entries(from: Data([0x00, 0x01, 0x02])))
    }

    // MARK: - Test helpers

    private func buildStoredZip(name: String, payload: Data) throws -> Data {
        let nameBytes = Array(name.utf8)
        let crc = crc32(of: payload)
        let size = UInt32(payload.count)

        var lfh = Data()
        lfh.append(uint32: 0x04034B50)             // local file header signature
        lfh.append(uint16: 20)                     // version needed
        lfh.append(uint16: 0)                      // flags
        lfh.append(uint16: 0)                      // method (0 = stored)
        lfh.append(uint16: 0)                      // mod time
        lfh.append(uint16: 0)                      // mod date
        lfh.append(uint32: crc)                    // crc-32
        lfh.append(uint32: size)                   // compressed size
        lfh.append(uint32: size)                   // uncompressed size
        lfh.append(uint16: UInt16(nameBytes.count))
        lfh.append(uint16: 0)                      // extra length
        lfh.append(contentsOf: nameBytes)
        lfh.append(payload)

        let cdOffset = UInt32(lfh.count)
        var cd = Data()
        cd.append(uint32: 0x02014B50)              // central directory signature
        cd.append(uint16: 20)                      // version made by
        cd.append(uint16: 20)                      // version needed
        cd.append(uint16: 0)                       // flags
        cd.append(uint16: 0)                       // method
        cd.append(uint16: 0)                       // mod time
        cd.append(uint16: 0)                       // mod date
        cd.append(uint32: crc)
        cd.append(uint32: size)
        cd.append(uint32: size)
        cd.append(uint16: UInt16(nameBytes.count))
        cd.append(uint16: 0)                       // extra length
        cd.append(uint16: 0)                       // comment length
        cd.append(uint16: 0)                       // disk number
        cd.append(uint16: 0)                       // internal attrs
        cd.append(uint32: 0)                       // external attrs
        cd.append(uint32: 0)                       // local header offset
        cd.append(contentsOf: nameBytes)

        var eocd = Data()
        eocd.append(uint32: 0x06054B50)
        eocd.append(uint16: 0)                     // disk number
        eocd.append(uint16: 0)                     // start disk
        eocd.append(uint16: 1)                     // entries on disk
        eocd.append(uint16: 1)                     // entries total
        eocd.append(uint32: UInt32(cd.count))      // central dir size
        eocd.append(uint32: cdOffset)              // central dir offset
        eocd.append(uint16: 0)                     // comment length

        var out = lfh
        out.append(cd)
        out.append(eocd)
        return out
    }

    private func crc32(of data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask: UInt32 = (crc & 1) == 0 ? 0 : 0xEDB88320
                crc = (crc >> 1) ^ mask
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func append(uint32 value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
