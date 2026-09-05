import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportError: LocalizedError {
    case pixelBufferCreationFailed
    case imageDestinationFailed
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .pixelBufferCreationFailed:
            return "Could not create a pixel buffer for video encoding."
        case .imageDestinationFailed:
            return "Could not write the image file."
        case .writerFailed(let reason):
            return "Video export failed: \(reason)"
        }
    }
}

/// Writes generated frames to MP4 (H.264) or animated GIF, and handles
/// downscaling from the model's native 512² to the export resolution.
enum VideoExporter {

    static func resize(_ image: CGImage, to pixels: Int) -> CGImage {
        guard image.width != pixels || image.height != pixels else { return image }
        guard let ctx = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return ctx.makeImage() ?? image
    }

    /// Center-crop + scale to a square — prepares a picked photo for the
    /// pipeline's fixed 512×512 input.
    static func aspectFillSquare(_ image: CGImage, side: Int) -> CGImage {
        guard image.width != side || image.height != side else { return image }
        guard let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let scale = CGFloat(side) / min(w, h)
        let drawSize = CGSize(width: w * scale, height: h * scale)
        let origin = CGPoint(
            x: (CGFloat(side) - drawSize.width) / 2,
            y: (CGFloat(side) - drawSize.height) / 2
        )
        ctx.draw(image, in: CGRect(origin: origin, size: drawSize))
        return ctx.makeImage() ?? image
    }

    /// Scale so the longest side equals `target`, preserving aspect ratio.
    static func fitLongestSide(_ image: CGImage, to target: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest != target else { return image }
        let scale = Double(target) / Double(longest)
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }

    static func writeMP4(frames: [CGImage], fps: Int, to url: URL) async throws {
        precondition(!frames.isEmpty, "writeMP4 requires at least one frame")
        try? FileManager.default.removeItem(at: url)

        let width = frames[0].width
        let height = frames[0].height
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        for (index, frame) in frames.enumerated() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard let buffer = pixelBuffer(from: frame, width: width, height: height) else {
                throw ExportError.pixelBufferCreationFailed
            }
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
            adaptor.append(buffer, withPresentationTime: time)
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
        }
    }

    static func writeGIF(frames: [CGImage], fps: Int, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil
        ) else { throw ExportError.imageDestinationFailed }

        let fileProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        // Browsers clamp GIF frame delays below ~20 ms to 100 ms, so cap
        // effective playback at 30 fps to keep timing honest everywhere.
        let delay = max(1.0 / Double(fps), 1.0 / 30.0)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ]
        ]
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.imageDestinationFailed
        }
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw ExportError.imageDestinationFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.imageDestinationFailed
        }
    }

    private static func pixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, attrs, &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
