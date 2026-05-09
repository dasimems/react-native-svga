import Foundation

internal final class SvgaMemoryCache {

    static let shared = SvgaMemoryCache()

    private let cache = NSCache<NSString, CachedEntity>()
    private var explicitLimit: Int?

    private final class CachedEntity {
        let entity: SvgaEntity
        init(_ entity: SvgaEntity) { self.entity = entity }
    }

    init() {
        cache.totalCostLimit = Self.defaultLimit()
    }

    func setMaxBytes(_ bytes: Int) {
        explicitLimit = max(0, bytes)
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
