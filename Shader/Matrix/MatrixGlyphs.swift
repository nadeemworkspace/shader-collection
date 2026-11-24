//
//  MatrixGlyphs.swift
//  Shader
//
//  The characters the rain is written in, and the atlas texture they're drawn into.
//

import UIKit
import CoreText

/// A set of characters the rain draws glyphs from, and how to draw them.
nonisolated struct MatrixScript: Sendable {
    let name: String
    let characters: String
    let fontName: String
    /// This character's ink is scaled to the glyph height; the rest keep their size
    /// relative to it.
    var sizeReference: Character = "H"
    /// Squeezes the glyphs sideways, keeping stroke widths.
    var widthScale: CGFloat = 1
    /// Extra weight, as a stroke around each glyph in percent of the font size.
    var stroke: CGFloat = 0
    /// How often glyphs come from this set, relative to the others.
    var weight = 1
}

nonisolated extension MatrixScript {
    /// The film's mix, as in the reference: mostly half-width katakana, then Latin
    /// capitals, digits and a few symbols.
    static let all: [MatrixScript] = [
        MatrixScript(name: "Katakana",
                     characters: "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲンガジズゼヅドブ",
                     fontName: "HiraMaruProN-W4", sizeReference: "ロ", widthScale: 0.7, stroke: 8, weight: 6),
        MatrixScript(name: "Latin", characters: "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
                     fontName: "CourierNewPS-BoldMT", widthScale: 0.85, stroke: 2.5, weight: 3),
        MatrixScript(name: "Digits", characters: "0123456789",
                     fontName: "CourierNewPS-BoldMT", widthScale: 0.85, stroke: 2.5, weight: 2),
        MatrixScript(name: "Symbols", characters: ":\"=*+<>¦",
                     fontName: "CourierNewPS-BoldMT", widthScale: 0.85, stroke: 2.5),
    ]

    fileprivate func font(size: CGFloat) -> UIFont {
        let descriptor = UIFontDescriptor(name: fontName, size: size)
            .withMatrix(CGAffineTransform(scaleX: widthScale, y: 1))
        return UIFont(descriptor: descriptor, size: size)
    }
}

/// Every glyph of a list of scripts, white on black in a grid of cells, one byte of
/// ink per texel. Characters no installed font can draw are left out.
nonisolated struct MatrixGlyphAtlas {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    let bytesPerRow: Int
    /// Size of a cell, in texels.
    let cellWidth: Int
    let cellHeight: Int
    /// Cells per row.
    let columns: Int
    /// Each script's cells, in the order the scripts were given. Some may be empty.
    let ranges: [Range<Int>]

    /// - Parameters:
    ///   - cellAspect: width over height of a cell, as on screen.
    ///   - glyphHeight: height of each script's reference glyph, as a share of the cell.
    init(scripts: [MatrixScript], cellAspect: CGFloat, glyphHeight: CGFloat, cellHeight: Int = 128, columns: Int = 16) {
        let cellWidth = Int((CGFloat(cellHeight) * cellAspect).rounded())
        let cell = CGSize(width: cellWidth, height: cellHeight)
        // Glyphs are centred on their ink and shrunk if needed to keep a margin, which
        // the mip levels blur into.
        let maxInk = CGSize(width: cell.width * 0.92, height: cell.height * 0.85)
        let white = CGColor(gray: 1, alpha: 1)

        func line(_ character: Character, _ script: MatrixScript, size: CGFloat) -> CTLine {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): script.font(size: size),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
                NSAttributedString.Key(kCTStrokeColorAttributeName as String): white,
                NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -script.stroke,
            ]
            return CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: attributes))
        }

        // Measured against this context; it's resized for drawing below.
        let probe = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!

        var lines: [(line: CTLine, stroke: CGFloat)] = []
        var ranges: [Range<Int>] = []
        for script in scripts {
            let start = lines.count
            // Size the font so the reference glyph's ink, stroke included, is
            // `glyphHeight` of the cell.
            let probeSize: CGFloat = 100
            let reference = CTLineGetImageBounds(line(script.sizeReference, script, size: probeSize), probe).height
                + probeSize * script.stroke / 100
            let size = reference > 0 ? probeSize * glyphHeight * cell.height / reference : probeSize
            for character in script.characters {
                let glyph = line(character, script, size: size)
                if Self.isDrawable(glyph) {
                    lines.append((glyph, size * script.stroke / 100))
                }
            }
            ranges.append(start..<lines.count)
        }

        let rows = max((lines.count + columns - 1) / columns, 1)
        let width = columns * cellWidth
        let height = rows * cellHeight
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { fatalError("Couldn't make the glyph atlas context") }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setLineJoin(.round)

        for (index, (line, stroke)) in lines.enumerated() {
            // Image bounds are measured from the text position, which drawing advances
            // (and saving the graphics state doesn't restore).
            context.textPosition = .zero
            let ink = CTLineGetImageBounds(line, context).insetBy(dx: -stroke / 2, dy: -stroke / 2)
            guard ink.width > 0, ink.height > 0 else { continue }
            let fit = min(1, maxInk.width / ink.width, maxInk.height / ink.height)
            // Core Graphics counts up from the bottom; the texture's first row is the top.
            let center = CGPoint(x: (CGFloat(index % columns) + 0.5) * cell.width,
                                 y: CGFloat(height) - (CGFloat(index / columns) + 0.5) * cell.height)
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: fit, y: fit)
            context.textPosition = CGPoint(x: -ink.midX, y: -ink.midY)
            CTLineDraw(line, context)
            context.restoreGState()
        }

        let bytesPerRow = context.bytesPerRow
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        pixels = Array(UnsafeBufferPointer(start: data, count: bytesPerRow * height))
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.columns = columns
        self.ranges = ranges
    }

    /// False when Core Text had to fall back to the last-resort font (a placeholder box).
    private static func isDrawable(_ line: CTLine) -> Bool {
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        guard !runs.isEmpty else { return false }
        return runs.allSatisfy { run in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName] else { return false }
            let font = value as! CTFont
            return !(CTFontCopyPostScriptName(font) as String).contains("LastResort")
        }
    }
}
