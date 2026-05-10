import Compression
import CoreGraphics
import Foundation
import ImageIO
import UIKit

internal enum SvgaParser {

    private static let MAX_FRAMES = 100_000
    private static let MAX_SPRITES = 10_000
    private static let DEFAULT_FPS = 15
    private static let MAX_INFLATED_BYTES = 64 * 1024 * 1024

    /// Bitmap downsampling cap. Scales with device RAM so low-end iPhones
    /// don't OOM on multi-sprite SVGAs at full resolution. Mutable so the
    /// host (`HybridSvgaManager.init`) can compute it once at startup.
    static var maxBitmapDimension: Int = defaultBitmapDimension()

    private static func defaultBitmapDimension() -> Int {
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let totalGB = Double(totalBytes) / 1_073_741_824.0
        switch totalGB {
        case ..<2.0: return 1024
        case ..<3.0: return 1536
        default: return 2048
        }
    }

    // SVGA ships in several packagings, all decoded into the same SvgaEntity:
    //   - v2 zip:           PK\x03\x04 ... movie.binary plus images/ and audio/
    //   - v2 zlib stream:   78 xx ...     zlib-compressed protobuf with inline blobs
    //   - v2 gzip stream:   1F 8B 08 ...  gzip-compressed protobuf with inline blobs
    //   - raw protobuf:     uncompressed MovieEntity (rare, but some servers serve this)
    static func parse(_ data: Data) throws -> SvgaEntity {
        if isZip(data) { return try parseZip(data) }
        if isZlib(data) { return try parseFromMovieBinary(try inflateZlibStream(data)) }
        if isGzip(data) { return try parseFromMovieBinary(try inflateGzipStream(data)) }
        if looksLikeProtobuf(data) { return try parseFromMovieBinary(data) }
        throw SvgaError("unrecognised svga payload")
    }

    private static func isZip(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04
    }

    private static func isZlib(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        if data[0] != 0x78 { return false }
        let combined = (Int(data[0]) << 8) | Int(data[1])
        return combined % 31 == 0
    }

    private static func isGzip(_ data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        return data[0] == 0x1F && data[1] == 0x8B && data[2] == 0x08
    }

    private static func looksLikeProtobuf(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        let field = first >> 3
        let wire = first & 0x7
        if field == 0 || field > 5 { return false }
        return wire == 0 || wire == 2 || wire == 5
    }

    private static func composeTransforms(_ movie: MovieEntity, images: [String: CGImage]) {
        for sprite in movie.sprites {
            guard let image = images[sprite.imageKey] else { continue }
            let bw = CGFloat(image.width)
            let bh = CGFloat(image.height)
            if bw <= 0 || bh <= 0 { continue }
            for frame in sprite.frames {
                if !frame.hasContent { continue }
                let w = frame.layout.size.width
                let h = frame.layout.size.height
                if w <= 0 || h <= 0 { continue }
                var t = frame.transform
                t = CGAffineTransform(translationX: frame.layout.origin.x, y: frame.layout.origin.y)
                    .concatenating(t)
                t = CGAffineTransform(scaleX: w / bw, y: h / bh).concatenating(t)
                frame.applyComposedTransform(t)
            }
        }
    }

    private static func parseZip(_ data: Data) throws -> SvgaEntity {
        let entries = try ZipReader.entries(from: data)
        var movieBinary: Data?
        var imageBytes: [String: Data] = [:]
        var audioBytes: [String: Data] = [:]

        for entry in entries {
            let name = entry.name
            if name == "movie.binary" { movieBinary = entry.data; continue }
            if name.hasPrefix("images/") {
                imageBytes[stripFolder(name, prefix: "images/")] = entry.data
                continue
            }
            if name.hasPrefix("audio/") {
                audioBytes[stripFolder(name, prefix: "audio/")] = entry.data
                continue
            }
        }

        guard let binary = movieBinary else { throw SvgaError("movie.binary missing") }
        let parsed = try parseMovie(binary)

        // Some v2 zips embed images inline in the protobuf as well; merge.
        for (key, bytes) in parsed.inlineBlobs {
            if imageBytes[key] == nil && audioBytes[key] == nil {
                imageBytes[key] = bytes
            }
        }

        let images = decodeImages(imageBytes)
        composeTransforms(parsed.movie, images: images)
        return SvgaEntity(movie: parsed.movie, images: images, audioData: audioBytes)
    }

