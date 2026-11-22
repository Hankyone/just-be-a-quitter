import Foundation

enum ApplicationCatalog {
    static func scanInstalledApps() -> [InstalledAppInfo] {
        let fileManager = FileManager.default
        let ownBundleID = Bundle.main.bundleIdentifier
        var appsByBundleID: [String: InstalledAppInfo] = [:]

        for root in searchRoots(fileManager: fileManager) where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard url.pathExtension == "app" else {
                    // Only look one folder deep (e.g. /Applications/Utilities).
                    if enumerator.level >= 2 { enumerator.skipDescendants() }
                    continue
                }

                if let app = appInfo(at: url), app.bundleID != ownBundleID, appsByBundleID[app.bundleID] == nil {
                    appsByBundleID[app.bundleID] = app
                }
            }
        }

        return appsByBundleID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    static func appInfo(at url: URL) -> InstalledAppInfo? {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
            return nil
        }

        let displayName =
            (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String) ??
            (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ??
            (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ??
            url.deletingPathExtension().lastPathComponent

        return InstalledAppInfo(bundleID: bundleID, displayName: displayName, bundleURL: url)
    }

    private static func searchRoots(fileManager: FileManager) -> [URL] {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        var seen = Set<String>()
        return roots.filter { seen.insert($0.path).inserted }
    }
}
