import AppKit

class MatrixRenderer {
    let font: NSFont
    let cellSize: CGSize

    // Cached attribute dictionaries for the four possible colors
    let attrsGreen: [NSAttributedString.Key: Any]
    let attrsLime: [NSAttributedString.Key: Any]
    let attrsSilver: [NSAttributedString.Key: Any]
    let attrsWhite: [NSAttributedString.Key: Any]

    init(isPreview: Bool = false) {
        let fontSize: CGFloat = isPreview ? 6 : 14
        font = NSFont(name: "Menlo", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        // Measure cell size from a reference character
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = NSAttributedString(string: "W", attributes: attrs).size()
        cellSize = CGSize(width: ceil(size.width), height: ceil(size.height))

        // Pre-build attribute dictionaries for the four colors used by the simulation
        let green = NSColor(red: 0, green: 170.0 / 255.0, blue: 0, alpha: 1)
        let lime = NSColor(red: 85.0 / 255.0, green: 1, blue: 85.0 / 255.0, alpha: 1)
        let silver = NSColor(red: 170.0 / 255.0, green: 170.0 / 255.0, blue: 170.0 / 255.0, alpha: 1)
        let white = NSColor.white

        attrsGreen = [.font: font, .foregroundColor: green]
        attrsLime = [.font: font, .foregroundColor: lime]
        attrsSilver = [.font: font, .foregroundColor: silver]
        attrsWhite = [.font: font, .foregroundColor: white]
    }

    func render(
        context _: CGContext,
        grid: UnsafePointer<RsMatrixCell>,
        width: UInt32,
        height: UInt32,
        bounds _: CGRect
    ) {
        for row in 0 ..< height {
            for col in 0 ..< width {
                let idx = Int(row) * Int(width) + Int(col)
                let cell = grid[idx]

                // Skip blank cells (space with black color)
                if cell.codepoint == 0x20 && cell.r == 0 && cell.g == 0 && cell.b == 0 {
                    continue
                }

                guard let scalar = Unicode.Scalar(cell.codepoint) else { continue }
                let ch = String(Character(scalar))

                let attrs: [NSAttributedString.Key: Any]
                switch (cell.r, cell.g, cell.b) {
                case (0, 0xAA, 0): attrs = attrsGreen
                case (0x55, 0xFF, 0x55): attrs = attrsLime
                case (0xAA, 0xAA, 0xAA): attrs = attrsSilver
                case (0xFF, 0xFF, 0xFF): attrs = attrsWhite
                default: continue
                }

                let x = CGFloat(col) * cellSize.width
                let y = CGFloat(row) * cellSize.height

                NSAttributedString(string: ch, attributes: attrs)
                    .draw(at: NSPoint(x: x, y: y))
            }
        }
    }
}
