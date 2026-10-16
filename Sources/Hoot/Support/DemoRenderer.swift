import AppKit
import HootCore
import SwiftUI

/// Developer aid for the README/landing-page video:
/// `Hoot.app/Contents/MacOS/Hoot --render-demo <dir>` writes one PNG per scene, then exits.
///
/// Every scene uses invented data. The Hoot parts (menu, cards, bars, icon) are the real
/// app views; the desktop around them (menu bar, windows, notification) is drawn here.
@MainActor
enum DemoRenderer {
    static let size = CGSize(width: 1440, height: 900)

    enum Desktop {
        case calm, waiting, allowed, question, plan
    }

    struct Scene {
        let name: String
        var title = false
        var ending = false
        var desktop = Desktop.calm
        var notification = false
        var menu: MenuTab?
        var highlightMenuBar = false
        /// > 1 zooms into the top-right corner (drawn enlarged, so text stays sharp).
        var zoom: CGFloat = 1
        var caption: String
        var setup: @MainActor (AppModel) -> Void = { _ in }
    }

    static let scenes: [Scene] = [
        Scene(name: "01-title", title: true, caption: ""),
        Scene(name: "02-away", desktop: .calm,
              caption: "Claude Code is working in your terminal. You're somewhere else."),
        Scene(name: "03-notified", desktop: .waiting, notification: true,
              caption: "Claude needs permission, so Hoot lets you know.",
              setup: { $0.attention.addDemoSample(.bash) }),
        Scene(name: "04-card", desktop: .waiting, menu: .activity,
              caption: "See exactly what will run. Allow once, always allow, or deny with a reason.",
              setup: { $0.attention.addDemoSample(.bash) }),
        Scene(name: "05-allowed", desktop: .allowed, menu: .activity,
              caption: "Answer from the menu bar, and the terminal carries on by itself.",
              setup: { m in
                  m.attention.addDemoRecent(project: "my-app", text: "Claude wants to use Bash: git push --force-with-lease origin main",
                                            isPermission: true, minutesAgo: 0)
                  m.attention.addDemoRecent(project: "api-server", text: "Claude is waiting for your input",
                                            isPermission: false, minutesAgo: 14)
              }),
        Scene(name: "06-question", desktop: .question, menu: .activity,
              caption: "Claude has a question? Pick an answer, or type your own.",
              setup: { $0.attention.addDemoSample(.question, answered: true) }),
        Scene(name: "07-plan", desktop: .plan, menu: .activity,
              caption: "Review a plan. Approve it, or send it back with feedback.",
              setup: { $0.attention.addDemoSample(.plan) }),
        Scene(name: "08-usage", desktop: .calm, menu: .usage,
              caption: "Your session and weekly limits, and token usage, at a glance."),
        Scene(name: "09-menubar", desktop: .calm, highlightMenuBar: true,
              caption: "Or just glance at the menu bar: session usage, right next to Hoot."),
        Scene(name: "09b-menubar-zoom", desktop: .calm, highlightMenuBar: true, zoom: 3.4,
              caption: "Session usage, right next to Hoot."),
        Scene(name: "10-end", ending: true, caption: ""),
    ]

    static func runIfRequested(model: AppModel) -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-demo"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        model.demoMode = true
        model.usage.setDemoSample()
        model.limits.setPreviewSample()
        let savedTab = UserDefaults.standard.string(forKey: "menuTab")
        Task {
            for scene in scenes {
                model.attention.clearForDemo()
                scene.setup(model)
                if model.attention.recent.isEmpty {
                    model.attention.addDemoRecent(project: "api-server", text: "Claude is waiting for your input",
                                                  isPermission: false, minutesAgo: 14)
                    model.attention.addDemoRecent(project: "docs-site", text: "Claude wants to use Edit: README.md",
                                                  isPermission: true, minutesAgo: 32)
                }
                if let tab = scene.menu { UserDefaults.standard.set(tab.rawValue, forKey: "menuTab") }
                await render(DemoSceneView(scene: scene).environment(model), to: dir.appendingPathComponent("\(scene.name).png"))
            }
            // Explicit, not `defer`: exit() would skip it.
            UserDefaults.standard.set(savedTab, forKey: "menuTab")
            exit(0)
        }
        return true
    }

    private static func render(_ view: some View, to url: URL) async {
        let host = NSHostingView(rootView: view.environment(\.fitsWindowToContent, false))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(450))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

