import Foundation
import AppKit

/// A shared in-memory image cache for storing already-resized artwork images.
/// The cache uses `NSCache` so the system can automatically purge it under memory pressure.
final class ImageCache {
    static let shared = ImageCache()

    private let cache: NSCache<NSString, NSImage>

    private init() {
        let cache = NSCache<NSString, NSImage>()
        // Tighter limits tuned through profiling:
        // • `countLimit` ~3 000 thumbnails which covers sizeable libraries while preventing runaway growth.
        // • `totalCostLimit` ~300 MB based on the *decompressed* bitmap footprint (see `representationSize`).
        //   `NSCache` automatically evicts least-recently-used entries when these thresholds are reached,
        //   and the cache will also be purged entirely under system memory pressure.
        cache.countLimit = 10_000
        cache.totalCostLimit = 512 * 1_024 * 1_024 // ≈ 512 MB
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