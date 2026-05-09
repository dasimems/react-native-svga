import XCTest
@testable import Svga

final class ScaleCalculatorTests: XCTestCase {

    private let eps: CGFloat = 0.001

    func testFillStretchesToViewDimensions() {
        let r = ScaleCalc.compute(mode: .fill, viewWidth: 200, viewHeight: 100, contentWidth: 100, contentHeight: 100)
        XCTAssertEqual(r.scaleX, 2, accuracy: eps)
        XCTAssertEqual(r.scaleY, 1, accuracy: eps)
        XCTAssertEqual(r.translateX, 0, accuracy: eps)
        XCTAssertEqual(r.translateY, 0, accuracy: eps)
    }

    func testAspectFitUsesSmallerScaleAndCenters() {
        let r = ScaleCalc.compute(mode: .aspectfit, viewWidth: 200, viewHeight: 100, contentWidth: 100, contentHeight: 100)
        XCTAssertEqual(r.scaleX, 1, accuracy: eps)
        XCTAssertEqual(r.scaleY, 1, accuracy: eps)
        XCTAssertEqual(r.translateX, 50, accuracy: eps)
        XCTAssertEqual(r.translateY, 0, accuracy: eps)
    }

    func testAspectFillUsesLargerScale() {
        let r = ScaleCalc.compute(mode: .aspectfill, viewWidth: 200, viewHeight: 100, contentWidth: 100, contentHeight: 100)
        XCTAssertEqual(r.scaleX, 2, accuracy: eps)
        XCTAssertEqual(r.scaleY, 2, accuracy: eps)
        XCTAssertEqual(r.translateX, 0, accuracy: eps)
        XCTAssertEqual(r.translateY, -50, accuracy: eps)
    }

    func testZeroContentDimensionsReturnIdentity() {
        let r = ScaleCalc.compute(mode: .aspectfit, viewWidth: 200, viewHeight: 100, contentWidth: 0, contentHeight: 0)
        XCTAssertEqual(r.scaleX, 1, accuracy: eps)
        XCTAssertEqual(r.scaleY, 1, accuracy: eps)
        XCTAssertEqual(r.translateX, 0, accuracy: eps)
        XCTAssertEqual(r.translateY, 0, accuracy: eps)
    }
}