// MARK: - Scene

private struct DemoSceneView: View {
    @Environment(AppModel.self) private var model
    let scene: DemoRenderer.Scene

    var body: some View {
        ZStack(alignment: .topLeading) {
            Wallpaper()
            if scene.title {
                TitleCard()
            } else if scene.ending {
                EndCard()
            } else {
                desktop
                    .scaleEffect(scene.zoom, anchor: .topTrailing)
                if scene.zoom > 1, !scene.caption.isEmpty {
                    Caption(text: scene.caption)
                        .frame(width: DemoRenderer.size.width)
                        .offset(y: DemoRenderer.size.height - 112)
                }
            }
        }
        .frame(width: DemoRenderer.size.width, height: DemoRenderer.size.height)
        .clipped()
    }

    private var desktop: some View {
        ZStack(alignment: .topLeading) {
            TerminalWindow(state: scene.desktop)
                .offset(x: 70, y: 110)
            BrowserWindow()
                .offset(x: 430, y: 210)
            MenuBarStrip(alert: model.attention.hasUnansweredAlert,
                         percent: model.limits.menuBarText(.session), highlight: scene.highlightMenuBar)
            if scene.notification {
                NotificationBanner()
                    .offset(x: DemoRenderer.size.width - 392, y: 34)
            }
            if scene.menu != nil {
                MenuContentView()
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
                    .offset(x: DemoRenderer.size.width - 360 - 14, y: 30)
            }
            if !scene.caption.isEmpty, scene.zoom == 1 {
                Caption(text: scene.caption)
                    .frame(width: DemoRenderer.size.width)
                    .offset(y: DemoRenderer.size.height - 112)
            }
        }
    }
}

private struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.33, blue: 0.47), Color(red: 0.30, green: 0.24, blue: 0.46)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.50, green: 0.82, blue: 0.78).opacity(0.35), .clear],
                           center: .init(x: 0.2, y: 0.85), startRadius: 10, endRadius: 700)
        }
    }
}

private struct MenuBarStrip: View {
    let alert: Bool
    let percent: String?
    let highlight: Bool

    var body: some View {
        HStack(spacing: 18) {
            Text("Browser").fontWeight(.semibold)
            Text("File")
            Text("Edit")
            Text("View")
            Spacer()
            HStack(spacing: 4) {
                Image(nsImage: MenuBarIcon.image(alert: alert))
                    .renderingMode(.template)
                if let percent { Text(verbatim: percent).monospacedDigit() }
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background {
                if highlight {
                    RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.28))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(red: 1, green: 0.8, blue: 0.3), lineWidth: 2))
                        .shadow(color: Color(red: 1, green: 0.8, blue: 0.3).opacity(0.8), radius: 8)
                }
            }
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            // Real time, so it agrees with the times in Recent and the reset times.
            Text(Date(), format: .dateTime.weekday(.abbreviated).hour().minute())
        }
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(width: DemoRenderer.size.width, height: 26)
        .background(.black.opacity(0.22))
    }
}

private struct WindowChrome<Content: View>: View {
    let title: String
    let dark: Bool
    let size: CGSize
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 12, height: 12)
                Spacer()
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(dark ? .white.opacity(0.75) : .black.opacity(0.65))
                Spacer()
                Color.clear.frame(width: 52, height: 12)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(dark ? Color(white: 0.17) : Color(white: 0.93))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(dark ? Color(white: 0.11) : .white)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
    }
}

private struct TerminalWindow: View {
    let state: DemoRenderer.Desktop

