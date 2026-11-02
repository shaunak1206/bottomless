import Foundation
import CryptoKit

/// One item exported from the phone's library, ready to be hashed and uploaded.
public struct ExportedAsset: Sendable {
    public var primary: URL
    public var primaryMime: String
    public var filename: String?
    public var paired: URL?
    public var pairedMime: String?
    public var kind: AssetKind
    public var takenAt: Date
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var lat: Double?
    public var lon: Double?
    public var favorite: Bool
    public init(primary: URL, primaryMime: String, filename: String?, paired: URL? = nil, pairedMime: String? = nil, kind: AssetKind,
                takenAt: Date, width: Int? = nil, height: Int? = nil, duration: Double? = nil, lat: Double? = nil, lon: Double? = nil,
                favorite: Bool = false) {
        self.primary = primary; self.primaryMime = primaryMime; self.filename = filename; self.paired = paired
        self.pairedMime = pairedMime; self.kind = kind; self.takenAt = takenAt; self.width = width; self.height = height
        self.duration = duration; self.lat = lat; self.lon = lon; self.favorite = favorite
    }
}

/// The phone's photo library (PhotoKit in the app, a folder of files in tests).
public protocol LocalLibrary: Sendable {
    func allAssets() async throws -> [LocalAssetInfo]
    func export(_ localId: String, into dir: URL) async throws -> ExportedAsset
}

/// Moves original files to cloud storage. The app uses a background URLSession so uploads continue while suspended.
public protocol OriginalUploader: AnyObject, Sendable {
    func start(file: URL, target: UploadTarget, tag: String) throws
    func activeTags() async -> Set<String>
    var onFinished: (@Sendable (_ tag: String, _ status: Int, _ error: String?) -> Void)? { get set }
}

/// Plan stored per job: the request (to refresh expired URLs) plus where the staged files are.
public struct StagedUpload: Codable, Sendable {
    public var request: PrepareRequest
    public var plan: UploadPlan
}

