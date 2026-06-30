import AppKit

struct TrackedApp: Codable, Identifiable, Equatable {
    var bundleID: String
    var displayName: String
    var isEnabled: Bool
    var quitDelaySeconds: Double

    var id: String { bundleID }

    init(bundleID: String, displayName: String, isEnabled: Bool, quitDelaySeconds: Double) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.quitDelaySeconds = quitDelaySeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        displayName = try container.decode(String.self, forKey: .displayName)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)

        if let doubleValue = try? container.decode(Double.self, forKey: .quitDelaySeconds) {
            quitDelaySeconds = doubleValue
        } else if let intValue = try? container.decode(Int.self, forKey: .quitDelaySeconds) {
            quitDelaySeconds = Double(intValue)
        } else {
            quitDelaySeconds = 0.25
        }
    }
}

struct InstalledAppInfo: Identifiable, Equatable {
    var bundleID: String
    var displayName: String
    var bundleURL: URL
    var isRunning: Bool

    var id: String { bundleID }

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: bundleURL.path)
    }
}