    private var lines: [(String, Color)] {
        let dim = Color.white.opacity(0.55), text = Color.white.opacity(0.92)
        let accent = Color(red: 0.95, green: 0.62, blue: 0.40), ok = Color(red: 0.45, green: 0.85, blue: 0.5)
        var l: [(String, Color)] = [
            ("~/my-app $ claude", dim),
            ("> Rebase the feature branch on main and push it", text),
            ("", text),
            ("● Rebased onto main (3 commits).", text),
            ("● Now I'll push the branch.", text),
        ]
        switch state {
        case .calm:
            break
        case .waiting:
            l += [("", text), ("  Bash(git push --force-with-lease origin main)", accent), ("", text),
                  ("  Do you want to proceed?", text), ("  ❯ 1. Yes", text), ("    2. No", text)]
        case .allowed:
            l += [("  Bash(git push --force-with-lease origin main)", accent), ("  ⎿ Pushed main → origin", ok), ("", text),
                  ("● Done. The branch is rebased and pushed.", text)]
        case .question:
            l = [("~/api-server $ claude", dim), ("> Add persistence to the API", text), ("", text),
                 ("● Before I start: which database should the API use?", text), ("  (waiting for your answer)", dim)]
        case .plan:
            l = [("~/api-server $ claude --permission-mode plan", dim), ("> Add rate limiting to login", text), ("", text),
                 ("● Plan ready: Add rate limiting (4 steps).", text), ("  Waiting for approval.", dim)]
        }
        return l
    }

    var body: some View {
        WindowChrome(title: state == .question || state == .plan ? "api-server: claude" : "my-app: claude", dark: true,
                     size: CGSize(width: 700, height: 470)) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line.0.isEmpty ? " " : line.0).foregroundStyle(line.1)
                }
            }
            .font(.system(size: 14, design: .monospaced))
            .padding(18)
        }
    }
}

private struct BrowserWindow: View {
    var body: some View {
        WindowChrome(title: "Docs: Getting Started", dark: false, size: CGSize(width: 860, height: 540)) {
            VStack(alignment: .leading, spacing: 14) {
                RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.94)).frame(height: 30)
                RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.30)).frame(width: 380, height: 26)
                ForEach(0..<9, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.85))
                        .frame(width: [700, 660, 720, 520, 690, 600, 710, 430, 640][i], height: 11)
                }
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.86, green: 0.92, blue: 0.98)).frame(height: 110)
                    RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.93, green: 0.90, blue: 0.98)).frame(height: 110)
                }
            }
            .padding(24)
        }
    }
}

private struct NotificationBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: AppIconImage.image).resizable().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text("my-app").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("now").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text("Claude wants to use Bash").font(.system(size: 13))
                Text("git push --force-with-lease origin main").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(12)
        .frame(width: 378)
        .background(Color(white: 0.97).opacity(0.97), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
    }
}

private struct Caption: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28).padding(.vertical, 14)
            .background(.black.opacity(0.62), in: Capsule())
            .frame(maxWidth: 1100)
    }
}

private struct TitleCard: View {
    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: AppIconImage.image).resizable().frame(width: 180, height: 180)
            Text("Hoot").font(.system(size: 76, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text("A menu-bar owl for Claude Code").font(.system(size: 32, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            Text("Demo with sample data").font(.system(size: 18)).foregroundStyle(.white.opacity(0.6)).padding(.top, 8)
        }
        .frame(width: DemoRenderer.size.width, height: DemoRenderer.size.height)
    }
}

private struct EndCard: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: AppIconImage.image).resizable().frame(width: 140, height: 140)
            Text("Hoot is free and open source").font(.system(size: 50, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text("github.com/sarthak090/hoot").font(.system(size: 30, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.92))
            Text("macOS 14+ · MIT license · Unofficial, not affiliated with Anthropic")
                .font(.system(size: 18)).foregroundStyle(.white.opacity(0.6)).padding(.top, 10)
        }
        .frame(width: DemoRenderer.size.width, height: DemoRenderer.size.height)
    }
}

@MainActor
enum AppIconImage {
    static let image: NSImage = {
        guard let cg = HootRenderer.image(pixels: 512, style: .color(tile: true), eyes: .normal) else { return NSImage() }
        return NSImage(cgImage: cg, size: NSSize(width: 512, height: 512))
    }()
}