    private static func parseFromMovieBinary(_ data: Data) throws -> SvgaEntity {
        let parsed = try parseMovie(data)
        let (imageBytes, audioBytes) = classifyBlobs(parsed)
        let images = decodeImages(imageBytes)
        composeTransforms(parsed.movie, images: images)
        return SvgaEntity(movie: parsed.movie, images: images, audioData: audioBytes)
    }

    private static func classifyBlobs(_ parsed: ParsedMovie) -> ([String: Data], [String: Data]) {
        var imageBytes: [String: Data] = [:]
        var audioBytes: [String: Data] = [:]
        let imageKeys = Set(parsed.movie.sprites.map { $0.imageKey })
        let audioKeys = Set(parsed.movie.audios.map { $0.audioKey })
        for (key, bytes) in parsed.inlineBlobs {
            if audioKeys.contains(key) { audioBytes[key] = bytes; continue }
            if imageKeys.contains(key) { imageBytes[key] = bytes; continue }
            imageBytes[key] = bytes
        }
        return (imageBytes, audioBytes)
    }

    private static func stripFolder(_ name: String, prefix: String) -> String {
        let trimmed = String(name.dropFirst(prefix.count))
        if let dot = trimmed.lastIndex(of: ".") { return String(trimmed[..<dot]) }
        return trimmed
    }

    private static func decodeImages(_ source: [String: Data]) -> [String: CGImage] {
        var out: [String: CGImage] = [:]
        out.reserveCapacity(source.count)
        for (key, data) in source {
            guard let image = decodeImage(data) else { continue }
            out[key] = image
        }
        return out
    }

    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxBitmapDimension,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private struct ParsedMovie {
        let movie: MovieEntity
        let inlineBlobs: [String: Data]
    }

    private static func parseMovie(_ data: Data) throws -> ParsedMovie {
        let reader = ProtoReader(data)
        var width: CGFloat = 0
        var height: CGFloat = 0
        var fps = DEFAULT_FPS
        var frames = 0
        var sprites: [SpriteEntity] = []
        var audios: [AudioEntity] = []
        var inlineBlobs: [String: Data] = [:]

        while reader.hasMore {
            let tag = try reader.readTag()
            switch tag.field {
            case 1:
                _ = try reader.readString() // version, ignored
            case 2:
                let params = try parseParams(try reader.readSubReader())
                width = CGFloat(params.viewBoxWidth)
                height = CGFloat(params.viewBoxHeight)
                fps = params.fps
                frames = params.frames
            case 3:
                let entry = try parseImageEntry(try reader.readSubReader())
                inlineBlobs[entry.key] = entry.value
            case 4:
                if sprites.count >= MAX_SPRITES { throw SvgaError("too many sprites") }
                sprites.append(try parseSprite(try reader.readSubReader()))
            case 5:
                audios.append(try parseAudio(try reader.readSubReader()))
            default:
                try reader.skip(wire: tag.wire)
            }
        }

        let movie = MovieEntity(
            viewBoxWidth: width,
            viewBoxHeight: height,
            fps: fps,
            frames: frames,
            sprites: sprites,
            audios: audios
        )
        return ParsedMovie(movie: movie, inlineBlobs: inlineBlobs)
    }

    private struct MovieParams {
        let viewBoxWidth: Float
        let viewBoxHeight: Float
        let fps: Int
        let frames: Int
    }

