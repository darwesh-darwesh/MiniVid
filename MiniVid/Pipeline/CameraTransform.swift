import CoreGraphics
import Foundation

/// Applies a small per-frame affine transform to the previous frame before
/// feeding it back through img2img — the classic Deforum feedback loop.
/// A slight overscan hides the borders revealed by pans and rotations.
enum CameraTransform {

    static func apply(_ move: CameraMove, to image: CGImage, amount: Float) -> CGImage {
        guard move != .fixed else { return image }

        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let a = CGFloat(max(0, min(1, amount)))

        guard let ctx = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        ctx.interpolationQuality = .high
        ctx.translateBy(x: w / 2, y: h / 2)

        switch move {
        case .zoomIn:
            let s = 1 + 0.03 * a
            ctx.scaleBy(x: s, y: s)
        case .zoomOut:
            // Never drop below 1.0 or the borders would show.
            let s = max(1.0, 1.03 - 0.025 * a)
            ctx.scaleBy(x: s, y: s)
        case .panLeft, .panRight, .panUp, .panDown:
            let overscan = 1 + 0.03 * a
            ctx.scaleBy(x: overscan, y: overscan)
            let shift = 0.02 * a
            switch move {
            case .panLeft: ctx.translateBy(x: shift * w, y: 0)
            case .panRight: ctx.translateBy(x: -shift * w, y: 0)
            case .panUp: ctx.translateBy(x: 0, y: -shift * h)   // CG origin is bottom-left
            case .panDown: ctx.translateBy(x: 0, y: shift * h)
            default: break
            }
        case .rotateCW, .rotateCCW:
            let overscan = 1 + 0.05 * a
            ctx.scaleBy(x: overscan, y: overscan)
            let angle = (1.5 * a) * .pi / 180
            ctx.rotate(by: move == .rotateCW ? -angle : angle)
        case .fixed:
            break
        }

        ctx.translateBy(x: -w / 2, y: -h / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
