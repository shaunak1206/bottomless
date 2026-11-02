import UIKit
import Photos
import BottomlessCore

/// Loads thumbnails and previews: memory cache → disk cache → server; photos still only on the phone come from PhotoKit.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()
    private let memory = NSCache<NSString, UIImage>()
    private let photos = PHCachingImageManager()

    init() { memory.totalCostLimit = 120 << 20 }   // decoded bitmaps, by bytes: a count limit let 800 big ones pile up

    func cached(_ key: String) -> UIImage? { memory.object(forKey: key as NSString) }

    /// The thumbnail if it is already decoded in memory: shown at once, without a fade.
    func cachedThumbnail(_ id: String) -> UIImage? { cached("t:" + id) }

    private func keep(_ img: UIImage, _ key: String) {
        let px = img.size.width * img.scale * img.size.height * img.scale
        memory.setObject(img, forKey: key as NSString, cost: Int(px) * 4)
    }

    func thumbnail(_ id: String) async -> UIImage? {
        let key = "t:" + id
        if let img = memory.object(forKey: key as NSString) { return img }
        guard let s = AppServices.shared else { return nil }
        let data: Data?
        if let d = s.cache.data(.thumb, id) { data = d } else { data = try? await s.sync.thumbnail(id) }
        guard let data, let img = await decode(data) else { return nil }
        keep(img, key)
        return img
    }

    func preview(_ id: String) async -> UIImage? {
        let key = "p:" + id
        if let img = memory.object(forKey: key as NSString) { return img }
        guard let s = AppServices.shared, let data = try? await s.sync.preview(id), let img = await decode(data) else { return nil }
        keep(img, key)
        return img
    }

    /// A photo that has not been backed up yet (or is still on the phone).
    func local(_ localId: String, size: CGSize) async -> UIImage? {
        let key = "l:\(Int(size.width)):" + localId
        if let img = memory.object(forKey: key as NSString) { return img }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil).firstObject else { return nil }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        opts.resizeMode = .fast
        let img: UIImage? = await withCheckedContinuation { c in
            photos.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: opts) { image, _ in c.resume(returning: image) }
        }
        if let img { keep(img, key) }
        return img
    }

    private func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { UIImage(data: data)?.preparingForDisplay() }.value
    }
}

/// Fetches thumbnails just ahead of where the grid is, four at a time, newest request first: after a fast
/// scroll the spot you stopped at loads next, and requests for places already flung past are dropped.
actor ThumbnailPrefetcher {
    private var queue: [String] = []        // the last one is fetched next
    private var queued: Set<String> = []
    private var running = 0
    private let maxRunning = 4
    private let maxQueued = 90

    func want(_ ids: [String]) {
        for id in ids.reversed() where !queued.contains(id) && ImageLoader.shared.cachedThumbnail(id) == nil {
            queue.append(id)
            queued.insert(id)
        }
        if queue.count > maxQueued {
            for id in queue.prefix(queue.count - maxQueued) { queued.remove(id) }
            queue.removeFirst(queue.count - maxQueued)
        }
        pump()
    }

    private func pump() {
        while running < maxRunning, let id = queue.popLast() {
            queued.remove(id)
            running += 1
            Task.detached(priority: .utility) {
                _ = await ImageLoader.shared.thumbnail(id)
                await self.finished()
            }
        }
    }

    private func finished() {
        running -= 1
        pump()
    }
}
