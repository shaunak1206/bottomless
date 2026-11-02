import Foundation
import Photos
import UniformTypeIdentifiers
import BottomlessCore

/// The iPhone's photo library, seen through PhotoKit.
final class PhotoKitLibrary: LocalLibrary, @unchecked Sendable {
    enum ExportError: Error, CustomStringConvertible {
        case notFound, noResource
        var description: String { self == .notFound ? "photo is no longer in the library" : "photo has no exportable file" }
    }

    static var isAuthorized: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    static func requestAccess() async -> Bool {
        let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return s == .authorized || s == .limited
    }

    private static func kind(_ a: PHAsset) -> AssetKind {
        if a.mediaType == .video { return .video }
        return a.mediaSubtypes.contains(.photoLive) ? .live : .photo
    }

    func allAssets() async throws -> [LocalAssetInfo] {
        let opts = PHFetchOptions()
        opts.includeAssetSourceTypes = [.typeUserLibrary]
        let result = PHAsset.fetchAssets(with: opts)
        var out: [LocalAssetInfo] = []
        out.reserveCapacity(result.count)
        result.enumerateObjects { a, _, _ in
            guard a.mediaType == .image || a.mediaType == .video else { return }
            out.append(LocalAssetInfo(localId: a.localIdentifier, createdAt: a.creationDate ?? Date(timeIntervalSince1970: 0),
                                      kind: Self.kind(a), isFavorite: a.isFavorite))
        }
        return out
    }

    private func write(_ resource: PHAssetResource, to url: URL) async throws {
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true          // "Optimize iPhone Storage" keeps originals in iCloud
        try? FileManager.default.removeItem(at: url)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: opts) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    /// The albums you made in Photos, with the photos in each.
    static func userAlbums() -> [(localId: String, title: String, photos: [String])] {
        var out: [(String, String, [String])] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).enumerateObjects { c, _, _ in
            var ids: [String] = []
            PHAsset.fetchAssets(in: c, options: nil).enumerateObjects { a, _, _ in ids.append(a.localIdentifier) }
            out.append((c.localIdentifier, c.localizedTitle ?? "Album", ids))
        }
        return out
    }

    /// Writes the motion clip of a Live Photo that is on this iPhone to `url` (no network needed). False when it has none.
    func pairedVideo(_ localId: String, to url: URL) async -> Bool {
        guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil).firstObject else { return false }
        let resources = PHAssetResource.assetResources(for: a)
        guard let r = resources.first(where: { $0.type == .fullSizePairedVideo }) ?? resources.first(where: { $0.type == .pairedVideo }) else { return false }
        do { try await write(r, to: url); return true } catch { return false }
    }

    private static func ext(for resource: PHAssetResource) -> String {
        UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension
            ?? (resource.originalFilename as NSString).pathExtension.lowercased()
    }

    func export(_ localId: String, into dir: URL) async throws -> ExportedAsset {
        guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil).firstObject else { throw ExportError.notFound }
        let resources = PHAssetResource.assetResources(for: a)
        var kind = Self.kind(a)
        // The current version (with edits) is what the user sees, so that is what gets backed up.
        let primary: PHAssetResource?
        if kind == .video {
            primary = resources.first { $0.type == .fullSizeVideo } ?? resources.first { $0.type == .video }
        } else {
            primary = resources.first { $0.type == .fullSizePhoto } ?? resources.first { $0.type == .photo }
        }
        guard let primary else { throw ExportError.noResource }
        let originalName = resources.first { $0.type == .photo || $0.type == .video }?.originalFilename ?? primary.originalFilename
        let base = (originalName as NSString).deletingPathExtension
        let filename = "\(base).\(Self.ext(for: primary))"
        let file = dir.appendingPathComponent(filename)
        try await write(primary, to: file)

        var pairedURL: URL?
        var pairedMime: String?
        if kind == .live {
            if let p = resources.first(where: { $0.type == .fullSizePairedVideo }) ?? resources.first(where: { $0.type == .pairedVideo }) {
                let u = dir.appendingPathComponent("\(base)-motion.\(Self.ext(for: p))")
                try await write(p, to: u)
                pairedURL = u
                pairedMime = UTType(p.uniformTypeIdentifier)?.preferredMIMEType ?? "video/quicktime"
            } else {
                kind = .photo
            }
        }
        let mime = UTType(primary.uniformTypeIdentifier)?.preferredMIMEType ?? MimeTypes.of(file)
        return ExportedAsset(primary: file, primaryMime: mime, filename: filename, paired: pairedURL, pairedMime: pairedMime,
                             kind: kind, takenAt: a.creationDate ?? Date(), width: a.pixelWidth, height: a.pixelHeight,
                             duration: a.mediaType == .video ? a.duration : nil,
                             lat: a.location?.coordinate.latitude, lon: a.location?.coordinate.longitude, favorite: a.isFavorite)
    }

    /// Removes backed-up photos from the phone. iOS always shows its own confirmation, and keeps them in
    /// Recently Deleted for 30 days.
    func delete(_ localIds: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIds, options: nil)
        guard assets.count > 0 else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    /// Puts a downloaded original back into the Photos library.
    func saveToPhotos(file: URL, isVideo: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: isVideo ? .video : .photo, fileURL: file, options: nil)
        }
    }
}
