import CoreGraphics
import Foundation

/// Fights the frame-to-frame flicker inherent to img2img feedback loops —
/// the classic Deforum "color coherence" trick plus a light temporal blend.
/// Purely statistical (per-channel mean/std transfer), no extra ML model,
/// a few milliseconds per 512² frame.
enum CoherenceStabilizer {

    /// - Parameters:
    ///   - frame: freshly generated frame.
    ///   - reference: color anchor — frame 0, or the I2V input photo.
    ///   - previous: camera-transformed previous frame (temporal blend anchor).
    ///   - amount: 0 = off, 1 = full palette lock + strongest blend.
    static func stabilize(
        _ frame: CGImage,
        reference: CGImage,
        previous: CGImage?,
        amount: Float
    ) -> CGImage {
        let strength = CGFloat(max(0, min(1, amount)))
        guard strength > 0.01 else { return frame }

        var result = matchColor(of: frame, to: reference, strength: strength)
        if let previous {
            // Cap the blend low: it kills shimmer but too much causes ghosting.
            result = blended(result, with: previous, alpha: 0.25 * strength)
        }
        return result
    }

    /// Reinhard-style per-channel mean/std transfer, applied partially.
    private static func matchColor(of image: CGImage, to reference: CGImage, strength: CGFloat) -> CGImage {
        guard var srcData = rgbaBytes(image), let refData = rgbaBytes(reference) else { return image }
        let src = channelStats(srcData)
        let ref = channelStats(refData)
        let s = Double(strength)

        for c in 0..<3 {
            let scale = ref.std[c] / max(src.std[c], 1)
            let gain = 1 + (scale - 1) * s
            let targetMean = src.mean[c] + (ref.mean[c] - src.mean[c]) * s
            var i = c
            while i < srcData.count {
                let v = (Double(srcData[i]) - src.mean[c]) * gain + targetMean
                srcData[i] = UInt8(max(0, min(255, v)))
                i += 4
            }
        }
        return imageFrom(bytes: &srcData, width: image.width, height: image.height) ?? image
    }

    private static func blended(_ base: CGImage, with overlay: CGImage, alpha: CGFloat) -> CGImage {
        guard alpha > 0.005,
              let ctx = CGContext(
                  data: nil,
                  width: base.width,
                  height: base.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return base }
        let rect = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        ctx.interpolationQuality = .high
        ctx.draw(base, in: rect)
        ctx.setAlpha(alpha)
        ctx.draw(overlay, in: rect)
        return ctx.makeImage() ?? base
    }

    private static func rgbaBytes(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? data : nil
    }

    private static func channelStats(_ data: [UInt8]) -> (mean: [Double], std: [Double]) {
        var sum = [0.0, 0.0, 0.0]
        var sumSq = [0.0, 0.0, 0.0]
        let pixelCount = Double(data.count / 4)
        var i = 0
        while i < data.count {
            for c in 0..<3 {
                let v = Double(data[i + c])
                sum[c] += v
                sumSq[c] += v * v
            }
            i += 4
        }
        var mean = [Double]()
        var std = [Double]()
        for c in 0..<3 {
            let m = sum[c] / pixelCount
            mean.append(m)
            std.append(max(sqrt(max(sumSq[c] / pixelCount - m * m, 0)), 1))
        }
        return (mean, std)
    }

    private static func imageFrom(bytes: inout [UInt8], width: Int, height: Int) -> CGImage? {
        bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
    }
}
