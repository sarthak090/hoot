import AppKit
import SwiftUI

/// Layout constants shared by the menu-bar window, modelled on macOS's own
/// menu-bar extras (Wi-Fi, Focus, Control Center).
enum MenuMetrics {
    static let width: CGFloat = 360
    static let outerPadding: CGFloat = 12
    static let platterRadius: CGFloat = 10
    static let rowRadius: CGFloat = 6
}

/// Small grey section title, as in Control Center modules.
struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(verbatim: trailing).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Rounded, lightly filled group: the macOS "platter".
struct Platter: ViewModifier {
    var padding: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: MenuMetrics.platterRadius, style: .continuous))
    }
}

extension View {
    func platter(padding: CGFloat = 10) -> some View { modifier(Platter(padding: padding)) }
}

/// Full-width menu row ("Wi-Fi Settings…") with a hover highlight and an optional shortcut hint.
struct MenuRowStyle: ButtonStyle {
    var shortcut: String?

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, shortcut: shortcut)
    }

    private struct Row: View {
        let configuration: Configuration
        let shortcut: String?
        @State private var hovering = false

        var body: some View {
            HStack {
                configuration.label
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: MenuMetrics.rowRadius, style: .continuous)
                    .fill(hovering || configuration.isPressed ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear))
            )
            .onHover { hovering = $0 }
        }
    }
}

/// Inline notice: icon + text + optional action, on a tinted platter.
struct Banner: View {
    enum Kind { case warning, info }

    let kind: Kind
    let text: String
    var action: String?
    var perform: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(kind == .warning ? Color.orange : Color.secondary)
            Text(verbatim: text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action, let perform {
                Button(action, action: perform).controlSize(.small)
            }
        }
        .platter(padding: 8)
    }
}

/// Keeps the MenuBarExtra window exactly as tall as its content, without the content
/// ever jumping.
///
/// Two SwiftUI behaviours combine badly here: a `.window` MenuBarExtra grows with its
/// content but doesn't shrink, and it sizes the root view to its *ideal* size and centres
/// it in the window. So whenever content height changes (switching tabs, a card coming or
/// going) there were frames where the window was the old height and the content sat
/// centred in it: measured at ±187pt of vertical jump on a tab switch.
///
/// Fix: the root always reports the height the window *currently* has, with the real
/// content pinned to the top (padded or clipped for that moment). Then the window is resized
/// to the content's height (on the next run-loop turn: AppKit forbids resizing mid-layout),
/// and only after that does the root take the new height. Window and root never disagree,
/// so there is nothing to centre and nothing moves.
struct FitWindowToContent: ViewModifier {
    @State private var contentHeight: CGFloat = 0
    /// Content height the window has right now (nil until first sized).
    @State private var windowHeight: CGFloat?

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear
                    .preference(key: ContentHeightKey.self, value: proxy.size.height)
                    .onChange(of: proxy.frame(in: .global).minY) { _, top in
                        Log.ui.debug("menu content top offset \(top, format: .fixed(precision: 1)) height \(proxy.size.height, format: .fixed(precision: 1))")
                    }
            })
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            .frame(height: windowHeight ?? (contentHeight > 0 ? contentHeight : nil), alignment: .top)
            .clipped()
            .background(WindowHeightSetter(target: contentHeight) { applied in
                if windowHeight != applied { windowHeight = applied }
            })
    }

    private struct ContentHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    private struct WindowHeightSetter: NSViewRepresentable {
        let target: CGFloat
        let applied: (CGFloat) -> Void

        func makeNSView(context: Context) -> AttachWatcher { AttachWatcher() }

        func updateNSView(_ view: AttachWatcher, context: Context) {
            let target = target
            let applied = applied
            // Size the window the moment this view joins it (menu opening), before the first
            // frame is drawn, instead of one run-loop turn later.
            view.onAttach = { window in
                // Content not measured yet: let the next pass handle it rather than
                // adopting the window's stale height.
                guard target > 0 else { return }
                Self.resize(window, to: target)
                applied(window.contentRect(forFrameRect: window.frame).height)
            }
            // Next run-loop turn: the window exists, and AppKit isn't mid-layout.
            DispatchQueue.main.async {
                guard let window = view.window else { return }
                Self.resize(window, to: target)
                applied(window.contentRect(forFrameRect: window.frame).height)
            }
        }

        static func resize(_ window: NSWindow, to target: CGFloat) {
            guard target > 0 else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            guard abs(content.height - target) > 0.5 else { return }
            let pinnedTop = NSRect(x: content.minX, y: content.maxY - target, width: content.width, height: target)
            window.setFrame(window.frameRect(forContentRect: pinnedTop), display: false, animate: false)
        }
    }

    final class AttachWatcher: NSView {
        var onAttach: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onAttach?(window) }
        }
    }
}

extension View {
    func fitWindowToContent() -> some View { modifier(FitWindowToContent()) }
}

/// SF Symbol for a Claude Code tool.
enum ToolSymbol {
    static func name(for tool: String) -> String {
        switch tool {
        case "Bash": "terminal"
        case "Edit", "MultiEdit": "pencil"
        case "Write": "doc.badge.plus"
        case "NotebookEdit": "book"
        case "Read": "doc.text"
        case "Glob", "Grep", "LS": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        default: tool.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }
}
