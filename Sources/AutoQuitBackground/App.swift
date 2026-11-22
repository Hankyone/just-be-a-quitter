import AppKit
import SwiftUI

@main
@MainActor
enum JustBeAQuitter {
    static let appName = "Just Be a Quitter"

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsWindow = SettingsWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = Self.makeMainMenu()

        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            settingsWindow.writeSnapshot(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            exit(0)
        }

        let quietLaunch = CommandLine.arguments.contains("--background")
        let shouldShowWindow = BackgroundAgent.wasLaunchedByAgent == false && quietLaunch == false

        if let other = InstanceMessage.otherRunningInstance() {
            if BackgroundAgent.wasLaunchedByAgent {
                // launchd's copy always wins so crash recovery stays in place.
                InstanceMessage.yield.post()
                Self.waitForExit(of: other.processIdentifier)
            } else {
                InstanceMessage.showWindow.post()
                exit(0)
            }
        }

        let isInstalledApp = Bundle.main.bundlePath.hasSuffix(".app")
        if BackgroundAgent.wasLaunchedByAgent == false, isInstalledApp, BackgroundAgent.handOffToAgent(showWindow: quietLaunch == false) {
            exit(0)
        }

        listen(for: .showWindow) { [weak self] in self?.settingsWindow.show() }
        listen(for: .yield) { exit(0) }

        let appState = AppState.shared
        appState.start()

        if shouldShowWindow || BackgroundAgent.consumeShowRequest() || appState.needsAttention {
            settingsWindow.show()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return true
    }

    private func listen(for message: InstanceMessage, action: @escaping @MainActor () -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: message.name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
    }

    private static func waitForExit(of pid: pid_t) {
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0, Date() < deadline {
            usleep(50_000)
        }
    }

    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(JustBeAQuitter.appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(JustBeAQuitter.appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(withTitle: "Stop Watching and Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command, .option]
        mainMenu.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        mainMenu.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = fileMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu

        return mainMenu
    }
}

/// Owns the settings window. The SwiftUI view only exists while the window is open,
/// so the app does no UI work at all while it sits in the background.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = makeWindow()
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("SettingsWindow")
            self.window = window
        }

        AppState.shared.settingsWindowDidOpen()
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
        AppState.shared.settingsWindowDidClose()
        NSApp.setActivationPolicy(.accessory)
    }

    /// Renders the window offscreen to a PNG (used to check the UI without showing anything).
    func writeSnapshot(to url: URL) {
        AppState.shared.prepareForSnapshot()
        let window = makeWindow()
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        guard let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(
            rootView: ContentView().environmentObject(AppState.shared)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = JustBeAQuitter.appName
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 560))
        window.contentMinSize = NSSize(width: 560, height: 460)
        return window
    }
}
