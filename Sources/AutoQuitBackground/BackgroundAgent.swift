import AppKit
import ServiceManagement

/// Keeps the app running through a per-user launchd agent bundled in the app
/// (Contents/Library/LaunchAgents). launchd starts it at login and restarts it if it
/// ever crashes or is killed; choosing Quit exits cleanly, so it stays quit until next login.
@MainActor
enum BackgroundAgent {
    static let label = "com.hankyone.JustBeAQuitter.agent"
    static let launchArgument = "--launched-by-agent"

    private static let showOnLaunchKey = "showWindowOnNextLaunch"
    private static var service: SMAppService { .agent(plistName: "\(label).plist") }

    static var wasLaunchedByAgent: Bool {
        CommandLine.arguments.contains(launchArgument)
    }

    static var status: SMAppService.Status { service.status }

    /// Registers the agent if needed. Returns true when it is enabled.
    @discardableResult
    static func register() -> Bool {
        if service.status != .enabled {
            do {
                try service.register()
            } catch {
                NSLog("Just Be a Quitter: could not register launch agent: \(error)")
            }
        }
        return service.status == .enabled
    }

    /// Called from a copy the user launched by hand. Moves the app under launchd's care
    /// and asks the launchd copy to open its window. Returns false if this copy should keep running.
    static func handOffToAgent(showWindow: Bool = true) -> Bool {
        guard register() else { return false }

        UserDefaults.standard.set(showWindow, forKey: showOnLaunchKey)
        UserDefaults.standard.synchronize()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("Just Be a Quitter: kickstart failed: \(error)")
        }

        guard process.terminationStatus == 0 else {
            UserDefaults.standard.removeObject(forKey: showOnLaunchKey)
            return false
        }
        return true
    }

    /// True once if a hand-off asked this launch to show the window.
    static func consumeShowRequest() -> Bool {
        guard UserDefaults.standard.bool(forKey: showOnLaunchKey) else { return false }
        UserDefaults.standard.removeObject(forKey: showOnLaunchKey)
        return true
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Lets a second copy of the app talk to the one already running.
enum InstanceMessage: String {
    case showWindow = "com.hankyone.JustBeAQuitter.showWindow"
    case yield = "com.hankyone.JustBeAQuitter.yield"

    var name: Notification.Name { Notification.Name(rawValue) }

    func post() {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
    }

    static func otherRunningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != ownPID && $0.isTerminated == false }
    }
}
