import Foundation

/// Where one local photo is in the backup pipeline.
public enum BackupState: String, Codable, Sendable, CaseIterable {
    case new          // seen on the phone, nothing done yet
    case prepared     // exported, hashed, thumbnails made, server gave upload URLs
    case uploading    // original handed to the background upload session
    case uploaded     // original (and paired video) are in cloud storage
    case committed    // server verified it; backed up
    case failed       // gave up after repeated errors (retried on demand)
}

/// What the phone's photo library reports about one item.
public struct LocalAssetInfo: Sendable, Equatable {
    public var localId: String
    public var createdAt: Date
    public var kind: AssetKind
    public var isFavorite: Bool
    public init(localId: String, createdAt: Date, kind: AssetKind, isFavorite: Bool) {
        self.localId = localId; self.createdAt = createdAt; self.kind = kind; self.isFavorite = isFavorite
    }
}

/// Everything needed to finish an upload after the app was suspended (stored as JSON).
public struct UploadPlan: Codable, Sendable, Equatable {
    public var assetId: String
    public var original: UploadTarget
    public var paired: UploadTarget?
    public var primaryFile: String       // file names inside the job's staging directory
    public var pairedFile: String?
    public var thumbFile: String
    public var previewFile: String
    public var preparedAt: Date
}

public struct BackupJob: Sendable, Equatable {
    public var localId: String
    public var createdAt: Date
    public var kind: AssetKind
    public var isFavorite: Bool
    public var state: BackupState
    public var assetId: String?
    public var sha256: String?
    public var attempts: Int
    public var lastError: String?
    public var nextTryAt: Date
    public var plan: UploadPlan?
    public var originalDone: Bool
    public var pairedDone: Bool
    public var onDevice: Bool
}

/// The phone's copy of the library (mirrors the server's change feed) plus the backup queue.
public final class Catalog: @unchecked Sendable {
    public let db: SQLiteDB

