import Foundation

internal enum SvgaDiskCache {

    private static let SVGA_DIR = "svga_cache"
    private static let SOUND_DIR = "svga_sounds"
    private static let DEFAULT_LIMIT: Int64 = 50 * 1024 * 1024
    private static var maxBytes: Int64 = DEFAULT_LIMIT
    private static let queue = DispatchQueue(label: "svga.diskcache", attributes: .concurrent)
    private static let writeQueue = DispatchQueue(label: "svga.diskcache.write")

    static func setMaxBytes(_ bytes: Int64) {
        queue.async(flags: .barrier) { maxBytes = max(0, bytes) }
    }

    static func getMaxBytes() -> Int64 {
        return queue.sync { maxBytes }
    }

    static func svgaURL(for source: String) -> URL { fileURL(in: SVGA_DIR, key: Hashing.sha256(source)) }
    static func soundURL(for key: String) -> URL { fileURL(in: SOUND_DIR, key: Hashing.sha256(key)) }

    static func isCached(_ source: String) -> Bool {
        return FileManager.default.fileExists(atPath: svgaURL(for: source).path)
    }

    static func pathOrNil(_ source: String) -> String? {
        let url = svgaURL(for: source)
        if FileManager.default.fileExists(atPath: url.path) { return url.path }
        return nil
    }

    // touch on read so frequently-replayed entries don't get evicted by a
    // single one-shot save. mtime drives eviction order in evictToMakeRoom.
    static func cachedURL(_ source: String) -> URL? {
        let url = svgaURL(for: source)
        if !FileManager.default.fileExists(atPath: url.path) { return nil }
        touch(url)
        return url
    }

    static func cachedSoundURL(for key: String) -> URL? {
        let url = soundURL(for: key)
        if !FileManager.default.fileExists(atPath: url.path) { return nil }
        touch(url)
        return url
    }

    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }

    static func saveSvga(_ source: String, data: Data) throws -> URL {
        let url = svgaURL(for: source)
        var thrown: Error?
        // Synchronous so callers receive a usable URL only after the bytes
        // are committed. Note: the *caller* (SvgaSourceLoader.preloadRemote
        // and saveSoundFile) provides its own dispatch — the URLSession
        // completion-queue users in `loadData` have been routed to
        // `saveSvgaAsync` so this `.sync` doesn't pin that queue.
        writeQueue.sync {
            do {
                evictToMakeRoom(in: SVGA_DIR, limit: getMaxBytes(), incoming: Int64(data.count), replacing: url)
                try writeAtomic(url, data: data)
            } catch {
                thrown = error
            }
        }
        if let thrown = thrown { throw thrown }
        return url
    }

    /// Fire-and-forget write used from queues we don't want to block (e.g.
    /// the URLSession completion queue). Errors are silently dropped — the
    /// download succeeded so the user-facing entity is delivered; cache
    /// failure only means the next load won't be a cache hit.
    static func saveSvgaAsync(_ source: String, data: Data) {
        let url = svgaURL(for: source)
        writeQueue.async {
            do {
                evictToMakeRoom(in: SVGA_DIR, limit: getMaxBytes(), incoming: Int64(data.count), replacing: url)
                try writeAtomic(url, data: data)
            } catch {
                // intentional: best-effort cache write
            }
        }
    }

    static func saveSound(_ key: String, data: Data) throws -> URL {
        let url = soundURL(for: key)
        var thrown: Error?
        writeQueue.sync {
            do {
                evictToMakeRoom(in: SOUND_DIR, limit: getMaxBytes(), incoming: Int64(data.count), replacing: url)
                try writeAtomic(url, data: data)
            } catch {
                thrown = error
            }
        }
        if let thrown = thrown { throw thrown }
        return url
    }

    static func clearSvga() throws {
        let dir = try ensureDir(SVGA_DIR)
        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        for item in items { try? FileManager.default.removeItem(at: item) }
    }

    static func clearSounds() throws {
        let dir = try ensureDir(SOUND_DIR)
        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        for item in items { try? FileManager.default.removeItem(at: item) }
    }

    static func totalSvgaBytes() -> Int64 {
        guard let dir = try? ensureDir(SVGA_DIR) else { return 0 }
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for item in items {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    private static func fileURL(in folder: String, key: String) -> URL {
        let dir = (try? ensureDir(folder)) ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent(key)
    }

    private static func ensureDir(_ folder: String) throws -> URL {
        let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = cache.appendingPathComponent(folder, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func writeAtomic(_ target: URL, data: Data) throws {
        let tmp = target.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        // If `moveItem` succeeds, the cleanup is a no-op (tmp no longer
        // exists at that path). If it throws (cross-volume, permission,
        // racing process), the defer reaps the orphan so the cache dir
        // doesn't accumulate `.tmp` siblings on every failed write.
        defer { try? FileManager.default.removeItem(at: tmp) }
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: tmp, to: target)
    }

    private static func evictToMakeRoom(in folder: String, limit: Int64, incoming: Int64, replacing: URL) {
        guard let dir = try? ensureDir(folder) else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        var withMeta: [(url: URL, size: Int64, mtime: Date)] = []
        var total: Int64 = 0
        for item in items {
            let values = try? item.resourceValues(forKeys: Set(keys))
            let size = Int64(values?.fileSize ?? 0)
            let mtime = values?.contentModificationDate ?? Date.distantPast
            // The slot we're about to overwrite contributes 0 to the
            // post-write total — its bytes get replaced by `incoming`,
            // not added to it. Skipping it here (vs counting then
            // subtracting) keeps the budget calculation symmetric with
            // the eviction loop below, which only walks `withMeta`.
            if item.path == replacing.path { continue }
            withMeta.append((item, size, mtime))
            total += size
        }
        let target = limit - incoming
        if total <= target { return }
        withMeta.sort { $0.mtime < $1.mtime }
        for entry in withMeta {
            if total <= target { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
