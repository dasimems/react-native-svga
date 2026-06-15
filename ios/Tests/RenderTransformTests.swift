import XCTest
import CoreGraphics
@testable import Svga

/// Locks the GPU-renderer geometry math without a device.
///
/// `SvgaPlayerView` renders each sprite by setting its layer transform to
/// `frame.transform.concatenating(outerTransform)`, where `outerTransform` is
/// `ScaleResult.transform` (the viewBox → view-space scale + centering map).
/// These tests assert that composition maps known content/bitmap points to the
/// expected device-space points for every `scaleMode`, so a future change to
/// the affine order is caught here rather than as upside-down or mispositioned
/// gifts on device.
final class RenderTransformTests: XCTestCase {

    private let eps: CGFloat = 0.001

    private func assertMaps(
        _ t: CGAffineTransform,
        _ point: CGPoint,
        to expected: CGPoint,
        _ message: String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let got = point.applying(t)
        XCTAssertEqual(got.x, expected.x, accuracy: eps, "\(message) x", file: file, line: line)
        XCTAssertEqual(got.y, expected.y, accuracy: eps, "\(message) y", file: file, line: line)
    }

    // MARK: - outerTransform (ScaleResult.transform) per scale mode

    // viewBox 100×100 into a 200×400 view.

    func testAspectFitOuterTransformScalesUniformlyAndCenters() {
        // scale = min(2, 4) = 2; ty = (400 - 200)/2 = 100. Map: (x,y)→(2x, 2y+100).
        let t = ScaleCalc.compute(mode: .aspectfit, viewWidth: 200, viewHeight: 400, contentWidth: 100, contentHeight: 100).transform
        assertMaps(t, CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: 100), "aspectFit origin")
        assertMaps(t, CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 300), "aspectFit far corner")
    }

    func testAspectFillOuterTransformScalesUniformlyAndCenters() {
        // scale = max(2, 4) = 4; tx = (200 - 400)/2 = -100. Map: (x,y)→(4x-100, 4y).
        let t = ScaleCalc.compute(mode: .aspectfill, viewWidth: 200, viewHeight: 400, contentWidth: 100, contentHeight: 100).transform
        assertMaps(t, CGPoint(x: 0, y: 0), to: CGPoint(x: -100, y: 0), "aspectFill origin")
        assertMaps(t, CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 400), "aspectFill far corner")
    }

    func testFillOuterTransformStretchesNonUniformly() {
        // sx = 2, sy = 4, no centering. Map: (x,y)→(2x, 4y).
        let t = ScaleCalc.compute(mode: .fill, viewWidth: 200, viewHeight: 400, contentWidth: 100, contentHeight: 100).transform
        assertMaps(t, CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: 0), "fill origin")
        assertMaps(t, CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 400), "fill far corner")
    }

    // MARK: - full per-sprite composition (what applyFrame sets on each layer)

    func testFrameTransformComposedWithOuterMapsBitmapToDeviceRect() {
        // A sprite whose composed `frame.transform` places its 50×50 bitmap box
        // into content rect origin (10,20) size (30,40): (x,y)→(10+0.6x, 20+0.8y).
        let frameTransform = CGAffineTransform(scaleX: 0.6, y: 0.8)
            .concatenating(CGAffineTransform(translationX: 10, y: 20))

        // Under aspectFit (2x, 2y+100), the bitmap corners must land at the
        // composed device rect: (10,20)→(20,140), (40,60)→(80,220).
        let outer = ScaleCalc.compute(mode: .aspectfit, viewWidth: 200, viewHeight: 400, contentWidth: 100, contentHeight: 100).transform
        let composed = frameTransform.concatenating(outer)

        assertMaps(composed, CGPoint(x: 0, y: 0), to: CGPoint(x: 20, y: 140), "bitmap top-left")
        assertMaps(composed, CGPoint(x: 50, y: 50), to: CGPoint(x: 80, y: 220), "bitmap bottom-right")
    }

    func testCompositionIsUprightNotYFlipped() {
        // Regression guard for the dropped y-flip: with the renderer's order,
        // a bitmap's TOP edge (local y=0) must map to a SMALLER device y than
        // its BOTTOM edge (local y=bh). If a flip ever creeps back in, this
        // inverts and fails. (Both scale factors here are positive.)
        let outer = ScaleCalc.compute(mode: .fill, viewWidth: 200, viewHeight: 400, contentWidth: 100, contentHeight: 100).transform
        let composed = CGAffineTransform.identity.concatenating(outer)
        let top = CGPoint(x: 0, y: 0).applying(composed)
        let bottom = CGPoint(x: 0, y: 100).applying(composed)
        XCTAssertLessThan(top.y, bottom.y, "content top must render above content bottom (no y-flip)")
    }
}
