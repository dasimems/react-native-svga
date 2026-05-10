import Foundation
import NitroModules

final class HybridSvgaManager: HybridSvgaManagerSpec {

    private static let MAX_CONCURRENT_PRELOADS = 4
    private let sounds = SvgaSoundLibrary()

    func preload(urls: [String], cacheKeys: [String]) throws -> Promise<Void> {
        // The manager is owned by Nitro for the JS context's lifetime; if we
        // captured `self` weakly and Nitro reclaimed the manager mid-preload,
        // the promise would resolve with `()` instead of failing — JS-side
        // `await SvgaCache.preload(urls)` would then return a false success.
        // Capture strongly and rely on `cancel()` in `dispose()` to break
        // outstanding work cleanly.
        return Promise.async {
            try await self.preloadAll(urls, cacheKeys: cacheKeys)
        }
    }

    func preloadDecoded(urls: [String], cacheKeys: [String]) throws -> Promise<Void> {
        let limit = Self.MAX_CONCURRENT_PRELOADS
        return Promise.async {
            // Collect the first error and propagate it once the group drains
            // (so a single bad URL surfaces up to JS as a real failure
            // instead of silently swallowing every result). Other URLs are
            // best-effort and don't get re-thrown.
            try await withThrowingTaskGroup(of: Result<Void, Error>.self) { group in
                var inFlight = 0
                let pairs = Self.zipKeys(urls: urls, cacheKeys: cacheKeys)
                var iterator = pairs.makeIterator()
                func enqueueNext() {
                    guard let (source, key) = iterator.next() else { return }
                    inFlight += 1
                    group.addTask {
                        await withCheckedContinuation { (cont: CheckedContinuation<Result<Void, Error>, Never>) in
                            SvgaSourceLoader.loadEntity(source, cacheKey: key) { result in
                                switch result {
                                case .success: cont.resume(returning: .success(()))
                                case .failure(let err): cont.resume(returning: .failure(err))
                                }
                            }
                        }
                    }
                }
                for _ in 0..<min(limit, pairs.count) { enqueueNext() }
                var firstError: Error?
                while inFlight > 0 {
                    if let result = try await group.next() {
                        if case .failure(let err) = result, firstError == nil {
                            firstError = err
                        }
                    }
                    inFlight -= 1
                    enqueueNext()
                }
                if let firstError = firstError { throw firstError }
            }
        }
    }

    func isCached(cacheKey: String) throws -> Bool {
        // For local/bundled paths the cacheKey is the filesystem path itself,
        // not a remote-cache identity — keep the existing behaviour for those.
        guard let resolved = UrlValidator.resolve(cacheKey) else {
            return SvgaDiskCache.isCached(cacheKey)
        }
        switch resolved.kind {
        case .remote:
            return SvgaDiskCache.isCached(cacheKey)
        case .localFile:
            return FileManager.default.fileExists(atPath: resolved.value)
        case .bundledAsset:
            return Self.assetExists(resolved.value)
        }
    }

    func getCachePath(cacheKey: String) throws -> String? {
        guard let resolved = UrlValidator.resolve(cacheKey) else {
            return SvgaDiskCache.pathOrNil(cacheKey)
        }
        switch resolved.kind {
        case .remote:
            return SvgaDiskCache.pathOrNil(cacheKey)
        case .localFile:
            return FileManager.default.fileExists(atPath: resolved.value) ? resolved.value : nil
        case .bundledAsset:
            return Self.assetExists(resolved.value) ? resolved.value : nil
        }
    }

    private static func assetExists(_ name: String) -> Bool {
        return SvgaSourceLoader.bundleURL(for: name) != nil
    }

    func clearCache() throws {
        try SvgaDiskCache.clearSvga()
        try SvgaDiskCache.clearSounds()
        SvgaMemoryCache.shared.clear()
    }

    func getCacheSize() throws -> Promise<Double> {
        return Promise.async {
            return Double(SvgaDiskCache.totalSvgaBytes())
        }
    }

    func getCacheCount() throws -> Promise<Double> {
        return Promise.async {
            return Double(SvgaDiskCache.totalSvgaCount())
        }
    }

    func setCacheLimit(bytes: Double) throws {
        SvgaDiskCache.setMaxBytes(Self.clampToInt64(bytes))
    }

