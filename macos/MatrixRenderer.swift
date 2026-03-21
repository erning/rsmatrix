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

    // Per-(font, color) draw buffers
    private struct BatchKey: Hashable {
        let fontPtr: UnsafeRawPointer
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    private var glyphBatches: [BatchKey: [CGGlyph]] = [:]
    private var pointBatches: [BatchKey: [CGPoint]] = [:]

    // Use ObjectIdentifier-like key for CTFont
    private struct FontKey: Hashable {
        let ptr: UnsafeRawPointer
        init(_ font: CTFont) {
            ptr = UnsafeRawPointer(Unmanaged.passUnretained(font as AnyObject).toOpaque())
        }
        init(ptr: UnsafeRawPointer) {
            self.ptr = ptr
        }
    }

    // Track all fonts we've seen for batch drawing
    private var knownFonts: [FontKey: (font: CTFont, ascent: CGFloat)] = [:]

    init(fontSize: CGFloat = 14) {
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

        guard let scalar = Unicode.Scalar(codepoint) else {
            let cached = CachedGlyph(glyph: 0, font: ctFont, ascent: ascent)
            glyphCache[codepoint] = cached
            return cached
        }

        // Encode as UTF-16 (current charset is BMP-only, no surrogate pairs)
        var utf16: [UniChar] = []
        UTF16.encode(scalar, into: { utf16.append($0) })

        var g = CGGlyph(0)

        // Try primary font first
        if CTFontGetGlyphsForCharacters(ctFont, &utf16, &g, utf16.count) {
            let cached = CachedGlyph(glyph: g, font: ctFont, ascent: ascent)
            glyphCache[codepoint] = cached
            return cached
        }

        // Font fallback: find a font that has this character
        let str = String(Character(scalar)) as CFString
        let range = CFRangeMake(0, CFStringGetLength(str))
        let fallbackFont = CTFontCreateForString(ctFont, str, range)
        let fallbackAscent = CTFontGetAscent(fallbackFont)

        CTFontGetGlyphsForCharacters(fallbackFont, &utf16, &g, utf16.count)

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
        for key in glyphBatches.keys {
            glyphBatches[key]!.removeAll(keepingCapacity: true)
            pointBatches[key]!.removeAll(keepingCapacity: true)
        }

        // Collect glyphs into (font, color) buckets
        let totalHeight = CGFloat(height) * cellSize.height
        for row in 0 ..< height {
            for col in 0 ..< width {
                let idx = Int(row) * Int(width) + Int(col)
                let cell = grid[idx]

                if cell.r == 0 && cell.g == 0 && cell.b == 0 {
                    continue
                }

                let info = resolveGlyph(for: cell.codepoint)
                let fontPtr = UnsafeRawPointer(
                    Unmanaged.passUnretained(info.font as AnyObject).toOpaque()
                )
                let batchKey = BatchKey(fontPtr: fontPtr, r: cell.r, g: cell.g, b: cell.b)

                if glyphBatches[batchKey] == nil {
                    glyphBatches[batchKey] = []
                    pointBatches[batchKey] = []
                }

                let x = CGFloat(col) * cellSize.width
                let y = totalHeight - CGFloat(row + 1) * cellSize.height + info.ascent

                glyphBatches[batchKey]!.append(info.glyph)
                pointBatches[batchKey]!.append(CGPoint(x: x, y: y))
            }
        }

        // Draw all batches
        context.saveGState()
        context.translateBy(x: 0, y: totalHeight)
        context.scaleBy(x: 1, y: -1)
        context.setTextDrawingMode(.fill)

        for (batchKey, glyphs) in glyphBatches {
            if glyphs.isEmpty { continue }

            // Look up the font for this batch
            let fontKey = FontKey(ptr: batchKey.fontPtr)
            guard let fontInfo = knownFonts[fontKey] else { continue }

            context.setFillColor(
                red: CGFloat(batchKey.r) / 255.0,
                green: CGFloat(batchKey.g) / 255.0,
                blue: CGFloat(batchKey.b) / 255.0,
                alpha: 1
            )
            CTFontDrawGlyphs(fontInfo.font, glyphs, pointBatches[batchKey]!, glyphs.count, context)
        }

        context.restoreGState()
    }
}
