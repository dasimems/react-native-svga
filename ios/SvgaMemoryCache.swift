import Foundation
import os

internal final class SvgaMemoryCache {

    static let shared = SvgaMemoryCache()

    private let cache = NSCache<NSString, CachedEntity>()
    /// Guards `setMaxBytes`, `setMaxAgeMs`, the `put`-time read of
    /// `cache.totalCostLimit`, and the TTL counters. NSCache itself is
    /// internally synchronised, but the gating compares (skip when limit == 0,
    /// expired-on-get) and the matched read+write of TTL state need to be
    /// serialised against the concurrent `parseQueue` workers that all
    /// funnel into `put`.
    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    private var maxAgeMs: Int64 = 0

    private final class CachedEntity {
        let entity: SvgaEntity
        // Wall-clock storage time; used for TTL filtering on read. Bumped on
        // every `put` so a re-download under the same key extends life.
        let storedAt: Date
        init(_ entity: SvgaEntity) {
            self.entity = entity
            self.storedAt = Date()
        }
    }

    init() {
        lock.initialize(to: os_unfair_lock())
        cache.totalCostLimit = Self.defaultLimit()
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func setMaxBytes(_ bytes: Int) {
        // Clamp the requested limit to a device-safe ceiling. The host app may
        // request a large flat limit (e.g. 300 MB) that's fine on a high-RAM
        // phone but ruinous on a low-RAM one — a decoded-bitmap cache that big
        // pushes the device into memory pressure, the OS fires a trim, and the
        // cache clears itself, wiping the very entries a preload just warmed.
        // Honour the request where there's headroom; cap it where there isn't.
        let safe = min(max(0, bytes), Self.deviceSafeCeiling())
        os_unfair_lock_lock(lock)
        cache.totalCostLimit = safe
        os_unfair_lock_unlock(lock)
    }

    /// Upper bound on the in-memory (decoded-bitmap) cache for this device,
    /// derived from physical RAM. Tunable. High-RAM devices get ~1/6 of RAM
    /// (so a 300 MB app request still sails through on 3 GB+); low-RAM devices
    /// are held well below the trim threshold.
    private static func deviceSafeCeiling() -> Int {
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let totalGB = Double(totalBytes) / 1_073_741_824.0
        switch totalGB {
        case ..<2.0: return 32 * 1024 * 1024
        case ..<3.0: return 96 * 1024 * 1024
        case ..<4.0: return 192 * 1024 * 1024
        default: return max(Int(totalBytes / 6), 256 * 1024 * 1024)
        }
    }

    func setMaxAgeMs(_ ms: Int64) {
        let safe = max(0, ms)
        os_unfair_lock_lock(lock)
        maxAgeMs = safe
        os_unfair_lock_unlock(lock)
    }

    /// Holds the lock across the cache observation, TTL check, and removal so
    /// a concurrent `put` for the same key cannot slip a fresh wrapper in
    /// between our staleness decision and the eviction call. Without this,
    /// the stale-then-fresh-put-then-removal interleaving would erase the
    /// freshly-cached entity, forcing a redundant re-download on the next get.
    /// We additionally identity-compare via `===` before removing, so even if
    /// NSCache's internal eviction races our held lock, we never delete a
    /// wrapper we didn't observe.
    func get(_ key: String) -> SvgaEntity? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard let cached = cache.object(forKey: key as NSString) else { return nil }
        if maxAgeMs > 0 {
            let ageMs = Int64(Date().timeIntervalSince(cached.storedAt) * 1000)
            if ageMs > maxAgeMs {
                if let current = cache.object(forKey: key as NSString), current === cached {
                    cache.removeObject(forKey: key as NSString)
                }
                return nil
            }
        }
        return cached.entity
    }

    /// Lock held across the limit read AND the actual `setObject` call so
    /// concurrent `get`s observe a consistent view of the cache state.
    func put(_ key: String, _ entity: SvgaEntity) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        if cache.totalCostLimit <= 0 { return }
        let cost = max(1, entity.byteSize)
        cache.setObject(CachedEntity(entity), forKey: key as NSString, cost: cost)
    }

    func clear() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        cache.removeAllObjects()
    }

    private static func defaultLimit() -> Int {
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let totalGB = Double(totalBytes) / 1_073_741_824.0
        switch totalGB {
        case ..<2.0: return 8 * 1024 * 1024
        case ..<3.0: return 16 * 1024 * 1024
        default: return 32 * 1024 * 1024
        }
    }
}
