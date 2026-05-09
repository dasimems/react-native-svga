import Foundation

internal final class ProtoReader {
    enum Wire: Int {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    struct Tag {
        let field: Int
        let wire: Int
    }

    private let bytes: [UInt8]
    private let limit: Int
    private var pos: Int

    init(_ data: Data) {
        self.bytes = [UInt8](data)
        self.limit = self.bytes.count
        self.pos = 0
    }

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.limit = bytes.count
        self.pos = 0
    }

    private init(bytes: [UInt8], pos: Int, limit: Int) {
        self.bytes = bytes
        self.pos = pos
        self.limit = limit
    }

    var hasMore: Bool { pos < limit }

    func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var read = 0
        while pos < limit {
            if read >= 10 { throw SvgaError("varint too long") }
            let b = UInt64(bytes[pos])
            pos += 1
            read += 1
            result |= (b & 0x7F) << shift
            if (b & 0x80) == 0 { return result }
            shift += 7
        }
        throw SvgaError("truncated varint")
    }

    func readTag() throws -> Tag {
        let raw = Int(try readVarint())
        return Tag(field: raw >> 3, wire: raw & 0x7)
    }

    func readSubReader() throws -> ProtoReader {
        let len = Int(try readVarint())
        if len < 0 || pos + len > limit { throw SvgaError("length-delimited overflow") }
        let sub = ProtoReader(bytes: bytes, pos: pos, limit: pos + len)
        pos += len
        return sub
    }

    func readBytes() throws -> Data {
        let len = Int(try readVarint())
        if len < 0 || pos + len > limit { throw SvgaError("length-delimited overflow") }
        let slice = bytes[pos..<(pos + len)]
        pos += len
        return Data(slice)
    }

    func readString() throws -> String {
        let len = Int(try readVarint())
        if len < 0 || pos + len > limit { throw SvgaError("length-delimited overflow") }
        let slice = bytes[pos..<(pos + len)]
        pos += len
        return String(decoding: slice, as: UTF8.self)
    }

    func readInt32() throws -> Int32 { Int32(truncatingIfNeeded: try readVarint()) }

    func readFloat() throws -> Float {
        if pos + 4 > limit { throw SvgaError("truncated float") }
        let bits = UInt32(bytes[pos])
            | (UInt32(bytes[pos + 1]) << 8)
            | (UInt32(bytes[pos + 2]) << 16)
            | (UInt32(bytes[pos + 3]) << 24)
        pos += 4
        return Float(bitPattern: bits)
    }

    func skip(wire: Int) throws {
        switch wire {
        case Wire.varint.rawValue: _ = try readVarint()
        case Wire.fixed64.rawValue: try advance(8)
        case Wire.lengthDelimited.rawValue: try skipBytes()
        case Wire.fixed32.rawValue: try advance(4)
        default: throw SvgaError("unknown wire type \(wire)")
        }
    }

    private func skipBytes() throws {
        let len = Int(try readVarint())
        if len < 0 || pos + len > limit { throw SvgaError("length-delimited overflow") }
        pos += len
    }

    private func advance(_ n: Int) throws {
        if pos + n > limit { throw SvgaError("truncated fixed field") }
        pos += n
    }
}
