import XCTest
@testable import BottomlessCore

/// Writes a fake Google Takeout export the way Google lays it out, split over two zips' worth of folders.
struct FakeTakeout {
    let part1: URL, part2: URL
    static let photos = "Takeout/Google Photos/Photos from 2019"
    static let album = "Takeout/Google Photos/Trip to Austin"
    static let longTitle = "PXL_20190801_123456789_this_is_a_long_name_truncated_by_google.jpg"
    static let longFile = String(longTitle.prefix(47)) + ".jpg"
    static func ts(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    static func sidecar(_ title: String, taken: String, geo: (Double, Double)? = nil, favorite: Bool = false) -> Data {
        var o: [String: Any] = [
            "title": title, "description": "",
            "creationTime": ["timestamp": String(Int(ts("2021-01-01T00:00:00Z").timeIntervalSince1970)), "formatted": "Jan 1, 2021"],
            "photoTakenTime": ["timestamp": String(Int(ts(taken).timeIntervalSince1970)), "formatted": "whatever"],
            "geoData": ["latitude": geo?.0 ?? 0.0, "longitude": geo?.1 ?? 0.0, "altitude": 0.0],
        ]
        if favorite { o["favorited"] = true }
        return try! JSONSerialization.data(withJSONObject: o)
    }

    static func make() async throws -> FakeTakeout {
        let root = tempDir("takeout-\(UUID().uuidString.prefix(6))")
        let p1 = root.appendingPathComponent("part1"), p2 = root.appendingPathComponent("part2")
        let y1 = p1.appendingPathComponent(photos), al = p1.appendingPathComponent(album), y2 = p2.appendingPathComponent(photos)
        for d in [y1, al, y2] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        func jpg(_ dir: URL, _ name: String, seed: Int) throws -> Data {
            let d = makeJPEG(width: 640, height: 480, seed: seed); try d.write(to: dir.appendingPathComponent(name)); return d
        }
        func json(_ dir: URL, _ name: String, _ data: Data) throws { try data.write(to: dir.appendingPathComponent(name)) }

        // a favourite with a location, also in an album (same bytes)
        let one = try jpg(y1, "IMG_0001.jpg", seed: 1)
        try json(y1, "IMG_0001.jpg.supplemental-metadata.json", sidecar("IMG_0001.jpg", taken: "2019-06-01T15:00:00Z", geo: (30.2672, -97.7431), favorite: true))
        try one.write(to: al.appendingPathComponent("IMG_0001.jpg"))
        try json(al, "IMG_0001.jpg.json", sidecar("IMG_0001.jpg", taken: "2019-06-01T15:00:00Z", geo: (30.2672, -97.7431), favorite: true))
        try json(al, "metadata.json", try JSONSerialization.data(withJSONObject: ["title": "Trip to Austin", "description": "", "access": "protected",
                                                                                  "date": ["timestamp": "1560000000"]]))
        // sidecar only arrives in part 2
        _ = try jpg(y1, "IMG_0002.jpg", seed: 2)
        try json(y2, "IMG_0002.jpg.supplemental-metadata.json", sidecar("IMG_0002.jpg", taken: "2019-07-04T02:30:00Z"))
        // live photo
        _ = try jpg(y1, "IMG_0003.jpg", seed: 3)
        try await makeMovie(at: y1.appendingPathComponent("IMG_0003.MOV"), seconds: 1.5, size: 160)
        try json(y1, "IMG_0003.jpg.json", sidecar("IMG_0003.jpg", taken: "2019-08-01T10:00:00Z"))
        // plain video
        try await makeMovie(at: y1.appendingPathComponent("VID_0004.mp4"), seconds: 2, size: 200)
        try json(y1, "VID_0004.mp4.supplemental-metadata.json", sidecar("VID_0004.mp4", taken: "2019-09-09T09:09:09Z"))
        // duplicate numbering: "IMG_0005(1).jpg" is described by "IMG_0005.jpg(1).json"
        _ = try jpg(y1, "IMG_0005.jpg", seed: 5)
        try json(y1, "IMG_0005.jpg.json", sidecar("IMG_0005.jpg", taken: "2019-10-01T00:00:00Z"))
        _ = try jpg(y1, "IMG_0005(1).jpg", seed: 55)
        try json(y1, "IMG_0005.jpg(1).json", sidecar("IMG_0005.jpg", taken: "2019-10-02T00:00:00Z"))
        // edited copy uses the original's sidecar
        _ = try jpg(y1, "IMG_0006.jpg", seed: 6)
        _ = try jpg(y1, "IMG_0006-edited.jpg", seed: 66)
        try json(y1, "IMG_0006.jpg.json", sidecar("IMG_0006.jpg", taken: "2019-11-11T11:11:00Z"))
        // truncated long name
        _ = try jpg(y1, longFile, seed: 7)
        try json(y1, String(longTitle.prefix(46)) + ".json", sidecar(longTitle, taken: "2019-08-01T12:34:56Z"))
        // something Apple cannot decode still gets backed up
        try Data("not really a video".utf8).write(to: y1.appendingPathComponent("old_clip.avi"))
        try json(y1, "old_clip.avi.json", sidecar("old_clip.avi", taken: "2009-05-05T05:05:05Z"))
        // Takeout writes "McDonald's" as "McDonald_s" in the file name but not in the sidecar title
        _ = try jpg(y1, "Screenshot_McDonald_s.jpg", seed: 9)
        try json(y1, "Screenshot_McDonald_s.jpg.json", sidecar("Screenshot_McDonald's.jpg", taken: "2021-05-04T15:32:29Z"))
        // a Motion Photo split across zips: the clip in part 1, the photo and its sidecar in part 2
        try await makeMovie(at: y1.appendingPathComponent("PXL_0009.MP4"), seconds: 1, size: 120)
        _ = try jpg(y2, "PXL_0009.jpg", seed: 10)
        try json(y2, "PXL_0009.jpg.supplemental-metadata.json", sidecar("PXL_0009.jpg", taken: "2019-05-05T05:00:00Z", geo: (48.8584, 2.2945)))
        // two different photos with the same name (two phones), and in part 2 the clip of the second one
        _ = try jpg(y1, "IMG_7000.jpg", seed: 11)
        try json(y1, "IMG_7000.jpg.json", sidecar("IMG_7000.jpg", taken: "2019-01-01T10:00:00Z"))
        _ = try jpg(y1, "IMG_7000.jpeg", seed: 12)
        try json(y1, "IMG_7000.jpeg.json", sidecar("IMG_7000.jpeg", taken: "2019-03-03T12:00:00Z"))
        try await makeMovie(at: y2.appendingPathComponent("IMG_7000.MP4"), seconds: 1, size: 120, date: ts("2019-03-03T12:00:00Z"))
        // part 2 also has a new photo
        _ = try jpg(y2, "IMG_0008.jpg", seed: 8)
        try json(y2, "IMG_0008.jpg.supplemental-metadata.json", sidecar("IMG_0008.jpg", taken: "2019-12-25T08:00:00Z"))
        return FakeTakeout(part1: p1, part2: p2)
    }
}

final class TakeoutParsingTests: XCTestCase {
    func testSidecarParsing() throws {
        let s = try XCTUnwrap(TakeoutSidecar.parse(FakeTakeout.sidecar("A.jpg", taken: "2019-06-01T15:00:00Z", geo: (1.5, 2.5), favorite: true)))
        XCTAssertEqual(s.title, "A.jpg")
        XCTAssertEqual(s.takenAt, FakeTakeout.ts("2019-06-01T15:00:00Z"))
        XCTAssertEqual(s.lat, 1.5); XCTAssertEqual(s.lon, 2.5)
        XCTAssertTrue(s.favorite)
        let noGeo = try XCTUnwrap(TakeoutSidecar.parse(FakeTakeout.sidecar("B.jpg", taken: "2019-06-01T15:00:00Z")))
        XCTAssertNil(noGeo.lat, "0,0 means no location")
        XCTAssertNil(TakeoutSidecar.parse(Data(#"{"title":"Album","date":{"timestamp":"1"}}"#.utf8)), "album metadata is not a photo")
        XCTAssertNil(TakeoutSidecar.parse(Data("[1,2]".utf8)))
    }

    func testKeysForDuplicatesEditsAndTruncation() throws {
        let sc = try XCTUnwrap(TakeoutSidecar.parse(FakeTakeout.sidecar("IMG_5.jpg", taken: "2019-01-01T00:00:00Z")))
        XCTAssertEqual(Takeout.sidecarKey(folder: "F", jsonName: "IMG_5.jpg.json", sidecar: sc), "f/img_5.jpg")
        XCTAssertEqual(Takeout.sidecarKey(folder: "F", jsonName: "IMG_5.jpg(2).json", sidecar: sc), "f/img_5(2).jpg")
        XCTAssertEqual(Takeout.sidecarKey(folder: "F", jsonName: "IMG_5.jpg.supplemental-metadata(1).json", sidecar: sc), "f/img_5(1).jpg")
        XCTAssertEqual(Takeout.candidateKeys(folder: "F", mediaName: "IMG_5-edited.jpg"), ["f/img_5-edited.jpg", "f/img_5.jpg"])
        let keys = ["f/" + FakeTakeout.longTitle.lowercased(), "f/other.jpg"]
        XCTAssertEqual(Takeout.prefixMatch(folder: "F", mediaName: FakeTakeout.longFile, keysInFolder: keys), keys[0])
        XCTAssertNil(Takeout.prefixMatch(folder: "F", mediaName: "short.jpg", keysInFolder: keys))
    }

    func testItemsPairLivePhotosAndPutYearFoldersFirst() async throws {
        let t = try await FakeTakeout.make()
        let items = Takeout.items(in: t.part1) { _ in true }
        XCTAssertEqual(items.count, 15)
        XCTAssertTrue(items.first!.folder.hasSuffix("Photos from 2019"))
        let live = try XCTUnwrap(items.first { $0.name == "IMG_0003.jpg" })
        XCTAssertEqual(live.paired?.lastPathComponent, "IMG_0003.MOV")
        XCTAssertFalse(items.contains { $0.name == "IMG_0003.MOV" }, "the motion half is not a separate item")
        XCTAssertEqual(items.first { $0.name == "VID_0004.mp4" }?.paired, nil)
    }
}

/// Imports the fake export into a running Worker (scripts/test_core.sh), like the real Google Photos import.
final class TakeoutIntegrationTests: XCTestCase {
    func testImportKeepsDatesPlacesFavoritesAndFixesLateSidecars() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["BOTTOMLESS_TEST_API"], let token = env["BOTTOMLESS_TEST_TOKEN"] else {
            throw XCTSkip("set BOTTOMLESS_TEST_API and BOTTOMLESS_TEST_TOKEN (scripts/test_core.sh does this)")
        }
        let api = APIClient(config: APIConfig(baseURL: URL(string: base)!, token: token))
        let t = try await FakeTakeout.make()
        let state = tempDir().appendingPathComponent("state.sqlite").path
        let importer = try TakeoutImporter(api: api, statePath: state)

        let s1 = try await importer.importFolder(t.part1)
        XCTAssertEqual(s1.uploaded, 14, "15 items, the album copy is already there")
        XCTAssertEqual(s1.existing, 1)
        XCTAssertEqual(s1.failed, 0)
        XCTAssertEqual(s1.placeholders, 1, "the undecodable clip got a plain tile")

        let s2 = try await importer.importFolder(t.part2)
        XCTAssertEqual(s2.uploaded, 3)
        XCTAssertEqual(s2.patched, 2, "IMG_0002 and the PXL_0009 clip got their dates once the sidecars showed up")
        XCTAssertEqual(s2.merged, 2, "both split Motion Photos were joined back together")

        // An album copy of the clip that is now inside the Live Photo must not come back as a separate video.
        let part3 = t.part1.deletingLastPathComponent().appendingPathComponent("part3/Takeout/Google Photos/Paris trip")
        try FileManager.default.createDirectory(at: part3, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: t.part1.appendingPathComponent(FakeTakeout.photos + "/PXL_0009.MP4"),
                                         to: part3.appendingPathComponent("PXL_0009.MP4"))
        let s3 = try await importer.importFolder(t.part1.deletingLastPathComponent().appendingPathComponent("part3"))
        XCTAssertEqual(s3.uploaded, 0, "the clip is already part of a Live Photo")
        XCTAssertEqual(s3.existing, 1)

        let again = try await importer.importFolder(t.part1)
        XCTAssertEqual(again.uploaded + again.existing + again.failed, 0, "a re-run does nothing")
        XCTAssertEqual(again.alreadyDone, 15)

        var byName: [String: RemoteAsset] = [:]
        var cursor: Int64 = 0
        while true {
            let page = try await api.changes(since: cursor)
            for a in page.assets { if let f = a.filename { byName[f] = a } }
            cursor = page.cursor
            if !page.hasMore { break }
        }
        func taken(_ name: String) -> Date? { byName[name].map { Date(ms: $0.takenAt) } }
        let one = try XCTUnwrap(byName["IMG_0001.jpg"])
        XCTAssertEqual(taken("IMG_0001.jpg"), FakeTakeout.ts("2019-06-01T15:00:00Z"))
        XCTAssertEqual(one.lat ?? 0, 30.2672, accuracy: 1e-6)
        XCTAssertEqual(one.lon ?? 0, -97.7431, accuracy: 1e-6)
        XCTAssertTrue(one.favorite)
        XCTAssertEqual(taken("IMG_0002.jpg"), FakeTakeout.ts("2019-07-04T02:30:00Z"))
        XCTAssertEqual(byName["IMG_0003.jpg"]?.kind, .live)
        XCTAssertEqual(byName["IMG_0003.jpg"]?.hasPaired, true)
        XCTAssertEqual(byName["VID_0004.mp4"]?.kind, .video)
        XCTAssertEqual(byName["VID_0004.mp4"]?.duration ?? 0, 2, accuracy: 0.2)
        XCTAssertEqual(taken("IMG_0005.jpg"), FakeTakeout.ts("2019-10-01T00:00:00Z"))
        XCTAssertEqual(taken("IMG_0005(1).jpg"), FakeTakeout.ts("2019-10-02T00:00:00Z"))
        XCTAssertEqual(taken("IMG_0006-edited.jpg"), FakeTakeout.ts("2019-11-11T11:11:00Z"))
        XCTAssertEqual(taken(FakeTakeout.longFile), FakeTakeout.ts("2019-08-01T12:34:56Z"))
        XCTAssertEqual(taken("old_clip.avi"), FakeTakeout.ts("2009-05-05T05:05:05Z"))
        XCTAssertEqual(taken("IMG_0008.jpg"), FakeTakeout.ts("2019-12-25T08:00:00Z"))
        XCTAssertEqual(taken("Screenshot_McDonald_s.jpg"), FakeTakeout.ts("2021-05-04T15:32:29Z"))
        XCTAssertEqual(taken("PXL_0009.MP4"), FakeTakeout.ts("2019-05-05T05:00:00Z"), "the clip takes its photo's date")
        XCTAssertEqual(byName["PXL_0009.MP4"]?.lat ?? 0, 48.8584, accuracy: 1e-6)
        XCTAssertEqual(byName["PXL_0009.jpg"]?.kind, .live)
        XCTAssertEqual(byName["PXL_0009.jpg"]?.hasPaired, true)
        XCTAssertEqual(byName["PXL_0009.MP4"]?.status, .purged, "the separate clip is gone from the library")
        XCTAssertEqual(byName["VID_0004.mp4"]?.status, .ready, "a real video with no matching photo stays a video")
        XCTAssertEqual(byName["IMG_7000.jpeg"]?.kind, .live, "the clip joins the same-named photo taken at the same moment")
        XCTAssertEqual(byName["IMG_7000.jpg"]?.kind, .photo, "not the other photo that happens to share its name")
        XCTAssertEqual(importer.counts()["missing_metadata"], 0)

        // A second Google account with the same Motion Photo, split the same way: its copy of the clip arrives first as
        // its own video, then the photo turns out to be the Live Photo that already has that clip, so the copy goes.
        let other = t.part1.deletingLastPathComponent().appendingPathComponent("account2")
        let a = other.appendingPathComponent("a/" + FakeTakeout.photos), b = other.appendingPathComponent("b/" + FakeTakeout.photos)
        for d in [a, b] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try FileManager.default.copyItem(at: t.part1.appendingPathComponent(FakeTakeout.photos + "/PXL_0009.MP4"), to: a.appendingPathComponent("PXL_0009.MP4"))
        try FileManager.default.copyItem(at: t.part2.appendingPathComponent(FakeTakeout.photos + "/PXL_0009.jpg"), to: b.appendingPathComponent("PXL_0009.jpg"))
        let second = try TakeoutImporter(api: api, statePath: tempDir().appendingPathComponent("account2.sqlite").path)
        let sa = try await second.importFolder(other.appendingPathComponent("a"))
        XCTAssertEqual(sa.uploaded, 1, "on its own the clip looks like a new video")
        let sb = try await second.importFolder(other.appendingPathComponent("b"))
        XCTAssertEqual(sb.existing, 1)
        XCTAssertEqual(sb.duplicateClips, 1, "the second copy of the clip is removed")
        let live = try await api.asset(byName["PXL_0009.jpg"]!.id)
        XCTAssertEqual(live.kind, .live, "the Live Photo is untouched")
    }
}
