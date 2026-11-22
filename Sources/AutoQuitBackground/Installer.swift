import AppKit

/// Handles first launch from the downloaded disk image and in-place updates.
@MainActor
enum Installer {
    private static let bundleURL = Bundle.main.bundleURL
    private static let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(bundleURL.lastPathComponent)

    static var isRunningFromDiskImage: Bool {
        let path = bundleURL.path
        return path.hasSuffix(".app") && (path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/"))
    }

    /// True when the copy on disk was replaced after `app` started, i.e. it's an older version.
    /// Uses the file's status-change time, which copying can't preserve.
    static func isOutdated(_ app: NSRunningApplication) -> Bool {
        guard let launchDate = app.launchDate,
              let executable = Bundle.main.executableURL,
              let modified = try? executable.resourceValues(forKeys: [.attributeModificationDateKey]).attributeModificationDate
        else {
            return false
        }
        return modified > launchDate
    }

    static func offerToMoveToApplications() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        let alert = NSAlert()
        alert.messageText = "Move to Applications?"
        alert.informativeText = "\(JustBeAQuitter.appName) runs in the background, so it needs to live in your Applications folder."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            // Ask a running older copy to step aside before replacing it.
            if InstanceMessage.otherRunningInstance() != nil {
                InstanceMessage.yield.post()
                Thread.sleep(forTimeInterval: 1)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            }
            try FileManager.default.copyItem(at: bundleURL, to: destination)
        } catch {
            let failure = NSAlert()
            failure.messageText = "Couldn't move the app"
            failure.informativeText = "Drag \(JustBeAQuitter.appName) into your Applications folder, then open it from there."
            failure.runModal()
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [destination.path]
        try? process.run()
        process.waitUntilExit()
    }
}
