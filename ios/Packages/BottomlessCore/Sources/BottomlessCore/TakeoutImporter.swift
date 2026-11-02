import Foundation
import AVFoundation
import CoreGraphics

/// Imports an extracted Google Takeout (Google Photos) folder into Bottomless, keeping capture time, location and
/// favorites from the JSON sidecars. Safe to re-run: progress lives in a small SQLite file and the server dedupes by
/// hash. Takeout splits an export into several zips and a photo's sidecar can land in a different zip than the photo,
/// so sidecars are remembered across runs and late ones are applied with a metadata PATCH.
public final class TakeoutImporter: @unchecked Sendable {
    public struct Stats: Sendable, Equatable {
        public var uploaded = 0, existing = 0, failed = 0, alreadyDone = 0, patched = 0, placeholders = 0, merged = 0
        public var duplicateClips = 0
        public var bytes: Int64 = 0
        public init() {}
    }

    /// Thrown when the Worker refuses because a monthly cap was reached; the import stops instead of retrying.
    public struct CapReached: Error, CustomStringConvertible { public let message: String; public var description: String { message } }

    public let api: APIClient
    public var concurrency: Int
    private let db: SQLiteDB
    private let session: URLSession
    private let log: @Sendable (String) -> Void
    private let gate = HashGate()
    /// Same-named videos at or under this size are treated as the motion half of a Live Photo.
    public static let liveClipMaxBytes: Int64 = 12 << 20

