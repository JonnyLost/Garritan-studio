import CoreImage
import CoreImage.CIFilterBuiltins
import DAWCore
import Foundation

/// Offline-only image compositor for a permanent SMPTE label in delivered
/// movies. No Core Image objects are shared between concurrent export frames.
enum StudioPictureTimecodeBurnIn {
    static func label(picture: StudioPictureProject, movieSeconds: Double) -> String {
        let rate = picture.frameRate.framesPerSecond
        guard movieSeconds.isFinite, rate.isFinite, rate > 0 else {
            return picture.timecode(atMovieFrame: 0)
        }
        let rawFrame = max(0, movieSeconds * rate)
        let nearest = rawFrame.rounded()
        let stable = abs(rawFrame - nearest) < 1e-7 ? nearest : rawFrame
        let bounded = min(Double(max(0, picture.totalFrames - 1)),
                          stable.rounded(.down))
        return picture.timecode(atMovieFrame: Int64(bounded))
    }

    static func render(source: CIImage, movieSeconds: Double,
                       picture: StudioPictureProject) -> CIImage {
        let bounds = source.extent
        guard bounds.width >= 40, bounds.height >= 40,
              bounds.width.isFinite, bounds.height.isFinite else { return source }

        let filter = CIFilter.textImageGenerator()
        filter.text = label(picture: picture, movieSeconds: movieSeconds)
        filter.fontName = "Menlo-Bold"
        filter.fontSize = Float(max(10, min(30, bounds.height * 0.035)))
        filter.scaleFactor = 1
        guard let text = filter.outputImage else { return source }

        // Composite a readable, semi-transparent backing and its opaque
        // white glyphs in source-image coordinates (Core Image is bottom-up).
        let padding: CGFloat = max(3, min(14, bounds.height * 0.012))
        let width = min(bounds.width - 8, text.extent.width + padding * 2)
        let height = min(bounds.height - 8, text.extent.height + padding * 2)
        guard width > 0, height > 0 else { return source }
        let rect = CGRect(x: bounds.minX + 4, y: bounds.minY + 4,
                          width: width, height: height)
        let backing = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.72))
            .cropped(to: rect)

        // CITextImageGenerator produces text with alpha. Tint the glyphs
        // white while retaining their coverage for legibility.
        let tint = CIFilter.colorMatrix()
        tint.inputImage = text
        tint.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        tint.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        tint.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        tint.biasVector = CIVector(x: 1, y: 1, z: 1, w: 0)
        let glyphs = (tint.outputImage ?? text)
            .transformed(by: CGAffineTransform(
                translationX: rect.minX + padding - text.extent.minX,
                y: rect.minY + padding - text.extent.minY))
        return glyphs.composited(over: backing)
            .composited(over: source)
            .cropped(to: bounds)
    }
}
