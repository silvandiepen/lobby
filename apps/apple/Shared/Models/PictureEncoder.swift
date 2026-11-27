// SPDX-License-Identifier: MPL-2.0
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a picture a person chose into what Lobby Server takes: upright, not too large, and
/// without what the camera wrote down.
enum PictureEncoder {
    /// A JPEG, for artwork.
    static func jpeg(from data: Data, maxPixels: Int = 2400) -> Data? {
        encode(data, as: .jpeg, maxPixels: maxPixels)
    }

    /// A PNG, for a logo: it keeps its transparency.
    static func png(from data: Data, maxPixels: Int = 1200) -> Data? {
        encode(data, as: .png, maxPixels: maxPixels)
    }

    static func image(from data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // A thumbnail of the picture itself, turned the way it is meant to be seen. A smaller
        // picture is not made larger.
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    private static func encode(_ data: Data, as type: UTType, maxPixels: Int) -> Data? {
        guard let image = image(from: data, maxPixels: maxPixels) else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, type.identifier as CFString, 1, nil) else { return nil }
        let options = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary : nil
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination) ? encoded as Data : nil
    }
}
