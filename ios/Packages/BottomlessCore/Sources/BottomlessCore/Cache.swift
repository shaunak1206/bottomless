import Foundation

/// Decides which previews live on the phone: the newest N, every favorite, and a few recently viewed ones.
/// Thumbnails are always kept for every asset (that is what makes the whole library browsable offline).
public enum CachePolicy {
    public struct Item: Sendable, Equatable {
        public var id: String
        public var takenAt: Date
        public var favorite: Bool
        public var lastViewed: Date?
        public init(id: String, takenAt: Date, favorite: Bool, lastViewed: Date?) {
            self.id = id; self.takenAt = takenAt; self.favorite = favorite; self.lastViewed = lastViewed
        }
    }

    public struct Plan: Sendable, Equatable {
        public var pinned: Set<String>
        public var fetch: [String]        // pinned but not on the phone yet, newest first
        public var evict: [String]        // cached but no longer wanted
    }

    public static func previews(_ items: [Item], cached: Set<String>, recentCount: Int, viewedExtra: Int) -> Plan {
        let byDate = items.sorted { $0.takenAt > $1.takenAt }
        var pinned = Set(byDate.prefix(max(0, recentCount)).map(\.id))
        for i in items where i.favorite { pinned.insert(i.id) }
        let recentlyViewed = items
            .filter { !pinned.contains($0.id) && $0.lastViewed != nil && cached.contains($0.id) }
            .sorted { $0.lastViewed! > $1.lastViewed! }
            .prefix(max(0, viewedExtra))
            .map(\.id)
        let keep = pinned.union(recentlyViewed)
        let fetch = byDate.filter { pinned.contains($0.id) && !cached.contains($0.id) }.map(\.id)
        let evict = cached.subtracting(keep).sorted()
        return Plan(pinned: pinned, fetch: fetch, evict: evict)
    }
}

/// Files on the phone: thumbnails, previews and downloaded originals.
public final class CacheStore: @unchecked Sendable {
    public enum Kind: String, CaseIterable { case thumb = "thumbs", preview = "previews", original = "originals" }
    public let root: URL
    private let fm = FileManager.default

    public init(root: URL) throws {
        self.root = root
        for k in Kind.allCases {
            try fm.createDirectory(at: root.appendingPathComponent(k.rawValue), withIntermediateDirectories: true)
        }
        // Excluded from iCloud/iTunes backups: everything here can be downloaded again.
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    public func url(_ kind: Kind, _ id: String, ext: String = "jpg") -> URL {
        root.appendingPathComponent(kind.rawValue).appendingPathComponent("\(id).\(ext)")
    }

    public func has(_ kind: Kind, _ id: String) -> Bool { fm.fileExists(atPath: url(kind, id).path) }

    public func data(_ kind: Kind, _ id: String) -> Data? { try? Data(contentsOf: url(kind, id)) }

    public func write(_ data: Data, _ kind: Kind, _ id: String) throws {
        try data.write(to: url(kind, id), options: .atomic)
    }

    /// Moves a finished file into the cache (e.g. a thumbnail made during backup).
    public func adopt(file: URL, _ kind: Kind, _ id: String, ext: String = "jpg") throws {
        let dest = url(kind, id, ext: ext)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: file, to: dest)
    }

    public func remove(_ kind: Kind, _ id: String) {
        let dir = root.appendingPathComponent(kind.rawValue)
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(id + ".") {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    public func removeAll(for id: String) { Kind.allCases.forEach { remove($0, id) } }

    public func ids(_ kind: Kind) -> Set<String> {
        let names = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(kind.rawValue).path)) ?? []
        return Set(names.compactMap { n in n.split(separator: ".").first.map(String.init) })
    }

    public func bytes(_ kind: Kind) -> Int64 {
        let dir = root.appendingPathComponent(kind.rawValue)
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.reduce(0) { sum, n in
            sum + Int64((try? fm.attributesOfItem(atPath: dir.appendingPathComponent(n).path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// Keeps downloaded originals under `maxBytes`, deleting the least recently used first.
    public func trimOriginals(maxBytes: Int64) {
        let dir = root.appendingPathComponent(Kind.original.rawValue)
        let keys: [URLResourceKey] = [.contentAccessDateKey, .contentModificationDateKey, .fileSizeKey]
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        var entries = files.map { f -> (URL, Date, Int64) in
            let v = try? f.resourceValues(forKeys: Set(keys))
            return (f, v?.contentAccessDate ?? v?.contentModificationDate ?? .distantPast, Int64(v?.fileSize ?? 0))
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        entries.sort { $0.1 < $1.1 }
        for (f, _, size) in entries where total > maxBytes {
            try? fm.removeItem(at: f)
            total -= size
        }
    }
}
