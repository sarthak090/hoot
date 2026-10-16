import AppKit
import HootCore

/// Monochrome template images of Hoot for the menu bar (18x18pt with a @2x representation).
@MainActor
enum MenuBarIcon {
    private static let idle = make(alert: false)
    private static let alert = make(alert: true)

    static func image(alert isAlert: Bool) -> NSImage {
        isAlert ? alert : idle
    }

    private static func make(alert: Bool) -> NSImage {
        let points = 18
        let image = NSImage(size: NSSize(width: points, height: points))
        for scale in [1, 2] {
            guard let cg = HootRenderer.image(pixels: points * scale, style: .template,
                                              eyes: alert ? .wide : .normal, badge: alert) else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = NSSize(width: points, height: points)
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        image.accessibilityDescription = alert ? "Hoot: Claude needs you" : "Hoot"
        return image
    }
}
