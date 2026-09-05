import CoreGraphics

/// Inserts linearly blended in-between frames (cross-dissolve). For the
/// morphing content this pipeline produces, blending reads as smoother
/// motion at zero diffusion cost — the cheap alternative to a real
/// interpolation network like RIFE (roadmap v0.5).
enum FrameInterpolator {

    static func smooth(_ frames: [CGImage], factor: Int) -> [CGImage] {
        guard factor > 1, frames.count > 1 else { return frames }
        var output: [CGImage] = []
        output.reserveCapacity(frames.count * factor)
        for i in 0..<frames.count {
            output.append(frames[i])
            guard i < frames.count - 1 else { break }
            for k in 1..<factor {
                let t = CGFloat(k) / CGFloat(factor)
                output.append(blend(frames[i], frames[i + 1], t: t))
            }
        }
        return output
    }

    private static func blend(_ a: CGImage, _ b: CGImage, t: CGFloat) -> CGImage {
        guard let ctx = CGContext(
            data: nil,
            width: a.width,
            height: a.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return a }
        let rect = CGRect(x: 0, y: 0, width: a.width, height: a.height)
        ctx.interpolationQuality = .high
        ctx.draw(a, in: rect)
        ctx.setAlpha(t)
        ctx.draw(b, in: rect)
        return ctx.makeImage() ?? a
    }
}