/// Backs up the phone's library: export → hash → thumbnail/preview → prepare → upload original → commit.
/// Every step is persisted in the catalog, so it resumes after the app is suspended or killed.
public actor BackupEngine {
    public let api: APIClient
    public let catalog: Catalog
    public let cache: CacheStore
    public let library: LocalLibrary
    public let uploader: OriginalUploader
    public let stagingRoot: URL
    public var maxStaged = 24               // prepared + uploading at once (bounds the disk used for staging)
    public var maxAttempts = 8
    /// The two-day split for big batches (nil: no daily limit). Every run asks it, including the ones
    /// started by finished uploads, so the limit holds however the backup was woken.
    public let allowance: DailyAllowance?
    private let now: @Sendable () -> Date
    private var running = false
    private var rerunRequested = false
    private var resumeTask: Task<Void, Never>?

    public init(api: APIClient, catalog: Catalog, cache: CacheStore, library: LocalLibrary, uploader: OriginalUploader,
                stagingRoot: URL, allowance: DailyAllowance? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api; self.catalog = catalog; self.cache = cache; self.library = library; self.uploader = uploader
        self.stagingRoot = stagingRoot; self.allowance = allowance; self.now = now
        try? FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    }

    /// Wire upload completions into the engine (call once at launch, before the background session reconnects).
    public nonisolated func attachUploader() {
        uploader.onFinished = { [weak self] tag, status, error in
            guard let self else { return }
            Task { await self.uploadFinished(tag: tag, status: status, error: error) }
        }
    }

    // MARK: scan

    /// Finds new photos on the phone and pushes favorite changes made in the Photos app.
    @discardableResult
    public func scan() async throws -> Catalog.DiscoverResult {
        let local = try await library.allAssets()
        let r = try catalog.discover(local, now: now())
        for change in r.favoriteChanges {
            if let updated = try? await api.setFavorite(change.assetId, change.favorite) { _ = try? catalog.apply([updated]) }
        }
        return r
    }

    // MARK: run

    public struct Summary: Sendable, Equatable {
        public var prepared = 0, deduped = 0, uploadsStarted = 0, committed = 0, failed = 0
    }

    /// Set when the cloud refuses new work until a limit resets (a spending cap, or Cloudflare's free daily database
    /// limit during a big first backup). Until then nothing is retried and no photo uses up its attempts.
    public nonisolated var pausedUntil: Date? {
        guard let v = catalog.value("backup.pausedUntil"), let ms = Int64(v) else { return nil }
        return Date(ms: ms)
    }

    private func isPaused() -> Bool { pausedUntil.map { now() < $0 } ?? false }

    private func pause(for error: APIError) {
        let until = error.capLifts(after: now())
        try? catalog.setValue(String(until.ms), for: "backup.pausedUntil")
        // If the app is still open when the limit lifts, carry on without waiting to be opened again.
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            let wait = until.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await self?.kick()
        }
    }

    /// Advances every job as far as it can go right now. Returns when nothing more can be done (or the deadline passes).
    @discardableResult
    public func run(deadline: Date? = nil, maxNew: Int = .max) async -> Summary {
        var s = Summary()
        // A run already in progress picks the new work up before it returns.
        guard !running else { rerunRequested = true; return s }
        if isPaused() { return s }
        running = true
        defer { running = false; NotificationCenter.default.post(name: .bottomlessBackupChanged, object: nil) }
        func timeLeft() -> Bool { !Task.isCancelled && !isPaused() && (deadline.map { now() < $0 } ?? true) }

        await recoverLostUploads()
        var newBudget = min(maxNew, allowance?.remaining(waiting: catalog.backupCounts()[.new] ?? 0) ?? .max)
        rerunRequested = false
        while timeLeft() {
            var progressed = false
            for j in catalog.dueJobs(.uploaded, limit: 50, now: now()) where timeLeft() {
                if await commit(j) { s.committed += 1 } else { s.failed += 1 }
                progressed = true
            }
            for j in catalog.dueJobs(.prepared, limit: 50, now: now()) where timeLeft() {
                if await startUpload(j) { s.uploadsStarted += 1 } else { s.failed += 1 }
                progressed = true
            }
            let staged = (catalog.backupCounts()[.prepared] ?? 0) + (catalog.backupCounts()[.uploading] ?? 0)
            let room = min(maxStaged - staged, newBudget)
            if room > 0 {
                for j in catalog.dueJobs(.new, limit: room, now: now()) where timeLeft() {
                    switch await prepare(j) {
                    case .prepared: s.prepared += 1; allowance?.use()
                    case .deduped: s.deduped += 1; s.committed += 1
                    case .failed: s.failed += 1
                    }
                    newBudget -= 1
                    progressed = true
                }
            }
            if !progressed {
                guard rerunRequested else { break }
                rerunRequested = false        // an upload finished meanwhile: go round again
            }
        }
        return s
    }

    /// Continues the pipeline after an upload completes (commit, then start more uploads).
    private func kick() {
        if running { rerunRequested = true; return }
        Task { await self.run() }
    }

    // MARK: steps

    private func stagingDir(_ localId: String) -> URL {
        let h = SHA256.hash(data: Data(localId.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return stagingRoot.appendingPathComponent(h, isDirectory: true)
    }

    private func fail(_ j: BackupJob, back to: BackupState, _ error: Error) {
        var j = j
        if let e = error as? APIError, e.isCapReached {
            // Not this photo's fault: keep it queued as it was, without using up an attempt, and stop for now.
            pause(for: e)
            j.state = to
            j.lastError = String(describing: error)
            j.nextTryAt = pausedUntil ?? now()
            try? catalog.save(j, now: now())
            return
        }
        j.attempts += 1
        j.lastError = String(describing: error)
        if j.attempts >= maxAttempts {
            j.state = .failed
        } else {
            j.state = to
            let delay = min(6 * 3600.0, 60 * pow(2, Double(j.attempts - 1)))
            j.nextTryAt = now().addingTimeInterval(delay)
        }
        try? catalog.save(j, now: now())
    }

    private enum PrepareOutcome { case prepared, deduped, failed }

    private func prepare(_ job: BackupJob) async -> PrepareOutcome {
        let dir = stagingDir(job.localId)
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let ex = try await library.export(job.localId, into: dir)
            let digest = try Hashing.digest(of: ex.primary)
            let pairedDigest = try ex.paired.map { try Hashing.digest(of: $0) }
            let derived = ex.kind == .video ? try await Derivatives.videoDerivatives(from: ex.primary)
                                            : try Derivatives.imageDerivatives(from: ex.primary)
            try derived.thumb.write(to: dir.appendingPathComponent("thumb.jpg"))
            try derived.preview.write(to: dir.appendingPathComponent("preview.jpg"))

            let req = PrepareRequest(
                sha256: digest.sha256, md5: digest.md5, size: digest.size, mime: ex.primaryMime, kind: ex.kind,
                filename: ex.filename, takenAt: ex.takenAt.ms, width: ex.width, height: ex.height, duration: ex.duration,
                lat: ex.lat, lon: ex.lon, favorite: ex.favorite || job.isFavorite,
                paired: pairedDigest.map { PrepareRequest.Paired(size: $0.size, md5: $0.md5, mime: ex.pairedMime ?? "video/quicktime") })
            let resp = try await api.prepare(req)

            var j = job
            j.sha256 = digest.sha256
            j.assetId = resp.assetId
            if resp.status == "exists" {
                // Already in the cloud (same bytes): keep our thumbnails for offline browsing and finish.
                if !cache.has(.thumb, resp.assetId) { try? cache.adopt(file: dir.appendingPathComponent("thumb.jpg"), .thumb, resp.assetId) }
                if let a = resp.asset { _ = try? catalog.apply([a]) }
                if (ex.favorite || job.isFavorite), let a = resp.asset, !a.favorite,
                   let updated = try? await api.setFavorite(a.id, true) { _ = try? catalog.apply([updated]) }
                try? fm.removeItem(at: dir)
                j.state = .committed; j.plan = nil; j.attempts = 0; j.lastError = nil
                try catalog.save(j, now: now())
                return .deduped
            }
            guard let uploads = resp.uploads else { throw APIError.badResponse }
            let plan = UploadPlan(assetId: resp.assetId, original: uploads.original, paired: uploads.paired,
                                  primaryFile: ex.primary.lastPathComponent, pairedFile: ex.paired?.lastPathComponent,
                                  thumbFile: "thumb.jpg", previewFile: "preview.jpg", preparedAt: now())
            try JSONEncoder().encode(StagedUpload(request: req, plan: plan)).write(to: dir.appendingPathComponent("staged.json"))
            j.plan = plan
            j.state = .prepared
            j.originalDone = false
            j.pairedDone = plan.paired == nil
            j.nextTryAt = now()
            j.lastError = nil
            try catalog.save(j, now: now())
            return .prepared
        } catch {
            try? fm.removeItem(at: dir)
            fail(job, back: .new, error)
            return .failed
        }
    }

    /// Presigned URLs last 6 hours; ask for fresh ones if the plan is older than 5.
    private func freshPlan(_ job: BackupJob) async throws -> UploadPlan {
        guard var plan = job.plan else { throw APIError.badResponse }
        if now().timeIntervalSince(plan.preparedAt) < 5 * 3600 { return plan }
        let staged = try JSONDecoder().decode(StagedUpload.self, from: Data(contentsOf: stagingDir(job.localId).appendingPathComponent("staged.json")))
        let resp = try await api.prepare(staged.request)
        guard let uploads = resp.uploads, resp.assetId == plan.assetId else { throw APIError.badResponse }
        plan.original = uploads.original
        plan.paired = uploads.paired
        plan.preparedAt = now()
        return plan
    }

    private func startUpload(_ job: BackupJob) async -> Bool {
        do {
            let plan = try await freshPlan(job)
            let dir = stagingDir(job.localId)
            var j = job
            j.plan = plan
            if !j.originalDone {
                try uploader.start(file: dir.appendingPathComponent(plan.primaryFile), target: plan.original, tag: job.localId + "#o")
            }
            if !j.pairedDone, let paired = plan.paired, let file = plan.pairedFile {
                try uploader.start(file: dir.appendingPathComponent(file), target: paired, tag: job.localId + "#p")
            }
            j.state = .uploading
            j.nextTryAt = now().addingTimeInterval(12 * 3600)     // if no completion arrives by then, try again
            try catalog.save(j, now: now())
            return true
        } catch {
            // The staging folder is gone (e.g. cleared by iOS) or the server refused: start over from export.
            fail(job, back: FileManager.default.fileExists(atPath: stagingDir(job.localId).path) ? .prepared : .new, error)
            return false
        }
    }

    /// Called (via the uploader) when one original or paired-video upload ends.
    public func uploadFinished(tag: String, status: Int, error: String?) {
        guard let hash = tag.lastIndex(of: "#") else { return }
        let localId = String(tag[..<hash])
        let part = tag[tag.index(after: hash)...]
        guard var j = catalog.job(localId), j.state == .uploading else { return }
        if (200..<300).contains(status) && error == nil {
            if part == "o" { j.originalDone = true } else { j.pairedDone = true }
            if j.originalDone && j.pairedDone { j.state = .uploaded; j.nextTryAt = now() }
            try? catalog.save(j, now: now())
            if j.state == .uploaded { kick() }
        } else {
            if status == 403, var p = j.plan { p.preparedAt = .distantPast; j.plan = p }   // expired URL: refresh next time
            fail(j, back: .prepared, APIError.http(status: status, message: error ?? "upload failed"))
        }
    }

    private func commit(_ job: BackupJob) async -> Bool {
        guard let plan = job.plan else { fail(job, back: .new, APIError.badResponse); return false }
        let dir = stagingDir(job.localId)
        do {
            let thumb = try Data(contentsOf: dir.appendingPathComponent(plan.thumbFile))
            let preview = try Data(contentsOf: dir.appendingPathComponent(plan.previewFile))
            try await api.uploadDerived(assetId: plan.assetId, .thumb, data: thumb)
            try await api.uploadDerived(assetId: plan.assetId, .preview, data: preview)
            let asset = try await api.commit(assetId: plan.assetId)
            try catalog.apply([asset])
            try? cache.write(thumb, .thumb, asset.id)
            try? cache.write(preview, .preview, asset.id)
            try? FileManager.default.removeItem(at: dir)
            var j = job
            j.state = .committed; j.plan = nil; j.attempts = 0; j.lastError = nil
            try catalog.save(j, now: now())
            return true
        } catch let e as APIError {
            if case .http(409, _) = e {
                // The server could not verify the original: upload it again.
                var j = job
                j.originalDone = false
                j.pairedDone = plan.paired == nil
                fail(j, back: .prepared, e)
            } else {
                fail(job, back: .uploaded, e)
            }
            return false
        } catch {
            fail(job, back: FileManager.default.fileExists(atPath: dir.path) ? .uploaded : .new, error)
            return false
        }
    }

    /// Uploads whose background task disappeared (app force-quit, reboot) go back to the queue.
    private func recoverLostUploads() async {
        let uploading = catalog.jobs(.uploading)
        guard !uploading.isEmpty else { return }
        let active = await uploader.activeTags()
        for var j in uploading {
            let tags = [j.originalDone ? nil : j.localId + "#o", j.pairedDone ? nil : j.localId + "#p"].compactMap { $0 }
            if tags.allSatisfy({ !active.contains($0) }) {
                j.state = .prepared
                j.nextTryAt = now()
                try? catalog.save(j, now: now())
            }
        }
    }

    public func statusCounts() -> [BackupState: Int] { catalog.backupCounts() }
}
