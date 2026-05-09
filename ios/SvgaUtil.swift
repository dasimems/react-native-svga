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
        if trimmed.contains("..") { return nil }

        guard let components = URLComponents(string: trimmed) else {
            if trimmed.hasPrefix("/") { return ResolvedSource(kind: .localFile, value: trimmed) }
            return nil
        }
        let scheme = components.scheme?.lowercased()

        if scheme == "http" || scheme == "https" {
            guard let host = components.host, !host.isEmpty else { return nil }
            return ResolvedSource(kind: .remote, value: trimmed)
        }
        if scheme == "asset" {
            let name = trimmed.replacingOccurrences(of: "asset://", with: "")
            return ResolvedSource(kind: .bundledAsset, value: name)
        }
        if scheme == "file" {
            guard let path = components.path.removingPercentEncoding else { return nil }
            return ResolvedSource(kind: .localFile, value: path)
        }
        if scheme == nil && trimmed.hasPrefix("/") {
            return ResolvedSource(kind: .localFile, value: trimmed)
        }
        return nil
    }
}

internal struct SvgaError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