    public init(api: APIClient, statePath: String, concurrency: Int = 6, session: URLSession = .shared,
                log: @escaping @Sendable (String) -> Void = { _ in }) throws {
        self.api = api
        self.concurrency = concurrency
        self.session = session
        self.log = log
        db = try SQLiteDB(path: statePath)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS sidecars (key TEXT PRIMARY KEY, folder TEXT NOT NULL, json TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS sidecars_folder ON sidecars(folder);
            CREATE TABLE IF NOT EXISTS items (key TEXT PRIMARY KEY, folder TEXT NOT NULL, name TEXT NOT NULL, asset_id TEXT,
                status TEXT NOT NULL, has_sidecar INTEGER NOT NULL DEFAULT 0, error TEXT, updated_at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS live_merges (photo_id TEXT NOT NULL, video_id TEXT NOT NULL, result TEXT NOT NULL,
                PRIMARY KEY (photo_id, video_id));
            """)
        if !(try db.query("PRAGMA table_info(live_merges)").contains { $0.string("name") == "video_sha" }) {
            try db.execute("ALTER TABLE live_merges ADD COLUMN video_sha TEXT")
        }
        // A clip that became part of a Live Photo is done: no metadata fixes for it, and never uploaded again.
        try db.execute("""
            UPDATE items SET status = 'merged', has_sidecar = 1
            WHERE asset_id IN (SELECT video_id FROM live_merges WHERE result IN ('merged', 'duplicate', 'gone')) AND status != 'merged'
            """)
    }

    // MARK: sidecars

    /// Remembers every sidecar under `root`. Returns how many were found.
    @discardableResult
    public func indexSidecars(in root: URL) throws -> Int {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return 0 }
        var rows: [(String, String, String)] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url), let sc = TakeoutSidecar.parse(data),
                  let json = try? JSONEncoder().encode(sc) else { continue }
            let folder = Takeout.relativeFolder(of: url, root: root)
            rows.append((Takeout.sidecarKey(folder: folder, jsonName: url.lastPathComponent, sidecar: sc), folder.lowercased(),
                         String(decoding: json, as: UTF8.self)))
        }
        try db.transaction {
            for r in rows { try db.execute("INSERT OR REPLACE INTO sidecars (key, folder, json) VALUES (?, ?, ?)", [.text(r.0), .text(r.1), .text(r.2)]) }
        }
        return rows.count
    }

    private func storedSidecar(_ key: String) -> TakeoutSidecar? {
        guard let s = (try? db.query("SELECT json FROM sidecars WHERE key = ?", [.text(key)]))?.first?.string("json") else { return nil }
        return try? JSONDecoder().decode(TakeoutSidecar.self, from: Data(s.utf8))
    }

    /// The sidecar describing a media file: exact name, then the original of an "-edited" copy, then a truncated name,
    /// then a name whose punctuation Takeout replaced, then (for the motion clip of a Live or Motion Photo, which has
    /// no sidecar of its own) the sidecar of the photo with the same name.
    public func sidecar(folder: String, name: String) -> TakeoutSidecar? {
        let candidates = Takeout.candidateKeys(folder: folder, mediaName: name)
        for k in candidates { if let s = storedSidecar(k) { return s } }
        let keys = (try? db.query("SELECT key FROM sidecars WHERE folder = ?", [.text(folder.lowercased())]))?.compactMap { $0.string("key") } ?? []
        if let k = Takeout.prefixMatch(folder: folder, mediaName: name, keysInFolder: keys) { return storedSidecar(k) }
        let wanted = Set(candidates.map(Takeout.sanitized))
        if let k = keys.first(where: { wanted.contains(Takeout.sanitized($0)) }) { return storedSidecar(k) }
        if Takeout.videoExtensions.contains((name as NSString).pathExtension.lowercased()) {
            let stem = Takeout.key(folder: folder, name: (name as NSString).deletingPathExtension) + "."
            // Only when the name is unambiguous: two different photos can share a name (two phones, a counter reset).
            let photoKeys = keys.filter { $0.hasPrefix(stem) && Takeout.imageExtensions.contains(($0 as NSString).pathExtension) }
            if photoKeys.count == 1 { return storedSidecar(photoKeys[0]) }
        }
        return nil
    }

    // MARK: import

    /// Imports every photo and video under `root` (an extracted Takeout folder).
    public func importFolder(_ root: URL) async throws -> Stats {
        let n = try indexSidecars(in: root)
        let all = Takeout.items(in: root) { url in
            ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? .max) <= Self.liveClipMaxBytes
        }
        let done = Set(((try? db.query("SELECT key FROM items WHERE status IN ('uploaded','existing','merged')")) ?? []).compactMap { $0.string("key") })
        let todo = all.filter { !done.contains(Takeout.key(folder: $0.folder, name: $0.name)) }
        log("found \(all.count) items and \(n) sidecars in \(root.lastPathComponent); \(all.count - todo.count) already imported")
        var stats = Stats()
        stats.alreadyDone = all.count - todo.count
        var capError: CapReached?
        try await withThrowingTaskGroup(of: (Outcome, Int64).self) { group in
            var next = 0
            func addNext() {
                guard next < todo.count else { return }
                let item = todo[next]; next += 1
                group.addTask { try await self.importOne(item) }
            }
            for _ in 0..<min(concurrency, todo.count) { addNext() }
            var finished = 0
            while true {
                let result: (Outcome, Int64)?
                do { result = try await group.next() } catch let e as CapReached { capError = e; group.cancelAll(); break }
                guard let (outcome, bytes) = result else { break }
                switch outcome {
                case .uploaded(let placeholder): stats.uploaded += 1; stats.bytes += bytes; if placeholder { stats.placeholders += 1 }
                case .existing: stats.existing += 1
                case .failed: stats.failed += 1
                }
                finished += 1
                if finished % 50 == 0 || finished == todo.count {
                    log("  \(finished)/\(todo.count)  uploaded \(stats.uploaded)  already there \(stats.existing)  failed \(stats.failed)  \(Self.gb(stats.bytes))")
                }
                addNext()
            }
        }
        if let capError { throw capError }
        stats.patched = await patchLateMetadata()
        (stats.merged, stats.duplicateClips) = try await mergeSplitLivePhotos()
        return stats
    }

    enum Outcome { case uploaded(placeholder: Bool), existing, failed }

    private func record(_ item: Takeout.Item, assetId: String?, status: String, hasSidecar: Bool, error: String? = nil) {
        try? db.execute("""
            INSERT OR REPLACE INTO items (key, folder, name, asset_id, status, has_sidecar, error, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(Takeout.key(folder: item.folder, name: item.name)), .text(item.folder), .text(item.name), SQLValue(assetId),
                  .text(status), SQLValue(hasSidecar), SQLValue(error), .int(Date().ms)])
    }

    private func importOne(_ item: Takeout.Item) async throws -> (Outcome, Int64) {
        let sc = sidecar(folder: item.folder, name: item.name)
        do {
            let d = try Hashing.digest(of: item.primary)
            // Another copy (an album folder) of a clip that is already inside a Live Photo.
            if let row = try? db.query("SELECT video_id FROM live_merges WHERE video_sha = ? AND result IN ('merged', 'duplicate')", [.text(d.sha256)]).first {
                record(item, assetId: row.string("video_id"), status: "merged", hasSidecar: true)
                return (.existing, 0)
            }
            // Identical files (an album copy of a photo) wait for each other, so the second one finds it already there.
            await gate.enter(d.sha256)
            let result: Result<(Outcome, Int64), Error>
            do { result = .success(try await upload(item, sidecar: sc, digest: d)) } catch { result = .failure(error) }
            await gate.leave(d.sha256)
            return try result.get()
        } catch let e as CapReached {
            throw e
        } catch {
            log("  failed \(item.folder)/\(item.name): \(error)")
            record(item, assetId: nil, status: "failed", hasSidecar: sc != nil, error: "\(error)")
            return (.failed, 0)
        }
    }

    private func upload(_ item: Takeout.Item, sidecar sc: TakeoutSidecar?, digest d: FileDigest) async throws -> (Outcome, Int64) {
        let meta = await Self.metadata(item, sidecar: sc)
        let pd = try item.paired.map { try Hashing.digest(of: $0) }
        let isVideo = Takeout.videoExtensions.contains(item.primary.pathExtension.lowercased())
        let kind: AssetKind = item.paired != nil ? .live : (isVideo ? .video : .photo)
        let req = PrepareRequest(
            sha256: d.sha256, md5: d.md5, size: d.size, mime: MimeTypes.of(item.primary), kind: kind, filename: item.name,
            takenAt: meta.takenAt.ms, width: meta.width, height: meta.height, duration: meta.duration, lat: meta.lat, lon: meta.lon,
            favorite: sc?.favorite ?? false,
            paired: pd.map { PrepareRequest.Paired(size: $0.size, md5: $0.md5, mime: MimeTypes.of(item.paired!)) })
        let prep = try await retrying { try await self.api.prepare(req) }
        if prep.status == "exists" {
            record(item, assetId: prep.assetId, status: "existing", hasSidecar: sc != nil)
            return (.existing, 0)
        }
        guard let uploads = prep.uploads else { throw APIError.badResponse }
        try await retrying { try await self.put(item.primary, uploads.original) }
        if let paired = item.paired, let target = uploads.paired { try await retrying { try await self.put(paired, target) } }
        var placeholder = false
        let derived: (thumb: Data, preview: Data)
        do {
            derived = isVideo ? try await Derivatives.videoDerivatives(from: item.primary) : try Derivatives.imageDerivatives(from: item.primary)
        } catch {
            // Formats Apple cannot decode (old AVI/WMV, odd RAWs) still get their original backed up, with a plain tile.
            derived = try Self.placeholder()
            placeholder = true
        }
        try await retrying { try await self.api.uploadDerived(assetId: prep.assetId, .thumb, data: derived.thumb) }
        try await retrying { try await self.api.uploadDerived(assetId: prep.assetId, .preview, data: derived.preview) }
        _ = try await retrying { try await self.api.commit(assetId: prep.assetId) }
        record(item, assetId: prep.assetId, status: "uploaded", hasSidecar: sc != nil)
        return (.uploaded(placeholder: placeholder), d.size + (pd?.size ?? 0))
    }

    /// Applies sidecars that arrived after their photo was uploaded (they were in a later Takeout zip).
    public func patchLateMetadata() async -> Int {
        let rows = (try? db.query("SELECT key, folder, name, asset_id FROM items WHERE has_sidecar = 0 AND asset_id IS NOT NULL")) ?? []
        var patched = 0
        for r in rows {
            guard let key = r.string("key"), let folder = r.string("folder"), let name = r.string("name"), let id = r.string("asset_id"),
                  let sc = sidecar(folder: folder, name: name) else { continue }
            do {
                _ = try await retrying {
                    try await self.api.updateMetadata(id, takenAt: sc.takenAt, lat: sc.lat, lon: sc.lon, favorite: sc.favorite ? true : nil)
                }
                try? db.execute("UPDATE items SET has_sidecar = 1, updated_at = ? WHERE key = ?", [.int(Date().ms), .text(key)])
                patched += 1
            } catch APIError.http(404, _) {
                // The clip was joined into a Live Photo meanwhile (it no longer exists on its own): nothing to fix.
                try? db.execute("UPDATE items SET has_sidecar = 1, updated_at = ? WHERE key = ?", [.int(Date().ms), .text(key)])
            } catch { log("  could not fix metadata of \(folder)/\(name): \(error)") }
        }
        if patched > 0 { log("applied late metadata to \(patched) items") }
        return patched
    }

    /// Live and Motion Photos whose photo and clip landed in different zips were uploaded as a photo plus a short video.
    /// Once both halves are in, this joins them into one Live Photo on the server. A clip whose photo is already a Live
    /// Photo with that same clip (the same picture exported from a second Google account) is removed as a duplicate.
    public func mergeSplitLivePhotos() async throws -> (merged: Int, duplicates: Int) {
        let rows = (try? db.query("SELECT folder, name, asset_id FROM items WHERE asset_id IS NOT NULL AND status != 'merged'")) ?? []
        var photos: [String: Set<String>] = [:], clips: [String: Set<String>] = [:]
        for r in rows {
            guard let folder = r.string("folder"), let name = r.string("name"), let id = r.string("asset_id") else { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            let group = Takeout.key(folder: folder, name: (name as NSString).deletingPathExtension)
            if Takeout.imageExtensions.contains(ext) { photos[group, default: []].insert(id) }
            else if Takeout.videoExtensions.contains(ext) { clips[group, default: []].insert(id) }
        }
        // Clips already joined, removed, or found to be a real video are not asked about again.
        let settled = Set(((try? db.query("SELECT video_id FROM live_merges WHERE result != 'skipped'")) ?? []).compactMap { $0.string("video_id") })
        var candidates: [(photoIds: [String], videoId: String)] = []
        for (group, videoIds) in clips {
            guard videoIds.count == 1, let p = photos[group], !p.isEmpty, !settled.contains(videoIds.first!) else { continue }
            candidates.append((p.sorted(), videoIds.first!))
        }
        var merged = 0, duplicates = 0
        for (photoIds, videoId) in candidates {
            var photoId = photoIds[0]
            var result = "skipped"
            var clipSha: String?
            do {
                let clip = try await retrying { try await self.api.asset(videoId) }
                clipSha = clip.sha256
                var photo = try await retrying { try await self.api.asset(photoId) }
                if photoIds.count > 1 {
                    // Two different photos share this name: the clip belongs to the one taken at the same moment.
                    var near: [RemoteAsset] = []
                    for id in photoIds {
                        let a = try await retrying { try await self.api.asset(id) }
                        if abs(a.takenAt - clip.takenAt) <= 3000 { near.append(a) }
                    }
                    guard near.count == 1 else { throw SkipPair() }
                    photo = near[0]; photoId = photo.id
                }
                let isClip = clip.kind == .video && clip.size <= Self.liveClipMaxBytes && (clip.duration ?? 0) <= 6.5
                if isClip && photo.kind == .photo && !photo.hasPaired {
                    _ = try await retrying { try await self.api.mergeLive(photoId: photoId, videoId: videoId) }
                    result = "merged"; merged += 1
                } else if isClip && photo.hasPaired && photo.pairedSize == clip.size {
                    let r = try await retrying { try await self.api.mergeLive(photoId: photoId, videoId: videoId) }
                    if r.duplicate { result = "duplicate"; duplicates += 1 }
                }
            } catch let e as CapReached {
                throw e
            } catch is SkipPair {
                result = "skipped"
            } catch APIError.http(404, _) {
                result = "gone"     // one half was already joined or removed (e.g. while importing another account)
            } catch APIError.http(409, let msg) {
                log("  left \(photoId) + \(videoId) as they are: \(msg)")
            } catch {
                log("  could not merge Live Photo \(photoId) + \(videoId): \(error)")
                continue
            }
            if result != "skipped" {
                try? db.execute("UPDATE items SET status = 'merged', has_sidecar = 1 WHERE asset_id = ?", [.text(videoId)])
            }
            try? db.execute("INSERT OR REPLACE INTO live_merges (photo_id, video_id, result, video_sha) VALUES (?, ?, ?, ?)",
                            [.text(photoId), .text(videoId), .text(result), .text(clipSha ?? "")])
        }
        if merged > 0 { log("joined \(merged) Live Photos whose photo and clip were in different zips") }
        if duplicates > 0 { log("removed \(duplicates) duplicate motion clips (their Live Photo already has the same clip)") }
        return (merged, duplicates)
    }

    public func counts() -> [String: Int] {
        var out: [String: Int] = [:]
        for r in (try? db.query("SELECT status, COUNT(*) AS n FROM items GROUP BY status")) ?? [] {
            if let s = r.string("status") { out[s] = Int(r.int("n") ?? 0) }
        }
        out["missing_metadata"] = Int((try? db.query("SELECT COUNT(*) AS n FROM items WHERE has_sidecar = 0"))?.first?.int("n") ?? 0)
        return out
    }

    // MARK: helpers

    struct Meta { var takenAt: Date; var lat: Double?; var lon: Double?; var width: Int?; var height: Int?; var duration: Double? }

    /// Capture time precedence: sidecar photoTakenTime > EXIF > video creation date > sidecar upload time > now.
    /// Location: sidecar geoData > geoDataExif (both in the sidecar) > EXIF GPS.
    static func metadata(_ item: Takeout.Item, sidecar: TakeoutSidecar?) async -> Meta {
        var m = Meta(takenAt: Date(), lat: sidecar?.lat, lon: sidecar?.lon)
        var fileDate: Date?
        if Takeout.videoExtensions.contains(item.primary.pathExtension.lowercased()) {
            let asset = AVURLAsset(url: item.primary)
            if let d = try? await asset.load(.duration), d.seconds.isFinite { m.duration = d.seconds }
            if let item = try? await asset.load(.creationDate), let d = try? await item.load(.dateValue) { fileDate = d }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) {
                let r = CGRect(origin: .zero, size: size).applying(t)
                m.width = Int(abs(r.width)); m.height = Int(abs(r.height))
            }
        } else {
            let info = Derivatives.imageInfo(item.primary)
            m.width = info.width; m.height = info.height; fileDate = info.date
            if m.lat == nil, let la = info.lat, let lo = info.lon { m.lat = la; m.lon = lo }
        }
        m.takenAt = sidecar?.takenAt ?? fileDate ?? sidecar?.createdAt ?? Date()
        return m
    }

    private func put(_ file: URL, _ target: UploadTarget) async throws {
        var req = URLRequest(url: target.url)
        req.httpMethod = target.method
        req.timeoutInterval = 900
        for (k, v) in target.headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.upload(for: req, fromFile: file)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError.http(status: status, message: String(decoding: data.prefix(300), as: UTF8.self)) }
    }

