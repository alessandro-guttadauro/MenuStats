import Foundation

struct VolumeInfo: Identifiable {
    var id: String { path }
    var name: String
    var path: String
    var total: UInt64
    /// Truly free space (what `df` and diskutil report).
    var free: UInt64
    /// Free plus purgeable space macOS can reclaim on demand (caches, local snapshots, optimizable iCloud files).
    var available: UInt64
    var isRemovable: Bool
    var isNetwork: Bool

    var used: UInt64 { total - min(free, total) }
    var purgeable: UInt64 { available > free ? available - free : 0 }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var purgeableFraction: Double { total > 0 ? Double(purgeable) / Double(total) : 0 }
}

/// Mounted, user-visible volumes with their capacity.
enum VolumeReader {
    static func sample() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            let free = UInt64(values.volumeAvailableCapacity ?? 0)
            let available = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) } ?? free
            return VolumeInfo(
                name: values.volumeLocalizedName ?? url.lastPathComponent,
                path: url.path,
                total: UInt64(total),
                free: free,
                available: max(available, free),
                isRemovable: values.volumeIsRemovable == true || values.volumeIsEjectable == true,
                isNetwork: values.volumeIsLocal == false
            )
        }
        .sorted { ($0.path == "/" ? 0 : 1, $0.name) < ($1.path == "/" ? 0 : 1, $1.name) }
    }
}
