import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
@testable import BottomlessCore

func tempDir(_ name: String = UUID().uuidString) -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("bottomless-tests/\(name)", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// A colourful JPEG of the given size (different seed → different bytes).
func makeJPEG(width: Int, height: Int, seed: Int, orientation: Int = 1, gps: (Double, Double)? = nil) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    var rng = SystemRandomNumberGenerator()
    for i in 0..<12 {
        let r = CGFloat((seed * 37 + i * 53) % 255) / 255, g = CGFloat((seed * 11 + i * 97) % 255) / 255
        ctx.setFillColor(red: r, green: g, blue: CGFloat(UInt8.random(in: 0...255, using: &rng)) / 255, alpha: 1)
        ctx.fill(CGRect(x: (i * width) / 12, y: 0, width: width / 12 + 1, height: height))
    }
    let img = ctx.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    var props: [CFString: Any] = [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 0.9,
                                  kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:01 12:34:56"]]
    if let (lat, lon) = gps {
        props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: abs(lat), kCGImagePropertyGPSLatitudeRef: lat < 0 ? "S" : "N",
                                                kCGImagePropertyGPSLongitude: abs(lon), kCGImagePropertyGPSLongitudeRef: lon < 0 ? "W" : "E"]
    }
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    CGImageDestinationFinalize(dest)
    return data as Data
}

/// A short H.264 movie made of solid-colour frames.
func makeMovie(at url: URL, seconds: Double = 1.5, size: Int = 320, date: Date? = nil) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: size,
        kCVPixelBufferHeightKey as String: size])
    writer.add(input)
    if let date {
        let meta = AVMutableMetadataItem()
        meta.keySpace = .quickTimeMetadata
        meta.key = AVMetadataKey.quickTimeMetadataKeyCreationDate as NSString
        meta.value = ISO8601DateFormatter().string(from: date) as NSString
        writer.metadata = [meta]
    }
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let frames = Int(seconds * 10)
    for f in 0..<frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        memset(CVPixelBufferGetBaseAddress(pb!), Int32(40 + f * 10), CVPixelBufferGetDataSize(pb!))
        CVPixelBufferUnlockBaseAddress(pb!, [])
        adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 10))
    }
    input.markAsFinished()
    await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

/// A "photo library" backed by files in a folder: what PhotoKit is in the app.
final class FolderLibrary: LocalLibrary, @unchecked Sendable {
    struct Item { var info: LocalAssetInfo; var file: URL; var paired: URL?; var mime: String }
    private let lock = NSLock()
    private var items: [String: Item] = [:]
    var exportCount = 0

    func add(_ id: String, file: URL, kind: AssetKind, created: Date, favorite: Bool = false, paired: URL? = nil, mime: String = "image/jpeg") {
        lock.lock(); defer { lock.unlock() }
        items[id] = Item(info: LocalAssetInfo(localId: id, createdAt: created, kind: kind, isFavorite: favorite), file: file, paired: paired, mime: mime)
    }
    func remove(_ id: String) { lock.lock(); items[id] = nil; lock.unlock() }
    func setFavorite(_ id: String, _ fav: Bool) { lock.lock(); items[id]?.info.isFavorite = fav; lock.unlock() }

    func allAssets() async throws -> [LocalAssetInfo] {
        lock.lock(); defer { lock.unlock() }
        return items.values.map(\.info)
    }

    func export(_ localId: String, into dir: URL) async throws -> ExportedAsset {
        let item: Item? = { lock.lock(); defer { lock.unlock() }; exportCount += 1; return items[localId] }()
        guard let item else { throw CocoaError(.fileNoSuchFile) }
        let dest = dir.appendingPathComponent(item.file.lastPathComponent)
        try FileManager.default.copyItem(at: item.file, to: dest)
        var pairedDest: URL?
        if let p = item.paired {
            pairedDest = dir.appendingPathComponent("paired-" + p.lastPathComponent)
            try FileManager.default.copyItem(at: p, to: pairedDest!)
        }
        let info = Derivatives.imageInfo(dest)
        return ExportedAsset(primary: dest, primaryMime: item.mime, filename: item.file.lastPathComponent, paired: pairedDest,
                             pairedMime: pairedDest == nil ? nil : "video/quicktime", kind: item.info.kind, takenAt: item.info.createdAt,
                             width: info.width, height: info.height, duration: item.info.kind == .video ? 1.5 : nil,
                             lat: info.lat, lon: info.lon, favorite: item.info.isFavorite)
    }
}

func remote(_ id: String, takenAt: Int64 = 1_000, status: AssetStatus = .ready, favorite: Bool = false, seq: Int64 = 1) -> RemoteAsset {
    RemoteAsset(id: id, sha256: String(repeating: "a", count: 64), kind: .photo, mime: "image/jpeg", size: 10, filename: "\(id).jpg",
                width: 10, height: 10, duration: nil, takenAt: takenAt, lat: nil, lon: nil, favorite: favorite, hidden: false,
                hasPaired: false, pairedMime: nil, pairedSize: nil, hasThumb: true, hasPreview: true, status: status,
                createdAt: 0, updatedAt: 0, trashedAt: status == .trashed ? 5 : nil, seq: seq)
}
