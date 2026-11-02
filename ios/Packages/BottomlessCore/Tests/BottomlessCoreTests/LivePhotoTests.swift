import XCTest
@testable import BottomlessCore

final class LivePhotoTests: XCTestCase {
    func testLiveOffIsStoredAndOlderServersMeanOn() throws {
        let catalog = try Catalog(path: tempDir().appendingPathComponent("c.sqlite").path)
        var r = remote("L")
        r.kind = .live; r.hasPaired = true; r.liveOff = true
        try catalog.apply([r])
        XCTAssertEqual(catalog.asset("L")?.liveOff, true)
        r.liveOff = nil
        try catalog.apply([r])
        XCTAssertEqual(catalog.asset("L")?.liveOff, false, "a feed without the field means Live is on")
    }

    func testCatalogFromBeforeTheLiveSwitchIsUpgraded() throws {
        let path = tempDir().appendingPathComponent("old.sqlite").path
        let old = try SQLiteDB(path: path)
        try old.execute("""
            CREATE TABLE assets (id TEXT PRIMARY KEY, sha256 TEXT, kind TEXT NOT NULL, mime TEXT, size INTEGER, filename TEXT,
              width INTEGER, height INTEGER, duration REAL, taken_at INTEGER NOT NULL, lat REAL, lon REAL,
              favorite INTEGER NOT NULL DEFAULT 0, hidden INTEGER NOT NULL DEFAULT 0, has_paired INTEGER NOT NULL DEFAULT 0,
              status TEXT NOT NULL, trashed_at INTEGER, seq INTEGER NOT NULL DEFAULT 0, last_viewed INTEGER);
            INSERT INTO assets (id, kind, taken_at, status) VALUES ('A', 'live', 1, 'ready');
            """)
        let catalog = try Catalog(path: path)
        XCTAssertEqual(catalog.asset("A")?.liveOff, false)
    }

    func testSettingsSavedByAnOlderVersionKeepTheirValues() throws {
        let saved = #"{"keepOnPhoneDays":7,"offlinePreviewCount":100,"wifiOnly":false,"autoBackup":true,"originalsCacheMB":512,"iCloudPhotosOffConfirmed":true}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(saved.utf8))
        XCTAssertEqual(s.keepOnPhoneDays, 7)
        XCTAssertFalse(s.wifiOnly)
        XCTAssertTrue(s.iCloudPhotosOffConfirmed)
        XCTAssertTrue(s.playLivePhotos, "new settings start at their default")
    }
}
