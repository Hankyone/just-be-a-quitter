import AppKit
@preconcurrency import ApplicationServices

/// Watches tracked apps through the Accessibility API and quits one once its last window is gone.
@MainActor
final class AppMonitorService {
    private final class ObserverContext: @unchecked Sendable {
        weak var service: AppMonitorService?
        let pid: pid_t

        init(service: AppMonitorService, pid: pid_t) {
            self.service = service
            self.pid = pid
        }
    }

    private struct ObservedApp {
        let runningApplication: NSRunningApplication
        let applicationElement: AXUIElement
        let observer: AXObserver
        let context: ObserverContext
        var trackedApp: TrackedApp
        /// Only quit apps we've seen with a window, so slow launches and
        /// intentionally windowless apps are left alone.
        var hasSeenWindow = false
        var failedChecks = 0
        var evaluationTask: Task<Void, Never>?
        var quitTask: Task<Void, Never>?
    }

    private enum WindowState {
        case hasWindows
        case noWindows
        case unknown
    }

    private static let evaluationDebounce: Duration = .milliseconds(150)
    private static let retryDelay: Duration = .seconds(1)
    private static let maxFailedChecks = 5

    private static let appNotifications: [CFString] = [
        kAXWindowCreatedNotification as CFString,
        kAXUIElementDestroyedNotification as CFString,
        kAXFocusedWindowChangedNotification as CFString,
        kAXMainWindowChangedNotification as CFString
    ]

