import AppKit

struct TrackedApp: Codable, Identifiable, Equatable {
    var bundleID: String
    var displayName: String
    var isEnabled: Bool
    var quitDelaySeconds: Double

    var id: String { bundleID }

    /// Delay choices offered in the UI. The shortest still leaves a beat for apps that
    /// briefly close and reopen a window (e.g. switching documents).
    static let delayOptions: [Double] = [0.25, 1, 3, 5, 10, 30, 60]
    static let defaultDelay: Double = 1

    static func label(forDelay seconds: Double) -> String {
        switch seconds {
        case ..<0.5: "Right away"
        case 60...: "After \(Int(seconds / 60)) min"
        default: "After \(Int(seconds)) s"
        }
    }

    static func nearestDelayOption(to seconds: Double) -> Double {
        delayOptions.min(by: { abs($0 - seconds) < abs($1 - seconds) }) ?? defaultDelay
    }

    init(bundleID: String, displayName: String, isEnabled: Bool = true, quitDelaySeconds: Double = defaultDelay) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.quitDelaySeconds = quitDelaySeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        displayName = try container.decode(String.self, forKey: .displayName)
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? true
        let storedDelay = (try? container.decode(Double.self, forKey: .quitDelaySeconds)) ?? Self.defaultDelay
        quitDelaySeconds = Self.nearestDelayOption(to: storedDelay)
    }
}

struct InstalledAppInfo: Identifiable, Equatable, Sendable {
    var bundleID: String
    var displayName: String
    var bundleURL: URL

    var id: String { bundleID }
}

struct QuitEvent: Identifiable, Equatable {
    let id = UUID()
    let displayName: String
    let bundleID: String
    let date: Date
}
