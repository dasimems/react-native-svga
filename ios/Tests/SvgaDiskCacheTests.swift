import XCTest
@testable import Svga

final class SvgaDiskCacheTests: XCTestCase {

    private let key = "svga-disk-cache-tests-\(UUID().uuidString)"

    override func tearDown() {
        SvgaDiskCache.remove(key)
        super.tearDown()
    }

    func testRemoveDropsASavedEntry() throws {
        _ = try SvgaDiskCache.saveSvga(key, data: Data([0x78, 0x9C, 0x00]))
        XCTAssertTrue(SvgaDiskCache.isCached(key))
        XCTAssertNotNil(SvgaDiskCache.cachedURL(key))

        SvgaDiskCache.remove(key)

        XCTAssertFalse(SvgaDiskCache.isCached(key))
        XCTAssertNil(SvgaDiskCache.cachedURL(key))
    }

    func testRemoveOfMissingKeyIsANoOp() {
        XCTAssertFalse(SvgaDiskCache.isCached(key))
        SvgaDiskCache.remove(key)
        XCTAssertFalse(SvgaDiskCache.isCached(key))
    }

    func testRemoveOnlyTouchesItsOwnKey() throws {
        let other = key + "-other"
        defer { SvgaDiskCache.remove(other) }
        _ = try SvgaDiskCache.saveSvga(key, data: Data([0x01]))
        _ = try SvgaDiskCache.saveSvga(other, data: Data([0x02]))

        SvgaDiskCache.remove(key)

        XCTAssertFalse(SvgaDiskCache.isCached(key))
        XCTAssertTrue(SvgaDiskCache.isCached(other))
    }
}
