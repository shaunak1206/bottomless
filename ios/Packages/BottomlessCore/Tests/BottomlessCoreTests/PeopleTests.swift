import XCTest
@testable import BottomlessCore

final class PeopleTests: XCTestCase {
    func testPeopleListNamedFirstOnlyPhotosInTheLibraryAndSmallGroupsWait() throws {
        let catalog = try Catalog(path: tempDir().appendingPathComponent("p.sqlite").path)
        try catalog.apply([remote("a", takenAt: 3_000), remote("b", takenAt: 2_000), remote("c", takenAt: 1_000), remote("d"),
                           remote("gone", status: .trashed)])
        let face = FaceBox(faceId: "f1", assetId: "a", x: 0.1, y: 0.2, w: 0.3, h: 0.3)
        try catalog.replacePeople([
            RemotePerson(id: "big", name: nil, hidden: false, cover: face, assetIds: ["a", "b", "c", "d"]),
            RemotePerson(id: "manas", name: "Manas", hidden: false, cover: nil, assetIds: ["a", "b", "c", "gone"]),
            RemotePerson(id: "few", name: nil, hidden: false, cover: nil, assetIds: ["a", "b"]),
            RemotePerson(id: "hid", name: "Stranger", hidden: true, cover: nil, assetIds: ["a", "b", "c"]),
            RemotePerson(id: "named1", name: "Bhumika", hidden: false, cover: nil, assetIds: ["d"]),
        ], version: 7)
        XCTAssertEqual(catalog.peopleVersion, 7)
        let people = catalog.peopleSummaries()
        XCTAssertEqual(people.map(\.id), ["manas", "named1", "big"],
                       "named first (a named person shows with one photo); unnamed groups under 3 photos and hidden people are left out")
        XCTAssertEqual(people.map(\.count), [3, 1, 4], "trashed photos do not count")
        XCTAssertEqual(people[2].cover, face)
        XCTAssertEqual(catalog.peopleSummaries(includeHidden: true).map(\.id), ["manas", "hid", "named1", "big"])
        XCTAssertEqual(catalog.personAssets("big").map(\.id), ["a", "b", "c", "d"], "newest first")
        XCTAssertEqual(Set(catalog.people(inAsset: "a").map(\.id)), ["big", "manas", "few"])

        try catalog.replacePeople([RemotePerson(id: "big", name: "Mom", hidden: false, cover: nil, assetIds: ["a", "b", "c"])], version: 8)
        XCTAssertEqual(catalog.peopleSummaries().map(\.name), ["Mom"], "a new list replaces the old one")
    }

    func testPeopleAreOnlyDownloadedWhenTheyChanged() async throws {
        PeopleServer.calls = []
        let catalog = try Catalog(path: tempDir().appendingPathComponent("p2.sqlite").path)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PeopleServer.self]
        let api = APIClient(config: APIConfig(baseURL: URL(string: "https://example.test")!, token: "t"), session: URLSession(configuration: config))
        let sync = SyncEngine(api: api, catalog: catalog, cache: try CacheStore(root: tempDir()))
        try await sync.pullPeople()
        XCTAssertEqual(catalog.peopleVersion, 5)
        try await sync.pullPeople()
        XCTAssertEqual(PeopleServer.calls, ["v1/people", "v1/people?since=5"])
        XCTAssertEqual(try catalog.db.query("SELECT COUNT(*) AS n FROM people").first?.int("n"), 1, "an unchanged answer keeps the list")
    }
}

/// Answers /v1/people like the Worker: the full list first, then "unchanged" once the phone sends that version back.
final class PeopleServer: URLProtocol {
    nonisolated(unsafe) static var calls: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.calls.append(String(url.path.dropFirst()) + (url.query.map { "?" + $0 } ?? ""))
        let body = url.query == "since=5"
            ? #"{"version":5,"unchanged":true}"#
            : #"{"version":5,"people":[{"id":"p1","name":null,"hidden":false,"cover":null,"assetIds":["x"]}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
