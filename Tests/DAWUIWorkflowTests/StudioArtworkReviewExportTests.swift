import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import DAWUI

/// Exports the actual native Studio Path geometry as labelled PNG review sheets.
///
/// CI sets STUDIO_ARTWORK_EXPORT_DIR and uploads all pages as an artifact.
/// Without that environment variable this XCTest is a no-op, so ordinary
/// local/CI `swift test` execution does not produce unexpected files.
final class StudioArtworkReviewExportTests: XCTestCase {
    private let pageColumns = 4
    private let pageRows = 6
    private let pageWidth = 1440
    private let pageHeight = 1260
    private let tileWidth: CGFloat = 325
    private let tileHeight: CGFloat = 166
    private let marginX: CGFloat = 37
    private let marginTop: CGFloat = 136
    private let horizontalGap: CGFloat = 22
    private let verticalGap: CGFloat = 17

    func testExportContactSheets() throws {
        guard let directory = ProcessInfo.processInfo.environment["STUDIO_ARTWORK_EXPORT_DIR"],
              !directory.isEmpty else { return }

        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: output, withIntermediateDirectories: true
        )

        let singles = InstrumentIconIdentity.allCases
        let ensembles = StudioInstrumentGroupArtwork.allCases

        var manifest: [[String: Any]] = []
        for (isGroup, label, count) in [
            (false, "Individual and family identities", singles.count),
            (true, "Section and ensemble identities", ensembles.count)
        ] {
            let perPage = pageColumns * pageRows
            for start in stride(from: 0, to: count, by: perPage) {
                let index = start / perPage + 1
                let last = min(start + perPage, count)
                let filename = String(
                    format: "%@-%02d.png", isGroup ? "sections" : "instruments", index
                )
                let metadata: [(String, String, InstrumentIconDrawing)] = (start..<last).map { position in
                    if isGroup {
                        let identity = ensembles[position]
                        return (identity.rawValue, identity.accessibilityLabel,
                                InstrumentIconDrawing.makeGroup(identity))
                    }
                    let identity = singles[position]
                    return (String(describing: identity), identity.accessibilityLabel,
                            InstrumentIconDrawing.make(identity))
                }
                try drawPage(
                    title: label,
                    index: index,
                    total: count,
                    images: metadata,
                    output: output.appendingPathComponent(filename)
                )
                manifest.append([
                    "file": filename,
                    "category": isGroup ? "ensemble" : "instrument",
                    "items": metadata.map { ["key": $0.0, "name": $0.1] }
                ])
            }
        }

        let json = try JSONSerialization.data(
            withJSONObject: ["baseCount": singles.count,
                             "ensembleCount": ensembles.count,
                             "pages": manifest],
            options: [.prettyPrinted, .sortedKeys]
        )
        try json.write(to: output.appendingPathComponent("manifest.json"))
    }

    private func drawPage(
        title: String, index: Int, total: Int,
        images: [(String, String, InstrumentIconDrawing)],
        output: URL
    ) throws {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pageWidth, pixelsHigh: pageHeight,
                bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            )
        )
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics

        let ctx = graphics.cgContext
        let bg = NSColor(calibratedRed: 0.075, green: 0.094, blue: 0.12, alpha: 1)
        let tile = NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.17, alpha: 1)
        let border = NSColor(calibratedRed: 0.46, green: 0.36, blue: 0.27, alpha: 1)
        let ink = NSColor(calibratedRed: 0.94, green: 0.78, blue: 0.53, alpha: 1)
        let secondary = NSColor(calibratedRed: 0.73, green: 0.74, blue: 0.77, alpha: 1)

        ctx.setFillColor(bg.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

        drawText("GARRITAN STUDIO  /  CINEMATIC ATELIER",
                 at: CGRect(x: 38, y: pageHeight - 60, width: pageWidth - 76, height: 40),
                 size: 30, color: ink, bold: true, alignment: .left)
        drawText("\(title.uppercased()) · Page \(index) · \(total) identities",
                 at: CGRect(x: 40, y: pageHeight - 98, width: pageWidth - 80, height: 26),
                 size: 17, color: secondary, bold: false, alignment: .left)

        for (offset, image) in images.enumerated() {
            let col = offset % pageColumns
            let row = offset / pageColumns
            let left = marginX + CGFloat(col) * (tileWidth + horizontalGap)
            let top = marginTop + CGFloat(row) * (tileHeight + verticalGap)
            let bottom = CGFloat(pageHeight) - top - tileHeight
            let frame = CGRect(x: left, y: bottom, width: tileWidth, height: tileHeight)

            ctx.setFillColor(tile.cgColor)
            ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 10,
                               cornerHeight: 10, transform: nil))
            ctx.fillPath()
            ctx.setStrokeColor(border.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(1)
            ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 10,
                               cornerHeight: 10, transform: nil))
            ctx.strokePath()

            // These are the same Path objects as the SwiftUI runtime uses.
            drawIcon(image.2, in: CGRect(x: left + 18,
                                         y: bottom + 47, width: 91, height: 91),
                     context: ctx, color: ink, detail: secondary)
            drawIcon(image.2, in: CGRect(x: left + 141,
                                         y: bottom + 79, width: 29, height: 29),
                     context: ctx, color: ink, detail: secondary)

            drawText("BROWSER       TRACK",
                     at: CGRect(x: left + 9, y: bottom + 33,
                                width: 218, height: 17),
                     size: 10, color: secondary, bold: false, alignment: .center)
            drawText(image.1,
                     at: CGRect(x: left + 8, y: bottom + 7,
                                width: tileWidth - 16, height: 27),
                     size: 16, color: .white, bold: true, alignment: .center)

            // Identity key helps locate exact source cases.
            drawText(image.0,
                     at: CGRect(x: left + 195, y: bottom + 82,
                                width: 114, height: 24),
                     size: 10, color: secondary, bold: false, alignment: .right)
        }

        let footer = "Actual native Path artwork  ·  No AI-generated replacement images  ·  Full manifests in manifest.json"
        drawText(footer,
                 at: CGRect(x: 40, y: 14, width: pageWidth - 80, height: 22),
                 size: 13, color: secondary, bold: false, alignment: .center)

        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output)
    }

    private func drawIcon(
        _ art: InstrumentIconDrawing,
        in rect: CGRect,
        context: CGContext,
        color: NSColor,
        detail: NSColor
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        context.translateBy(x: rect.minX, y: rect.minY + rect.height)
        context.scaleBy(x: rect.width / 100, y: -rect.height / 100)
        context.setLineJoin(.round)
        context.setLineCap(.round)

        context.setFillColor(color.withAlphaComponent(0.12).cgColor)
        for shape in art.silhouettes {
            context.addPath(shape.cgPath)
            context.fillPath()
        }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(3.8)
        for shape in art.primary {
            context.addPath(shape.cgPath)
            context.strokePath()
        }
        context.setStrokeColor(detail.cgColor)
        context.setLineWidth(1.8)
        if rect.width >= 40 {
            for shape in art.details {
                context.addPath(shape.cgPath)
                context.strokePath()
            }
        } else {
            context.setLineWidth(3.0)
            for shape in art.compactDetails {
                context.addPath(shape.cgPath)
                context.strokePath()
            }
        }
    }

    private func drawText(
        _ value: String, at rect: CGRect, size: CGFloat,
        color: NSColor, bold: Bool, alignment: NSTextAlignment
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(
            in: rect,
            withAttributes: [
                .font: bold ? NSFont.boldSystemFont(ofSize: size)
                            : NSFont.systemFont(ofSize: size),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }
}
