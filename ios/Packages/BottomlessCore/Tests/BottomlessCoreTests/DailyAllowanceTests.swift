import XCTest
@testable import BottomlessCore

final class DailyAllowanceTests: XCTestCase {
    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_792_950_000) }   // 2026-10-25 17:40 UTC

    func make() throws -> (DailyAllowance, Clock, Catalog) {
        let catalog = try Catalog(path: tempDir().appendingPathComponent("c.sqlite").path)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let clock = Clock()
        return (DailyAllowance(catalog: catalog, calendar: utc, now: { clock.now }), clock, catalog)
    }

    func testUnderAHundredAllGoToday() throws {
        let (a, _, _) = try make()
        XCTAssertEqual(a.remaining(waiting: 30), .max)
        XCTAssertEqual(a.remaining(waiting: 99), .max)
        XCTAssertEqual(a.leftForTomorrow(waiting: 99), 0)
    }

    func testAHundredOrMoreSplitOverTwoDays() throws {
        let (a, clock, _) = try make()
        XCTAssertEqual(a.remaining(waiting: 150), 75)
        a.use(75)
        XCTAssertEqual(a.remaining(waiting: 75), 0)
        XCTAssertEqual(a.leftForTomorrow(waiting: 75), 75)
        clock.now += 86_400                     // the next day takes the rest, even 100 or more
        XCTAssertEqual(a.remaining(waiting: 75), .max)
        XCTAssertEqual(a.remaining(waiting: 120), .max)
        clock.now += 86_400                     // the day after that can split a new batch again
        XCTAssertEqual(a.remaining(waiting: 200), 100)
    }

    func testABigBatchLaterInTheDaySplitsWhatIsLeft() throws {
        let (a, _, _) = try make()
        XCTAssertEqual(a.remaining(waiting: 10), .max)
        a.use(10)
        XCTAssertEqual(a.remaining(waiting: 300), 150)      // 10 already started + half of the 300
        a.use(150)
        XCTAssertEqual(a.remaining(waiting: 150), 0)
    }

    func testEngineStartsNothingNewOnceTodaysShareIsUsed() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [DailyLimitServer.self]
        DailyLimitServer.requests = 0
        let api = APIClient(config: APIConfig(baseURL: URL(string: "https://bottomless.invalid")!, token: "t"),
                            session: URLSession(configuration: cfg))
        let root = tempDir()
        let (allowance, _, catalog) = try make()
        let cache = try CacheStore(root: root.appendingPathComponent("cache"))
        let library = FolderLibrary()
        for i in 0..<3 {
            let f = root.appendingPathComponent("p\(i).jpg")
            try makeJPEG(width: 200, height: 150, seed: i).write(to: f)
            library.add("L\(i)", file: f, kind: .photo, created: Date(timeIntervalSince1970: Double(1_000 + i)))
        }
        let engine = BackupEngine(api: api, catalog: catalog, cache: cache, library: library, uploader: DirectUploader(),
                                  stagingRoot: root.appendingPathComponent("staging"), allowance: allowance)
        try await engine.scan()
        _ = allowance.remaining(waiting: 150)   // a split day: 75 allowed
        allowance.use(75)                       // and all 75 already started
        let s = await engine.run()
        XCTAssertEqual(s.prepared + s.failed, 0)
        XCTAssertEqual(DailyLimitServer.requests, 0, "no new photo should have reached the server")
        XCTAssertEqual(catalog.backupCounts()[.new], 3)
    }
}
