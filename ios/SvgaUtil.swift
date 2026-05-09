import CommonCrypto
import Foundation

internal enum Hashing {
    static func sha256(_ input: String) -> String {
        guard let data = input.data(using: .utf8) else { return "" }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

internal enum SourceKind { case remote, localFile, bundledAsset }

internal struct ResolvedSource {
    let kind: SourceKind
    let value: String
}

internal enum UrlValidator {
    static func resolve(_ source: String) -> ResolvedSource? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        guard let components = URLComponents(string: trimmed) else {
            if trimmed.hasPrefix("/") {
                if pathContainsTraversal(trimmed) { return nil }
                return ResolvedSource(kind: .localFile, value: trimmed)
            }
            return nil
        }
        let scheme = components.scheme?.lowercased()

        if scheme == "http" || scheme == "https" {
            guard let host = components.host, !host.isEmpty else { return nil }
            if pathContainsTraversal(components.path) { return nil }
            return ResolvedSource(kind: .remote, value: trimmed)
        }
        if scheme == "asset" {
            let name = trimmed.replacingOccurrences(of: "asset://", with: "")
            if pathContainsTraversal(name) { return nil }
            return ResolvedSource(kind: .bundledAsset, value: name)
        }
        if scheme == "file" {
            guard let path = components.path.removingPercentEncoding else { return nil }
            if pathContainsTraversal(path) { return nil }
            return ResolvedSource(kind: .localFile, value: path)
        }
        if scheme == nil && trimmed.hasPrefix("/") {
            if pathContainsTraversal(trimmed) { return nil }
            return ResolvedSource(kind: .localFile, value: trimmed)
        }
        return nil
    }

    private static func pathContainsTraversal(_ path: String) -> Bool {
        // Reject only path-segment '..', not arbitrary substrings like 'foo..bar'.
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            if segment == ".." { return true }
        }
        return false
    }
}

internal struct SvgaError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
