import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
                .padding(.horizontal, 20)
                .padding(.top, 34)
                .padding(.bottom, 14)

            if appState.hasAccessibilityAccess {
                WatchListView()
                Divider()
                FooterView()
            } else {
                PermissionView()
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .ignoresSafeArea(edges: .top)
        .background(.background)
        .animation(.easeInOut(duration: 0.2), value: appState.hasAccessibilityAccess)
    }
}

// MARK: - Header

private struct HeaderView: View {
    @EnvironmentObject private var appState: AppState

    private var status: (text: String, color: Color) {
        if appState.hasAccessibilityAccess == false {
            return ("Needs Accessibility access", .orange)
        }
        if appState.monitoringEnabled == false {
            return ("Paused", .secondary)
        }
        let count = appState.trackedApps.filter(\.isEnabled).count
        if count == 0 {
            return ("Add an app to get started", .secondary)
        }
        return ("Watching \(count) app\(count == 1 ? "" : "s")", .green)
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(JustBeAQuitter.appName)
                    .font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.color)
                        .frame(width: 7, height: 7)
                    Text(status.text)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            Spacer()

            if appState.hasAccessibilityAccess {
                Toggle("Watching", isOn: $appState.monitoringEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(appState.monitoringEnabled ? "Pause quitting apps" : "Resume quitting apps")
            }
        }
    }
}

// MARK: - Watch list

private struct WatchListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection = Set<String>()
    @State private var isAddingApps = false

    var body: some View {
        VStack(spacing: 0) {
            Text("Quit these apps when their last window closes")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            Table(appState.trackedApps, selection: $selection) {
                TableColumn("App") { app in
                    HStack(spacing: 8) {
                        Image(nsImage: appState.icon(for: app.bundleID))
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(app.displayName)
                            .foregroundStyle(app.isEnabled ? .primary : .secondary)
                            .lineLimit(1)
                        if appState.isRunning(app.bundleID) {
                            Text("Open")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    .help(app.bundleID)
                }

                TableColumn("Quit") { app in
                    Picker("Quit", selection: Binding(
                        get: { app.quitDelaySeconds },
                        set: { appState.setQuitDelay($0, for: app.bundleID) }
                    )) {
                        ForEach(TrackedApp.delayOptions, id: \.self) { seconds in
                            Text(TrackedApp.label(forDelay: seconds)).tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .disabled(app.isEnabled == false)
                }
                .width(min: 110, ideal: 120, max: 140)

                TableColumn("On") { app in
                    Toggle("On", isOn: Binding(
                        get: { app.isEnabled },
                        set: { appState.setEnabled($0, for: app.bundleID) }
                    ))
                    .labelsHidden()
                }
                .width(32)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Stop Watching") { appState.remove(bundleIDs: ids) }
            }
            .onDeleteCommand { removeSelection() }
            .overlay {
                if appState.trackedApps.isEmpty {
                    ContentUnavailableView {
                        Label("No apps yet", systemImage: "macwindow.badge.plus")
                    } description: {
                        Text("Add apps like Preview or QuickTime Player and they'll quit when you close their last window.")
                    } actions: {
                        Button("Add Apps…") { isAddingApps = true }
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    isAddingApps = true
                } label: {
                    Label("Add Apps", systemImage: "plus")
                }
                .popover(isPresented: $isAddingApps, arrowEdge: .bottom) {
                    AddAppsView()
                        .environmentObject(appState)
                }

                Button {
                    removeSelection()
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selection.isEmpty)

                Spacer()
            }
            .controlSize(.regular)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func removeSelection() {
        appState.remove(bundleIDs: selection)
        selection = []
    }
}

// MARK: - Add apps popover

private struct AddAppsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query = ""

    private var matches: [InstalledAppInfo] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard query.isEmpty == false else { return appState.installedApps }
        return appState.installedApps.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let running = matches.filter { appState.isRunning($0.bundleID) }
        let others = matches.filter { appState.isRunning($0.bundleID) == false }

        VStack(spacing: 0) {
            TextField("Search apps", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)

            Divider()

            if appState.installedApps.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if running.isEmpty == false {
                        Section("Open now") { rows(running) }
                    }
                    Section(running.isEmpty ? "Apps" : "Other apps") { rows(others) }
                }
                .listStyle(.sidebar)
            }

            Divider()

            HStack {
                Button("Choose Other App…", action: chooseApp)
                Spacer()
            }
            .padding(10)
        }
        .frame(width: 340, height: 440)
    }

    @ViewBuilder
    private func rows(_ apps: [InstalledAppInfo]) -> some View {
        ForEach(apps) { app in
            let isTracked = appState.isTracked(app.bundleID)
            Button {
                if isTracked {
                    appState.remove(bundleIDs: [app.bundleID])
                } else {
                    appState.add(app)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(nsImage: appState.icon(for: app.bundleID))
                        .resizable()
                        .frame(width: 20, height: 20)
                    Text(app.displayName)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: isTracked ? "checkmark.circle.fill" : "plus.circle")
                        .foregroundStyle(isTracked ? Color.accentColor : Color.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(app.bundleID)
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Watch"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(appState.addApp(at:))
    }
}

// MARK: - Footer

private struct FooterView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            agentStatus
            Spacer(minLength: 12)
            lastQuit
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var agentStatus: some View {
        switch appState.agentStatus {
        case .enabled:
            Label("Starts at login", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
                .help("Runs in the background, opens at login and restarts itself if it ever stops unexpectedly.")
        case .requiresApproval:
            Label("Allow in Login Items to start at login", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Button("Open Settings") { appState.openLoginItemsSettings() }
                .controlSize(.small)
        default:
            Label("Doesn't start at login", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Button("Turn On") { appState.enableBackgroundAgent() }
                .controlSize(.small)
        }

        Button("Quit…") { confirmQuit() }
            .controlSize(.small)
            .buttonStyle(.link)
            .foregroundStyle(.secondary)
            .help("Stop watching until you open the app again or log in")
    }

    @ViewBuilder
    private var lastQuit: some View {
        if let event = appState.recentQuits.first {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text("Quit \(event.displayName) \(Self.relative(event.date, now: context.date))")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help(appState.recentQuits.map { "\($0.displayName) at \($0.date.formatted(date: .omitted, time: .shortened))" }.joined(separator: "\n"))
        }
    }

    private static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private func confirmQuit() {
        let alert = NSAlert()
        alert.messageText = "Stop watching apps?"
        alert.informativeText = "Apps won't quit on their own until you open \(JustBeAQuitter.appName) again or log in."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            appState.quitApplication()
        }
    }
}

// MARK: - Permission

private struct PermissionView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "hand.raised.square.on.square")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("Allow Accessibility access")
                    .font(.title3.weight(.semibold))
                Text("It's how the app sees when an app's last window closes. Turn on \(JustBeAQuitter.appName) in System Settings → Privacy & Security → Accessibility.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 380)
            }

            Button("Open System Settings") { appState.requestAccessibilityAccess() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for access…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
