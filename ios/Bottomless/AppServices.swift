import Foundation
import Photos
import BottomlessCore

/// The app's long-lived objects. Built once per process, shared by the UI, background tasks and Shortcuts actions.
final class AppServices: @unchecked Sendable {
    static let shared: AppServices? = try? AppServices()

    let config: APIConfig
    let api: APIClient
    let catalog: Catalog
    let cache: CacheStore
    let sync: SyncEngine
    let uploader: BackgroundUploader
    let library: PhotoKitLibrary
    let engine: BackupEngine
    let allowance: DailyAllowance
    let root: URL

    enum SetupError: Error { case notConfigured }

    /// Server address and token come from the build settings (Info.plist); a launch environment can override them,
    /// which the simulator tests use to point at a local Worker. In the simulator only the launch environment counts:
    /// iOS also launches apps in the background (the nightly backup task) without it, and such a launch must never
    /// reach the real library with a simulator's test photos.
    static func configuration() -> APIConfig? {
        let env = ProcessInfo.processInfo.environment
        #if targetEnvironment(simulator)
        let info: [String: Any] = [:]
        #else
        let info = Bundle.main.infoDictionary ?? [:]
        #endif
        let base = env["BOTTOMLESS_API_BASE"] ?? info["BottomlessAPIBase"] as? String ?? ""
        let token = env["BOTTOMLESS_TOKEN"] ?? info["BottomlessToken"] as? String ?? ""
        guard !token.isEmpty, let url = URL(string: base), url.scheme != nil else { return nil }
        return APIConfig(baseURL: url, token: token)
    }

    init() throws {
        guard let config = Self.configuration() else { throw SetupError.notConfigured }
        self.config = config
        let fm = FileManager.default
        root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bottomless", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        api = APIClient(config: config)
        // The local catalog mirrors one server. Pointed at a different one, start over instead of mixing libraries.
        let catalogPath = root.appendingPathComponent("catalog.sqlite").path
        var catalog = try Catalog(path: catalogPath)
        if let previous = catalog.value("server"), previous != config.baseURL.absoluteString {
            for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: catalogPath + suffix) }
            try? fm.removeItem(at: root.appendingPathComponent("Cache", isDirectory: true))
            catalog = try Catalog(path: catalogPath)
        }
        try? catalog.setValue(config.baseURL.absoluteString, for: "server")
        self.catalog = catalog
        cache = try CacheStore(root: root.appendingPathComponent("Cache", isDirectory: true))
        sync = SyncEngine(api: api, catalog: catalog, cache: cache)
        let settings = Settings.load()
        uploader = BackgroundUploader(allowsCellular: !settings.wifiOnly)
        library = PhotoKitLibrary()
        allowance = DailyAllowance(catalog: catalog)
        engine = BackupEngine(api: api, catalog: catalog, cache: cache, library: library, uploader: uploader,
                              stagingRoot: root.appendingPathComponent("Staging", isDirectory: true), allowance: allowance)
        engine.attachUploader()
        uploader.connect()
    }

    struct RunSummary: Sendable {
        var newPhotos = 0
        var committed = 0
        var pulled = 0
        var failed = 0
    }

    /// One full pass: pull the catalog, find new photos, back them up, refresh the offline cache.
    func runAll(deadline: Date? = nil, backup: Bool = true) async -> RunSummary {
        var s = RunSummary()
        let settings = Settings.load()
        await sync.flushPending()
        if let r = try? await sync.pull() { s.pulled = r.changed }
        if backup && settings.autoBackup && PhotoKitLibrary.isAuthorized {
            if let found = try? await engine.scan() { s.newPhotos = found.added }
            let b = await engine.run(deadline: deadline)
            s.committed = b.committed
            s.failed = b.failed
        }
        // Albums made on this phone go to the cloud (so they outlive the photos on the phone), then come back down.
        if PhotoKitLibrary.isAuthorized {
            let full = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
            try? await sync.pushAlbums(PhotoKitLibrary.userAlbums(), phoneAlbumsComplete: full)
        }
        try? await sync.pullAlbums()
        try? await sync.pullPeople()
        if deadline.map({ Date() < $0 }) ?? true {
            await sync.fillCache(recentCount: settings.offlinePreviewCount)
        }
        UserDefaults.standard.set(Date(), forKey: "bottomless.lastRun")
        return s
    }
}
