import Foundation

public struct APIConfig: Sendable, Equatable {
    public var baseURL: URL
    public var token: String
    public init(baseURL: URL, token: String) { self.baseURL = baseURL; self.token = token }
}

public enum APIError: Error, Equatable, CustomStringConvertible {
    case http(status: Int, message: String)
    case badResponse
    case notConfigured

    public var description: String {
        switch self {
        case .http(let s, let m): return "HTTP \(s): \(m)"
        case .badResponse: return "unexpected response from server"
        case .notConfigured: return "server address or token is missing"
        }
    }
    public var isRetryable: Bool {
        if case .http(let s, _) = self { return s >= 500 || s == 408 || s == 429 }
        return true
    }

    /// The server refused because a spending guardrail or Cloudflare's free daily database limit was reached. That is
    /// not a problem with the photo being sent, and retrying before the limit resets only wastes battery.
    public var isCapReached: Bool {
        guard case .http(429, let m) = self else { return false }
        let l = m.lowercased()
        return l.contains("cap") || l.contains("limit")
    }

    /// When a cap from `isCapReached` lifts: just after midnight UTC for the daily database limit, the 1st of next month
    /// for monthly caps, otherwise in 6 hours.
    public func capLifts(after now: Date) -> Date {
        guard case .http(_, let m) = self else { return now.addingTimeInterval(3600) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        if m.contains("00:00 UTC") {
            return utc.startOfDay(for: now).addingTimeInterval(86400 + 300)
        }
        if m.lowercased().contains("monthly"), let next = utc.date(byAdding: .month, value: 1, to: now),
           let first = utc.date(from: utc.dateComponents([.year, .month], from: next)) {
            return first.addingTimeInterval(300)
        }
        return now.addingTimeInterval(6 * 3600)
    }
}

/// Talks to the Bottomless Worker. Every call carries the bearer token.
public final class APIClient: @unchecked Sendable {
    public let config: APIConfig
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(config: APIConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [],
                         body: Data? = nil, contentType: String? = "application/json") -> URLRequest {
        var comps = URLComponents(url: config.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body; if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") } }
        req.timeoutInterval = 60
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                ?? String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(status: http.statusCode, message: msg)
        }
        return data
    }

    private func json<T: Decodable>(_ req: URLRequest, as: T.Type = T.self) async throws -> T {
        try decoder.decode(T.self, from: try await send(req))
    }

    private struct AssetEnvelope: Decodable { var asset: RemoteAsset }

    public func health() async throws -> Bool {
        struct H: Decodable { var ok: Bool }
        return try await json(request("v1/health"), as: H.self).ok
    }

    public func prepare(_ body: PrepareRequest) async throws -> PrepareResponse {
        try await json(request("v1/assets/prepare", method: "POST", body: try encoder.encode(body)))
    }

    public enum Derived: String { case thumb, preview }

    public func uploadDerived(assetId: String, _ which: Derived, data: Data, contentType: String = "image/jpeg") async throws {
        _ = try await send(request("v1/assets/\(assetId)/\(which.rawValue)", method: "PUT", body: data, contentType: contentType))
    }

    public func commit(assetId: String) async throws -> RemoteAsset {
        struct C: Decodable { var asset: RemoteAsset }
        return try await json(request("v1/assets/\(assetId)/commit", method: "POST"), as: C.self).asset
    }

    public func changes(since: Int64, limit: Int = 500) async throws -> ChangesPage {
        try await json(request("v1/changes", query: [.init(name: "since", value: String(since)), .init(name: "limit", value: String(limit))]))
    }

    public func asset(_ id: String) async throws -> RemoteAsset {
        try await json(request("v1/assets/\(id)"), as: AssetEnvelope.self).asset
    }

    public func setFavorite(_ id: String, _ favorite: Bool) async throws -> RemoteAsset {
        let body = try JSONSerialization.data(withJSONObject: ["favorite": favorite])
        return try await json(request("v1/assets/\(id)", method: "PATCH", body: body), as: AssetEnvelope.self).asset
    }

    public func setHidden(_ id: String, _ hidden: Bool) async throws -> RemoteAsset {
        let body = try JSONSerialization.data(withJSONObject: ["hidden": hidden])
        return try await json(request("v1/assets/\(id)", method: "PATCH", body: body), as: AssetEnvelope.self).asset
    }

