import Foundation
import NitroModules

final class HybridSvgaManager: HybridSvgaManagerSpec {

    private let sounds = SvgaSoundLibrary()
    private let queue = DispatchQueue(label: "svga.manager", qos: .utility, attributes: .concurrent)

    func preload(urls: [String]) throws -> Promise<Void> {
        return Promise.async { [weak self] in
            guard let self = self else { return }
            try await self.preloadAll(urls)
        }
    }

    func preloadDecoded(urls: [String]) throws -> Promise<Void> {
        return Promise.async {
            await withTaskGroup(of: Void.self) { group in
                for source in urls {
                    group.addTask {
                        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                            SvgaSourceLoader.loadEntity(source) { _ in cont.resume(returning: ()) }
                        }
                    }
                }
                for await _ in group { }
            }
        }
    }

    func isCached(url: String) throws -> Bool {
        guard let resolved = UrlValidator.resolve(url) else { return false }
        if resolved.kind != .remote { return false }
        return SvgaDiskCache.isCached(resolved.value)
    }

    func getCachePath(url: String) throws -> String? {
        guard let resolved = UrlValidator.resolve(url) else { return nil }
        if resolved.kind != .remote { return nil }
        return SvgaDiskCache.pathOrNil(resolved.value)
    }

    func clearCache() throws {
        try SvgaDiskCache.clearSvga()
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

    deinit { sounds.release() }

    private func preloadAll(_ urls: [String]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for source in urls {
                group.addTask { try await self.preloadOne(source) }
            }
            for try await _ in group { }
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