    public init(path: String) throws {
        db = try SQLiteDB(path: path)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS assets (
          id TEXT PRIMARY KEY, sha256 TEXT, kind TEXT NOT NULL, mime TEXT, size INTEGER, filename TEXT,
          width INTEGER, height INTEGER, duration REAL, taken_at INTEGER NOT NULL, lat REAL, lon REAL,
          favorite INTEGER NOT NULL DEFAULT 0, hidden INTEGER NOT NULL DEFAULT 0, has_paired INTEGER NOT NULL DEFAULT 0,
          status TEXT NOT NULL, trashed_at INTEGER, seq INTEGER NOT NULL DEFAULT 0, last_viewed INTEGER);
        CREATE INDEX IF NOT EXISTS assets_taken ON assets (taken_at DESC);
        CREATE TABLE IF NOT EXISTS backups (
          local_id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, kind TEXT NOT NULL, is_favorite INTEGER NOT NULL DEFAULT 0,
          state TEXT NOT NULL, asset_id TEXT, sha256 TEXT, attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT,
          next_try_at INTEGER NOT NULL DEFAULT 0, plan TEXT, original_done INTEGER NOT NULL DEFAULT 0,
          paired_done INTEGER NOT NULL DEFAULT 0, on_device INTEGER NOT NULL DEFAULT 1, updated_at INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS backups_state ON backups (state, next_try_at);
        CREATE INDEX IF NOT EXISTS backups_asset ON backups (asset_id);
        CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS outbox (seq INTEGER PRIMARY KEY AUTOINCREMENT, asset_id TEXT NOT NULL, op TEXT NOT NULL,
          value INTEGER NOT NULL, created_at INTEGER NOT NULL);
        """)
        let columns = try db.query("PRAGMA table_info(assets)").compactMap { $0.string("name") }
        if !columns.contains("live_off") { try db.execute("ALTER TABLE assets ADD COLUMN live_off INTEGER NOT NULL DEFAULT 0") }
        if !columns.contains("added_at") {
            // When each photo reached Bottomless (for Recently Added). Older catalogs re-read the feed once to fill it in.
            try db.execute("ALTER TABLE assets ADD COLUMN added_at INTEGER")
            try db.execute("DELETE FROM kv WHERE key = 'cursor'")
        }
        try db.execute("""
            CREATE TABLE IF NOT EXISTS albums (id TEXT PRIMARY KEY, title TEXT NOT NULL, source TEXT, updated_at INTEGER);
            CREATE TABLE IF NOT EXISTS album_items (album_id TEXT NOT NULL, asset_id TEXT NOT NULL, ord INTEGER NOT NULL,
              PRIMARY KEY (album_id, asset_id)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS album_sent (album_id TEXT NOT NULL, asset_id TEXT NOT NULL,
              PRIMARY KEY (album_id, asset_id)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS album_sent_title (album_id TEXT PRIMARY KEY, title TEXT NOT NULL);
            """)
    }

    // MARK: key/value

    public func value(_ key: String) -> String? {
        (try? db.query("SELECT value FROM kv WHERE key = ?", [.text(key)]))?.first?.string("value")
    }

    public func setValue(_ value: String?, for key: String) throws {
        if let value {
            try db.execute("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           [.text(key), .text(value)])
        } else {
            try db.execute("DELETE FROM kv WHERE key = ?", [.text(key)])
        }
    }

    public var cursor: Int64 {
        get { Int64(value("cursor") ?? "0") ?? 0 }
    }
    public func setCursor(_ c: Int64) throws { try setValue(String(c), for: "cursor") }

    // MARK: remote mirror

    /// Applies a page of the change feed. Returns ids that were purged (their cached files should go).
    @discardableResult
    public func apply(_ remote: [RemoteAsset]) throws -> [String] {
        var purged: [String] = []
        try db.transaction {
            for a in remote {
                if a.status == .purged || a.status == .pending {
                    try db.execute("DELETE FROM assets WHERE id = ?", [.text(a.id)])
                    if a.status == .purged { purged.append(a.id) }
                    continue
                }
                try db.execute("""
                INSERT INTO assets (id, sha256, kind, mime, size, filename, width, height, duration, taken_at, lat, lon,
                  favorite, hidden, has_paired, status, trashed_at, seq, live_off, added_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET sha256 = excluded.sha256, kind = excluded.kind, mime = excluded.mime,
                  size = excluded.size, filename = excluded.filename, width = excluded.width, height = excluded.height,
                  duration = excluded.duration, taken_at = excluded.taken_at, lat = excluded.lat, lon = excluded.lon,
                  favorite = excluded.favorite, hidden = excluded.hidden, has_paired = excluded.has_paired,
                  status = excluded.status, trashed_at = excluded.trashed_at, seq = excluded.seq, live_off = excluded.live_off,
                  added_at = excluded.added_at
                """, [.text(a.id), .text(a.sha256), .text(a.kind.rawValue), .text(a.mime), .int(a.size), SQLValue(a.filename),
                      SQLValue(a.width), SQLValue(a.height), SQLValue(a.duration), .int(a.takenAt), SQLValue(a.lat), SQLValue(a.lon),
                      SQLValue(a.favorite), SQLValue(a.hidden), SQLValue(a.hasPaired), .text(a.status.rawValue),
                      SQLValue(a.trashedAt), .int(a.seq), SQLValue(a.liveOff ?? false), .int(a.createdAt)])
            }
        }
        return purged
    }

    private func asset(from r: Row) -> CatalogAsset {
        CatalogAsset(
            id: r.string("id")!, kind: AssetKind(rawValue: r.string("kind") ?? "photo") ?? .photo, mime: r.string("mime") ?? "",
            size: r.int("size") ?? 0, filename: r.string("filename"), width: r.int("width").map(Int.init),
            height: r.int("height").map(Int.init), duration: r.double("duration"), takenAt: Date(ms: r.int("taken_at") ?? 0),
            lat: r.double("lat"), lon: r.double("lon"), favorite: r.bool("favorite"), hidden: r.bool("hidden"),
            hasPaired: r.bool("has_paired"), status: AssetStatus(rawValue: r.string("status") ?? "ready") ?? .ready,
            trashedAt: r.int("trashed_at").map { Date(ms: $0) }, liveOff: r.bool("live_off"), localId: r.string("local_id"))
    }

    private let assetSelect = """
        SELECT a.*, (SELECT b.local_id FROM backups b WHERE b.asset_id = a.id AND b.on_device = 1 LIMIT 1) AS local_id
        FROM assets a
        """

    public func asset(_ id: String) -> CatalogAsset? {
        (try? db.query("\(assetSelect) WHERE a.id = ?", [.text(id)]))?.first.map(asset(from:))
    }

    /// Ready, not hidden, newest first.
    public func readyAssets(favoritesOnly: Bool = false) -> [CatalogAsset] {
        let fav = favoritesOnly ? " AND a.favorite = 1" : ""
        return ((try? db.query("\(assetSelect) WHERE a.status = 'ready' AND a.hidden = 0\(fav) ORDER BY a.taken_at DESC")) ?? [])
            .map(asset(from:))
    }

    // MARK: collections

    /// Groups built from what is stored with every photo in the cloud, so they stay after photos leave the phone.
    public enum Collection: String, CaseIterable, Sendable, Identifiable {
        case favorites, recentlyAdded, videos, livePhotos, screenshots, places
        public var id: String { rawValue }

        var filter: String {
            switch self {
            case .favorites: return "a.favorite = 1"
            case .recentlyAdded: return "a.added_at >= ?"
            case .videos: return "a.kind = 'video'"
            case .livePhotos: return "a.kind = 'live'"
            // Android names them Screenshot_...; iPhone screenshots are PNGs shaped like the screen.
            case .screenshots: return """
                (lower(a.filename) LIKE '%screenshot%' OR (a.mime = 'image/png' AND a.width > 0 AND a.height > 0
                  AND (a.height * 1.0 / a.width >= 1.7 OR a.width * 1.0 / a.height >= 1.7)))
                """
            case .places: return "a.lat IS NOT NULL AND a.lon IS NOT NULL"
            }
        }
        var order: String { self == .recentlyAdded ? "a.added_at DESC" : "a.taken_at DESC" }
    }

    public static let recentlyAddedDays = 30

    private func collectionArgs(_ c: Collection, now: Date) -> [SQLValue] {
        c == .recentlyAdded ? [.int(now.addingTimeInterval(-Double(Self.recentlyAddedDays) * 86400).ms)] : []
    }

    public func assets(in c: Collection, now: Date = Date()) -> [CatalogAsset] {
        ((try? db.query("\(assetSelect) WHERE a.status = 'ready' AND a.hidden = 0 AND \(c.filter) ORDER BY \(c.order)",
                        collectionArgs(c, now: now))) ?? []).map(asset(from:))
    }

    public struct GroupSummary: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var count: Int
        public var coverId: String?
    }

    /// Count and newest photo of each collection (for the Collections tab's tiles).
    public func collectionSummaries(now: Date = Date()) -> [Collection: GroupSummary] {
        var out: [Collection: GroupSummary] = [:]
        for c in Collection.allCases {
            let where_ = "a.status = 'ready' AND a.hidden = 0 AND \(c.filter)"
            let args = collectionArgs(c, now: now)
            let n = (try? db.query("SELECT COUNT(*) AS n FROM assets a WHERE \(where_)", args))?.first?.int("n") ?? 0
            let cover = (try? db.query("SELECT a.id FROM assets a WHERE \(where_) ORDER BY \(c.order) LIMIT 1", args))?.first?.string("id")
            out[c] = GroupSummary(id: c.rawValue, title: c.rawValue, count: Int(n), coverId: cover)
        }
        return out
    }

    /// Photos with a location, for the Places map (id, place, date), oldest data first is fine: the map groups them.
    public func locatedPoints() -> [(id: String, lat: Double, lon: Double)] {
        ((try? db.query("SELECT id, lat, lon FROM assets WHERE status = 'ready' AND hidden = 0 AND lat IS NOT NULL AND lon IS NOT NULL ORDER BY taken_at DESC")) ?? [])
            .compactMap { r in
                guard let id = r.string("id"), let la = r.double("lat"), let lo = r.double("lon") else { return nil }
                return (id, la, lo)
            }
    }

    public func assets(ids: [String]) -> [CatalogAsset] {
        guard !ids.isEmpty else { return [] }
        var out: [CatalogAsset] = []
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            out += ((try? db.query("\(assetSelect) WHERE a.status = 'ready' AND a.id IN (\(marks))", chunk.map { .text($0) })) ?? []).map(asset(from:))
        }
        return out.sorted { $0.takenAt > $1.takenAt }
    }

    // MARK: albums

    /// The albums as the server has them (replaces what was here).
    public func replaceAlbums(_ albums: [RemoteAlbum]) throws {
        try db.transaction {
            try db.execute("DELETE FROM album_items")
            try db.execute("DELETE FROM albums")
            for a in albums {
                try db.execute("INSERT INTO albums (id, title, source, updated_at) VALUES (?, ?, ?, ?)",
                               [.text(a.id), .text(a.title), .text(a.source), .int(a.updatedAt)])
                for (i, asset) in a.assetIds.enumerated() {
                    try db.execute("INSERT OR IGNORE INTO album_items (album_id, asset_id, ord) VALUES (?, ?, ?)", [.text(a.id), .text(asset), .int(Int64(i))])
                }
            }
        }
    }

    public func albumSummaries() -> [GroupSummary] {
        ((try? db.query("""
            SELECT al.id, al.title,
              (SELECT COUNT(*) FROM album_items i JOIN assets a ON a.id = i.asset_id WHERE i.album_id = al.id AND a.status = 'ready') AS n,
              (SELECT i.asset_id FROM album_items i JOIN assets a ON a.id = i.asset_id WHERE i.album_id = al.id AND a.status = 'ready'
                 ORDER BY a.taken_at DESC LIMIT 1) AS cover
            FROM albums al ORDER BY al.title COLLATE NOCASE
            """)) ?? []).map {
            GroupSummary(id: $0.string("id") ?? "", title: $0.string("title") ?? "Album", count: Int($0.int("n") ?? 0), coverId: $0.string("cover"))
        }.filter { $0.count > 0 }
    }

    public func albumAssets(_ albumId: String) -> [CatalogAsset] {
        ((try? db.query("""
            \(assetSelect) JOIN album_items i ON i.asset_id = a.id
            WHERE i.album_id = ? AND a.status = 'ready' ORDER BY a.taken_at DESC
            """, [.text(albumId)])) ?? []).map(asset(from:))
    }

    /// The cloud asset for a photo on this phone, once it is backed up.
    public func backedUpAssetId(localId: String) -> String? {
        (try? db.query("SELECT asset_id FROM backups WHERE local_id = ? AND state = 'committed'", [.text(localId)]))?.first?.string("asset_id")
    }

    /// Whether this phone still has the photo (it may have been freed up since it went into an album).
    public func isOnDevice(assetId: String) -> Bool {
        ((try? db.query("SELECT 1 FROM backups WHERE asset_id = ? AND on_device = 1 LIMIT 1", [.text(assetId)])) ?? []).count > 0
    }

    /// What this phone last sent for an album, so it only sends what changed.
    public func albumSent(_ albumId: String) -> (title: String?, assetIds: Set<String>) {
        let ids = Set(((try? db.query("SELECT asset_id FROM album_sent WHERE album_id = ?", [.text(albumId)])) ?? []).compactMap { $0.string("asset_id") })
        let title = (try? db.query("SELECT title FROM album_sent_title WHERE album_id = ?", [.text(albumId)]))?.first?.string("title")
        return (title, ids)
    }

    public func sentAlbumIds() -> [String] {
        ((try? db.query("SELECT album_id FROM album_sent_title")) ?? []).compactMap { $0.string("album_id") }
    }

    public func recordAlbumSent(_ albumId: String, title: String, added: Set<String>, removed: Set<String>) throws {
        try db.transaction {
            try db.execute("INSERT INTO album_sent_title (album_id, title) VALUES (?, ?) ON CONFLICT(album_id) DO UPDATE SET title = excluded.title",
                           [.text(albumId), .text(title)])
            for a in added { try db.execute("INSERT OR IGNORE INTO album_sent (album_id, asset_id) VALUES (?, ?)", [.text(albumId), .text(a)]) }
            for a in removed { try db.execute("DELETE FROM album_sent WHERE album_id = ? AND asset_id = ?", [.text(albumId), .text(a)]) }
        }
    }

    public func forgetAlbumSent(_ albumId: String) throws {
        try db.execute("DELETE FROM album_sent WHERE album_id = ?", [.text(albumId)])
        try db.execute("DELETE FROM album_sent_title WHERE album_id = ?", [.text(albumId)])
    }

    public func hiddenAssets() -> [CatalogAsset] {
        ((try? db.query("\(assetSelect) WHERE a.status = 'ready' AND a.hidden = 1 ORDER BY a.taken_at DESC")) ?? []).map(asset(from:))
    }

    public func trashedAssets() -> [CatalogAsset] {
        ((try? db.query("\(assetSelect) WHERE a.status = 'trashed' ORDER BY a.trashed_at DESC")) ?? []).map(asset(from:))
    }

    /// The whole library for the grid: backed-up assets plus photos still waiting on this phone, newest first.
    public func libraryItems() -> [LibraryEntry] {
        var items = readyAssets().map(LibraryEntry.remote)
        let waiting = (try? db.query("""
            SELECT local_id, created_at, kind, state FROM backups
            WHERE state != 'committed' AND on_device = 1
            """)) ?? []
        for r in waiting {
            items.append(.local(localId: r.string("local_id")!, createdAt: Date(ms: r.int("created_at") ?? 0),
                                kind: AssetKind(rawValue: r.string("kind") ?? "photo") ?? .photo,
                                state: BackupState(rawValue: r.string("state") ?? "new") ?? .new))
        }
        return items.sorted { $0.date > $1.date }
    }

    // MARK: outbox

    /// A change made on this phone that the server has not accepted yet.
    public struct PendingChange: Sendable, Equatable {
        public enum Op: String, Sendable { case trash, favorite, liveOff }
        public var seq: Int64
        public var assetId: String
        public var op: Op
        /// trash: true = to Recently Deleted, false = restored; favorite / liveOff: the new value.
        public var value: Bool
    }

    /// Records a change and shows it right away. A later change of the same kind to the same photo replaces it.
    public func enqueue(_ assetId: String, _ op: PendingChange.Op, _ value: Bool, now: Date = Date()) throws {
        try db.transaction {
            try db.execute("DELETE FROM outbox WHERE asset_id = ? AND op = ?", [.text(assetId), .text(op.rawValue)])
            try db.execute("INSERT INTO outbox (asset_id, op, value, created_at) VALUES (?, ?, ?, ?)",
                           [.text(assetId), .text(op.rawValue), SQLValue(value), .int(now.ms)])
            try applyLocally(assetId, op, value, now: now)
        }
    }

    public func pendingChanges() -> [PendingChange] {
        ((try? db.query("SELECT seq, asset_id, op, value FROM outbox ORDER BY seq")) ?? []).compactMap { r in
            guard let op = PendingChange.Op(rawValue: r.string("op") ?? "") else { return nil }
            return PendingChange(seq: r.int("seq") ?? 0, assetId: r.string("asset_id") ?? "", op: op, value: r.bool("value"))
        }
    }

    public func removePending(_ seq: Int64) throws {
        try db.execute("DELETE FROM outbox WHERE seq = ?", [.int(seq)])
    }

    /// Re-applies changes still waiting for the server on top of what the server last said, so a sync in between
    /// does not bring back a photo you deleted (or undo a favorite) before the server has accepted it.
    public func reapplyPending(now: Date = Date()) throws {
        for c in pendingChanges() { try applyLocally(c.assetId, c.op, c.value, now: now) }
    }

    private func applyLocally(_ id: String, _ op: PendingChange.Op, _ value: Bool, now: Date) throws {
        switch op {
        case .trash:
            if value { try db.execute("UPDATE assets SET status = 'trashed', trashed_at = COALESCE(trashed_at, ?) WHERE id = ? AND status = 'ready'", [.int(now.ms), .text(id)]) }
            else { try db.execute("UPDATE assets SET status = 'ready', trashed_at = NULL WHERE id = ? AND status = 'trashed'", [.text(id)]) }
        case .favorite: try db.execute("UPDATE assets SET favorite = ? WHERE id = ?", [SQLValue(value), .text(id)])
        case .liveOff: try db.execute("UPDATE assets SET live_off = ? WHERE id = ?", [SQLValue(value), .text(id)])
        }
    }

    public func setFavoriteLocally(_ id: String, _ favorite: Bool) throws {
        try db.execute("UPDATE assets SET favorite = ? WHERE id = ?", [SQLValue(favorite), .text(id)])
    }

    public func markViewed(_ id: String, at date: Date = Date()) {
        try? db.execute("UPDATE assets SET last_viewed = ? WHERE id = ?", [.int(date.ms), .text(id)])
    }

    /// ids of previews to pin offline plus recently viewed ones (input for CachePolicy).
    public func cacheInputs() -> [CachePolicy.Item] {
        ((try? db.query("SELECT id, taken_at, favorite, last_viewed FROM assets WHERE status = 'ready' AND hidden = 0")) ?? []).map {
            CachePolicy.Item(id: $0.string("id")!, takenAt: Date(ms: $0.int("taken_at") ?? 0), favorite: $0.bool("favorite"),
                             lastViewed: $0.int("last_viewed").map { Date(ms: $0) })
        }
    }

    public func allAssetIds() -> [String] {
        ((try? db.query("SELECT id FROM assets")) ?? []).compactMap { $0.string("id") }
    }

    public func counts() -> (ready: Int, favorites: Int, trashed: Int) {
        let r = (try? db.query("""
            SELECT SUM(status = 'ready') AS ready, SUM(status = 'ready' AND favorite = 1) AS fav, SUM(status = 'trashed') AS trash FROM assets
            """))?.first
        return (Int(r?.int("ready") ?? 0), Int(r?.int("fav") ?? 0), Int(r?.int("trash") ?? 0))
    }

    // MARK: backup queue

    public struct DiscoverResult: Sendable {
        public var added: Int
        public var favoriteChanges: [(assetId: String, favorite: Bool)]
        public var goneFromDevice: Int
    }

    /// Reconciles the queue with what is in the phone's library right now.
    public func discover(_ local: [LocalAssetInfo], now: Date = Date()) throws -> DiscoverResult {
        var result = DiscoverResult(added: 0, favoriteChanges: [], goneFromDevice: 0)
        try db.transaction {
            var known: [String: (fav: Bool, assetId: String?, state: String, onDevice: Bool)] = [:]
            for r in try db.query("SELECT local_id, is_favorite, asset_id, state, on_device FROM backups") {
                known[r.string("local_id")!] = (r.bool("is_favorite"), r.string("asset_id"), r.string("state") ?? "new", r.bool("on_device"))
            }
            var present = Set<String>()
            for a in local {
                present.insert(a.localId)
                if let k = known[a.localId] {
                    if k.fav != a.isFavorite {
                        try db.execute("UPDATE backups SET is_favorite = ?, updated_at = ? WHERE local_id = ?",
                                       [SQLValue(a.isFavorite), .int(now.ms), .text(a.localId)])
                        if k.state == BackupState.committed.rawValue, let id = k.assetId {
                            result.favoriteChanges.append((id, a.isFavorite))
                        }
                    }
                    if !k.onDevice {
                        try db.execute("UPDATE backups SET on_device = 1 WHERE local_id = ?", [.text(a.localId)])
                    }
                } else {
                    try db.execute("""
                        INSERT INTO backups (local_id, created_at, kind, is_favorite, state, updated_at) VALUES (?, ?, ?, ?, 'new', ?)
                        """, [.text(a.localId), .int(a.createdAt.ms), .text(a.kind.rawValue), SQLValue(a.isFavorite), .int(now.ms)])
                    result.added += 1
                }
            }
            for (id, k) in known where k.onDevice && !present.contains(id) {
                try db.execute("UPDATE backups SET on_device = 0, updated_at = ? WHERE local_id = ?", [.int(now.ms), .text(id)])
                result.goneFromDevice += 1
            }
        }
        return result
    }

    private func job(from r: Row) -> BackupJob {
        BackupJob(
            localId: r.string("local_id")!, createdAt: Date(ms: r.int("created_at") ?? 0),
            kind: AssetKind(rawValue: r.string("kind") ?? "photo") ?? .photo, isFavorite: r.bool("is_favorite"),
            state: BackupState(rawValue: r.string("state") ?? "new") ?? .new, assetId: r.string("asset_id"),
            sha256: r.string("sha256"), attempts: Int(r.int("attempts") ?? 0), lastError: r.string("last_error"),
            nextTryAt: Date(ms: r.int("next_try_at") ?? 0),
            plan: r.string("plan").flatMap { try? JSONDecoder().decode(UploadPlan.self, from: Data($0.utf8)) },
            originalDone: r.bool("original_done"), pairedDone: r.bool("paired_done"), onDevice: r.bool("on_device"))
    }

    public func job(_ localId: String) -> BackupJob? {
        (try? db.query("SELECT * FROM backups WHERE local_id = ?", [.text(localId)]))?.first.map(job(from:))
    }

    /// Jobs in `state` whose retry time has come, newest photos first (so recent photos are safe soonest).
    public func dueJobs(_ state: BackupState, limit: Int, now: Date = Date()) -> [BackupJob] {
        ((try? db.query("""
            SELECT * FROM backups WHERE state = ? AND next_try_at <= ? AND on_device = 1 ORDER BY created_at DESC LIMIT ?
            """, [.text(state.rawValue), .int(now.ms), .int(Int64(limit))])) ?? []).map(job(from:))
    }

    public func jobs(_ state: BackupState) -> [BackupJob] {
        ((try? db.query("SELECT * FROM backups WHERE state = ? ORDER BY created_at DESC", [.text(state.rawValue)])) ?? []).map(job(from:))
    }

    public func save(_ j: BackupJob, now: Date = Date()) throws {
        let plan = try j.plan.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try db.execute("""
            UPDATE backups SET state = ?, asset_id = ?, sha256 = ?, attempts = ?, last_error = ?, next_try_at = ?, plan = ?,
              original_done = ?, paired_done = ?, is_favorite = ?, updated_at = ? WHERE local_id = ?
            """, [.text(j.state.rawValue), SQLValue(j.assetId), SQLValue(j.sha256), .int(Int64(j.attempts)), SQLValue(j.lastError),
                  .int(j.nextTryAt.ms), SQLValue(plan), SQLValue(j.originalDone), SQLValue(j.pairedDone), SQLValue(j.isFavorite),
                  .int(now.ms), .text(j.localId)])
    }

    public func backupCounts() -> [BackupState: Int] {
        var out: [BackupState: Int] = [:]
        for r in (try? db.query("SELECT state, COUNT(*) AS n FROM backups WHERE on_device = 1 GROUP BY state")) ?? [] {
            if let s = BackupState(rawValue: r.string("state") ?? "") { out[s] = Int(r.int("n") ?? 0) }
        }
        return out
    }

    /// Retry everything that gave up.
    public func resetFailed() throws {
        try db.execute("UPDATE backups SET state = 'new', attempts = 0, next_try_at = 0, last_error = NULL, plan = NULL, original_done = 0, paired_done = 0 WHERE state = 'failed'")
    }

    public func localId(forAsset id: String) -> String? {
        (try? db.query("SELECT local_id FROM backups WHERE asset_id = ? AND on_device = 1 LIMIT 1", [.text(id)]))?.first?.string("local_id")
    }

    /// Backed-up photos still on the phone that the free-up-space rule allows deleting from the phone.
    public func freeUpCandidates(olderThan cutoff: Date) -> [String] {
        ((try? db.query("""
            SELECT b.local_id FROM backups b JOIN assets a ON a.id = b.asset_id
            WHERE b.state = 'committed' AND b.on_device = 1 AND b.is_favorite = 0 AND a.favorite = 0
              AND a.status = 'ready' AND b.created_at < ? ORDER BY b.created_at
            """, [.int(cutoff.ms)])) ?? []).compactMap { $0.string("local_id") }
    }

    public func markRemovedFromDevice(_ localIds: [String]) throws {
        try db.transaction {
            for id in localIds { try db.execute("UPDATE backups SET on_device = 0 WHERE local_id = ?", [.text(id)]) }
        }
    }
}
