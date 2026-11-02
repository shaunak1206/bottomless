import SwiftUI
import Network
import Photos
import BottomlessCore

@Observable @MainActor
final class AppModel {
    let services = AppServices.shared
    var configured: Bool { services != nil }

    var items: [LibraryEntry] = []
    var librarySections: [LibrarySection] = []
    /// Where each entry sits in `items`, so a cell coming on screen can fetch the thumbnails just after it.
    @ObservationIgnored var positions: [String: Int] = [:]
    @ObservationIgnored private let prefetcher = ThumbnailPrefetcher()
    var favoriteSections: [LibrarySection] = []
    var favorites: [CatalogAsset] = []
    var collections: [Catalog.Collection: Catalog.GroupSummary] = [:]
    var albums: [Catalog.GroupSummary] = []
    var people: [Catalog.PersonSummary] = []
    var trashed: [CatalogAsset] = []
    var backupCounts: [BackupState: Int] = [:]
    var stats: ServerStats?
    var shares: [SharedLink] = []
    var freeUpCount = 0
    var photoAccess: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var isOffline = ProcessInfo.processInfo.arguments.contains("-forceOffline")
    var isWorking = false
    var lastRun: Date? = UserDefaults.standard.object(forKey: "bottomless.lastRun") as? Date
    var message: String?
    var openFreeUp = false
    var settings = Settings.load() { didSet { settings.save() } }
    /// The cloud refused new uploads until this time (a spending cap, or Cloudflare's free daily database limit).
    var backupPausedUntil: Date?
    /// Bumped when a photo's Live switch changes, so open viewers redraw.
    var liveRevision = 0
    /// Set to an asset id to play that Live Photo's motion once (from the viewer's LIVE menu).
    var livePlayRequest: String?

    private let forceOffline = ProcessInfo.processInfo.arguments.contains("-forceOffline")
    private let monitor = NWPathMonitor()
    private var started = false

    var waitingCount: Int { backupCounts.filter { $0.key != .committed && $0.key != .failed }.values.reduce(0, +) }
    var failedCount: Int { backupCounts[.failed] ?? 0 }
    var backedUpCount: Int { backupCounts[.committed] ?? 0 }

