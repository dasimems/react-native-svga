import Foundation

internal final class SvgaMemoryCache {

    static let shared = SvgaMemoryCache()

    private let cache = NSCache<NSString, CachedEntity>()

    private final class CachedEntity {
        let entity: SvgaEntity
        init(_ entity: SvgaEntity) { self.entity = entity }
    }

    init() {
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func setMaxBytes(_ bytes: Int) {
        cache.totalCostLimit = max(0, bytes)
    }

    func get(_ key: String) -> SvgaEntity? {
        return cache.object(forKey: key as NSString)?.entity
    }

    func put(_ key: String, _ entity: SvgaEntity) {
        if cache.totalCostLimit <= 0 { return }
        let cost = max(1, entity.byteSize)
        cache.setObject(CachedEntity(entity), forKey: key as NSString, cost: cost)
    }

    func clear() { cache.removeAllObjects() }
}
