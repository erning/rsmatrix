import AppKit
import CoreText

/// CoreText-based renderer using CTFontDrawGlyphs for batch drawing.
/// Handles font fallback for characters not in the primary font (e.g. katakana in Menlo).
class MatrixRenderer {
    let font: NSFont
    let cellSize: CGSize
    let ctFont: CTFont
    let ascent: CGFloat

    // Glyph cache: codepoint → (glyph, font, ascent)
    // Stores the resolved font per glyph for fallback support
    private var glyphCache: [UInt32: CachedGlyph] = [:]

    private struct CachedGlyph {
        let glyph: CGGlyph
        let font: CTFont
        let ascent: CGFloat
    }

    // Per-(font, color) draw buffers, keyed by font pointer identity
    // Inner arrays: [color_index] → (glyphs, points)
    private var drawBatches: [FontKey: [[CGGlyph]]] = [:]
    private var pointBatches: [FontKey: [[CGPoint]]] = [:]

    // Use ObjectIdentifier-like key for CTFont
    private struct FontKey: Hashable {
        let ptr: UnsafeRawPointer
        init(_ font: CTFont) {
            ptr = UnsafeRawPointer(Unmanaged.passUnretained(font as AnyObject).toOpaque())
        }
    }

    // Track all fonts we've seen for batch drawing
    private var knownFonts: [FontKey: (font: CTFont, ascent: CGFloat)] = [:]

    init(isPreview: Bool = false) {
        let fontSize: CGFloat = isPreview ? 6 : 14
        font = NSFont(name: "Menlo", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = NSAttributedString(string: "W", attributes: attrs).size()
        cellSize = CGSize(width: ceil(size.width), height: ceil(size.height))

        ctFont = font as CTFont
        ascent = CTFontGetAscent(ctFont)

        let key = FontKey(ctFont)
        knownFonts[key] = (ctFont, ascent)
    }

    private func resolveGlyph(for codepoint: UInt32) -> CachedGlyph {
        if let cached = glyphCache[codepoint] {
            return cached
        }

        var unichar = UniChar(codepoint)
        var g = CGGlyph(0)

        // Try primary font first
        if CTFontGetGlyphsForCharacters(ctFont, &unichar, &g, 1) {
            let cached = CachedGlyph(glyph: g, font: ctFont, ascent: ascent)
            glyphCache[codepoint] = cached
            return cached
        }

        // Font fallback: find a font that has this character
        guard let scalar = Unicode.Scalar(codepoint) else {
            let cached = CachedGlyph(glyph: 0, font: ctFont, ascent: ascent)
            glyphCache[codepoint] = cached
            return cached
        }
        let str = String(Character(scalar)) as CFString
        let range = CFRangeMake(0, 1)
        let fallbackFont = CTFontCreateForString(ctFont, str, range)
        let fallbackAscent = CTFontGetAscent(fallbackFont)

        CTFontGetGlyphsForCharacters(fallbackFont, &unichar, &g, 1)

        let key = FontKey(fallbackFont)
        knownFonts[key] = (fallbackFont, fallbackAscent)

        let cached = CachedGlyph(glyph: g, font: fallbackFont, ascent: fallbackAscent)
        glyphCache[codepoint] = cached
        return cached
    }

    func render(
        context: CGContext,
        grid: UnsafePointer<RsMatrixCell>,
        width: UInt32,
        height: UInt32
    ) {
        // Reset batches
        for key in drawBatches.keys {
            for i in 0..<4 {
                drawBatches[key]![i].removeAll(keepingCapacity: true)
                pointBatches[key]![i].removeAll(keepingCapacity: true)
            }
        }

        // Collect glyphs into (font, color) buckets
        for row in 0 ..< height {
            for col in 0 ..< width {
                let idx = Int(row) * Int(width) + Int(col)
                let cell = grid[idx]

                if cell.r == 0 && cell.g == 0 && cell.b == 0 {
                    continue
                }

                let colorIdx: Int
                switch (cell.r, cell.g, cell.b) {
                case (0, 0xAA, 0):       colorIdx = 0
                case (0x55, 0xFF, 0x55): colorIdx = 1
                case (0xAA, 0xAA, 0xAA): colorIdx = 2
                case (0xFF, 0xFF, 0xFF): colorIdx = 3
                default: continue
                }

                let info = resolveGlyph(for: cell.codepoint)
                let key = FontKey(info.font)

                // Ensure batch arrays exist for this font
                if drawBatches[key] == nil {
                    drawBatches[key] = [[], [], [], []]
                    pointBatches[key] = [[], [], [], []]
                }

                let x = CGFloat(col) * cellSize.width
                let y = CGFloat(row) * cellSize.height + info.ascent

                drawBatches[key]![colorIdx].append(info.glyph)
                pointBatches[key]![colorIdx].append(CGPoint(x: x, y: y))
            }
        }

        // Draw all batches
        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (0, 170.0/255.0, 0),             // green
            (85.0/255.0, 1, 85.0/255.0),     // lime
            (170.0/255.0, 170.0/255.0, 170.0/255.0), // silver
            (1, 1, 1),                         // white
        ]

        context.saveGState()
        context.setTextDrawingMode(.fill)

        for (key, fontInfo) in knownFonts {
            guard let glyphArrays = drawBatches[key],
                  let pointArrays = pointBatches[key] else { continue }

            for colorIdx in 0..<4 {
                let glyphs = glyphArrays[colorIdx]
                if glyphs.isEmpty { continue }

                let (r, g, b) = colors[colorIdx]
                context.setFillColor(red: r, green: g, blue: b, alpha: 1)
                CTFontDrawGlyphs(fontInfo.font, glyphs, pointArrays[colorIdx], glyphs.count, context)
            }
        }

        context.restoreGState()
    }
}