    private static func parseParams(_ r: ProtoReader) throws -> MovieParams {
        var width: Float = 0
        var height: Float = 0
        var fps = DEFAULT_FPS
        var frames = 0
        while r.hasMore {
            let tag = try r.readTag()
            switch tag.field {
            case 1: width = try r.readFloat()
            case 2: height = try r.readFloat()
            case 3: fps = max(1, Int(try r.readInt32()))
            case 4:
                frames = Int(try r.readInt32())
                if frames < 0 || frames > MAX_FRAMES { throw SvgaError("frame count out of range") }
            default: try r.skip(wire: tag.wire)
            }
        }
        return MovieParams(viewBoxWidth: width, viewBoxHeight: height, fps: fps, frames: frames)
    }

    private struct ImageEntry { let key: String; let value: Data }

    private static func parseImageEntry(_ r: ProtoReader) throws -> ImageEntry {
        var key = ""
        var value = Data()
        while r.hasMore {
            let tag = try r.readTag()
            switch tag.field {
            case 1: key = try r.readString()
            case 2: value = try r.readBytes()
            default: try r.skip(wire: tag.wire)
            }
        }
        return ImageEntry(key: key, value: value)
    }

    private static func parseSprite(_ r: ProtoReader) throws -> SpriteEntity {
        var imageKey = ""
        var frames: [FrameEntity] = []
        while r.hasMore {
            let tag = try r.readTag()
            switch tag.field {
            case 1: imageKey = try r.readString()
            case 2:
                if frames.count >= MAX_FRAMES { throw SvgaError("too many sprite frames") }
                frames.append(try parseFrame(try r.readSubReader()))
            default: try r.skip(wire: tag.wire)
            }
        }
        return SpriteEntity(imageKey: imageKey, frames: frames)
    }

    private static func parseFrame(_ r: ProtoReader) throws -> FrameEntity {
        var alpha: Float = 0
        var x: Float = 0, y: Float = 0, w: Float = 0, h: Float = 0
        var a: Float = 1, b: Float = 0, c: Float = 0, d: Float = 1, tx: Float = 0, ty: Float = 0
        var hasContent = false

        while r.hasMore {
            let tag = try r.readTag()
            switch tag.field {
            case 1:
                alpha = try r.readFloat()
                hasContent = alpha > 0
            case 2:
                let lr = try r.readSubReader()
                while lr.hasMore {
                    let lt = try lr.readTag()
                    switch lt.field {
                    case 1: x = try lr.readFloat()
                    case 2: y = try lr.readFloat()
                    case 3: w = try lr.readFloat()
                    case 4: h = try lr.readFloat()
                    default: try lr.skip(wire: lt.wire)
                    }
                }
            case 3:
                let tr = try r.readSubReader()
                while tr.hasMore {
                    let tt = try tr.readTag()
                    switch tt.field {
                    case 1: a = try tr.readFloat()
                    case 2: b = try tr.readFloat()
                    case 3: c = try tr.readFloat()
                    case 4: d = try tr.readFloat()
                    case 5: tx = try tr.readFloat()
                    case 6: ty = try tr.readFloat()
                    default: try tr.skip(wire: tt.wire)
                    }
                }
            default:
                try r.skip(wire: tag.wire)
            }
        }

        let transform = CGAffineTransform(
            a: CGFloat(a), b: CGFloat(b),
            c: CGFloat(c), d: CGFloat(d),
            tx: CGFloat(tx), ty: CGFloat(ty)
        )
        let layout = CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
        return FrameEntity(alpha: CGFloat(alpha), layout: layout, transform: transform, hasContent: hasContent)
    }

    private static func parseAudio(_ r: ProtoReader) throws -> AudioEntity {
        var key = ""
        var startFrame = 0
        var endFrame = 0
        var startTime = 0
        var totalTime = 0
        while r.hasMore {
            let tag = try r.readTag()
            switch tag.field {
            case 1: key = try r.readString()
            case 2: startFrame = Int(try r.readInt32())
            case 3: endFrame = Int(try r.readInt32())
            case 4: startTime = Int(try r.readInt32())
            case 5: totalTime = Int(try r.readInt32())
            default: try r.skip(wire: tag.wire)
            }
        }
        return AudioEntity(audioKey: key, startFrame: startFrame, endFrame: endFrame, startTime: startTime, totalTime: totalTime)
    }