    private let callback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let context = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
        let name = notification as String
        nonisolated(unsafe) let element = element
        // Observer sources are added to the main run loop, so we are already on the main thread.
        MainActor.assumeIsolated {
            context.service?.handle(notification: name, element: element, pid: context.pid)
        }
    }

    var onQuit: ((TrackedApp) -> Void)?

    private var trackedAppsByBundleID: [String: TrackedApp] = [:]
    private var observedApps: [pid_t: ObservedApp] = [:]
    private var isMonitoringEnabled = false
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.attachIfTracked(app) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                MainActor.assumeIsolated { self?.removeObservedApp(for: pid) }
            }
        ]
    }

    func update(trackedApps: [TrackedApp], monitoringEnabled: Bool) {
        trackedAppsByBundleID = Dictionary(trackedApps.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        isMonitoringEnabled = monitoringEnabled

        guard monitoringEnabled else {
            observedApps.keys.forEach(removeObservedApp(for:))
            return
        }

        for (pid, observedApp) in observedApps {
            if let trackedApp = enabledTrackedApp(for: observedApp.runningApplication) {
                observedApps[pid]?.trackedApp = trackedApp
            } else {
                removeObservedApp(for: pid)
            }
        }

        NSWorkspace.shared.runningApplications.forEach(attachIfTracked)
    }

    // MARK: - Observation

    private func enabledTrackedApp(for app: NSRunningApplication) -> TrackedApp? {
        guard let bundleID = app.bundleIdentifier,
              let trackedApp = trackedAppsByBundleID[bundleID],
              trackedApp.isEnabled else {
            return nil
        }
        return trackedApp
    }

    private func attachIfTracked(_ app: NSRunningApplication) {
        guard isMonitoringEnabled,
              observedApps[app.processIdentifier] == nil,
              app.isTerminated == false,
              let trackedApp = enabledTrackedApp(for: app) else {
            return
        }

        let pid = app.processIdentifier
        var createdObserver: AXObserver?
        guard AXObserverCreate(pid, callback, &createdObserver) == .success, let observer = createdObserver else {
            return
        }

        let applicationElement = AXUIElementCreateApplication(pid)
        let context = ObserverContext(service: self, pid: pid)
        let refcon = Unmanaged.passUnretained(context).toOpaque()

        for notification in Self.appNotifications {
            AXObserverAddNotification(observer, applicationElement, notification, refcon)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        observedApps[pid] = ObservedApp(
            runningApplication: app,
            applicationElement: applicationElement,
            observer: observer,
            context: context,
            trackedApp: trackedApp
        )

        if let windows = copyWindows(of: applicationElement) {
            windows.forEach { watchForDestruction(of: $0, pid: pid) }
        }

        scheduleEvaluation(for: pid)
    }

    private func removeObservedApp(for pid: pid_t) {
        guard let observedApp = observedApps.removeValue(forKey: pid) else { return }
        observedApp.evaluationTask?.cancel()
        observedApp.quitTask?.cancel()
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observedApp.observer), .defaultMode)
    }

    private func handle(notification: String, element: AXUIElement, pid: pid_t) {
        guard observedApps[pid] != nil else { return }

        if notification == kAXWindowCreatedNotification as String {
            watchForDestruction(of: element, pid: pid)
        }

        scheduleEvaluation(for: pid)
    }

    /// Destruction notifications are only reliable when registered on the window itself.
    private func watchForDestruction(of window: AXUIElement, pid: pid_t) {
        guard let observedApp = observedApps[pid] else { return }
        let refcon = Unmanaged.passUnretained(observedApp.context).toOpaque()
        AXObserverAddNotification(observedApp.observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
    }

    // MARK: - Evaluation

    private func scheduleEvaluation(for pid: pid_t, after delay: Duration = evaluationDebounce) {
        guard observedApps[pid] != nil else { return }
        observedApps[pid]?.evaluationTask?.cancel()
        observedApps[pid]?.evaluationTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard Task.isCancelled == false else { return }
            self?.evaluate(pid: pid)
        }
    }

    private func evaluate(pid: pid_t) {
        guard var observedApp = observedApps[pid] else { return }

        guard observedApp.runningApplication.isTerminated == false else {
            removeObservedApp(for: pid)
            return
        }

        switch windowState(of: observedApp.applicationElement) {
        case .hasWindows:
            observedApp.hasSeenWindow = true
            observedApp.failedChecks = 0
            observedApp.quitTask?.cancel()
            observedApp.quitTask = nil

        case .noWindows:
            observedApp.failedChecks = 0
            if observedApp.hasSeenWindow, observedApp.quitTask == nil {
                let delay = observedApp.trackedApp.quitDelaySeconds
                observedApp.quitTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard Task.isCancelled == false else { return }
                    self?.quitIfStillWindowless(pid: pid)
                }
            }

        case .unknown:
            // The app is busy or not answering. Never quit on a guess; look again shortly.
            observedApp.failedChecks += 1
            observedApps[pid] = observedApp
            if observedApp.failedChecks <= Self.maxFailedChecks {
                scheduleEvaluation(for: pid, after: Self.retryDelay)
            }
            return
        }

        observedApps[pid] = observedApp
    }

    private func quitIfStillWindowless(pid: pid_t) {
        guard let observedApp = observedApps[pid] else { return }
        observedApps[pid]?.quitTask = nil

        guard windowState(of: observedApp.applicationElement) == .noWindows,
              WindowServer.hasWindowOnAnotherSpace(pid: pid) == false else {
            return
        }

        if observedApp.runningApplication.terminate() {
            onQuit?(observedApp.trackedApp)
        }
    }

    // MARK: - Accessibility queries

    private func windowState(of applicationElement: AXUIElement) -> WindowState {
        guard let windows = copyWindows(of: applicationElement) else { return .unknown }
        return windows.contains(where: isRealWindow) ? .hasWindows : .noWindows
    }

    private func copyWindows(of applicationElement: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &value)

        switch result {
        case .success:
            return value as? [AXUIElement] ?? []
        case .noValue:
            return []
        default:
            return nil
        }
    }

    private func isRealWindow(_ window: AXUIElement) -> Bool {
        if let role = stringValue(of: window, attribute: kAXRoleAttribute), role != kAXWindowRole {
            return false
        }
        if let subrole = stringValue(of: window, attribute: kAXSubroleAttribute), subrole == kAXUnknownSubrole {
            return false
        }
        return true
    }

    private func stringValue(of element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
