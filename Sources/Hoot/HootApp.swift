import SwiftUI

@main
struct HootApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var welcomeWindow: NSWindow?
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if PreviewRenderer.runIfRequested(model: model) { return }
        // `kill`/logout send SIGTERM: quit normally so held hooks are released and the
        // socket is removed.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApplication.shared.terminate(nil) }
        source.resume()
        termSource = source
        model.start()
        if !model.settings.hasCompletedOnboarding {
            showWelcome()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    private func showWelcome() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to Hoot"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WelcomeView { [weak self] in
            self?.model.settings.hasCompletedOnboarding = true
            self?.welcomeWindow?.close()
            self?.welcomeWindow = nil
        }.environment(model))
        window.center()
        welcomeWindow = window
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// Hoot, optionally followed by plan usage left ("19%"), like the battery percentage.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let alert = model.attention.hasUnansweredAlert
        let mode = model.settings.menuBarUsage
        let text = model.limits.menuBarText(mode)
        let spoken = [alert ? "Hoot: Claude needs you" : "Hoot", model.limits.menuBarAccessibility(mode)]
            .compactMap { $0 }.joined(separator: ", ")
        HStack(spacing: 3) {
            Image(nsImage: MenuBarIcon.image(alert: alert))
            if let text {
                Text(verbatim: text).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}
