import AppKit
@preconcurrency import ApplicationServices

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
        let trackedApp: TrackedApp
        var pendingEvaluation: DispatchWorkItem?
        var pendingQuit: DispatchWorkItem?
        var preferredFocusApp: NSRunningApplication?
    }

    private let callback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let context = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
        let pid = context.pid
        weak var service = context.service
        Task { @MainActor in
            service?.scheduleEvaluation(for: pid)
        }
    }

    private var trackedAppsByBundleID: [String: TrackedApp] = [:]
    private var observedApps: [pid_t: ObservedApp] = [:]
    private(set) var isMonitoringEnabled = false

    func updateTrackedApps(_ trackedApps: [TrackedApp], monitoringEnabled: Bool) {
        trackedAppsByBundleID = Dictionary(uniqueKeysWithValues: trackedApps.map { ($0.bundleID, $0) })
        isMonitoringEnabled = monitoringEnabled

        if monitoringEnabled {
            syncRunningApplications()
        } else {
            stopMonitoring()
        }
    }

    func syncRunningApplications() {
        guard isMonitoringEnabled else { return }

        let runningTrackedApps = Set(
            NSWorkspace.shared.runningApplications
                .filter { app in
                    guard let bundleID = app.bundleIdentifier else {
                        return false
                    }

                    return trackedAppsByBundleID[bundleID]?.isEnabled == true
                }
                .map(\.processIdentifier)
        )

        for pid in observedApps.keys where !runningTrackedApps.contains(pid) {
            removeObservedApp(for: pid)
        }

        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  let trackedApp = trackedAppsByBundleID[bundleID],
                  trackedApp.isEnabled else {
                continue
            }

            guard observedApps[app.processIdentifier] == nil else {
                continue
            }

            attachObserver(to: app, trackedApp: trackedApp)
        }
    }

    func stopMonitoring() {
        for pid in Array(observedApps.keys) {
            removeObservedApp(for: pid)
        }
    }

    private func attachObserver(to app: NSRunningApplication, trackedApp: TrackedApp) {
        let pid = app.processIdentifier
        var observer: AXObserver?
        let result = AXObserverCreate(pid, callback, &observer)

        guard result == .success, let observer else {
            return
        }

        let applicationElement = AXUIElementCreateApplication(pid)
        let context = ObserverContext(service: self, pid: pid)
        let refcon = Unmanaged.passUnretained(context).toOpaque()

        let notifications: [CFString] = [
            kAXWindowCreatedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString,
            kAXWindowMiniaturizedNotification as CFString,
            kAXWindowDeminiaturizedNotification as CFString,
            kAXMainWindowChangedNotification as CFString,
            kAXFocusedWindowChangedNotification as CFString
        ]

        for notification in notifications {
            AXObserverAddNotification(observer, applicationElement, notification, refcon)
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        observedApps[pid] = ObservedApp(
            runningApplication: app,
            applicationElement: applicationElement,
            observer: observer,
            context: context,
            trackedApp: trackedApp
        )

        scheduleEvaluation(for: pid)
    }

    private func removeObservedApp(for pid: pid_t) {
        guard let observedApp = observedApps.removeValue(forKey: pid) else {
            return
        }

        observedApp.pendingEvaluation?.cancel()
        observedApp.pendingQuit?.cancel()

        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observedApp.observer),
            .defaultMode
        )
    }

    private func scheduleEvaluation(for pid: pid_t) {
        guard var observedApp = observedApps[pid] else {
            return
        }

        observedApp.pendingEvaluation?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.evaluateObservedApp(for: pid)
            }
        }

        observedApp.pendingEvaluation = workItem
        observedApps[pid] = observedApp

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func evaluateObservedApp(for pid: pid_t) {
        guard var observedApp = observedApps[pid] else {
            return
        }

        guard observedApp.runningApplication.isTerminated == false else {
            removeObservedApp(for: pid)
            return
        }

        let windowCount = qualifyingWindowCount(for: observedApp.applicationElement)

        if windowCount == 0 {
            if observedApp.pendingQuit == nil {
                let quitDelay = TimeInterval(observedApp.trackedApp.quitDelaySeconds)
                observedApp.preferredFocusApp = NSWorkspace.shared.frontmostApplication
                let workItem = DispatchWorkItem { [weak self] in
                    Task { @MainActor in
                        self?.terminateIfStillWindowless(pid: pid)
                    }
                }

                observedApp.pendingQuit = workItem
                observedApps[pid] = observedApp
                DispatchQueue.main.asyncAfter(deadline: .now() + quitDelay, execute: workItem)
            } else {
                observedApps[pid] = observedApp
            }
        } else {
            observedApp.pendingQuit?.cancel()
            observedApp.pendingQuit = nil
            observedApps[pid] = observedApp
        }
    }

    private func terminateIfStillWindowless(pid: pid_t) {
        guard var observedApp = observedApps[pid] else {
            return
        }

        observedApp.pendingQuit = nil
        observedApps[pid] = observedApp

        guard qualifyingWindowCount(for: observedApp.applicationElement) == 0 else {
            return
        }

        let preferredFocusApp = observedApp.preferredFocusApp
        observedApp.runningApplication.terminate()

        guard let preferredFocusApp,
              preferredFocusApp.processIdentifier != pid else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard preferredFocusApp.isTerminated == false else {
                return
            }

            preferredFocusApp.activate()
        }
    }

    private func qualifyingWindowCount(for applicationElement: AXUIElement) -> Int {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &value
        )

        guard result == .success, let windows = value as? [AXUIElement] else {
            return 0
        }

        return windows.filter(shouldCountWindow(_:)).count
    }

    private func shouldCountWindow(_ window: AXUIElement) -> Bool {
        if let role = stringValue(for: window, attribute: kAXRoleAttribute as CFString),
           role != kAXWindowRole as String {
            return false
        }

        if let subrole = stringValue(for: window, attribute: kAXSubroleAttribute as CFString),
           subrole == kAXUnknownSubrole as String {
            return false
        }

        return true
    }

    private func stringValue(for element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)

        guard result == .success, let value else {
            return nil
        }

        return value as? String
    }
}
