import AppKit
import SwiftUI

/// Developer aid: `Hoot.app/Contents/MacOS/Hoot --render-preview /tmp/hoot.png [--with-sample | --sample-limits | --demo]`
/// (`--demo` uses only invented data, for screenshots you publish).
/// renders the dropdown off-screen in light and dark mode (…-light.png / …-dark.png)
/// and exits. Starts only the usage reader: no hook server, no notifications.
@MainActor
enum PreviewRenderer {
    static func runIfRequested(model: AppModel) -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-preview"), i + 1 < args.count else { return false }
        let base = URL(fileURLWithPath: args[i + 1]).deletingPathExtension().path
        let demo = args.contains("--demo")
        model.demoMode = demo
        if demo {
            // Nothing real: invented usage, request and limits (for public screenshots).
            model.usage.setDemoSample()
        } else {
            model.usage.start()
        }
        if demo || args.contains("--with-sample") { model.attention.addPreviewSample() }
        if demo || args.contains("--with-sample") || args.contains("--sample-limits") { model.limits.setPreviewSample() }
        Task {
            for _ in 0..<100 where model.usage.summary == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            // Render each tab; restore the user's remembered tab afterwards.
            let savedTab = UserDefaults.standard.string(forKey: "menuTab")
            for (tab, (appearance, suffix)) in [("activity", (NSAppearance.Name.aqua, "activity-light")), ("activity", (.darkAqua, "activity-dark")),
                                                ("usage", (.aqua, "usage-light")), ("usage", (.darkAqua, "usage-dark"))] {
                UserDefaults.standard.set(tab, forKey: "menuTab")
                // The menu jumps to Activity while a request waits; drop the sample before Usage.
                if tab == "usage" { model.attention.releaseAll() }
                // A real (off-screen) AppKit window, so native controls and scroll views render.
                let host = NSHostingView(rootView: MenuContentView().environment(model)
                    .background(Color(nsColor: .windowBackgroundColor)))
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(x: 0, y: 0, width: 360, height: 400)
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(300))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.backgroundColor = appearance == .darkAqua ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.95, alpha: 1)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(300))
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "\(base)-\(suffix).png"))
                }
            }
            // Explicit, not `defer`: exit() would skip it.
            UserDefaults.standard.set(savedTab, forKey: "menuTab")
            exit(0)
        }
        return true
    }
}
