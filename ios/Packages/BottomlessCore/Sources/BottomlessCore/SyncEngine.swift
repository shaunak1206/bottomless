import Foundation

/// Pulls the server's change feed into the local catalog and keeps the on-phone cache in shape.
public final class SyncEngine: @unchecked Sendable {
    public let api: APIClient
    public let catalog: Catalog
    public let cache: CacheStore

    public init(api: APIClient, catalog: Catalog, cache: CacheStore) {
        self.api = api; self.catalog = catalog; self.cache = cache
    }

    public struct PullResult: Sendable, Equatable { public var changed: Int; public var purged: Int }

    /// Applies every change since the stored cursor. Safe to call often; does nothing when up to date.
    @discardableResult
    public func pull(pageSize: Int = 500) async throws -> PullResult {
        var result = PullResult(changed: 0, purged: 0)
        var cursor = catalog.cursor
        while true {
            let page = try await api.changes(since: cursor, limit: pageSize)
            let purged = try catalog.apply(page.assets)
            for id in purged { cache.removeAll(for: id) }
            result.changed += page.assets.count
            result.purged += purged.count
            cursor = page.cursor
            try catalog.setCursor(cursor)
            if !page.hasMore { break }
        }
        try? catalog.reapplyPending()
        return result
    }

    public struct CacheResult: Sendable, Equatable {
        public var thumbsFetched = 0
        public var previewsFetched = 0
        public var previewsEvicted = 0
        public var failures = 0
    }

    /// Downloads every missing thumbnail and the pinned previews; evicts previews nobody needs.
    @discardableResult
    public func fillCache(recentCount: Int, viewedExtra: Int = 100, maxConcurrent: Int = 6,
                          progress: (@Sendable (Int, Int) -> Void)? = nil) async -> CacheResult {
        var result = CacheResult()
        let items = catalog.cacheInputs()
        let liveIds = Set(catalog.allAssetIds())
        // Thumbnails of things no longer in the catalog (purged elsewhere) go.
        for stale in cache.ids(.thumb).subtracting(liveIds) { cache.remove(.thumb, stale) }

        let haveThumbs = cache.ids(.thumb)
        let needThumbs = items.sorted { $0.takenAt > $1.takenAt }.map(\.id).filter { !haveThumbs.contains($0) }
        let plan = CachePolicy.previews(items, cached: cache.ids(.preview), recentCount: recentCount, viewedExtra: viewedExtra)
        for id in plan.evict { cache.remove(.preview, id) }
        result.previewsEvicted = plan.evict.count

        let work: [(String, APIClient.Derived)] = needThumbs.map { ($0, .thumb) } + plan.fetch.map { ($0, .preview) }
        let total = work.count
        var done = 0
        await withTaskGroup(of: (APIClient.Derived, Bool).self) { group in
            var it = work.makeIterator()
            func addNext() -> Bool {
                guard let (id, which) = it.next() else { return false }
                group.addTask { [api, cache] in
                    do {
                        let data = try await api.derived(id, which)
                        try cache.write(data, which == .thumb ? .thumb : .preview, id)
                        return (which, true)
                    } catch { return (which, false) }
                }
                return true
            }
            for _ in 0..<maxConcurrent { if !addNext() { break } }
            while let (which, ok) = await group.next() {
                done += 1
                if ok { if which == .thumb { result.thumbsFetched += 1 } else { result.previewsFetched += 1 } } else { result.failures += 1 }
                progress?(done, total)
                _ = addNext()
            }
        }
        return result
    }

    /// The preview for one asset: from the cache, else downloaded (and cached as recently viewed).
    public func preview(_ id: String) async throws -> Data {
        if let d = cache.data(.preview, id) { catalog.markViewed(id); return d }
        let d = try await api.derived(id, .preview)
        try? cache.write(d, .preview, id)
        catalog.markViewed(id)
        return d
    }

    public func thumbnail(_ id: String) async throws -> Data {
        if let d = cache.data(.thumb, id) { return d }
        let d = try await api.derived(id, .thumb)
        try? cache.write(d, .thumb, id)
        return d
    }

    /// Downloads the full-resolution original to the cache and returns its file URL.
    public func original(_ asset: CatalogAsset, maxCacheBytes: Int64 = 1 << 30) async throws -> URL {
        let ext = (asset.filename as NSString?)?.pathExtension.lowercased().nonEmpty ?? MimeTypes.ext(for: asset.mime)
        let dest = cache.url(.original, asset.id, ext: ext)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        let url = try await api.originalURL(asset.id)
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.http(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, message: "original download failed")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        cache.trimOriginals(maxBytes: maxCacheBytes)
        return dest
    }

