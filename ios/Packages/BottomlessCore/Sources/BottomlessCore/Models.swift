import Foundation

public enum AssetKind: String, Codable, Sendable { case photo, video, live }
public enum AssetStatus: String, Codable, Sendable { case pending, ready, trashed, purged }

/// An asset as the Worker describes it (GET /v1/changes, /v1/assets/:id).
public struct RemoteAsset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sha256: String
    public var kind: AssetKind
    public var mime: String
    public var size: Int64
    public var filename: String?
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var takenAt: Int64            // unix ms
    public var lat: Double?
    public var lon: Double?
    public var favorite: Bool
    public var hidden: Bool
    /// Live turned off for this photo: show it as a still (the motion clip is kept).
    public var liveOff: Bool?
    public var hasPaired: Bool
    public var pairedMime: String?
    public var pairedSize: Int64?
    public var hasThumb: Bool
    public var hasPreview: Bool
    public var status: AssetStatus
    public var createdAt: Int64
    public var updatedAt: Int64
    public var trashedAt: Int64?
    public var seq: Int64
}

/// An asset as the UI sees it (from the local catalog).
public struct CatalogAsset: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: AssetKind
    public var mime: String
    public var size: Int64
    public var filename: String?
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var takenAt: Date
    public var lat: Double?
    public var lon: Double?
    public var favorite: Bool
    public var hidden: Bool
    public var hasPaired: Bool
    public var status: AssetStatus
    public var trashedAt: Date?
    public var liveOff: Bool = false
    /// PhotoKit local identifier when the photo is still in this iPhone's library.
    public var localId: String?
}

/// One cell in the library grid: either backed up (in the catalog) or still waiting on this phone.
public enum LibraryEntry: Identifiable, Hashable, Sendable {
    case remote(CatalogAsset)
    case local(localId: String, createdAt: Date, kind: AssetKind, state: BackupState)

    public var id: String {
        switch self {
        case .remote(let a): return a.id
        case .local(let localId, _, _, _): return "local:" + localId
        }
    }
    public var date: Date {
        switch self {
        case .remote(let a): return a.takenAt
        case .local(_, let d, _, _): return d
        }
    }
}

public struct UploadTarget: Codable, Equatable, Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
}

public struct PrepareRequest: Codable, Sendable {
    public struct Paired: Codable, Sendable { public var size: Int64; public var md5: String; public var mime: String }
    public var sha256: String
    public var md5: String
    public var size: Int64
    public var mime: String
    public var kind: AssetKind
    public var filename: String?
    public var takenAt: Int64
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var lat: Double?
    public var lon: Double?
    public var favorite: Bool
    public var paired: Paired?
}

public struct PrepareResponse: Codable, Sendable {
    public struct Uploads: Codable, Sendable { public var original: UploadTarget; public var paired: UploadTarget? }
    public var status: String            // "exists" | "upload"
    public var assetId: String
    public var asset: RemoteAsset?
    public var uploads: Uploads?
}

public struct ChangesPage: Codable, Sendable {
    public var assets: [RemoteAsset]
    public var cursor: Int64
    public var hasMore: Bool
}

public struct ServerStats: Codable, Sendable, Equatable {
    public var ready: Int
    public var trashed: Int
    public var pending: Int
    public var purged: Int
    public var bytes: Int64
    public var favorites: Int
    public var byKind: [String: Int]
    public var seq: Int64
}

/// An album as the server keeps it: its photos, newest first.
public struct RemoteAlbum: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var source: String
    public var updatedAt: Int64
    public var assetIds: [String]
    public init(id: String, title: String, source: String, updatedAt: Int64, assetIds: [String]) {
        self.id = id; self.title = title; self.source = source; self.updatedAt = updatedAt; self.assetIds = assetIds
    }
}

public struct AlbumsPage: Codable, Sendable { public var version: Int64; public var albums: [RemoteAlbum] }

/// Where a face is in a photo, as fractions of the photo's width and height (from the top left).
public struct FaceBox: Codable, Sendable, Equatable, Hashable {
    public var faceId: String
    public var assetId: String
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public init(faceId: String, assetId: String, x: Double, y: Double, w: Double, h: Double) {
        self.faceId = faceId; self.assetId = assetId; self.x = x; self.y = y; self.w = w; self.h = h
    }
}

/// Someone the Mac's face indexer (scripts/faces.py) found: the photos they are in, newest first, and the face to show.
public struct RemotePerson: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String?
    public var hidden: Bool
    public var cover: FaceBox?
    public var assetIds: [String]
    public init(id: String, name: String?, hidden: Bool, cover: FaceBox?, assetIds: [String]) {
        self.id = id; self.name = name; self.hidden = hidden; self.cover = cover; self.assetIds = assetIds
    }
}

/// `unchanged` is true (and `people` absent) when nothing moved since the version the phone sent.
public struct PeoplePage: Codable, Sendable { public var version: Int64; public var unchanged: Bool?; public var people: [RemotePerson]? }

public struct SharedLink: Codable, Sendable, Identifiable, Equatable {
    public var token: String
    public var url: URL
    public var title: String?
    public var count: Int?
    public var allowOriginal: Bool?
    public var createdAt: Int64?
    public var expiresAt: Int64
    public var id: String { token }
}

extension Date {
    public init(ms: Int64) { self.init(timeIntervalSince1970: TimeInterval(ms) / 1000) }
    public var ms: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}

extension Notification.Name {
    /// Posted when a backup run ends (the UI reloads its counts and grid).
    public static let bottomlessBackupChanged = Notification.Name("bottomlessBackupChanged")
}
