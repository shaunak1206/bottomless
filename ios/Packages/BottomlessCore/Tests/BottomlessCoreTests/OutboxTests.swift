import XCTest
@testable import BottomlessCore

/// A server that refuses writes (Cloudflare's daily limit) until told otherwise, then accepts them.
final class FlakyServer: URLProtocol {
    nonisolated(unsafe) static var refuse = true
    nonisolated(unsafe) static var accepted: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let id = request.url!.lastPathComponent
        let status: Int, body: Data
        if Self.refuse {
            status = 429
            body = Data(#"{"error":"Cloudflare D1 daily free-tier cap reached; resumes at 00:00 UTC","cap":true}"#.utf8)
        } else {
            status = 200
            Self.accepted.append("\(request.httpMethod!) \(id)")
            let a = request.httpMethod == "DELETE" ? remote(id, status: .trashed, seq: 9) : remote(id, favorite: true, seq: 9)
            body = try! JSONEncoder().encode(["asset": a])
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class OutboxTests: XCTestCase {
    func testChangesShowAtOnceAndReachTheServerWhenItAcceptsThem() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FlakyServer.self]
        FlakyServer.refuse = true
        FlakyServer.accepted = []
        let api = APIClient(config: APIConfig(baseURL: URL(string: "https://bottomless.invalid")!, token: "t"), session: URLSession(configuration: cfg))
        let root = tempDir()
        let catalog = try Catalog(path: root.appendingPathComponent("c.sqlite").path)
        try catalog.apply([remote("A", takenAt: 2), remote("B", takenAt: 1)])
        let sync = SyncEngine(api: api, catalog: catalog, cache: try CacheStore(root: root.appendingPathComponent("cache")))

        try await sync.trash("A")
        try await sync.setFavorite("B", true)
        XCTAssertEqual(catalog.asset("A")?.status, .trashed, "deleted on the phone at once")
        XCTAssertEqual(catalog.readyAssets().map(\.id), ["B"], "gone from the library")
        XCTAssertEqual(catalog.asset("B")?.favorite, true)
        XCTAssertEqual(catalog.pendingChanges().count, 2, "kept while the server refuses")

        // A sync in between still has the server's old view; it must not bring the photo back or undo the heart.
        try catalog.apply([remote("A", takenAt: 2, seq: 5), remote("B", takenAt: 1, seq: 6)])
        try catalog.reapplyPending()
        XCTAssertEqual(catalog.asset("A")?.status, .trashed)
        XCTAssertEqual(catalog.asset("B")?.favorite, true)

        FlakyServer.refuse = false
        let sent = await sync.flushPending()
        XCTAssertEqual(sent, 2)
        XCTAssertEqual(FlakyServer.accepted, ["DELETE A", "PATCH B"], "sent in the order they were made")
        XCTAssertTrue(catalog.pendingChanges().isEmpty)

        try await sync.restore("A")
        XCTAssertEqual(catalog.asset("A")?.status, .ready, "restoring also shows at once")
    }
}
