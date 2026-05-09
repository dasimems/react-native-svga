import XCTest
@testable import Svga

final class ProtoReaderTests: XCTestCase {

    func testSingleByteVarint() throws {
        let r = ProtoReader(Data([0x05]))
        XCTAssertEqual(try r.readVarint(), 5)
        XCTAssertFalse(r.hasMore)
    }

    func testMultiByteVarint() throws {
        let r = ProtoReader(Data([0xAC, 0x02]))
        XCTAssertEqual(try r.readVarint(), 300)
    }

    func testTagSplitsFieldAndWire() throws {
        let r = ProtoReader(Data([0x0A]))
        let tag = try r.readTag()
        XCTAssertEqual(tag.field, 1)
        XCTAssertEqual(tag.wire, ProtoReader.Wire.lengthDelimited.rawValue)
    }

    func testLengthDelimitedBytes() throws {
        let r = ProtoReader(Data([0x03, 0xAA, 0xBB, 0xCC]))
        let bytes = try r.readBytes()
        XCTAssertEqual([UInt8](bytes), [0xAA, 0xBB, 0xCC])
    }

    func testStringRoundTrip() throws {
        let payload = "hello".data(using: .utf8)!
        var data = Data([UInt8(payload.count)])
        data.append(payload)
        let r = ProtoReader(data)
        XCTAssertEqual(try r.readString(), "hello")
    }

    func testLittleEndianFloat() throws {
        let r = ProtoReader(Data([0x00, 0x00, 0x80, 0x3F]))
        XCTAssertEqual(try r.readFloat(), 1.0, accuracy: 0.0001)
    }

    func testTruncatedVarintThrows() {
        let r = ProtoReader(Data([0x80]))
        XCTAssertThrowsError(try r.readVarint())
    }

    func testLengthOverflowThrows() {
        let r = ProtoReader(Data([0x10, 0x00, 0x01]))
        XCTAssertThrowsError(try r.readBytes())
    }

    func testTruncatedFloatThrows() {
        let r = ProtoReader(Data([0x00, 0x00]))
        XCTAssertThrowsError(try r.readFloat())
    }

    func testSkipHandlesAllWireTypes() throws {
        let r = ProtoReader(Data([0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
        try r.skip(wire: ProtoReader.Wire.varint.rawValue)
        try r.skip(wire: ProtoReader.Wire.fixed64.rawValue)
        XCTAssertFalse(r.hasMore)
    }

    func testUnknownWireTypeThrows() {
        let r = ProtoReader(Data([0x00]))
        XCTAssertThrowsError(try r.skip(wire: 7))
    }

    func testHasMoreReportsRemaining() throws {
        let r = ProtoReader(Data([0x01, 0x02]))
        XCTAssertTrue(r.hasMore)
        _ = try r.readVarint()
        XCTAssertTrue(r.hasMore)
        _ = try r.readVarint()
        XCTAssertFalse(r.hasMore)
    }
}
