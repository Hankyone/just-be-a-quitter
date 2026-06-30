import SwiftUI

@main
struct AutoQuitBackgroundApp: App {
    static let appName = "Just Be a Quitter"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        Window(Self.appName, id: AppState.windowID) {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 860, minHeight: 680)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Show Settings") {
                    appState.showSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            CommandGroup(after: .appTermination) {
                Button("Quit Background Service") {
                    appState.quitApplication()
                }
                .keyboardShortcut("q", modifiers: [.command, .option])
            }
        }
    }
}