    private func retrying<T>(_ body: () async throws -> T) async throws -> T {
        var delay: UInt64 = 1_000_000_000
        for attempt in 1... {
            do { return try await body() } catch {
                if case APIError.http(429, let msg) = error, msg.lowercased().contains("cap") { throw CapReached(message: msg) }
                let retryable = (error as? APIError)?.isRetryable ?? true
                if !retryable || attempt >= 4 || Task.isCancelled { throw error }
                try await Task.sleep(nanoseconds: delay)
                delay *= 3
            }
        }
        fatalError("unreachable")
    }

    static func placeholder() throws -> (thumb: Data, preview: Data) {
        func tile(_ px: Int) throws -> Data {
            guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw MediaError.encodeFailed }
            ctx.setFillColor(red: 0.22, green: 0.22, blue: 0.24, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
            guard let img = ctx.makeImage() else { throw MediaError.encodeFailed }
            return try Derivatives.jpeg(from: img, quality: 0.7)
        }
        return (try tile(Derivatives.thumbPixels), try tile(512))
    }

    static func gb(_ bytes: Int64) -> String { String(format: "%.2f GB", Double(bytes) / 1_000_000_000) }
}

private struct SkipPair: Error {}

/// One upload per file content at a time.
private actor HashGate {
    private var running: [String: [CheckedContinuation<Void, Never>]] = [:]
    func enter(_ sha: String) async {
        while running[sha] != nil { await withCheckedContinuation { running[sha, default: []].append($0) } }
        running[sha] = []
    }
    func leave(_ sha: String) {
        for c in running.removeValue(forKey: sha) ?? [] { c.resume() }
    }
}
