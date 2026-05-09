import CoreGraphics
import Foundation
import UIKit

internal struct SvgaEntity {
    let movie: MovieEntity
    let images: [String: CGImage]
    let audioData: [String: Data]

    var byteSize: Int {
        var total = 0
        for (_, img) in images { total += img.bytesPerRow * img.height }
        for (_, data) in audioData { total += data.count }
        var totalFrames = 0
        for sprite in movie.sprites { totalFrames += sprite.frames.count }
        // FrameEntity ~80 B per frame; SpriteEntity overhead ~64 B.
        total += totalFrames * 80
        total += movie.sprites.count * 64
        return total
    }
}

internal struct MovieEntity {
    let viewBoxWidth: CGFloat
    let viewBoxHeight: CGFloat
    let fps: Int
    let frames: Int
    let sprites: [SpriteEntity]
    let audios: [AudioEntity]
}

internal struct SpriteEntity {
    let imageKey: String
    let frames: [FrameEntity]
}

internal final class FrameEntity {
    let alpha: CGFloat
    let layout: CGRect
    var transform: CGAffineTransform
    let hasContent: Bool

    init(alpha: CGFloat, layout: CGRect, transform: CGAffineTransform, hasContent: Bool) {
        self.alpha = alpha
        self.layout = layout
        self.transform = transform
        self.hasContent = hasContent
    }
}

internal struct AudioEntity {
    let audioKey: String
    let startFrame: Int
    let endFrame: Int
    let startTime: Int
    let totalTime: Int
}
