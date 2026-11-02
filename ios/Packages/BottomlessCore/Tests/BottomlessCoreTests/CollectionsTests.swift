import XCTest
@testable import BottomlessCore

/// Records album calls and answers them like the Worker does.
final class AlbumServer: URLProtocol {
    nonisolated(unsafe) static var calls: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var line = "\(request.httpMethod!) \(request.url!.lastPathComponent)"
        if let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            stream.close()
            if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let add = ((o["add"] as? [String]) ?? []).sorted(), remove = ((o["remove"] as? [String]) ?? []).sorted()
                line += " \(o["title"] ?? "") +\(add) -\(remove)"
            }
        } else if let data = request.httpBody, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let add = ((o["add"] as? [String]) ?? []).sorted(), remove = ((o["remove"] as? [String]) ?? []).sorted()
            line += " \(o["title"] ?? "") +\(add) -\(remove)"
        }
        Self.calls.append(line)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class CollectionsTests: XCTestCase {
    func testCollectionsComeFromWhatIsStoredWithEachPhoto() throws {
        let catalog = try Catalog(path: tempDir().appendingPathComponent("c.sqlite").path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func make(_ id: String, _ edit: (inout RemoteAsset) -> Void) -> RemoteAsset { var a = remote(id, takenAt: 1_000); edit(&a); return a }
        try catalog.apply([
            make("fav") { $0.favorite = true },
            make("vid") { $0.kind = .video; $0.mime = "video/mp4" },
            make("live") { $0.kind = .live; $0.hasPaired = true },
            make("iphoneShot") { $0.mime = "image/png"; $0.width = 1179; $0.height = 2556; $0.filename = "IMG_5000.PNG" },
            make("androidShot") { $0.filename = "Screenshot_20210504-103212_Instagram.jpg" },
            make("squarePng") { $0.mime = "image/png"; $0.width = 800; $0.height = 800 },
            make("paris") { $0.lat = 48.85; $0.lon = 2.35 },
            make("new") { $0.createdAt = now.addingTimeInterval(-3600).ms },
            make("old") { $0.createdAt = now.addingTimeInterval(-90 * 86400).ms },
        ])
        func ids(_ c: Catalog.Collection) -> Set<String> { Set(catalog.assets(in: c, now: now).map(\.id)) }
        XCTAssertEqual(ids(.favorites), ["fav"])
        XCTAssertEqual(ids(.videos), ["vid"])
        XCTAssertEqual(ids(.livePhotos), ["live"])
        XCTAssertEqual(ids(.screenshots), ["iphoneShot", "androidShot"], "a square PNG is not a screenshot")
        XCTAssertEqual(ids(.places), ["paris"])
        XCTAssertEqual(ids(.recentlyAdded), ["new"])
        let s = catalog.collectionSummaries(now: now)
        XCTAssertEqual(s[.screenshots]?.count, 2)
        XCTAssertEqual(s[.places]?.coverId, "paris")
        XCTAssertEqual(catalog.locatedPoints().map(\.id), ["paris"])
    }

    func testPhoneAlbumsAreMirroredAndSurviveFreeingUpSpace() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [AlbumServer.self]
        AlbumServer.calls = []
        let api = APIClient(config: APIConfig(baseURL: URL(string: "https://bottomless.invalid")!, token: "t"), session: URLSession(configuration: cfg))
        let root = tempDir()
        let catalog = try Catalog(path: root.appendingPathComponent("c.sqlite").path)
        let sync = SyncEngine(api: api, catalog: catalog, cache: try CacheStore(root: root.appendingPathComponent("cache")))
        let d0 = Date(timeIntervalSince1970: 1000)
        _ = try catalog.discover([LocalAssetInfo(localId: "L1", createdAt: d0, kind: .photo, isFavorite: false),
                                  LocalAssetInfo(localId: "L2", createdAt: d0, kind: .photo, isFavorite: false)])
        func backedUp(_ local: String, _ asset: String) throws { var j = catalog.job(local)!; j.state = .committed; j.assetId = asset; try catalog.save(j) }
        try backedUp("L1", "A1")
        let albumId = SyncEngine.albumId(forLocal: "album-1")

        try await sync.pushAlbums([("album-1", "Trip", ["L1", "L2"])], phoneAlbumsComplete: true)
        XCTAssertEqual(AlbumServer.calls.last, "PUT \(albumId) Trip +[\"A1\"] -[]", "only backed-up photos go up")
        try await sync.pushAlbums([("album-1", "Trip", ["L1", "L2"])], phoneAlbumsComplete: true)
        XCTAssertEqual(AlbumServer.calls.count, 1, "nothing changed, nothing sent")

        try backedUp("L2", "A2")
        try await sync.pushAlbums([("album-1", "Trip", ["L1", "L2"])], phoneAlbumsComplete: true)
        XCTAssertEqual(AlbumServer.calls.last, "PUT \(albumId) Trip +[\"A2\"] -[]")

        // L2 freed up from the phone (no longer on the device, so not in the phone album): it stays in the cloud album.
        _ = try catalog.discover([LocalAssetInfo(localId: "L1", createdAt: d0, kind: .photo, isFavorite: false)])
        try await sync.pushAlbums([("album-1", "Trip", ["L1"])], phoneAlbumsComplete: true)
        XCTAssertEqual(AlbumServer.calls.count, 2, "a freed-up photo is not removed from its album")

        // L1 taken out of the album on the phone (still on the phone): removed in the cloud too, with a rename.
        try await sync.pushAlbums([("album-1", "Paris", [])], phoneAlbumsComplete: true)
        XCTAssertEqual(AlbumServer.calls.last, "PUT \(albumId) Paris +[] -[\"A1\"]")

        // The album deleted on the phone.
        try await sync.pushAlbums([], phoneAlbumsComplete: true)
        XCTAssertEqual(AlbumServer.calls.last, "DELETE \(albumId)")
    }
}