    func setMemoryLimit(bytes: Double) throws {
        SvgaMemoryCache.shared.setMaxBytes(Self.clampToInt(bytes))
    }

    /// Defensive clamp against non-finite or out-of-range `Double`s. The JS
    /// `assertNonNegativeFinite` guard catches misuse at the package
    /// boundary, but a non-Nitro caller reaching the spec from another
    /// module could otherwise trap on `Int64(.infinity)` / `Int(.nan)`.
    private static func clampToInt64(_ value: Double) -> Int64 {
        if !value.isFinite || value <= 0 { return 0 }
        if value >= Double(Int64.max) { return Int64.max }
        return Int64(value)
    }
    private static func clampToInt(_ value: Double) -> Int {
        if !value.isFinite || value <= 0 { return 0 }
        if value >= Double(Int.max) { return Int.max }
        return Int(value)
    }

    func setMaxAgeMs(ms: Double) throws {
        // Mirror to both layers so a hit at either level honours the TTL.
        let clamped = Self.clampToInt64(ms)
        SvgaDiskCache.setMaxAgeMs(clamped)
        SvgaMemoryCache.shared.setMaxAgeMs(clamped)
    }

    func evictExpired() throws -> Promise<Double> {
        return Promise.async {
            // Bridge the callback-style API into Swift Concurrency so this
            // Task suspends (rather than parking a cooperative-pool worker)
            // while the disk walk runs on writeQueue.
            return await withCheckedContinuation { (cont: CheckedContinuation<Double, Never>) in
                SvgaDiskCache.evictExpired { count in
                    cont.resume(returning: Double(count))
                }
            }
        }
    }

    func loadSound(key: String, url: String) throws -> Promise<Void> {
        return Promise.async {
            let url = try await self.fetchSoundFile(key: key, url: url)
            try self.sounds.load(key: key, url: url)
        }
    }

    func playSound(key: String, volume: Double) throws {
        sounds.play(key: key, volume: Float(volume))
    }

    func stopSound(key: String) throws { sounds.stop(key: key) }
    func stopAllSounds() throws { sounds.stopAll() }
    func unloadSound(key: String) throws { sounds.unload(key: key) }

    func dispose() { sounds.release() }
    deinit { sounds.release() }

    private func preloadAll(_ urls: [String], cacheKeys: [String]) async throws {
        let limit = Self.MAX_CONCURRENT_PRELOADS
        let pairs = Self.zipKeys(urls: urls, cacheKeys: cacheKeys)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = pairs.makeIterator()
            var inFlight = 0
            func enqueue() throws {
                guard let (source, key) = iterator.next() else { return }
                inFlight += 1
                group.addTask { try await self.preloadOne(source, cacheKey: key) }
            }
            for _ in 0..<min(limit, pairs.count) { try enqueue() }
            while inFlight > 0 {
                try await group.next()
                inFlight -= 1
                try enqueue()
            }
        }
    }

    private func preloadOne(_ source: String, cacheKey: String) async throws {
        guard let resolved = UrlValidator.resolve(source) else { return }
        if resolved.kind != .remote { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            SvgaSourceLoader.preloadRemote(resolved.value, cacheKey: cacheKey) { result in
                switch result {
                case .success: cont.resume(returning: ())
                case .failure(let err): cont.resume(throwing: err)
                }
            }
        }
    }

    private func fetchSoundFile(key: String, url: String) async throws -> URL {
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            SvgaSourceLoader.loadSoundFile(key: key, url: url) { result in
                switch result {
                case .success(let url): cont.resume(returning: url)
                case .failure(let err): cont.resume(throwing: err)
                }
            }
        }
    }

    /// Pair urls with cache keys, falling back to the URL when the
    /// corresponding cacheKey is empty or missing. The JS layer normalises so
    /// in practice arrays are always aligned and non-empty, but defend
    /// against length mismatch to avoid an out-of-bounds crash on a malformed
    /// caller.
    private static func zipKeys(urls: [String], cacheKeys: [String]) -> [(String, String)] {
        var out: [(String, String)] = []
        out.reserveCapacity(urls.count)
        for i in 0..<urls.count {
            let url = urls[i]
            let key = (i < cacheKeys.count && !cacheKeys[i].isEmpty) ? cacheKeys[i] : url
            out.append((url, key))
        }
        return out
    }
}
