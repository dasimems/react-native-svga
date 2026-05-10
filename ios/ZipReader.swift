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
        let cdSize = Int(try read32(data, eocd.offset + 12))
        let cdOffset = Int(try read32(data, eocd.offset + 16))
        if cdSize < 0 { throw SvgaError("corrupt central directory") }
        // Use Int64 to detect overflow when cdOffset+cdSize wraps past Int.max
        // on hostile input. data.count is bounded by the file size (≤ 64 MB
        // upstream), so a wrap implies a malicious EOCD.
        let cdEnd64 = Int64(cdOffset) + Int64(cdSize)
        if cdOffset < 0 || cdEnd64 > Int64(data.count) {
            throw SvgaError("corrupt central directory")
        }

        var results: [ZipEntry] = []
        var totalBytes = 0
        var p = cdOffset
        let cdEnd = cdOffset + cdSize

        while p < cdEnd {
            if p + 46 > cdEnd { throw SvgaError("corrupt central directory header") }
            let sig = try read32(data, p)
            if sig != CDH_SIGNATURE { break }
            let method = try read16(data, p + 10)
            let compressedSize = Int(try read32(data, p + 20))
            let uncompressedSize = Int(try read32(data, p + 24))
            let nameLen = Int(try read16(data, p + 28))
            let extraLen = Int(try read16(data, p + 30))
            let commentLen = Int(try read16(data, p + 32))
            let localOffset = Int(try read32(data, p + 42))

            if compressedSize < 0 || uncompressedSize < 0 { throw SvgaError("negative size") }
            if uncompressedSize > MAX_ENTRY_BYTES { throw SvgaError("zip entry exceeds size limit") }

            let nameStart = p + 46
            let nameEnd64 = Int64(nameStart) + Int64(nameLen)
            if nameLen < 0 || nameEnd64 > Int64(cdEnd) {
                throw SvgaError("entry name overflow")
            }
            guard let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLen)), encoding: .utf8) else {
                throw SvgaError("entry name not utf8")
            }
            let nextP64 = Int64(nameStart) + Int64(nameLen) + Int64(extraLen) + Int64(commentLen)
            if extraLen < 0 || commentLen < 0 || nextP64 > Int64(cdEnd) {
                throw SvgaError("zip header field overflow")
            }
            p = Int(nextP64)

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
            // Tolerate a malformed prefix near the start of the scan window
            // (read32 throws if i < 0 or i+4 > data.count) — those positions
            // are simply not the EOCD.
            if (try? read32(data, i)) == EOCD_SIGNATURE { return Eocd(offset: i) }
            i -= 1
        }
        throw SvgaError("end-of-central-directory not found")
    }

    private static func readLocal(_ data: Data, at offset: Int, method: UInt16, compressedSize: Int, uncompressedSize: Int) throws -> Data {
        if offset < 0 || offset + 30 > data.count { throw SvgaError("local header out of range") }
        let sig = try read32(data, offset)
        if sig != LFH_SIGNATURE { throw SvgaError("invalid local header") }
        let nameLen = Int(try read16(data, offset + 26))
        let extraLen = Int(try read16(data, offset + 28))
        if nameLen < 0 || extraLen < 0 { throw SvgaError("invalid local header field") }
        let dataStart64 = Int64(offset) + 30 + Int64(nameLen) + Int64(extraLen)
        let dataEnd64 = dataStart64 + Int64(compressedSize)
        if dataEnd64 > Int64(data.count) || dataStart64 < 0 {
            throw SvgaError("entry data out of range")
        }
        let dataStart = Int(dataStart64)

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

    // Read helpers validate against `data.count` so callers don't need to
    // pre-check every offset. They also normalise to the slice's startIndex,
    // because Data subscripts are absolute and a slice can have a non-zero
    // startIndex — passing such a slice through `data[offset]` with a
    // caller-relative offset would silently read the wrong bytes (or trap).
    private static func read32(_ data: Data, _ offset: Int) throws -> UInt32 {
        if offset < 0 || offset + 4 > data.count {
            throw SvgaError("zip read out of range")
        }
        let base = data.startIndex
        let b0 = UInt32(data[base + offset])
        let b1 = UInt32(data[base + offset + 1]) << 8
        let b2 = UInt32(data[base + offset + 2]) << 16
        let b3 = UInt32(data[base + offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    private static func read16(_ data: Data, _ offset: Int) throws -> UInt16 {
        if offset < 0 || offset + 2 > data.count {
            throw SvgaError("zip read out of range")
        }
        let base = data.startIndex
        return UInt16(data[base + offset]) | (UInt16(data[base + offset + 1]) << 8)
    }

    private static func isSafeName(_ name: String) -> Bool {
        if name.isEmpty { return false }
        if name.contains("..") { return false }
        if name.hasPrefix("/") { return false }
        return true
    }
}
