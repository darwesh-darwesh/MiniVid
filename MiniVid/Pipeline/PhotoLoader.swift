import CoreGraphics
import PhotosUI
import SwiftUI
import UIKit

/// Shared PhotosPicker → CGImage loader: bakes EXIF orientation so the
/// pipeline and exporters always see upright pixels.
enum PhotoLoader {
    static func loadCGImage(from item: PhotosPickerItem) async -> CGImage? {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let picked = UIImage(data: data)
        else { return nil }

        if picked.imageOrientation == .up { return picked.cgImage }
        let upright = UIGraphicsImageRenderer(size: picked.size).image { _ in
            picked.draw(in: CGRect(origin: .zero, size: picked.size))
        }
        return upright.cgImage
    }
}
