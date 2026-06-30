import AppKit
@preconcurrency import ApplicationServices
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    static let windowID = "settings-window"

    @Published private(set) var trackedApps: [TrackedApp] = []
    @Published private(set) var installedApps: [InstalledAppInfo] = []
    @Published var manualBundleID = ""
    @Published var manualDisplayName = ""
    @Published private(set) var hasAccessibilityAccess = false
    @Published var monitoringEnabled = true {
        didSet {
            if monitoringEnabled != oldValue {
                persistState()
                refreshWatcher()
            }
        }
    }

    private let storageKey = "trackedApps"
    private let monitoringKey = "monitoringEnabled"
    private let monitorService = AppMonitorService()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var runningBundleIDs = Set<String>()
    private var libraryRefreshTask: Task<Void, Never>?

    private init() {
        loadState()
        registerWorkspaceObservers()
        refreshAccessibilityStatus(promptIfNeeded: false)
        refreshRunningApps()
        refreshInstalledApps()
        refreshWatcher()
    }

    func applicationDidFinishLaunching() {
        showSettingsWindow()
    }

    func showSettingsWindow() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == Self.windowID }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        for window in NSApp.windows where window.title == AutoQuitBackgroundApp.appName {
            window.identifier = NSUserInterfaceItemIdentifier(Self.windowID)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func quitApplication() {
        NSApp.terminate(nil)
    }

    func requestAccessibilityAccess() {
        refreshAccessibilityStatus(promptIfNeeded: true)
        refreshWatcher()
    }

    func recheckAccessibilityAccess() {
        refreshAccessibilityStatus(promptIfNeeded: false)
        refreshWatcher()
    }

    func refreshLibrary() {
        refreshRunningApps()
        refreshInstalledApps()
    }

    func refreshInstalledApps() {
        libraryRefreshTask?.cancel()
        libraryRefreshTask = Task {
            let scannedApps = await Task.detached(priority: .userInitiated) {
                ApplicationCatalog.scanInstalledApps()
            }.value

            guard Task.isCancelled == false else {
                return
            }

            installedApps = scannedApps.map { app in
                var app = app
                app.isRunning = runningBundleIDs.contains(app.bundleID)
                return app
            }
            .sorted(by: Self.installedAppSort(lhs:rhs:))
        }
    }

    func refreshRunningApps() {
        let ownBundleID = Bundle.main.bundleIdentifier

        runningBundleIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard app.activationPolicy == .regular,
                      let bundleID = app.bundleIdentifier,
                      bundleID != ownBundleID else {
                    return nil
                }

                return bundleID
            }
        )

        installedApps = installedApps.map { app in
            var app = app
            app.isRunning = runningBundleIDs.contains(app.bundleID)
            return app
        }
        .sorted(by: Self.installedAppSort(lhs:rhs:))
    }

    func addInstalledApp(_ installedApp: InstalledAppInfo) {
        addTrackedApp(
            bundleID: installedApp.bundleID,
            displayName: installedApp.displayName
        )
    }

    func addManualApp() {
        let bundleID = manualBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bundleID.isEmpty == false else {
            return
        }

        let displayName = manualDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        addTrackedApp(
            bundleID: bundleID,
            displayName: displayName.isEmpty ? bundleID : displayName
        )

        manualBundleID = ""
        manualDisplayName = ""
    }

    func isTracked(bundleID: String) -> Bool {
        trackedApps.contains(where: { $0.bundleID == bundleID })
    }

    func removeTrackedApp(bundleID: String) {
        trackedApps.removeAll { $0.bundleID == bundleID }
        persistState()
        refreshWatcher()
    }

    func setEnabled(_ isEnabled: Bool, for bundleID: String) {
        updateTrackedApp(bundleID: bundleID) { app in
            app.isEnabled = isEnabled
        }
    }

    func setQuitDelay(_ seconds: Double, for bundleID: String) {
        updateTrackedApp(bundleID: bundleID) { app in
            app.quitDelaySeconds = seconds
        }
    }

    func refreshAccessibilityStatus(promptIfNeeded: Bool) {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptIfNeeded
        ] as CFDictionary

        hasAccessibilityAccess = AXIsProcessTrustedWithOptions(options)
    }

    private func addTrackedApp(bundleID: String, displayName: String) {
        guard trackedApps.contains(where: { $0.bundleID == bundleID }) == false else {
            return
        }

        trackedApps.append(
            TrackedApp(
                bundleID: bundleID,
                displayName: displayName,
                isEnabled: true,
                quitDelaySeconds: 0.25
            )
        )

        trackedApps.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        persistState()
        refreshWatcher()
    }

    private func updateTrackedApp(bundleID: String, transform: (inout TrackedApp) -> Void) {
        guard let index = trackedApps.firstIndex(where: { $0.bundleID == bundleID }) else {
            return
        }

        transform(&trackedApps[index])
        persistState()
        refreshWatcher()
    }

    private func refreshWatcher() {
        monitorService.updateTrackedApps(
            trackedApps,
            monitoringEnabled: monitoringEnabled && hasAccessibilityAccess
        )
        monitorService.syncRunningApplications()
    }

    private func registerWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]

        workspaceObservers = names.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refreshRunningApps()
                    self.refreshWatcher()
                }
            }
        }
    }

    private func loadState() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([TrackedApp].self, from: data) {
            trackedApps = decoded
        }

        if UserDefaults.standard.object(forKey: monitoringKey) != nil {
            monitoringEnabled = UserDefaults.standard.bool(forKey: monitoringKey)
        }
    }

    private func persistState() {
        if let data = try? JSONEncoder().encode(trackedApps) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }

        UserDefaults.standard.set(monitoringEnabled, forKey: monitoringKey)
    }

    private static func installedAppSort(lhs: InstalledAppInfo, rhs: InstalledAppInfo) -> Bool {
        if lhs.isRunning != rhs.isRunning {
            return lhs.isRunning && rhs.isRunning == false
        }

        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
}
