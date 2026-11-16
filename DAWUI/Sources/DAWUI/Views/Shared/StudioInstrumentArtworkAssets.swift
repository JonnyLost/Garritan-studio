import AppKit
import Foundation

/// Optional, locally bundled Cinematic Atelier artwork.
///
/// There are deliberately no network lookups, generated placeholder images,
/// or commercial plugin dependencies. Missing/unapproved assets do not block
/// Studio: the browser continues to display its native vector illustrations.
enum StudioInstrumentArtworkAssets {
    private static let cache = NSCache<NSString, NSImage>()

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
        guard let url = Bundle.module.url(
            forResource: filename,
            withExtension: "png",
            subdirectory: "InstrumentArtwork"
        ), let image = NSImage(contentsOf: url) else {
            return nil
        }
        cache.setObject(image, forKey: cacheKey)
        return image
    }
}