    func start() async {
        guard configured, !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self, !self.forceOffline else { return }
                let offline = path.status != .satisfied
                if self.isOffline && !offline { self.isOffline = false; await self.refresh(backup: true) } else { self.isOffline = offline }
            }
        }
        monitor.start(queue: DispatchQueue(label: "bottomless.net"))
        // Uploads finish in the background; refresh the grid and counts whenever the backup engine moves on.
        NotificationCenter.default.addObserver(forName: .bottomlessBackupChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleReload() }
        }
        if photoAccess == .notDetermined {
            _ = await PhotoKitLibrary.requestAccess()
            photoAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
        reload()
        await refresh(backup: true)
    }

    private var reloading = false
    private var reloadAgain = false
    private var reloadScheduled = false

    /// Re-reads everything the UI shows from the local catalog. With tens of thousands of photos that takes a few
    /// hundred milliseconds, so it runs off the main thread (the grid stays smooth) and overlapping calls coalesce.
    func reload() {
        guard let s = services else { return }
        if UserDefaults.standard.bool(forKey: "bottomless.openFreeUp") {
            UserDefaults.standard.removeObject(forKey: "bottomless.openFreeUp")
            openFreeUp = true
        }
        if reloading { reloadAgain = true; return }
        reloading = true
        let keepDays = settings.keepOnPhoneDays
        let (shownItems, shownFavorites) = (items, favorites)
        Task.detached(priority: .userInitiated) { [weak self] in
            let snap = LibrarySnapshot(s, keepDays: keepDays)
            // Comparing here, off the main thread, means an unchanged library does not make SwiftUI re-diff a grid
            // of tens of thousands of cells (that is what made scrolling stall while a sync ran).
            let changed = (items: snap.items != shownItems, favorites: snap.favorites != shownFavorites)
            await self?.apply(snap, changed: changed)
        }
    }

    /// The backup engine reports progress after every upload; refresh at most every 2 seconds for that.
    func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            reloadScheduled = false
            reload()
        }
    }

    private func apply(_ snap: LibrarySnapshot, changed: (items: Bool, favorites: Bool)) {
        if changed.items {
            items = snap.items
            librarySections = snap.sections
            positions = snap.positions
        }
        if changed.favorites {
            favorites = snap.favorites
            favoriteSections = snap.favoriteSections
        }
        collections = snap.collections
        albums = snap.albums
        if people != snap.people { people = snap.people }
        trashed = snap.trashed
        if backupCounts != snap.backupCounts { backupCounts = snap.backupCounts }
        backupPausedUntil = snap.pausedUntil.flatMap { $0 > Date() ? $0 : nil }
        freeUpCount = snap.freeUpCount
        reloading = false
        if reloadAgain { reloadAgain = false; reload() }
    }

    /// The grid shows `item`: start fetching the thumbnails of the next ~30, nearest first.
    func prefetch(after item: LibraryEntry) {
        guard let i = positions[item.id], i % 6 == 0 else { return }
        let ids = items[(i + 1)..<min(i + 31, items.count)].compactMap { e -> String? in
            if case .remote(let a) = e { return a.id }
            return nil
        }
        let prefetcher = prefetcher
        Task { await prefetcher.want(ids) }
    }

    /// Sync with the server and (optionally) back up new photos, updating the UI while it runs.
    func refresh(backup: Bool) async {
        guard let s = services, !isWorking else { reload(); return }
        guard !isOffline else { reload(); return }
        isWorking = true
        defer { isWorking = false }
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.reload()
            }
        }
        let summary = await Task.detached { await s.runAll(backup: backup) }.value
        ticker.cancel()
        lastRun = Date()
        if summary.failed > 0 { message = "\(summary.failed) item(s) could not be backed up yet; they will be retried." }
        stats = try? await s.api.stats()
        shares = (try? await s.api.shares()) ?? shares
        reload()
    }

    func retryFailed() async {
        try? services?.catalog.resetFailed()
        await refresh(backup: true)
    }

    // MARK: actions on assets

    /// Bumped whenever a change is made on this phone, so open views re-read the photo from the catalog.
    var changeRevision = 0

    /// Applies a change on the phone at once (the photo disappears, the heart fills) and sends it to the server in the
    /// background. If the server cannot take it yet (daily cloud limit, no signal) it is kept and sent with a later sync.
    private func change(_ ids: [String], _ op: Catalog.PendingChange.Op, _ value: Bool) {
        guard let s = services else { return }
        for id in ids { try? s.catalog.enqueue(id, op, value) }
        changeRevision += 1
        reload()
        Task.detached { [weak self] in
            await s.sync.flushPending()
            await MainActor.run { self?.reload() }
        }
    }

    func toggleFavorite(_ asset: CatalogAsset) async { change([asset.id], .favorite, !asset.favorite) }

    func setLiveOff(_ asset: CatalogAsset, _ off: Bool) async {
        change([asset.id], .liveOff, off)
        liveRevision += 1
    }

    /// Whether this photo should play its motion: it is a Live Photo, Live is on for it, and Live Photos are on overall.
    func playsLive(_ asset: CatalogAsset) -> Bool {
        _ = liveRevision
        let fresh = services?.catalog.asset(asset.id) ?? asset
        return settings.playLivePhotos && fresh.kind == .live && fresh.hasPaired && !fresh.liveOff
    }

    /// The motion clip to play: straight from Photos when the Live Photo is still on this iPhone, otherwise downloaded
    /// once from the cloud and kept in the cache.
    func liveClip(_ asset: CatalogAsset) async -> URL? {
        guard let s = services else { return nil }
        let dest = s.cache.url(.original, asset.id + ".live", ext: "mov")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        if let localId = asset.localId, await PhotoKitLibrary().pairedVideo(localId, to: dest) { return dest }
        guard !isOffline else { return nil }
        return try? await s.sync.liveClip(asset, maxCacheBytes: Int64(settings.originalsCacheMB) << 20)
    }

    func trash(_ ids: [String]) async { change(ids, .trash, true) }
    func restore(_ id: String) async { change([id], .trash, false) }
    func setFavorite(_ ids: [String], _ fav: Bool) async { change(ids, .favorite, fav) }

    /// Files to hand to the share sheet: phone-sized previews (fast) or full originals.
    func shareFiles(_ ids: [String], originals: Bool) async throws -> [URL] {
        guard let s = services else { return [] }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        for id in ids {
            guard let a = s.catalog.asset(id) else { continue }
            let base = ((a.filename ?? "Photo") as NSString).deletingPathExtension
            if originals || a.kind == .video {
                let src = try await s.sync.original(a, maxCacheBytes: Int64(settings.originalsCacheMB) << 20)
                let dest = dir.appendingPathComponent("\(base).\(src.pathExtension)")
                try FileManager.default.copyItem(at: src, to: dest)
                out.append(dest)
            } else {
                let data = try await s.sync.preview(id)
                let dest = dir.appendingPathComponent("\(base).jpg")
                try data.write(to: dest)
                out.append(dest)
            }
        }
        return out
    }

    func createShareLink(_ ids: [String], title: String, days: Int, allowOriginal: Bool) async throws -> SharedLink {
        guard let s = services else { throw AppServices.SetupError.notConfigured }
        let link = try await s.api.createShare(assetIds: ids, title: title, days: days, allowOriginal: allowOriginal)
        shares.insert(link, at: 0)
        return link
    }

    func deleteShare(_ link: SharedLink) async {
        try? await services?.api.deleteShare(link.token)
        shares.removeAll { $0.token == link.token }
    }

    func originalFile(_ asset: CatalogAsset) async throws -> URL {
        guard let s = services else { throw AppServices.SetupError.notConfigured }
        return try await s.sync.original(asset, maxCacheBytes: Int64(settings.originalsCacheMB) << 20)
    }

    func saveToPhotos(_ asset: CatalogAsset) async {
        guard let s = services else { return }
        do {
            let file = try await originalFile(asset)
            try await s.library.saveToPhotos(file: file, isVideo: asset.kind == .video)
            message = "Saved to Photos."
        } catch { message = "Could not save to Photos: \(error)" }
    }

    // MARK: free up space

    /// Deletes backed-up photos older than the keep window from the phone (iOS asks to confirm).
    func freeUpSpace() async {
        guard let s = services, settings.iCloudPhotosOffConfirmed else { return }
        // Pull first so anything trashed or changed on another device is accounted for.
        _ = try? await s.sync.pull()
        let ids = s.catalog.freeUpCandidates(olderThan: FreeUpRule.cutoff(keepDays: settings.keepOnPhoneDays))
        guard !ids.isEmpty else { message = "Nothing to remove right now."; return }
        do {
            try await s.library.delete(ids)
            try s.catalog.markRemovedFromDevice(ids)
            message = "Removed \(ids.count) item(s) from this iPhone. They stay in Bottomless; empty Recently Deleted in Photos to get the space back now."
        } catch {
            message = "Nothing was removed (\(error.localizedDescription))."
        }
        reload()
    }

    func requestPhotoAccess() async {
        _ = await PhotoKitLibrary.requestAccess()
        photoAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        await refresh(backup: true)
    }
}

