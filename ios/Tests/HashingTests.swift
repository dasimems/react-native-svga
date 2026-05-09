import XCTest
@testable import Svga

final class HashingTests: XCTestCase {

    func testSha256IsDeterministicAndLowercaseHex() {
        let hash = Hashing.sha256("https://example.test/sample.svga")
        XCTAssertEqual(hash.count, 64)
        XCTAssertEqual(hash, hash.lowercased())
        XCTAssertEqual(hash, Hashing.sha256("https://example.test/sample.svga"))
    }

    func testDifferentInputsHashDifferently() {
        XCTAssertNotEqual(Hashing.sha256("a"), Hashing.sha256("b"))
    }

    func testEmptyStringKnownVector() {
        let expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        XCTAssertEqual(Hashing.sha256(""), expected)
    }

    func testKnownVectorAbc() {
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(Hashing.sha256("abc"), expected)
    }
}
