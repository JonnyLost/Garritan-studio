import AppKit
import Foundation

/// Optional, locally bundled Cinematic Atelier artwork.
///
/// There are deliberately no network lookups, generated placeholder images,
/// or commercial plugin dependencies. Missing/unapproved assets do not block
/// Studio: the browser continues to display its native vector illustrations.
enum StudioInstrumentArtworkAssets {
    // Image data stays small and bounded during long orchestral sessions.
    // Both caches use NSCache (thread-safe; automatically purged under memory
    // pressure). Missing bundle entries are cached so timeline redraws never
    // repeat failed file lookups for the same instrument.
    private static let cache: NSCache<NSString, NSImage> = {
        let result = NSCache<NSString, NSImage>()
        result.countLimit = 48
        result.totalCostLimit = 48 * 1024 * 1024
        return result
    }()
    private static let unavailable = NSCache<NSString, NSNumber>()

    /// Stable, deterministic filename for a physical instrument or ensemble.
    /// Names are independent of library, preset, articulation and patch ID.
    /// Enum identifiers are part of the asset contract; rename them only
    /// alongside a resource-file migration.
    static func key(name: String, path: String = "", category: String = "") -> String {
        if let group = StudioInstrumentGroupArtwork.resolve(
            name: name, path: path, category: category
        ) {
            return "ensemble_\(group.rawValue)"
        }
        let identity = InstrumentIconIdentity.resolve(
            name: name, path: path, category: category
        )
        return "instrument_\(String(describing: identity))"
    }

    /// Returns nil when artwork has not been approved/installed. The caller
    /// must render the native vector fallback in that case.
    static func image(name: String, path: String = "", category: String = "") -> NSImage? {
        let filename = key(name: name, path: path, category: category)
        let cacheKey = filename as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }
        if unavailable.object(forKey: cacheKey) != nil {
            return nil
        }
        guard let url = Bundle.module.url(
            forResource: filename,
            withExtension: "png",
            subdirectory: "InstrumentArtwork"
        ), let image = NSImage(contentsOf: url) else {
            unavailable.setObject(NSNumber(value: true), forKey: cacheKey)
            return nil
        }
        // Approved PNGs are validated in CI before bundling. Estimating the
        // decoded bitmap cost prevents many large browser images from filling
        // MacBook memory even when NSCache retains them.
        let estimatedCost = Int(max(1, image.size.width) * max(1, image.size.height) * 4)
        cache.setObject(image, forKey: cacheKey, cost: estimatedCost)
        return image
    }
}
