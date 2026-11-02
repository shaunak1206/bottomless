import Foundation

/// Metadata Google Takeout writes next to every Google Photos item (`<name>.json` / `<name>.supplemental-metadata.json`).
public struct TakeoutSidecar: Codable, Sendable, Equatable {
    public var title: String
    public var takenAt: Date?
    public var createdAt: Date?
    public var lat: Double?
    public var lon: Double?
    public var favorite: Bool
    public var description: String?

    /// Parses the JSON Google writes; returns nil for album metadata and other non-photo JSON files.
    public static func parse(_ data: Data) -> TakeoutSidecar? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let title = o["title"] as? String else { return nil }
        guard o["photoTakenTime"] != nil || o["creationTime"] != nil || o["geoData"] != nil else { return nil }
        func time(_ k: String) -> Date? {
            guard let t = o[k] as? [String: Any] else { return nil }
            if let s = t["timestamp"] as? String, let v = Double(s), v > 0 { return Date(timeIntervalSince1970: v) }
            if let v = t["timestamp"] as? Double, v > 0 { return Date(timeIntervalSince1970: v) }
            return nil
        }
        func geo(_ k: String) -> (Double, Double)? {
            guard let g = o[k] as? [String: Any], let la = g["latitude"] as? Double, let lo = g["longitude"] as? Double,
                  !(la == 0 && lo == 0) else { return nil }
            return (la, lo)
        }
        let g = geo("geoData") ?? geo("geoDataExif")
        let desc = (o["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return TakeoutSidecar(title: title, takenAt: time("photoTakenTime"), createdAt: time("creationTime"),
                              lat: g?.0, lon: g?.1, favorite: (o["favorited"] as? Bool) ?? false, description: desc)
    }
}

public enum Takeout {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "gif", "webp", "dng", "tif", "tiff",
                                                       "bmp", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "avif"]
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "3gp", "avi", "mkv", "mpg", "mpeg", "wmv", "webm", "mts", "m2ts"]

    public static func isMedia(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        return imageExtensions.contains(e) || videoExtensions.contains(e)
    }

    /// Index keys under which a sidecar is stored: "<folder>/<media file name>" (lowercased), accounting for
    /// duplicate numbering: "IMG_1.jpg(1).json" or "IMG_1.jpg.supplemental-metadata(1).json" describe "IMG_1(1).jpg".
    public static func sidecarKey(folder: String, jsonName: String, sidecar: TakeoutSidecar) -> String {
        var name = sidecar.title
        if let m = jsonName.range(of: #"\((\d+)\)\.json$"#, options: .regularExpression) {
            let n = jsonName[m].dropFirst().prefix { $0 != ")" }
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            name = ext.isEmpty ? "\(stem)(\(n))" : "\(stem)(\(n)).\(ext)"
        }
        return key(folder: folder, name: name)
    }

    public static func key(folder: String, name: String) -> String { (folder + "/" + name).lowercased() }

    /// Takeout writes file names with characters like ' : ? * replaced by "_" but keeps them in the sidecar title.
    public static func sanitized(_ key: String) -> String {
        String(key.map { "'\"*:<>?|&%#".contains($0) ? "_" : $0 })
    }

    /// Folder of `url` relative to `root` ("Takeout/Google Photos/Photos from 2019"), stable across zips.
    public static func relativeFolder(of url: URL, root: URL) -> String {
        let dir = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let base = root.resolvingSymlinksInPath().path
        var rel = dir.hasPrefix(base) ? String(dir.dropFirst(base.count)) : dir
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }

    /// Keys to try for a media file, most specific first: exact name, the original of an "-edited" copy, and the
    /// un-truncated title when Takeout cut the file name (handled by `prefixMatch`).
    public static func candidateKeys(folder: String, mediaName: String) -> [String] {
        var out = [key(folder: folder, name: mediaName)]
        let ext = (mediaName as NSString).pathExtension
        let stem = (mediaName as NSString).deletingPathExtension
        for suffix in ["-edited", "-bearbeitet", "-modifié", "-editado", "-modificato"] where stem.hasSuffix(suffix) {
            out.append(key(folder: folder, name: String(stem.dropLast(suffix.count)) + (ext.isEmpty ? "" : ".\(ext)")))
        }
        return out
    }

    /// Takeout truncates long media file names (to 47 characters before the extension) while the sidecar title keeps
    /// the full name. Finds the single title in the same folder that the truncated name is a prefix of.
    public static func prefixMatch(folder: String, mediaName: String, keysInFolder: [String]) -> String? {
        let stem = (mediaName as NSString).deletingPathExtension.lowercased()
        guard stem.count >= 30 else { return nil }
        let prefix = (folder + "/" + stem).lowercased()
        let hits = keysInFolder.filter { $0.hasPrefix(prefix) && $0 != key(folder: folder, name: mediaName) }
        return hits.count == 1 ? hits[0] : nil
    }

    /// One thing to import: a photo/video, plus the motion half when it is a Live Photo / Motion Photo.
    public struct Item: Sendable, Equatable {
        public var primary: URL
        public var paired: URL?
        public var folder: String          // path relative to the Takeout root
        public var name: String
    }

    /// Walks an extracted Takeout folder. Pairs `X.HEIC`/`X.JPG` with a short `X.MOV`/`X.MP4` as one Live Photo.
    /// `isShortClip` decides whether a same-named video is a motion clip (Live Photos are ~3 s) or a separate video.
    public static func items(in root: URL, isShortClip: (URL) -> Bool) -> [Item] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var byFolder: [String: [URL]] = [:]
        for case let url as URL in walker where isMedia(url) {
            byFolder[relativeFolder(of: url, root: root), default: []].append(url)
        }
        var out: [Item] = []
        for (folder, files) in byFolder {
            var videosByStem: [String: URL] = [:]
            for f in files where videoExtensions.contains(f.pathExtension.lowercased()) {
                videosByStem[f.deletingPathExtension().lastPathComponent.lowercased()] = f
            }
            var usedAsPair = Set<URL>()
            for f in files where imageExtensions.contains(f.pathExtension.lowercased()) {
                let stem = f.deletingPathExtension().lastPathComponent.lowercased()
                var paired: URL?
                if let v = videosByStem[stem], isShortClip(v) { paired = v; usedAsPair.insert(v) }
                out.append(Item(primary: f, paired: paired, folder: folder, name: f.lastPathComponent))
            }
            for f in files where videoExtensions.contains(f.pathExtension.lowercased()) && !usedAsPair.contains(f) {
                out.append(Item(primary: f, paired: nil, folder: folder, name: f.lastPathComponent))
            }
        }
        // "Photos from YYYY" folders first: album folders repeat the same photos and are then deduplicated by hash.
        return out.sorted { a, b in
            let ya = a.folder.contains("Photos from"), yb = b.folder.contains("Photos from")
            return ya != yb ? ya : (a.folder, a.name) < (b.folder, b.name)
        }
    }
}
