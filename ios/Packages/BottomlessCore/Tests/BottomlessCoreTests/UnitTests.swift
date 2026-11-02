import XCTest
import ImageIO
@testable import BottomlessCore

final class CatalogTests: XCTestCase {
    var catalog: Catalog!

    override func setUp() async throws {
        catalog = try Catalog(path: tempDir().appendingPathComponent("c.sqlite").path)
    }

    func testApplyUpsertsAndPurges() throws {
        try catalog.apply([remote("a", takenAt: 1), remote("b", takenAt: 2), remote("c", takenAt: 3, status: .trashed)])
        XCTAssertEqual(catalog.readyAssets().map(\.id), ["b", "a"], "newest first, trash excluded")
        XCTAssertEqual(catalog.trashedAssets().map(\.id), ["c"])
        let purged = try catalog.apply([remote("a", status: .purged), remote("b", takenAt: 2, favorite: true, seq: 9)])
        XCTAssertEqual(purged, ["a"])
        XCTAssertNil(catalog.asset("a"))
        XCTAssertEqual(catalog.readyAssets(favoritesOnly: true).map(\.id), ["b"])
        try catalog.setCursor(42)
        XCTAssertEqual(catalog.cursor, 42)
    }

    func testDiscoverAddsDetectsFavoriteChangesAndGoneItems() throws {
        let d0 = Date(timeIntervalSince1970: 1000)
        var r = try catalog.discover([LocalAssetInfo(localId: "L1", createdAt: d0, kind: .photo, isFavorite: false),
                                      LocalAssetInfo(localId: "L2", createdAt: d0, kind: .video, isFavorite: false)])
        XCTAssertEqual(r.added, 2)
        var j = catalog.job("L1")!
        j.state = .committed; j.assetId = "A1"
        try catalog.save(j)
        r = try catalog.discover([LocalAssetInfo(localId: "L1", createdAt: d0, kind: .photo, isFavorite: true)])
        XCTAssertEqual(r.added, 0)
        XCTAssertEqual(r.favoriteChanges.map(\.assetId), ["A1"])
        XCTAssertEqual(r.goneFromDevice, 1, "L2 disappeared from the phone")
        XCTAssertFalse(catalog.job("L2")!.onDevice)
    }

    func testLibraryMergesBackedUpAndWaitingItems() throws {
        try catalog.apply([remote("A1", takenAt: Date(timeIntervalSince1970: 2000).ms)])
        _ = try catalog.discover([LocalAssetInfo(localId: "L1", createdAt: Date(timeIntervalSince1970: 1000), kind: .photo, isFavorite: false),
                                  LocalAssetInfo(localId: "L2", createdAt: Date(timeIntervalSince1970: 3000), kind: .photo, isFavorite: false)])
        var j = catalog.job("L1")!
        j.state = .committed; j.assetId = "A1"
        try catalog.save(j)
        let items = catalog.libraryItems()
        XCTAssertEqual(items.map(\.id), ["local:L2", "A1"], "committed local items show as their remote asset")
        XCTAssertEqual(catalog.asset("A1")?.localId, "L1")
    }

    func testFreeUpCandidates() throws {
        let old = Date().addingTimeInterval(-60 * 86400), recent = Date().addingTimeInterval(-2 * 86400)
        try catalog.apply([remote("A1"), remote("A2"), remote("A3", favorite: true), remote("A4")])
        _ = try catalog.discover([
            LocalAssetInfo(localId: "old", createdAt: old, kind: .photo, isFavorite: false),
            LocalAssetInfo(localId: "recent", createdAt: recent, kind: .photo, isFavorite: false),
            LocalAssetInfo(localId: "oldfav", createdAt: old, kind: .photo, isFavorite: false),
            LocalAssetInfo(localId: "notbacked", createdAt: old, kind: .photo, isFavorite: false)])
        for (l, a) in [("old", "A1"), ("recent", "A2"), ("oldfav", "A3")] {
            var j = catalog.job(l)!; j.state = .committed; j.assetId = a; try catalog.save(j)
        }
        XCTAssertEqual(catalog.freeUpCandidates(olderThan: FreeUpRule.cutoff(keepDays: 30)), ["old"])
        try catalog.markRemovedFromDevice(["old"])
        XCTAssertEqual(catalog.freeUpCandidates(olderThan: FreeUpRule.cutoff(keepDays: 30)), [])
    }