    private static func inflateZlibStream(_ source: Data) throws -> Data {
        if source.count < 6 { throw SvgaError("zlib stream too short") }
        // COMPRESSION_ZLIB expects raw DEFLATE; strip the 2-byte zlib header.
        return try inflateRawDeflate(source.subdata(in: 2..<source.count))
    }

    private static func inflateGzipStream(_ source: Data) throws -> Data {
        let deflate = try stripGzipHeaderTrailer(source)
        return try inflateRawDeflate(deflate)
    }

    private static func stripGzipHeaderTrailer(_ data: Data) throws -> Data {
        guard data.count >= 18 else { throw SvgaError("gzip too short") }
        guard data[0] == 0x1F && data[1] == 0x8B else { throw SvgaError("not a gzip stream") }
        guard data[2] == 0x08 else { throw SvgaError("unsupported gzip method") }
        let flags = data[3]
        let trailerStart = data.count - 8
        var pos = 10
        if flags & 0x04 != 0 {
            guard pos + 2 <= trailerStart else { throw SvgaError("truncated gzip extra") }
            let xlen = Int(data[pos]) | (Int(data[pos + 1]) << 8)
            pos += 2 + xlen
            if pos > trailerStart { throw SvgaError("truncated gzip extra") }
        }
        if flags & 0x08 != 0 {
            while pos < trailerStart && data[pos] != 0 { pos += 1 }
            if pos >= trailerStart { throw SvgaError("truncated gzip name") }
            pos += 1
        }
        if flags & 0x10 != 0 {
            while pos < trailerStart && data[pos] != 0 { pos += 1 }
            if pos >= trailerStart { throw SvgaError("truncated gzip comment") }
            pos += 1
        }
        if flags & 0x02 != 0 {
            pos += 2
            if pos > trailerStart { throw SvgaError("truncated gzip header crc") }
        }
        guard pos < trailerStart else { throw SvgaError("gzip payload missing") }
        return data.subdata(in: pos..<trailerStart)
    }

    private static func inflateRawDeflate(_ payload: Data) throws -> Data {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: -1)!,
            dst_size: 0,
            src_ptr: UnsafeMutablePointer<UInt8>(bitPattern: -1)!,
            src_size: 0,
            state: nil
        )
        let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard initStatus == COMPRESSION_STATUS_OK else {
            throw SvgaError("deflate stream init failed")
        }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var output = Data()
        var thrown: Error?

        payload.withUnsafeBytes { srcRaw in
            guard let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress else {
                thrown = SvgaError("source buffer empty")
                return
            }
            stream.src_ptr = srcBase
            stream.src_size = payload.count
            stream.dst_ptr = buffer
            stream.dst_size = bufferSize

            while true {
                let priorSrcSize = stream.src_size
                let priorDstSize = stream.dst_size
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                if status == COMPRESSION_STATUS_ERROR {
                    thrown = SvgaError("deflate decode error")
                    return
                }
                let written = bufferSize - stream.dst_size
                if written > 0 { output.append(buffer, count: written) }
                if output.count > MAX_INFLATED_BYTES {
                    thrown = SvgaError("inflated payload exceeds size limit")
                    return
                }
                if status == COMPRESSION_STATUS_END { return }
                // Crafted streams can land the decoder in a state where it
                // returns COMPRESSION_STATUS_OK without consuming source or
                // producing output — the loop would then spin forever and
                // pin a CPU core. Detect zero net progress and bail.
                if stream.src_size == priorSrcSize && stream.dst_size == priorDstSize {
                    thrown = SvgaError("deflate decoder stalled")
                    return
                }
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
            }
        }

        if let thrown = thrown { throw thrown }
        return output
    }
}
