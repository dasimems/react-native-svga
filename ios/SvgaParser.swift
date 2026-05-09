import CoreGraphics
import Foundation
import UIKit

internal enum SvgaParser {

    private static let MAX_FRAMES = 100_000
    private static let MAX_SPRITES = 10_000
    private static let DEFAULT_FPS = 15

    static func parse(_ data: Data) throws -> SvgaEntity {
        let entries = try ZipReader.entries(from: data)
        var movieBinary: Data?
        var imageData: [String: Data] = [:]
        var audioData: [String: Data] = [:]

        for entry in entries {
            let name = entry.name
            if name == "movie.binary" { movieBinary = entry.data; continue }
            if name.hasPrefix("images/") {
                let key = stripFolder(name, prefix: "images/")
                imageData[key] = entry.data
                continue
            }
            if name.hasPrefix("audio/") {
                let key = stripFolder(name, prefix: "audio/")
                audioData[key] = entry.data
                continue
            }
        }

        guard let binary = movieBinary else { throw SvgaError("movie.binary missing") }
        let movie = try parseMovie(binary)
        let images = decodeImages(imageData)
        return SvgaEntity(movie: movie, images: images, audioData: audioData)
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
            guard let image = UIImage(data: data)?.cgImage else { continue }
            out[key] = image
        }
        return out
    }

    private static func parseMovie(_ data: Data) throws -> MovieEntity {
        let reader = ProtoReader(data)
        var width: CGFloat = 0
        var height: CGFloat = 0
        var fps = DEFAULT_FPS
        var frames = 0
        var sprites: [SpriteEntity] = []
        var audios: [AudioEntity] = []

        while reader.hasMore {
            let tag = try reader.readTag()
            switch tag.field {
            case 1:
                let params = try parseParams(try reader.readBytes())
                width = CGFloat(params.width)
                height = CGFloat(params.height)
                fps = params.fps
                frames = params.frames
            case 3:
                if sprites.count >= MAX_SPRITES { throw SvgaError("too many sprites") }
                sprites.append(try parseSprite(try reader.readBytes()))
            case 4:
                audios.append(try parseAudio(try reader.readBytes()))
            default:
                try reader.skip(wire: tag.wire)
            }
        }

        return MovieEntity(
            viewBoxWidth: width,
            viewBoxHeight: height,
            fps: fps,
            frames: frames,
            sprites: sprites,
            audios: audios
        )
    }

    private struct MovieParams { let width: Int32; let height: Int32; let fps: Int; let frames: Int }

    private static func parseParams(_ data: Data) throws -> MovieParams {
        let r = ProtoReader(data)
        var width: Int32 = 0
        var height: Int32 = 0
        var fps = DEFAULT_FPS
        var frames = 0
        while r.hasMore {
            let tag = try r.readTag()
            switch tag.field {
            case 1: width = try r.readInt32()
            case 2: height = try r.readInt32()
            case 3:
                frames = Int(try r.readInt32())
                if frames < 0 || frames > MAX_FRAMES { throw SvgaError("frame count out of range") }
            case 4: fps = max(1, Int(try r.readInt32()))
            default: try r.skip(wire: tag.wire)
            }
        }
        return MovieParams(width: width, height: height, fps: fps, frames: frames)
    }

    private static func parseSprite(_ data: Data) throws -> SpriteEntity {
        let r = ProtoReader(data)
        var imageKey = ""
        var frames: [FrameEntity] = []
        while r.hasMore {
            let tag = try r.readTag()
            switch tag.field {
            case 1: imageKey = try r.readString()
            case 2: frames.append(try parseFrame(try r.readBytes()))
            default: try r.skip(wire: tag.wire)
            }
        }
        return SpriteEntity(imageKey: imageKey, frames: frames)
    }

    private static func parseFrame(_ data: Data) throws -> FrameEntity {
        let r = ProtoReader(data)
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
                let lr = ProtoReader(try r.readBytes())
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
                let tr = ProtoReader(try r.readBytes())
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

    private static func parseAudio(_ data: Data) throws -> AudioEntity {
        let r = ProtoReader(data)
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
}
