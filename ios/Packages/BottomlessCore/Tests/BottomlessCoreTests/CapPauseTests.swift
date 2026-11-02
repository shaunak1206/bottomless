import XCTest
@testable import BottomlessCore

/// A server that answers everything with Cloudflare's daily-limit refusal, counting the requests it gets.
final class DailyLimitServer: URLProtocol {
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let body = #"{"error":"Cloudflare D1 daily free-tier cap reached; resumes at 00:00 UTC (D1_ERROR: limit exceeded)","cap":true}"#
        let resp = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class CapPauseTests: XCTestCase {
    func testDailyLimitPausesTheBackupWithoutUsingUpAttempts() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [DailyLimitServer.self]
        DailyLimitServer.requests = 0
        let api = APIClient(config: APIConfig(baseURL: URL(string: "https://bottomless.invalid")!, token: "t"), session: URLSession(configuration: cfg))
        let root = tempDir()
        let catalog = try Catalog(path: root.appendingPathComponent("c.sqlite").path)
        let cache = try CacheStore(root: root.appendingPathComponent("cache"))
        let library = FolderLibrary()
        for i in 0..<3 {
            let f = root.appendingPathComponent("p\(i).jpg")
            try makeJPEG(width: 200, height: 150, seed: i).write(to: f)
            library.add("L\(i)", file: f, kind: .photo, created: Date(timeIntervalSince1970: Double(1_000 + i)))
        }
        let clock = Date(timeIntervalSince1970: 1_792_950_000)      // 2026-10-25 17:40 UTC
        let engine = BackupEngine(api: api, catalog: catalog, cache: cache, library: library, uploader: DirectUploader(),
                                  stagingRoot: root.appendingPathComponent("staging"), now: { clock })
        try await engine.scan()

        let s = await engine.run()
        XCTAssertEqual(s.prepared, 0)
        XCTAssertEqual(DailyLimitServer.requests, 1, "stops at the first refusal instead of exporting and trying every photo")
        XCTAssertEqual(engine.pausedUntil, ISO8601DateFormatter().date(from: "2026-10-26T00:05:00Z"), "resumes just after the UTC reset")
        XCTAssertNotNil(catalog.job("L2")?.lastError, "the newest photo goes first")
        for id in ["L0", "L1", "L2"] {
            XCTAssertEqual(catalog.job(id)?.attempts, 0, "no photo uses up an attempt on a cap")
            XCTAssertEqual(catalog.job(id)?.state, .new)
        }
        _ = await engine.run()
        XCTAssertEqual(DailyLimitServer.requests, 1, "while paused the engine does not call the server")
    }

    func testWhenCapsLift() {
        let now = ISO8601DateFormatter().date(from: "2026-10-25T17:40:00Z")!
        let monthly = APIError.http(status: 429, message: "monthly upload limit reached (40000 new items); resumes next month or raise CAP_NEW_ASSETS_MONTH")
        XCTAssertTrue(monthly.isCapReached)
        XCTAssertEqual(monthly.capLifts(after: now), ISO8601DateFormatter().date(from: "2026-11-01T00:05:00Z"))
        XCTAssertFalse(APIError.http(status: 429, message: "Too Many Requests").isCapReached, "plain rate limiting is retried as usual")
        XCTAssertFalse(APIError.http(status: 500, message: "limit").isCapReached)
    }
}
