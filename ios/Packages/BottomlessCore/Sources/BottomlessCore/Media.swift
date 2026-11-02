import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

public struct FileDigest: Sendable, Equatable {
    public var sha256: String
    public var md5: String
    public var size: Int64
}

public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// SHA-256 (identity / dedupe) and MD5 (matches the storage ETag for upload verification), streamed in 1 MB chunks.
    public static func digest(of url: URL) throws -> FileDigest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha = SHA256()
        var md5 = Insecure.MD5()
        var size: Int64 = 0
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 1 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            sha.update(data: chunk)
            md5.update(data: chunk)
            size += Int64(chunk.count)
        }
        func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }
        return FileDigest(sha256: hex(sha.finalize()), md5: hex(md5.finalize()), size: size)
    }
}

public enum MediaError: Error, CustomStringConvertible {
    case unreadableImage(String)
    case encodeFailed
    case noVideoFrame
    public var description: String {
        switch self {
        case .unreadableImage(let p): return "cannot read image \(p)"
        case .encodeFailed: return "could not encode JPEG"
        case .noVideoFrame: return "could not read a frame from the video"
        }
    }
}

/// Thumbnails (360 px) and previews (2048 px) as JPEG, which every app and browser can show.
public enum Derivatives {
    public static let thumbPixels = 360
    public static let previewPixels = 2048

    public static func jpeg(from image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw MediaError.encodeFailed }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw MediaError.encodeFailed }
        return data as Data
    }

    /// Downscaled, orientation-corrected image from any ImageIO-readable file (HEIC, JPEG, PNG, RAW...).
    public static func scaledImage(from url: URL, maxPixels: Int) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw MediaError.unreadableImage(url.lastPathComponent)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw MediaError.unreadableImage(url.lastPathComponent)
        }
        return img
    }

    public static func imageDerivatives(from url: URL) throws -> (thumb: Data, preview: Data) {
        let preview = try scaledImage(from: url, maxPixels: previewPixels)
        let thumb = try scaledImage(from: url, maxPixels: thumbPixels)
        return (try jpeg(from: thumb, quality: 0.7), try jpeg(from: preview, quality: 0.78))
    }

    /// Poster frame for a video (1 s in, or the first frame for very short clips).
    public static func videoDerivatives(from url: URL) async throws -> (thumb: Data, preview: Data) {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: previewPixels, height: previewPixels)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let at = CMTime(seconds: min(1.0, max(0, duration / 2)), preferredTimescale: 600)
        let frame: CGImage
        do { frame = try await gen.image(at: at).image } catch { throw MediaError.noVideoFrame }
        let thumb = try downscale(frame, maxPixels: thumbPixels)
        return (try jpeg(from: thumb, quality: 0.7), try jpeg(from: frame, quality: 0.78))
    }

    static func downscale(_ image: CGImage, maxPixels: Int) throws -> CGImage {
        let scale = min(1, Double(maxPixels) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw MediaError.encodeFailed }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw MediaError.encodeFailed }
        return out
    }

    /// Pixel size, capture date and GPS from an image's metadata (used when PhotoKit does not provide them).
    public static func imageInfo(_ url: URL) -> (width: Int?, height: Int?, date: Date?, lat: Double?, lon: Double?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (nil, nil, nil, nil, nil) }
        let w = p[kCGImagePropertyPixelWidth] as? Int, h = p[kCGImagePropertyPixelHeight] as? Int
        var date: Date?
        if let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any], let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
            date = f.date(from: s)
        }
        var lat: Double?, lon: Double?
        if let gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let la = gps[kCGImagePropertyGPSLatitude] as? Double, let lo = gps[kCGImagePropertyGPSLongitude] as? Double {
            lat = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -la : la
            lon = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lo : lo
        }
        return (w, h, date, lat, lon)
    }
}

public enum MimeTypes {
    public static func of(_ url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? fallback(url.pathExtension.lowercased())
    }
    static func fallback(_ ext: String) -> String {
        switch ext {
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "dng": return "image/x-adobe-dng"
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
    public static func ext(for mime: String) -> String {
        UTType(mimeType: mime)?.preferredFilenameExtension ?? "bin"
    }
}
