import Foundation
import NitroModules

final class HybridSvgaManager: HybridSvgaManagerSpec {

    private static let MAX_CONCURRENT_PRELOADS = 4
    private let sounds = SvgaSoundLibrary()

    func preload(urls: [String]) throws -> Promise<Void> {
        return Promise.async { [weak self] in
            guard let self = self else { return }
            try await self.preloadAll(urls)
        }
    }

    func preloadDecoded(urls: [String]) throws -> Promise<Void> {
        let limit = Self.MAX_CONCURRENT_PRELOADS
        return Promise.async {
            await withTaskGroup(of: Void.self) { group in
                var inFlight = 0
                var iterator = urls.makeIterator()
                func enqueueNext() {
                    guard let source = iterator.next() else { return }
                    inFlight += 1
                    group.addTask {
                        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                            SvgaSourceLoader.loadEntity(source) { _ in cont.resume(returning: ()) }
                        }
                    }
                }
                for _ in 0..<min(limit, urls.count) { enqueueNext() }
                while inFlight > 0 {
                    _ = await group.next()
                    inFlight -= 1
                    enqueueNext()
                }
            }
        }
    }

    func isCached(url: String) throws -> Bool {
        guard let resolved = UrlValidator.resolve(url) else { return false }
        switch resolved.kind {
        case .remote:
            return SvgaDiskCache.isCached(resolved.value)
        case .localFile:
            return FileManager.default.fileExists(atPath: resolved.value)
        case .bundledAsset:
            return Self.assetExists(resolved.value)
        }
    }

    func getCachePath(url: String) throws -> String? {
        guard let resolved = UrlValidator.resolve(url) else { return nil }
        switch resolved.kind {
        case .remote:
            return SvgaDiskCache.pathOrNil(resolved.value)
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

    func setCacheLimit(bytes: Double) throws {
        SvgaDiskCache.setMaxBytes(Int64(bytes))
    }

    func setMemoryLimit(bytes: Double) throws {
        SvgaMemoryCache.shared.setMaxBytes(Int(bytes))
    }

    func loadSound(key: String, url: String) throws -> Promise<Void> {
        return Promise.async { [weak self] in
            guard let self = self else { return }
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

    private func preloadAll(_ urls: [String]) async throws {
        let limit = Self.MAX_CONCURRENT_PRELOADS
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = urls.makeIterator()
            var inFlight = 0
            func enqueue() throws {
                guard let source = iterator.next() else { return }
                inFlight += 1
                group.addTask { try await self.preloadOne(source) }
            }
            for _ in 0..<min(limit, urls.count) { try enqueue() }
            while inFlight > 0 {
                try await group.next()
                inFlight -= 1
                try enqueue()
            }
        }
    }

    private func preloadOne(_ source: String) async throws {
        guard let resolved = UrlValidator.resolve(source) else { return }
        if resolved.kind != .remote { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            SvgaSourceLoader.preloadRemote(resolved.value) { result in
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
}
