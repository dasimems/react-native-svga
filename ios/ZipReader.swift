import Compression
import Foundation

internal struct ZipEntry {
    let name: String
    let data: Data
}

internal enum ZipReader {

    private static let MAX_ENTRY_BYTES = 32 * 1024 * 1024
    private static let MAX_TOTAL_BYTES = 64 * 1024 * 1024
    private static let EOCD_SIGNATURE: UInt32 = 0x06054B50
    private static let CDH_SIGNATURE: UInt32 = 0x02014B50
    private static let LFH_SIGNATURE: UInt32 = 0x04034B50

    static func entries(from data: Data) throws -> [ZipEntry] {
        let eocd = try findEocd(data)
        let cdSize = Int(read32(data, eocd.offset + 12))
        let cdOffset = Int(read32(data, eocd.offset + 16))
        if cdOffset < 0 || cdOffset + cdSize > data.count { throw SvgaError("corrupt central directory") }
        if cdSize < 0 { throw SvgaError("corrupt central directory") }

        var results: [ZipEntry] = []
        var totalBytes = 0
        var p = cdOffset
        let cdEnd = cdOffset + cdSize

        while p < cdEnd {
            if p + 46 > cdEnd { throw SvgaError("corrupt central directory header") }
            let sig = read32(data, p)
            if sig != CDH_SIGNATURE { break }
            let method = read16(data, p + 10)
            let compressedSize = Int(read32(data, p + 20))
            let uncompressedSize = Int(read32(data, p + 24))
            let nameLen = Int(read16(data, p + 28))
            let extraLen = Int(read16(data, p + 30))
            let commentLen = Int(read16(data, p + 32))
            let localOffset = Int(read32(data, p + 42))

            if compressedSize < 0 || uncompressedSize < 0 { throw SvgaError("negative size") }
            if uncompressedSize > MAX_ENTRY_BYTES { throw SvgaError("zip entry exceeds size limit") }

            let nameStart = p + 46
            if nameStart + nameLen > cdEnd { throw SvgaError("entry name overflow") }
            guard let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLen)), encoding: .utf8) else {
                throw SvgaError("entry name not utf8")
            }
            p = nameStart + nameLen + extraLen + commentLen

            if !isSafeName(name) { continue }
            if name.hasSuffix("/") { continue }

            let payload = try readLocal(data, at: localOffset, method: method, compressedSize: compressedSize, uncompressedSize: uncompressedSize)
            totalBytes += payload.count
            if totalBytes > MAX_TOTAL_BYTES { throw SvgaError("zip total exceeds size limit") }

            results.append(ZipEntry(name: name, data: payload))
        }
        return results
    }

    private struct Eocd { let offset: Int }

    private static func findEocd(_ data: Data) throws -> Eocd {
        let n = data.count
        let minSize = 22
        if n < minSize { throw SvgaError("file too small for zip") }
        let maxScan = min(n, 65557)
        var i = n - minSize
        let lower = max(0, n - maxScan)
        while i >= lower {
            if read32(data, i) == EOCD_SIGNATURE { return Eocd(offset: i) }
            i -= 1
        }
        throw SvgaError("end-of-central-directory not found")
    }

    private static func readLocal(_ data: Data, at offset: Int, method: UInt16, compressedSize: Int, uncompressedSize: Int) throws -> Data {
        if offset < 0 || offset + 30 > data.count { throw SvgaError("local header out of range") }
        let sig = read32(data, offset)
        if sig != LFH_SIGNATURE { throw SvgaError("invalid local header") }
        let nameLen = Int(read16(data, offset + 26))
        let extraLen = Int(read16(data, offset + 28))
        let dataStart = offset + 30 + nameLen + extraLen
        if dataStart + compressedSize > data.count { throw SvgaError("entry data out of range") }

        let raw = data.subdata(in: dataStart..<(dataStart + compressedSize))
        if method == 0 { return raw }
        if method == 8 { return try inflate(raw, expectedSize: uncompressedSize) }
        throw SvgaError("unsupported zip compression method \(method)")
    }

    private static func inflate(_ source: Data, expectedSize: Int) throws -> Data {
        if expectedSize <= 0 { return Data() }
        let dstCapacity = expectedSize
        var dst = Data(count: dstCapacity)
        let written = source.withUnsafeBytes { srcRaw -> Int in
            guard let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return dst.withUnsafeMutableBytes { dstRaw -> Int in
                guard let dstPtr = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstPtr, dstCapacity, srcPtr, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        if written == 0 { throw SvgaError("inflate failed") }
        if written != expectedSize { throw SvgaError("inflate size mismatch") }
        dst.count = written
        return dst
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1]) << 8
        let b2 = UInt32(data[offset + 2]) << 16
        let b3 = UInt32(data[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    private static func read16(_ data: Data, _ offset: Int) -> UInt16 {
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func isSafeName(_ name: String) -> Bool {
        if name.isEmpty { return false }
        if name.contains("..") { return false }
        if name.hasPrefix("/") { return false }
        return true
    }
}
