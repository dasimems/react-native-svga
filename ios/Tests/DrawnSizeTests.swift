import XCTest
import CoreGraphics
@testable import Svga

/// Sprites decode at the size they are drawn on this screen, not at the
/// device cap: a 2048px bitmap shown at a quarter of the screen was most of
/// a big gift's memory and its first-frame texture upload.
final class DrawnSizeTests: XCTestCase {

    override func tearDown() {
        SvgaParser.screenPixels = .zero
        super.tearDown()
    }

    private func frame(_ w: CGFloat, _ h: CGFloat, scale: CGFloat = 1, content: Bool = true) -> FrameEntity {
        FrameEntity(
            alpha: 1,
            layout: CGRect(x: 0, y: 0, width: w, height: h),
            transform: CGAffineTransform(scaleX: scale, y: scale),
            hasContent: content
        )
    }

    private func movie(_ sprites: [SpriteEntity]) -> MovieEntity {
        MovieEntity(viewBoxWidth: 750, viewBoxHeight: 1334, fps: 20, frames: 2, sprites: sprites, audios: [])
    }

    func testDrawnSizeUsesTheLargestFrameOnScreen() {
        SvgaParser.screenPixels = CGSize(width: 1170, height: 2532)
        let sizes = SvgaParser.drawnSizes(movie([
            SpriteEntity(imageKey: "a", frames: [frame(100, 50), frame(100, 50, scale: 2)]),
            SpriteEntity(imageKey: "a", frames: [frame(10, 10, content: false)]),
        ]))
        // Fill scale = max(1170/750, 2532/1334) ≈ 1.898.
        let toScreen = max(1170.0 / 750.0, 2532.0 / 1334.0)
        XCTAssertEqual(sizes["a"]!.width, 200 * toScreen, accuracy: 0.01)
        XCTAssertEqual(sizes["a"]!.height, 100 * toScreen, accuracy: 0.01)
    }

    func testUnknownScreenFallsBackToTheDeviceCap() {
        XCTAssertTrue(SvgaParser.drawnSizes(movie([
            SpriteEntity(imageKey: "a", frames: [frame(100, 50)]),
        ])).isEmpty)
    }

    func testDecodeCapShrinksButNeverUpscales() {
        // A 2048×1024 image drawn at 400×200 decodes at ~440 on its long side
        // (+1 for float rounding on the ×1.1 headroom).
        let shrunk = SvgaParser.decodeCap(
            pixels: CGSize(width: 2048, height: 1024),
            drawn: CGSize(width: 400, height: 200),
            deviceCap: 2048
        )
        XCTAssertTrue((440...441).contains(shrunk), "got \(shrunk)")
        // Drawn larger than the bitmap: keep the original.
        XCTAssertEqual(SvgaParser.decodeCap(
            pixels: CGSize(width: 300, height: 300),
            drawn: CGSize(width: 900, height: 900),
            deviceCap: 2048
        ), 300)
        // Never above the device cap.
        XCTAssertEqual(SvgaParser.decodeCap(
            pixels: CGSize(width: 4096, height: 4096),
            drawn: CGSize(width: 3000, height: 3000),
            deviceCap: 2048
        ), 2048)
        // No drawn size: the device cap, as before.
        XCTAssertEqual(SvgaParser.decodeCap(
            pixels: CGSize(width: 1000, height: 1000),
            drawn: nil,
            deviceCap: 2048
        ), 2048)
    }
}
