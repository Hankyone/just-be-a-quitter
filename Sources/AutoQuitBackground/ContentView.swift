import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""

    private var filteredApps: [InstalledAppInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else {
            return appState.installedApps
        }

        return appState.installedApps.filter { app in
            app.displayName.localizedCaseInsensitiveContains(query) ||
            app.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    private var runningApps: [InstalledAppInfo] {
        filteredApps.filter(\.isRunning)
    }

    private var installedOnlyApps: [InstalledAppInfo] {
        filteredApps.filter { $0.isRunning == false }
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            Group {
                if appState.hasAccessibilityAccess {
                    mainView
                } else {
                    permissionGate
                }
            }
            .animation(.easeInOut(duration: 0.18), value: appState.hasAccessibilityAccess)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var permissionGate: some View {
        VStack {
            VStack(alignment: .leading, spacing: 18) {
                Text(AutoQuitBackgroundApp.appName)
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                Text("Grant Accessibility access once, then the app stays quietly in the background.")
                    .font(.title3.weight(.medium))

                VStack(alignment: .leading, spacing: 12) {
                    PermissionStep(
                        title: "Open the Accessibility settings",
                        detail: "macOS will jump to the right System Settings panel."
                    )
                    PermissionStep(
                        title: "Enable Just Be a Quitter",
                        detail: "Turn the switch on so the watcher can detect last-window changes."
                    )
                    PermissionStep(
                        title: "Return here and confirm",
                        detail: "As soon as permission is granted, this setup screen disappears."
                    )
                }
                .padding(.top, 4)

                HStack(spacing: 10) {
                    Button("Open Accessibility Access") {
                        appState.requestAccessibilityAccess()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Check Again") {
                        appState.recheckAccessibilityAccess()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Quit") {
                        appState.quitApplication()
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
            .background(panelBackground)
            .overlay(panelBorder)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var mainView: some View {
        VStack(spacing: 14) {
            topBar

            HStack(alignment: .top, spacing: 14) {
                trackedPane
                    .frame(width: 290)
                    .frame(maxHeight: .infinity)

                libraryPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AutoQuitBackgroundApp.appName)
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                Text("Watch selected apps and quit them when their last window closes.")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Toggle("Monitoring", isOn: $appState.monitoringEnabled)
                .toggleStyle(.switch)
                .fixedSize()

            Button("Refresh") {
                appState.refreshLibrary()
            }
            .buttonStyle(.bordered)

            Button("Quit") {
                appState.quitApplication()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("q", modifiers: [.command, .option])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(panelBackground)
        .overlay(panelBorder)
    }

    private var trackedPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            paneHeader(
                title: "Watching",
                subtitle: "Tracked apps and their quit delay."
            )

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if appState.trackedApps.isEmpty {
                        emptyState("No tracked apps yet.")
                    } else {
                        ForEach(appState.trackedApps) { trackedApp in
                            TrackedAppRow(
                                trackedApp: trackedApp,
                                onToggleEnabled: { appState.setEnabled($0, for: trackedApp.bundleID) },
                                onChangeDelay: { appState.setQuitDelay($0, for: trackedApp.bundleID) },
                                onRemove: { appState.removeTrackedApp(bundleID: trackedApp.bundleID) }
                            )
                        }
                    }

                    Divider()
                        .padding(.vertical, 4)

                    DisclosureGroup("Manual Bundle ID") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("com.apple.Preview", text: $appState.manualBundleID)
                                .textFieldStyle(.roundedBorder)

                            TextField("Display name (optional)", text: $appState.manualDisplayName)
                                .textFieldStyle(.roundedBorder)

                            Button("Add App") {
                                appState.addManualApp()
                            }
                            .buttonStyle(.bordered)
                            .disabled(appState.manualBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(12)
            }
            .scrollIndicators(.automatic)
        }
        .padding(12)
        .background(panelBackground)
        .overlay(panelBorder)
    }

    private var libraryPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                paneHeader(
                    title: "Applications",
                    subtitle: "Running apps first, then everything installed."
                )

                Spacer(minLength: 8)

                TextField("Search apps or bundle IDs", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if runningApps.isEmpty == false {
                        librarySection(title: "Running Now", apps: runningApps)
                    }

                    librarySection(
                        title: runningApps.isEmpty ? "All Applications" : "Installed",
                        apps: installedOnlyApps
                    )
                }
                .padding(12)
            }
            .scrollIndicators(.automatic)
        }
        .padding(12)
        .background(panelBackground)
        .overlay(panelBorder)
    }

    @ViewBuilder
    private func librarySection(title: String, apps: [InstalledAppInfo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)

                Spacer()

                Text("\(apps.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if apps.isEmpty {
                emptyState("No apps match the current search.")
            } else {
                ForEach(apps) { app in
                    AppLibraryRow(
                        app: app,
                        isTracked: appState.isTracked(bundleID: app.bundleID),
                        onAdd: { appState.addInstalledApp(app) }
                    )
                }
            }
        }
    }

    private func paneHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .underPageBackgroundColor))
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.black.opacity(0.08), lineWidth: 1)
    }
}

private struct PermissionStep: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)

            Text(detail)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct TrackedAppRow: View {
    let trackedApp: TrackedApp
    let onToggleEnabled: (Bool) -> Void
    let onChangeDelay: (Double) -> Void
    let onRemove: () -> Void

    private var delayLabel: String {
        if trackedApp.quitDelaySeconds == floor(trackedApp.quitDelaySeconds) {
            return "\(Int(trackedApp.quitDelaySeconds))s"
        }

        return String(format: "%.2gs", trackedApp.quitDelaySeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(trackedApp.displayName)
                        .font(.headline)
                        .lineLimit(1)

                    Text(trackedApp.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button("Remove", role: .destructive, action: onRemove)
                    .buttonStyle(.borderless)
            }

            HStack {
                Toggle("Enabled", isOn: Binding(
                    get: { trackedApp.isEnabled },
                    set: { onToggleEnabled($0) }
                ))
                .toggleStyle(.switch)

                Spacer()
            }

            HStack(spacing: 10) {
                Text("Delay")
                    .foregroundStyle(.secondary)

                Stepper(
                    value: Binding(
                        get: { trackedApp.quitDelaySeconds },
                        set: { onChangeDelay(min(max($0, 0), 5)) }
                    ),
                    in: 0 ... 5,
                    step: 0.25
                ) {
                    Text(delayLabel)
                        .monospacedDigit()
                }
            }
            .font(.subheadline)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct AppLibraryRow: View {
    let app: InstalledAppInfo
    let isTracked: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 28, height: 28)
                .cornerRadius(6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(app.displayName)
                        .font(.headline)
                        .lineLimit(1)

                    if app.isRunning {
                        Text("Running")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }

                Text(app.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isTracked {
                Text("Watching")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Button("Watch", action: onAdd)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }
}
