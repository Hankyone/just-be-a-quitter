import Foundation

enum ApplicationCatalog {
    static func scanInstalledApps() -> [InstalledAppInfo] {
        let fileManager = FileManager.default
        let searchRoots = applicationSearchRoots(fileManager: fileManager)
        var appsByBundleID: [String: InstalledAppInfo] = [:]

        for root in searchRoots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }

            while let item = enumerator.nextObject() as? URL {
                guard item.pathExtension == "app" else {
                    continue
                }

                defer {
                    enumerator.skipDescendants()
                }

                guard let bundle = Bundle(url: item),
                      let bundleID = bundle.bundleIdentifier else {
                    continue
                }

                let displayName =
                    (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ??
                    (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ??
                    item.deletingPathExtension().lastPathComponent

                appsByBundleID[bundleID] = InstalledAppInfo(
                    bundleID: bundleID,
                    displayName: displayName,
                    bundleURL: item,
                    isRunning: false
                )
            }
        }

        return appsByBundleID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private static func applicationSearchRoots(fileManager: FileManager) -> [URL] {
        let explicitRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]

        let discoveredRoots =
            fileManager.urls(for: .applicationDirectory, in: .localDomainMask) +
            fileManager.urls(for: .applicationDirectory, in: .systemDomainMask) +
            fileManager.urls(for: .applicationDirectory, in: .userDomainMask)

        var seenPaths = Set<String>()
        return (explicitRoots + discoveredRoots).filter { url in
            seenPaths.insert(url.path).inserted
        }
    }
}