    /// Turns Live off (show as a still) or back on for one Live Photo.
    public func setLiveOff(_ id: String, _ off: Bool) async throws -> RemoteAsset {
        let body = try JSONSerialization.data(withJSONObject: ["liveOff": off])
        return try await json(request("v1/assets/\(id)", method: "PATCH", body: body), as: AssetEnvelope.self).asset
    }

    /// Corrects capture time / location / favorite (used by the Google Photos importer when metadata arrives late).
    public func updateMetadata(_ id: String, takenAt: Date? = nil, lat: Double? = nil, lon: Double? = nil, favorite: Bool? = nil) async throws -> RemoteAsset {
        var obj: [String: Any] = [:]
        if let takenAt { obj["takenAt"] = takenAt.ms }
        if let lat, let lon { obj["lat"] = lat; obj["lon"] = lon }
        if let favorite { obj["favorite"] = favorite }
        let body = try JSONSerialization.data(withJSONObject: obj)
        return try await json(request("v1/assets/\(id)", method: "PATCH", body: body), as: AssetEnvelope.self).asset
    }

    /// Joins a photo with its separately uploaded motion clip into one Live Photo (the clip's own asset goes away).
    /// When the photo already has that exact clip, the separate copy is removed and `duplicate` is true.
    public func mergeLive(photoId: String, videoId: String) async throws -> (asset: RemoteAsset, duplicate: Bool) {
        struct R: Decodable { var asset: RemoteAsset; var duplicate: Bool? }
        let body = try JSONSerialization.data(withJSONObject: ["videoId": videoId])
        let r = try await json(request("v1/assets/\(photoId)/live", method: "POST", body: body), as: R.self)
        return (r.asset, r.duplicate ?? false)
    }

    public func albums() async throws -> AlbumsPage {
        try await json(request("v1/albums"))
    }

    /// Creates or renames an album and adds/removes photos.
    public func putAlbum(id: String, title: String, add: [String], remove: [String]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["title": title, "source": "iphone", "add": add, "remove": remove])
        _ = try await send(request("v1/albums/\(id)", method: "PUT", body: body))
    }

    public func deleteAlbum(id: String) async throws {
        _ = try await send(request("v1/albums/\(id)", method: "DELETE"))
    }

    public func trash(_ id: String) async throws -> RemoteAsset {
        try await json(request("v1/assets/\(id)", method: "DELETE"), as: AssetEnvelope.self).asset
    }

    public func restore(_ id: String) async throws -> RemoteAsset {
        try await json(request("v1/assets/\(id)/restore", method: "POST"), as: AssetEnvelope.self).asset
    }

    /// A short-lived URL for the full-resolution file (or the video half of a Live Photo).
    public func originalURL(_ id: String, paired: Bool = false, download: Bool = false) async throws -> URL {
        struct O: Decodable { var url: URL }
        var q: [URLQueryItem] = []
        if paired { q.append(.init(name: "paired", value: "1")) }
        if download { q.append(.init(name: "download", value: "1")) }
        return try await json(request("v1/assets/\(id)/original", query: q), as: O.self).url
    }

    public func derived(_ id: String, _ which: Derived) async throws -> Data {
        try await send(request("v1/assets/\(id)/\(which.rawValue)"))
    }

    public func stats() async throws -> ServerStats {
        try await json(request("v1/stats"))
    }

    public func createShare(assetIds: [String], title: String?, days: Int, allowOriginal: Bool) async throws -> SharedLink {
        var obj: [String: Any] = ["assetIds": assetIds, "days": days, "allowOriginal": allowOriginal]
        if let title, !title.isEmpty { obj["title"] = title }
        return try await json(request("v1/shares", method: "POST", body: try JSONSerialization.data(withJSONObject: obj)))
    }

    public func shares() async throws -> [SharedLink] {
        struct S: Decodable { var shares: [SharedLink] }
        return try await json(request("v1/shares"), as: S.self).shares
    }

    public func deleteShare(_ token: String) async throws {
        _ = try await send(request("v1/shares/\(token)", method: "DELETE"))
    }
}
