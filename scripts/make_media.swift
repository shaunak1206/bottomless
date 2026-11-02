// Generates a sample camera roll for simulator tests: JPEGs with capture dates spread over ~4 months (some with GPS)
// and a few short videos.  Usage: swift scripts/make_media.swift <out-dir> [photos] [videos]
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "sample-media", isDirectory: true)
let photoCount = args.count > 2 ? Int(args[2])! : 30
let videoCount = args.count > 3 ? Int(args[3])! : 2
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let exifFormat = DateFormatter()
exifFormat.dateFormat = "yyyy:MM:dd HH:mm:ss"
exifFormat.locale = Locale(identifier: "en_US_POSIX")

func photo(_ i: Int, date: Date, gps: (Double, Double)?) throws {
    let w = 2400, h = 1800
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let hue = Double(i % 12) / 12
    for band in 0..<24 {
        let t = Double(band) / 24
        ctx.setFillColor(red: 0.5 + 0.5 * sin(6.28 * (hue + t)), green: 0.5 + 0.5 * sin(6.28 * (hue + t + 0.33)),
                         blue: 0.5 + 0.5 * sin(6.28 * (hue + t + 0.66)), alpha: 1)
        ctx.fill(CGRect(x: 0, y: band * h / 24, width: w, height: h / 24 + 1))
    }
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.85)
    ctx.fillEllipse(in: CGRect(x: w / 2 - 300, y: h / 2 - 300, width: 600, height: 600))
    let img = ctx.makeImage()!
    let url = out.appendingPathComponent(String(format: "IMG_%04d.jpg", 1000 + i))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85,
                                  kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: exifFormat.string(from: date),
                                                                   kCGImagePropertyExifDateTimeDigitized: exifFormat.string(from: date)]]
    if let (lat, lon) = gps {
        props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: abs(lat), kCGImagePropertyGPSLatitudeRef: lat < 0 ? "S" : "N",
                                                kCGImagePropertyGPSLongitude: abs(lon), kCGImagePropertyGPSLongitudeRef: lon < 0 ? "W" : "E"]
    }
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

func video(_ i: Int, date: Date) async throws {
    let url = out.appendingPathComponent(String(format: "CLIP_%04d.mov", 1000 + i))
    let size = 720
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: size, kCVPixelBufferHeightKey as String: size])
    writer.add(input)
    let meta = AVMutableMetadataItem()
    meta.keySpace = .quickTimeMetadata
    meta.key = AVMetadataKey.quickTimeMetadataKeyCreationDate as NSString
    meta.value = ISO8601DateFormatter().string(from: date) as NSString
    writer.metadata = [meta]
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for f in 0..<45 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        memset(CVPixelBufferGetBaseAddress(pb!), Int32((f * 5 + i * 60) % 255), CVPixelBufferGetDataSize(pb!))
        CVPixelBufferUnlockBaseAddress(pb!, [])
        adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 15))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

let now = Date()
let day = 86400.0
for i in 0..<photoCount {
    // Half recent (last 3 weeks), half older (1-4 months) so "free up space" has candidates.
    let age = i % 2 == 0 ? Double(i) * 0.7 * day : (35 + Double(i) * 3) * day
    try photo(i, date: now.addingTimeInterval(-age), gps: i % 3 == 0 ? (30.2849 + Double(i) * 0.001, -97.7341) : nil)
}
for i in 0..<videoCount {
    try await video(i, date: now.addingTimeInterval(-Double(i * 40 + 1) * day))
}
print("wrote \(photoCount) photos and \(videoCount) videos to \(out.path)")
