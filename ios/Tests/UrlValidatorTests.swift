import XCTest
@testable import Svga

final class UrlValidatorTests: XCTestCase {

    func testHttpsResolvesAsRemote() {
        let r = UrlValidator.resolve("https://cdn.test/foo.svga")
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.kind, .remote)
        XCTAssertEqual(r?.value, "https://cdn.test/foo.svga")
    }

    func testHttpResolvesAsRemote() {
        XCTAssertEqual(UrlValidator.resolve("http://cdn.test/foo.svga")?.kind, .remote)
    }

    func testAssetSchemeStripsPrefix() {
        let r = UrlValidator.resolve("asset://animations/cheer.svga")
        XCTAssertEqual(r?.kind, .bundledAsset)
        XCTAssertEqual(r?.value, "animations/cheer.svga")
    }

    func testFileSchemeResolvesAsLocalFile() {
        let r = UrlValidator.resolve("file:///tmp/sample.svga")
        XCTAssertEqual(r?.kind, .localFile)
        XCTAssertEqual(r?.value, "/tmp/sample.svga")
    }

    func testBareAbsolutePathResolvesAsLocalFile() {
        let r = UrlValidator.resolve("/absolute/path/sample.svga")
        XCTAssertEqual(r?.kind, .localFile)
        XCTAssertEqual(r?.value, "/absolute/path/sample.svga")
    }

    func testPathTraversalRejected() {
        XCTAssertNil(UrlValidator.resolve("file:///tmp/../../etc/passwd"))
        XCTAssertNil(UrlValidator.resolve("/tmp/../../etc/passwd"))
    }

    func testEmptyAndBlankRejected() {
        XCTAssertNil(UrlValidator.resolve(""))
        XCTAssertNil(UrlValidator.resolve("   "))
    }

    func testUnknownSchemesRejected() {
        XCTAssertNil(UrlValidator.resolve("javascript:alert(1)"))
        XCTAssertNil(UrlValidator.resolve("ftp://x.test/y"))
        XCTAssertNil(UrlValidator.resolve("data:text/plain,hi"))
    }

    func testHttpsWithoutHostRejected() {
        XCTAssertNil(UrlValidator.resolve("https:///nohost"))
    }

    func testWhitespaceTrimmed() {
        let r = UrlValidator.resolve("  https://x.test/y.svga  ")
        XCTAssertEqual(r?.kind, .remote)
        XCTAssertEqual(r?.value, "https://x.test/y.svga")
    }
}
