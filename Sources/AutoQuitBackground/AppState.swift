import AppKit
@preconcurrency import ApplicationServices
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var trackedApps: [TrackedApp] = []
    @Published private(set) var installedApps: [InstalledAppInfo] = []
    @Published private(set) var runningBundleIDs: Set<String> = []
    @Published private(set) var recentQuits: [QuitEvent] = []
    @Published private(set) var hasAccessibilityAccess = false
    @Published private(set) var agentStatus: SMAppService.Status = .notRegistered
    @Published var monitoringEnabled = true {
        didSet {
            guard monitoringEnabled != oldValue else { return }
            UserDefaults.standard.set(monitoringEnabled, forKey: Self.monitoringKey)
            refreshWatcher()
        }
    }

    var needsAttention: Bool { hasAccessibilityAccess == false }

    private static let trackedAppsKey = "trackedApps"
    private static let monitoringKey = "monitoringEnabled"
    private static let maxRecentQuits = 8

    private let monitor = AppMonitorService()
    private var isWindowOpen = false
    private var windowObservers: [NSObjectProtocol] = []
    private var accessibilityPollTask: Task<Void, Never>?
    private var iconCache: [String: NSImage] = [:]

    private init() {
        loadState()
        monitor.onQuit = { [weak self] app in self?.recordQuit(of: app) }
    }

    // MARK: - Lifecycle

    func start() {
        refreshAccessibilityStatus()
        agentStatus = BackgroundAgent.status
        refreshWatcher()

        // macOS posts this whenever the Accessibility allow-list changes.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                self?.refreshAccessibilityStatus()
            }
        }
    }

    func settingsWindowDidOpen() {
        guard isWindowOpen == false else { return }
        isWindowOpen = true
        refreshAccessibilityStatus()
        agentStatus = BackgroundAgent.status
        refreshRunningApps()
        refreshInstalledApps()

        let center = NSWorkspace.shared.notificationCenter
        windowObservers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunningApps() }
            }
        }
    }

    func settingsWindowDidClose() {
        isWindowOpen = false
        windowObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        windowObservers = []
        installedApps = []
        iconCache = [:]
    }

    func prepareForSnapshot() {
        refreshAccessibilityStatus()
        agentStatus = BackgroundAgent.status
        refreshRunningApps()
        installedApps = ApplicationCatalog.scanInstalledApps()
    }

    func quitApplication() {
        NSApp.terminate(nil)
    }

    // MARK: - Permissions and login item

    func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        hasAccessibilityAccess = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshAccessibilityStatus()
    }

    func refreshAccessibilityStatus() {
        let trusted = AXIsProcessTrusted()
        if trusted != hasAccessibilityAccess {
            hasAccessibilityAccess = trusted
            refreshWatcher()
        }

        if trusted {
            accessibilityPollTask?.cancel()
            accessibilityPollTask = nil
        } else if accessibilityPollTask == nil {
            accessibilityPollTask = Task { [weak self] in
                while Task.isCancelled == false {
                    try? await Task.sleep(for: .seconds(2))
                    self?.refreshAccessibilityStatus()
                }
            }
        }
    }

    func enableBackgroundAgent() {
        BackgroundAgent.register()
        agentStatus = BackgroundAgent.status
        if agentStatus == .enabled, BackgroundAgent.wasLaunchedByAgent == false, BackgroundAgent.handOffToAgent() {
            exit(0)
        }
    }

    func openLoginItemsSettings() {
        BackgroundAgent.openLoginItemsSettings()
    }

    // MARK: - Tracked apps

    func isTracked(_ bundleID: String) -> Bool {
        trackedApps.contains { $0.bundleID == bundleID }
    }

    func isRunning(_ bundleID: String) -> Bool {
        runningBundleIDs.contains(bundleID)
    }

    func add(_ app: InstalledAppInfo) {
        guard isTracked(app.bundleID) == false else { return }
        trackedApps.append(TrackedApp(bundleID: app.bundleID, displayName: app.displayName))
        trackedApps.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        saveTrackedApps()
    }

    func addApp(at url: URL) {
        guard let app = ApplicationCatalog.appInfo(at: url) else { return }
        add(app)
    }

    func remove(bundleIDs: Set<String>) {
        trackedApps.removeAll { bundleIDs.contains($0.bundleID) }
        saveTrackedApps()
    }

    func setEnabled(_ isEnabled: Bool, for bundleID: String) {
        update(bundleID) { $0.isEnabled = isEnabled }
    }

    func setQuitDelay(_ seconds: Double, for bundleID: String) {
        update(bundleID) { $0.quitDelaySeconds = seconds }
    }

    func icon(for bundleID: String) -> NSImage {
        if let cached = iconCache[bundleID] { return cached }
        let icon: NSImage
        if let url = installedApps.first(where: { $0.bundleID == bundleID })?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSWorkspace.shared.icon(for: .applicationBundle)
        }
        iconCache[bundleID] = icon
        return icon
    }

    // MARK: - Private

    private func update(_ bundleID: String, transform: (inout TrackedApp) -> Void) {
        guard let index = trackedApps.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        transform(&trackedApps[index])
        saveTrackedApps()
    }

    private func recordQuit(of app: TrackedApp) {
        recentQuits.insert(QuitEvent(displayName: app.displayName, bundleID: app.bundleID, date: Date()), at: 0)
        if recentQuits.count > Self.maxRecentQuits {
            recentQuits.removeLast(recentQuits.count - Self.maxRecentQuits)
        }
    }

    private func refreshWatcher() {
        monitor.update(trackedApps: trackedApps, monitoringEnabled: monitoringEnabled && hasAccessibilityAccess)
    }

    private func refreshRunningApps() {
        runningBundleIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap { app in
                app.activationPolicy == .regular ? app.bundleIdentifier : nil
            }
        )
    }

    private func refreshInstalledApps() {
        Task {
            let apps = await Task.detached(priority: .userInitiated) {
                ApplicationCatalog.scanInstalledApps()
            }.value
            if isWindowOpen {
                installedApps = apps
            }
        }
    }

    private func loadState() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.trackedAppsKey),
           let decoded = try? JSONDecoder().decode([TrackedApp].self, from: data) {
            trackedApps = decoded
        }
        if defaults.object(forKey: Self.monitoringKey) != nil {
            monitoringEnabled = defaults.bool(forKey: Self.monitoringKey)
        }
    }

    private func saveTrackedApps() {
        if let data = try? JSONEncoder().encode(trackedApps) {
            UserDefaults.standard.set(data, forKey: Self.trackedAppsKey)
        }
        refreshWatcher()
    }
}
