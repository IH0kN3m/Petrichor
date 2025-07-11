import Foundation
import AppKit

/// A shared in-memory image cache for storing already-resized artwork images.
/// The cache uses `NSCache` so the system can automatically purge it under memory pressure.
final class ImageCache {
    static let shared = ImageCache()

    private let cache: NSCache<NSString, NSImage>

    private init() {
        let cache = NSCache<NSString, NSImage>()
        // We err on the side of *more* caching – decoding is usually more expensive than keeping
        // a couple hundred MB in RAM on modern Macs.  The system will still purge under pressure.
        // • Allow up to 150k thumbnails (≈ large 100 k-track libraries with artwork).
        // • Up to 1.5 GB decompressed bitmap footprint – plentiful on 16-32 GB machines.
        cache.countLimit = 150_000
        cache.totalCostLimit = 1_536 * 1_024 * 1_024 // ≈ 1.5 GB
        self.cache = cache
    }

    func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func insertImage(_ image: NSImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString, cost: image.representationSize)
    }
}

private extension NSImage {
    /// Approximate the *decompressed* memory footprint of the image instead of its encoded size.
    /// This produces a much more accurate cost for `NSCache.totalCostLimit` eviction decisions.
    var representationSize: Int {
        // Try to derive pixel dimensions from the first available representation.
        if let rep = representations.first {
            let pixelsWide = rep.pixelsWide
            let pixelsHigh = rep.pixelsHigh

            if pixelsWide > 0 && pixelsHigh > 0 {
                // 4 bytes per pixel for 32-bit RGBA.
                return pixelsWide * pixelsHigh * 4
            }
        }

        // Fallback to encoded data length when dimensions are unavailable.
        if let tiffRepresentation = tiffRepresentation {
            return tiffRepresentation.count
        }

        return 0
    }
} 
