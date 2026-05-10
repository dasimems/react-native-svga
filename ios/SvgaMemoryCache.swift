import Foundation
import os

internal final class SvgaMemoryCache {

    static let shared = SvgaMemoryCache()

    private let cache = NSCache<NSString, CachedEntity>()
    /// Guards `setMaxBytes` and the `put`-time read of `cache.totalCostLimit`.
    /// NSCache itself is internally synchronised, but the gating compare in
    /// `put` (skip when limit == 0) and the matched read+write in
    /// `setMaxBytes` need to be serialised against the new concurrent
    /// `parseQueue` workers that all funnel into `put`.
    private let lock = os_unfair_lock_t.allocate(capacity: 1)

    private final class CachedEntity {
        let entity: SvgaEntity
        init(_ entity: SvgaEntity) { self.entity = entity }
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
        let safe = max(0, bytes)
        os_unfair_lock_lock(lock)
        cache.totalCostLimit = safe
        os_unfair_lock_unlock(lock)
    }

    func get(_ key: String) -> SvgaEntity? {
        return cache.object(forKey: key as NSString)?.entity
    }

    func put(_ key: String, _ entity: SvgaEntity) {
        os_unfair_lock_lock(lock)
        let limit = cache.totalCostLimit
        os_unfair_lock_unlock(lock)
        if limit <= 0 { return }
        let cost = max(1, entity.byteSize)
        cache.setObject(CachedEntity(entity), forKey: key as NSString, cost: cost)
    }

    func clear() { cache.removeAllObjects() }

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