    func testJobsRoundTripWithPlan() throws {
        _ = try catalog.discover([LocalAssetInfo(localId: "L", createdAt: Date(), kind: .live, isFavorite: false)])
        var j = catalog.job("L")!
        j.state = .prepared
        j.plan = UploadPlan(assetId: "A", original: UploadTarget(url: URL(string: "https://x/o")!, method: "PUT", headers: ["a": "b"]),
                            paired: nil, primaryFile: "p.heic", pairedFile: nil, thumbFile: "t", previewFile: "v", preparedAt: Date(ms: 5))
        try catalog.save(j)
        XCTAssertEqual(catalog.job("L")?.plan, j.plan)
        XCTAssertEqual(catalog.dueJobs(.prepared, limit: 5).map(\.localId), ["L"])
        XCTAssertEqual(catalog.backupCounts()[.prepared], 1)
    }
}

final class CachePolicyTests: XCTestCase {
    func testPinsRecentAndFavoritesKeepsSomeViewed() {
        let base = Date(timeIntervalSince1970: 0)
        let viewed: [Int: Date] = [2: base.addingTimeInterval(500), 3: base.addingTimeInterval(400)]
        let items: [CachePolicy.Item] = (0..<10).map { (i: Int) -> CachePolicy.Item in
            CachePolicy.Item(id: "a\(i)", takenAt: base.addingTimeInterval(Double(i)), favorite: i == 1, lastViewed: viewed[i])
        }
        let plan = CachePolicy.previews(items, cached: ["a2", "a3", "a0", "a9"], recentCount: 3, viewedExtra: 1)
        XCTAssertEqual(plan.pinned, ["a9", "a8", "a7", "a1"])
        XCTAssertEqual(plan.fetch, ["a8", "a7", "a1"])
        XCTAssertEqual(plan.evict, ["a0", "a3"], "a2 is the most recently viewed extra; a3 and a0 go")
    }
}

final class MediaTests: XCTestCase {
    func testHashing() throws {
        let f = tempDir().appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: f)
        let d = try Hashing.digest(of: f)
        XCTAssertEqual(d.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(d.md5, "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(d.size, 3)
    }

    func testImageDerivativesRespectSizesAndOrientation() throws {
        let f = tempDir().appendingPathComponent("big.jpg")
        try makeJPEG(width: 3000, height: 2000, seed: 1, orientation: 6, gps: (30.28, -97.74)).write(to: f)
        let (thumb, preview) = try Derivatives.imageDerivatives(from: f)
        func size(_ d: Data) -> (Int, Int) {
            let s = CGImageSourceCreateWithData(d as CFData, nil)!
            let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as! [CFString: Any]
            return (p[kCGImagePropertyPixelWidth] as! Int, p[kCGImagePropertyPixelHeight] as! Int)
        }
        XCTAssertEqual(size(thumb).0, 240, "orientation 6 rotates: the long side becomes the height")
        XCTAssertEqual(size(thumb).1, 360)
        XCTAssertEqual(max(size(preview).0, size(preview).1), 2048)
        XCTAssertLessThan(thumb.count, 100_000)
        let info = Derivatives.imageInfo(f)
        XCTAssertEqual(info.width, 3000)
        XCTAssertEqual(info.lat!, 30.28, accuracy: 0.01)
        XCTAssertEqual(info.lon!, -97.74, accuracy: 0.01)
        XCTAssertNotNil(info.date)
    }

    func testVideoPoster() async throws {
        let f = tempDir().appendingPathComponent("clip.mov")
        try await makeMovie(at: f)
        let (thumb, preview) = try await Derivatives.videoDerivatives(from: f)
        XCTAssertGreaterThan(thumb.count, 100)
        XCTAssertGreaterThan(preview.count, 100)
    }

    func testMime() {
        XCTAssertEqual(MimeTypes.of(URL(fileURLWithPath: "/a/IMG_1.HEIC")), "image/heic")
        XCTAssertEqual(MimeTypes.of(URL(fileURLWithPath: "/a/clip.mov")), "video/quicktime")
        XCTAssertEqual(MimeTypes.ext(for: "image/jpeg"), "jpeg")
    }
}

/// Answers API requests from a closure, so the client can be tested without a server.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = StubProtocol.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class APIClientTests: XCTestCase {
    func testSendsTokenAndDecodesErrors() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        let api = APIClient(config: APIConfig(baseURL: URL(string: "https://api.test")!, token: "tok"), session: URLSession(configuration: cfg))
        StubProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            XCTAssertEqual(req.url?.query, "since=7&limit=500")
            return (200, Data(#"{"assets":[],"cursor":7,"hasMore":false}"#.utf8))
        }
        let page = try await api.changes(since: 7)
        XCTAssertEqual(page.cursor, 7)
        StubProtocol.handler = { _ in (409, Data(#"{"error":"asset is pending"}"#.utf8)) }
        do {
            _ = try await api.commit(assetId: "x")
            XCTFail("expected an error")
        } catch let e as APIError {
            XCTAssertEqual(e, .http(status: 409, message: "asset is pending"))
            XCTAssertFalse(e.isRetryable)
        }
    }
}
