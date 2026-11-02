import XCTest
@testable import BottomlessCore

/// End to end against a running Worker (scripts/test_core.sh starts one locally; set BOTTOMLESS_TEST_API to use another).
/// Two "phones": one backs up a library, the other only syncs, the way a fresh install would.
final class IntegrationTests: XCTestCase {
    var api: APIClient!

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["BOTTOMLESS_TEST_API"], let token = env["BOTTOMLESS_TEST_TOKEN"] else {
            throw XCTSkip("set BOTTOMLESS_TEST_API and BOTTOMLESS_TEST_TOKEN (scripts/test_core.sh does this)")
        }
        api = APIClient(config: APIConfig(baseURL: URL(string: base)!, token: token))
    }

    struct Phone {
        let catalog: Catalog, cache: CacheStore, sync: SyncEngine, engine: BackupEngine, library: FolderLibrary
    }

    func makePhone(_ name: String, library: FolderLibrary = FolderLibrary()) throws -> Phone {
        let root = tempDir("phone-\(name)-\(UUID().uuidString.prefix(6))")
        let catalog = try Catalog(path: root.appendingPathComponent("catalog.sqlite").path)
        let cache = try CacheStore(root: root.appendingPathComponent("cache"))
        let uploader = DirectUploader()
        let engine = BackupEngine(api: api, catalog: catalog, cache: cache, library: library, uploader: uploader,
                                  stagingRoot: root.appendingPathComponent("staging"))
        engine.attachUploader()
        return Phone(catalog: catalog, cache: cache, sync: SyncEngine(api: api, catalog: catalog, cache: cache), engine: engine, library: library)
    }

    /// Runs the engine until every job is committed (uploads finish asynchronously).
    func backupUntilDone(_ p: Phone, timeout: TimeInterval = 60) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            await p.engine.run()
            let c = p.catalog.backupCounts()
            if (c[.new] ?? 0) + (c[.prepared] ?? 0) + (c[.uploading] ?? 0) + (c[.uploaded] ?? 0) == 0 { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("backup did not finish: \(p.catalog.backupCounts())")
    }

    func testFullBackupSyncShareAndTrash() async throws {
        let dir = tempDir("library-\(UUID().uuidString.prefix(6))")
        let lib = FolderLibrary()
        let tag = Int.random(in: 1...1_000_000)
        let day: TimeInterval = 86400
        for i in 0..<5 {
            let f = dir.appendingPathComponent("IMG_\(i).jpg")
            try makeJPEG(width: 1600, height: 1200, seed: tag + i, gps: i == 0 ? (30.28, -97.74) : nil).write(to: f)
            lib.add("photo-\(i)", file: f, kind: .photo, created: Date().addingTimeInterval(-Double(i) * 20 * day), favorite: i == 4)
        }
        let live = dir.appendingPathComponent("LIVE.jpg"), liveMov = dir.appendingPathComponent("LIVE.mov")
        try makeJPEG(width: 1200, height: 900, seed: tag + 99).write(to: live)
        try await makeMovie(at: liveMov, seconds: 1)
        lib.add("live-1", file: live, kind: .live, created: Date().addingTimeInterval(-3 * day), paired: liveMov)
        let clip = dir.appendingPathComponent("CLIP.mov")
        try await makeMovie(at: clip, seconds: 2)
        lib.add("video-1", file: clip, kind: .video, created: Date().addingTimeInterval(-70 * day), mime: "video/quicktime")

        // Phone A backs everything up.
        let a = try makePhone("A", library: lib)
        let found = try await a.engine.scan()
        XCTAssertEqual(found.added, 7)
        try await backupUntilDone(a)
        XCTAssertEqual(a.catalog.backupCounts()[.committed], 7)
        XCTAssertEqual(a.catalog.readyAssets().count, 7)
        XCTAssertEqual(a.catalog.readyAssets(favoritesOnly: true).count, 1)
        let liveAsset = a.catalog.readyAssets().first { $0.kind == .live }!
        XCTAssertTrue(liveAsset.hasPaired)
        XCTAssertEqual(liveAsset.localId, "live-1")
        let gps = a.catalog.readyAssets().first { $0.lat != nil }!
        XCTAssertEqual(gps.lat!, 30.28, accuracy: 0.01)

        // Nothing is uploaded twice: a re-scan finds nothing new and dedupe protects re-adds.
        let rescan = try await a.engine.scan()
        XCTAssertEqual(rescan.added, 0)
        let staged = lib.exportCount
        await a.engine.run()
        XCTAssertEqual(lib.exportCount, staged)

        // Phone B (fresh install) syncs the catalog and the offline cache.
        let b = try makePhone("B")
        let pulled = try await b.sync.pull(pageSize: 3)
        XCTAssertGreaterThanOrEqual(pulled.changed, 7)
        let ids = Set(a.catalog.readyAssets().map(\.id))
        XCTAssertTrue(ids.isSubset(of: Set(b.catalog.readyAssets().map(\.id))))
        let filled = await b.sync.fillCache(recentCount: 3)
        XCTAssertEqual(filled.failures, 0)
        XCTAssertTrue(ids.isSubset(of: b.cache.ids(.thumb)), "every thumbnail is on the phone")
        let pinned = Set(b.catalog.readyAssets().prefix(3).map(\.id) + b.catalog.readyAssets(favoritesOnly: true).map(\.id))
        XCTAssertTrue(pinned.isSubset(of: b.cache.ids(.preview)), "previews of the 3 newest + every favorite are offline")

        // Originals come back byte for byte.
        let photo = a.catalog.readyAssets().first { $0.localId == "photo-1" }!
        let file = try await b.sync.original(b.catalog.asset(photo.id)!)
        XCTAssertEqual(try Hashing.digest(of: file).sha256, try Hashing.digest(of: dir.appendingPathComponent("IMG_1.jpg")).sha256)

        // A favorite set on one phone reaches the other; favorites made in the Photos app are pushed too.
        try await b.sync.setFavorite(photo.id, true)
        try await a.sync.pull()
        XCTAssertTrue(a.catalog.asset(photo.id)!.favorite)
        lib.setFavorite("photo-2", true)
        let favScan = try await a.engine.scan()
        XCTAssertEqual(favScan.favoriteChanges.count, 1)
        try await b.sync.pull()
        XCTAssertTrue(b.catalog.readyAssets(favoritesOnly: true).contains { $0.localId == nil && a.catalog.asset($0.id)?.localId == "photo-2" })

        // Share link for two photos.
        let link = try await api.createShare(assetIds: [photo.id, liveAsset.id], title: "Test", days: 1, allowOriginal: true)
        let (html, resp) = try await URLSession.shared.data(from: link.url)
        XCTAssertEqual((resp as! HTTPURLResponse).statusCode, 200)
        XCTAssertTrue(String(decoding: html, as: UTF8.self).contains(photo.id))
        try await api.deleteShare(link.token)

        // Trash on B disappears from A's library after a sync; restore brings it back.
        try await b.sync.trash(photo.id)
        try await a.sync.pull()
        XCTAssertFalse(a.catalog.readyAssets().contains { $0.id == photo.id })
        XCTAssertTrue(a.catalog.trashedAssets().contains { $0.id == photo.id })
        try await a.sync.restore(photo.id)
        try await b.sync.pull()
        XCTAssertTrue(b.catalog.readyAssets().contains { $0.id == photo.id })

        // Free-up-space rule: backed up, older than 30 days, not a favorite.
        let cutoff = FreeUpRule.cutoff(keepDays: 30)
        let candidates = Set(a.catalog.freeUpCandidates(olderThan: cutoff))
        XCTAssertEqual(candidates, ["photo-3", "video-1"], "photo-2 became a favorite, photo-4 is a favorite, the rest are recent")

        // Photos deleted from the phone stay in the library (as remote assets).
        lib.remove("photo-3")
        let goneScan = try await a.engine.scan()
        XCTAssertEqual(goneScan.goneFromDevice, 1)
        XCTAssertNil(a.catalog.asset(a.catalog.readyAssets().first { $0.filename == "IMG_3.jpg" }!.id)!.localId)
        let stats = try await api.stats()
        XCTAssertGreaterThanOrEqual(stats.ready, 7)
    }

    /// One run() is enough: uploads that finish afterwards must commit on their own (the app does not poll).
    func testFinishesWithoutBeingCalledAgain() async throws {
        let dir = tempDir("kick-\(UUID().uuidString.prefix(6))")
        let lib = FolderLibrary()
        for i in 0..<30 {
            let f = dir.appendingPathComponent("K\(i).jpg")
            try makeJPEG(width: 900, height: 700, seed: Int.random(in: 1...9_000_000)).write(to: f)
            lib.add("k-\(i)", file: f, kind: .photo, created: Date().addingTimeInterval(-Double(i) * 3600))
        }
        let p = try makePhone("K", library: lib)
        try await p.engine.scan()
        await p.engine.run()                     // starts at most maxStaged (24) uploads, then returns
        let end = Date().addingTimeInterval(60)
        while Date() < end, (p.catalog.backupCounts()[.committed] ?? 0) < 30 {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertEqual(p.catalog.backupCounts()[.committed], 30, "\(p.catalog.backupCounts())")
    }

    func testInterruptedUploadResumes() async throws {
        let dir = tempDir("resume-\(UUID().uuidString.prefix(6))")
        let lib = FolderLibrary()
        let f = dir.appendingPathComponent("R.jpg")
        try makeJPEG(width: 800, height: 600, seed: Int.random(in: 1...1_000_000)).write(to: f)
        lib.add("r-1", file: f, kind: .photo, created: Date())
        let p = try makePhone("R", library: lib)
        try await p.engine.scan()
        // Simulate a crash after prepare: the job is 'prepared' and no upload is running.
        await p.engine.run(maxNew: 1)
        var j = p.catalog.job("r-1")!
        if j.state == .uploading || j.state == .uploaded || j.state == .committed {
            // Uploads are quick locally; force the job back to 'uploading' with no live task to test recovery.
            j.state = .uploading; j.originalDone = false
            j.plan = j.plan ?? p.catalog.job("r-1")!.plan
            try p.catalog.save(j)
        }
        try await backupUntilDone(p)
        XCTAssertEqual(p.catalog.job("r-1")!.state, .committed)
    }
}
