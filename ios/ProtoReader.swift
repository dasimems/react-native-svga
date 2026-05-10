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

    private let data: Data
    private let base: Int
    private let limit: Int
    private var pos: Int

    init(_ data: Data) {
        self.data = data
        self.base = data.startIndex
        self.limit = data.endIndex
        self.pos = data.startIndex
    }

    private init(data: Data, base: Int, limit: Int) {
        self.data = data
        self.base = base
        self.limit = limit
        self.pos = base
    }

    var hasMore: Bool { pos < limit }

    func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var read = 0
        while pos < limit {
            if read >= 10 { throw SvgaError("varint too long") }
            let b = UInt64(data[pos])
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
        let len = try checkedLength()
        let sub = ProtoReader(data: data, base: pos, limit: pos + len)
        pos += len
        return sub
    }

    func readBytes() throws -> Data {
        let len = try checkedLength()
        let slice = data.subdata(in: pos..<(pos + len))
        pos += len
        return slice
    }

    func readString() throws -> String {
        let len = try checkedLength()
        // subdata copies; required because the caller may outlive `data` and
        // a slice would retain the whole buffer.
        let slice = data.subdata(in: pos..<(pos + len))
        pos += len
        return String(decoding: slice, as: UTF8.self)
    }

    func readInt32() throws -> Int32 { Int32(truncatingIfNeeded: try readVarint()) }

    func readFloat() throws -> Float {
        if pos + 4 > limit { throw SvgaError("truncated float") }
        let bits = UInt32(data[pos])
            | (UInt32(data[pos + 1]) << 8)
            | (UInt32(data[pos + 2]) << 16)
            | (UInt32(data[pos + 3]) << 24)
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
        let len = try checkedLength()
        pos += len
    }

    private func advance(_ n: Int) throws {
        if pos + n > limit { throw SvgaError("truncated fixed field") }
        pos += n
    }

    /// Reads a length-delimited length and validates it lies within the
    /// reader's window. Performed in Int64 space so a hostile varint near
    /// `Int.max` cannot wrap `pos + len` to a small positive number and slip
    /// the bounds check.
    private func checkedLength() throws -> Int {
        let raw = try readVarint()
        if raw > UInt64(Int.max) { throw SvgaError("length-delimited overflow") }
        let len = Int(raw)
        let end = Int64(pos) + Int64(len)
        if len < 0 || end > Int64(limit) {
            throw SvgaError("length-delimited overflow")
        }
        return len
    }
}
