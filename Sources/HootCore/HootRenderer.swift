import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws Hoot with CoreGraphics (PNG, menu-bar template) or as SVG text.
public enum HootRenderer {
    public enum Style: Sendable {
        /// Full color, optionally on the rounded app-icon tile.
        case color(tile: Bool)
        /// Black-on-transparent for an NSImage template.
        case template
    }

    // Geometry of the macOS app-icon grid, as fractions of the canvas (824pt tile in 1024pt).
    static let tileInset = 100.0 / 1024
    static let tileCornerRadius = 185.0 / 824
    static let owlInTile = 648.0 / 1024

    // Notification badge (template only), in grid units.
    static let badgeCenter = (x: 15.0, y: 3.0)
    static let badgeRadius = 2.6
    static let badgeGap = 1.0

    public static func image(pixels: Int, style: Style, eyes: HootEyes, badge: Bool = false) -> CGImage? {
        guard pixels > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let side = Double(pixels)
        // Top-left origin so rows read the same as the grid strings.
        ctx.translateBy(x: 0, y: side)
        ctx.scaleBy(x: 1, y: -1)

        var owlOrigin = 0.0
        var owlSide = side
        if case .color(tile: true) = style {
            drawTile(in: ctx, side: side)
            owlSide = side * owlInTile
            owlOrigin = (side - owlSide) / 2
        }

        let cell = owlSide / Double(HootArt.size)
        for (r, row) in HootArt.grid(eyes: eyes).enumerated() {
            for (c, px) in row.enumerated() {
                let color: RGBA?
                switch style {
                case .template: color = px.isFilledInTemplate ? RGBA(hex: 0x000000) : nil
                case .color: color = HootPalette.color(for: px)
                }
                guard let color else { continue }
                ctx.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a))
                // Snap cell edges to whole pixels so adjacent cells never leave seams.
                let x0 = (owlOrigin + Double(c) * cell).rounded()
                let y0 = (owlOrigin + Double(r) * cell).rounded()
                let x1 = (owlOrigin + Double(c + 1) * cell).rounded()
                let y1 = (owlOrigin + Double(r + 1) * cell).rounded()
                ctx.fill(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            }
        }

        if badge {
            let cx = owlOrigin + badgeCenter.x * cell
            let cy = owlOrigin + badgeCenter.y * cell
            let clearR = (badgeRadius + badgeGap) * cell
            let dotR = badgeRadius * cell
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: cx - clearR, y: cy - clearR, width: clearR * 2, height: clearR * 2))
            ctx.setBlendMode(.normal)
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2))
        }
        return ctx.makeImage()
    }

    private static func drawTile(in ctx: CGContext, side: Double) {
        let inset = side * tileInset
        let tileSide = side - inset * 2
        let rect = CGRect(x: inset, y: inset, width: tileSide, height: tileSide)
        let radius = tileSide * tileCornerRadius
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        let top = HootPalette.backgroundTop, bottom = HootPalette.backgroundBottom
        let colors = [
            CGColor(srgbRed: top.r, green: top.g, blue: top.b, alpha: 1),
            CGColor(srgbRed: bottom.r, green: bottom.g, blue: bottom.b, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        }
        ctx.restoreGState()
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    /// Hand-assembled SVG: one rect per horizontal run of same-colored cells.
    public static func svg(style: Style, eyes: HootEyes, badge: Bool = false) -> String {
        let tile: Bool
        if case .color(tile: true) = style { tile = true } else { tile = false }
        let canvas = tile ? 1024.0 : Double(HootArt.size)
        let owlSide = tile ? canvas * owlInTile : canvas
        let origin = (canvas - owlSide) / 2
        let cell = owlSide / Double(HootArt.size)

        var out = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(fmt(canvas)) \(fmt(canvas))" width="\(fmt(canvas))" height="\(fmt(canvas))" shape-rendering="crispEdges">
        <title>Hoot</title>

        """
        if tile {
            let inset = canvas * tileInset, s = canvas - inset * 2
            out += """
            <defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">\
            <stop offset="0" stop-color="\(hex(HootPalette.backgroundTop))"/>\
            <stop offset="1" stop-color="\(hex(HootPalette.backgroundBottom))"/></linearGradient></defs>
            <rect x="\(fmt(inset))" y="\(fmt(inset))" width="\(fmt(s))" height="\(fmt(s))" rx="\(fmt(s * tileCornerRadius))" fill="url(#bg)" shape-rendering="geometricPrecision"/>

            """
        }
        if badge {
            out += "<mask id=\"cut\"><rect width=\"100%\" height=\"100%\" fill=\"white\"/>"
            out += "<circle cx=\"\(fmt(origin + badgeCenter.x * cell))\" cy=\"\(fmt(origin + badgeCenter.y * cell))\" r=\"\(fmt((badgeRadius + badgeGap) * cell))\" fill=\"black\"/></mask>\n<g mask=\"url(#cut)\">\n"
        }
        for (r, row) in HootArt.grid(eyes: eyes).enumerated() {
            var c = 0
            while c < row.count {
                let fill = svgFill(row[c], style: style)
                var end = c + 1
                while end < row.count, svgFill(row[end], style: style) == fill { end += 1 }
                if let fill {
                    out += "<rect x=\"\(fmt(origin + Double(c) * cell))\" y=\"\(fmt(origin + Double(r) * cell))\" width=\"\(fmt(Double(end - c) * cell))\" height=\"\(fmt(cell))\" fill=\"\(fill)\"/>\n"
                }
                c = end
            }
        }
        if badge {
            out += "</g>\n<circle cx=\"\(fmt(origin + badgeCenter.x * cell))\" cy=\"\(fmt(origin + badgeCenter.y * cell))\" r=\"\(fmt(badgeRadius * cell))\" fill=\"#000\" shape-rendering=\"geometricPrecision\"/>\n"
        }
        return out + "</svg>\n"
    }

    private static func svgFill(_ px: HootPixel, style: Style) -> String? {
        switch style {
        case .template: px.isFilledInTemplate ? "#000" : nil
        case .color: HootPalette.color(for: px).map(hex)
        }
    }

    private static func hex(_ c: RGBA) -> String {
        String(format: "#%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }

    private static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
}