/// One month of the library grid.
struct LibrarySection: Identifiable {
    let id: Int             // year * 12 + month
    let title: String
    let items: [LibraryEntry]

    static func group(_ items: [LibraryEntry]) -> [LibrarySection] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        var out: [LibrarySection] = []
        var current: [LibraryEntry] = []
        var key = Int.min
        var first = Date()
        func flush() { if !current.isEmpty { out.append(LibrarySection(id: key, title: f.string(from: first), items: current)) } }
        for item in items {
            let c = cal.dateComponents([.year, .month], from: item.date)
            let k = (c.year ?? 0) * 12 + (c.month ?? 0)
            if k != key { flush(); key = k; first = item.date; current = [] }
            current.append(item)
        }
        flush()
        return out
    }
}

/// Everything the UI shows from the catalog, read in one go off the main thread.
struct LibrarySnapshot: Sendable {
    let items: [LibraryEntry]
    let sections: [LibrarySection]
    let positions: [String: Int]
    let favorites: [CatalogAsset]
    let favoriteSections: [LibrarySection]
    let trashed: [CatalogAsset]
    let backupCounts: [BackupState: Int]
    let freeUpCount: Int
    let pausedUntil: Date?
    let collections: [Catalog.Collection: Catalog.GroupSummary]
    let albums: [Catalog.GroupSummary]
    let people: [Catalog.PersonSummary]

    init(_ s: AppServices, keepDays: Int) {
        items = s.catalog.libraryItems()
        sections = LibrarySection.group(items)
        positions = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        favorites = s.catalog.readyAssets(favoritesOnly: true)
        favoriteSections = LibrarySection.group(favorites.map(LibraryEntry.remote))
        trashed = s.catalog.trashedAssets()
        backupCounts = s.catalog.backupCounts()
        freeUpCount = s.catalog.freeUpCandidates(olderThan: FreeUpRule.cutoff(keepDays: keepDays)).count
        pausedUntil = s.engine.pausedUntil
        collections = s.catalog.collectionSummaries()
        albums = s.catalog.albumSummaries()
        people = s.catalog.peopleSummaries()
    }
}

extension LibrarySection: @unchecked Sendable {}
