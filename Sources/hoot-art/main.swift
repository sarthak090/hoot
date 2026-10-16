import Foundation
import HootCore

// Usage:
//   hoot-art svg <dir>       write Hoot SVGs + menu-bar PNG previews (checked into Art/)
//   hoot-art iconset <dir>   write an AppIcon.iconset for iconutil

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func png(_ pixels: Int, _ style: HootRenderer.Style, _ eyes: HootEyes, badge: Bool = false, to url: URL) throws {
    guard let image = HootRenderer.image(pixels: pixels, style: style, eyes: eyes, badge: badge) else {
        fail("could not render \(url.lastPathComponent)")
    }
    try HootRenderer.writePNG(image, to: url)
}

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: hoot-art svg|iconset <dir>") }
let dir = URL(fileURLWithPath: args[2], isDirectory: true)

do {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    switch args[1] {
    case "svg":
        let svgs: [(String, String)] = [
            ("hoot.svg", HootRenderer.svg(style: .color(tile: false), eyes: .normal)),
            ("hoot-alert.svg", HootRenderer.svg(style: .color(tile: false), eyes: .wide)),
            ("app-icon.svg", HootRenderer.svg(style: .color(tile: true), eyes: .normal)),
            ("menubar-idle.svg", HootRenderer.svg(style: .template, eyes: .normal)),
            ("menubar-alert.svg", HootRenderer.svg(style: .template, eyes: .wide, badge: true)),
        ]
        for (name, text) in svgs {
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        for (scale, suffix) in [(1, ""), (2, "@2x")] {
            try png(18 * scale, .template, .normal, to: dir.appendingPathComponent("menubar-idle\(suffix).png"))
            try png(18 * scale, .template, .wide, badge: true, to: dir.appendingPathComponent("menubar-alert\(suffix).png"))
        }
        try png(512, .color(tile: true), .normal, to: dir.appendingPathComponent("app-icon-512.png"))
    case "iconset":
        for base in [16, 32, 128, 256, 512] {
            try png(base, .color(tile: true), .normal, to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
            try png(base * 2, .color(tile: true), .normal, to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
        }
    default:
        fail("unknown command \(args[1])")
    }
} catch {
    fail("hoot-art: \(error.localizedDescription)")
}