    /// Albums as the server has them (they are small; the whole list is fetched).
    public func pullAlbums() async throws {
        try catalog.replaceAlbums(try await api.albums().albums)
    }

    /// People found by the Mac's face indexer. The list is only downloaded when something changed.
    public func pullPeople() async throws {
        let page = try await api.people(since: catalog.peopleVersion)
        guard page.unchanged != true, let people = page.people else { return }
        try catalog.replacePeople(people, version: page.version)
    }

    /// Mirrors this phone's albums into the cloud. Only what changed since the last sync is sent. A photo that has left
    /// the phone (freed up) stays in its cloud album; one removed from an album on the phone is removed there too.
    /// Albums deleted on the phone are deleted in the cloud only when `phoneAlbumsComplete` (full Photos access).
    public func pushAlbums(_ phoneAlbums: [(localId: String, title: String, photos: [String])], phoneAlbumsComplete: Bool) async throws {
        var seen = Set<String>()
        for album in phoneAlbums {
            let id = Self.albumId(forLocal: album.localId)
            seen.insert(id)
            let desired = Set(album.photos.compactMap { catalog.backedUpAssetId(localId: $0) })
            let sent = catalog.albumSent(id)
            let add = desired.subtracting(sent.assetIds)
            let remove = sent.assetIds.subtracting(desired).filter { catalog.isOnDevice(assetId: $0) }
            if add.isEmpty && remove.isEmpty && sent.title == album.title { continue }
            if desired.isEmpty && sent.title == nil { continue }      // nothing backed up yet: create it later
            try await api.putAlbum(id: id, title: album.title, add: Array(add), remove: Array(remove))
            try catalog.recordAlbumSent(id, title: album.title, added: add, removed: Set(remove))
        }
        if phoneAlbumsComplete {
            for id in catalog.sentAlbumIds() where !seen.contains(id) {
                try await api.deleteAlbum(id: id)
                try catalog.forgetAlbumSent(id)
            }
        }
    }

    /// Stable cloud id for an album on this phone.
    public static func albumId(forLocal localId: String) -> String {
        "iphone-" + Hashing.sha256Hex(Data(localId.utf8)).prefix(20)
    }

    // MARK: changes made on this phone

    /// Delete, restore, favorite and Live on/off take effect on the phone at once and are sent to the server as soon as
    /// it accepts them. A daily cloud limit, no signal or airplane mode only delays them; they go out with the next sync.
    public func change(_ id: String, _ op: Catalog.PendingChange.Op, _ value: Bool) async {
        try? catalog.enqueue(id, op, value)
        await flushPending()
    }

    public func setFavorite(_ id: String, _ favorite: Bool) async throws { await change(id, .favorite, favorite) }
    public func setLiveOff(_ id: String, _ off: Bool) async throws { await change(id, .liveOff, off) }

    /// Sends waiting changes in order. Stops at the first one the server cannot take yet (it will retry later);
    /// drops ones the server says no longer apply (the photo is gone, or already in that state).
    @discardableResult
    public func flushPending() async -> Int {
        var sent = 0
        for c in catalog.pendingChanges() {
            do {
                let a: RemoteAsset
                switch c.op {
                case .trash: a = c.value ? try await api.trash(c.assetId) : try await api.restore(c.assetId)
                case .favorite: a = try await api.setFavorite(c.assetId, c.value)
                case .liveOff: a = try await api.setLiveOff(c.assetId, c.value)
                }
                try? catalog.removePending(c.seq)
                try? catalog.apply([a])
                sent += 1
            } catch APIError.http(let status, _) where status == 404 || status == 409 {
                try? catalog.removePending(c.seq)
            } catch {
                break
            }
        }
        try? catalog.reapplyPending()
        return sent
    }

    public var pendingCount: Int { catalog.pendingChanges().count }

    /// The motion clip of a Live Photo, downloaded once and then played from the phone.
    public func liveClip(_ asset: CatalogAsset, maxCacheBytes: Int64 = 1 << 30) async throws -> URL {
        let dest = cache.url(.original, asset.id + ".live", ext: "mov")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        let url = try await api.originalURL(asset.id, paired: true)
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.http(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, message: "motion clip download failed")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        cache.trimOriginals(maxBytes: maxCacheBytes)
        return dest
    }

    public func trash(_ id: String) async throws { await change(id, .trash, true) }
    public func restore(_ id: String) async throws { await change(id, .trash, false) }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
