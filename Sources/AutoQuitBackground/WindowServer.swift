import AppKit

/// The Accessibility API only reports windows on the Space the user is looking at.
/// Before quitting an app, ask the window server whether it still owns a real window
/// parked on another Space (or full-screen Space), so we never quit it out from under the user.
@MainActor
enum WindowServer {
    private typealias ConnectionFunction = @convention(c) () -> Int32
    private typealias CopySpacesFunction = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let allSpacesMask: Int32 = 0x7
    private static let minimumWindowSide: Double = 100

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static let connectionID: Int32? = {
        guard let symbol = dlsym(skyLight, "SLSMainConnectionID") else { return nil }
        return unsafeBitCast(symbol, to: ConnectionFunction.self)()
    }()

    private static let copySpacesForWindows: CopySpacesFunction? = {
        guard let symbol = dlsym(skyLight, "SLSCopySpacesForWindows") else { return nil }
        return unsafeBitCast(symbol, to: CopySpacesFunction.self)
    }()

    /// True when `pid` owns a normal-sized, off-screen window that is assigned to a Space.
    /// Closed-but-retained windows have no Space, so they don't count.
    static func hasWindowOnAnotherSpace(pid: pid_t) -> Bool {
        guard let connectionID, let copySpacesForWindows,
              let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return false
        }

        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowIsOnscreen as String] as? Bool) != true,
                  let number = window[kCGWindowNumber as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? [String: Double],
                  (bounds["Width"] ?? 0) >= minimumWindowSide,
                  (bounds["Height"] ?? 0) >= minimumWindowSide
            else {
                continue
            }

            let spaces = copySpacesForWindows(connectionID, allSpacesMask, [number] as CFArray)?
                .takeRetainedValue() as? [Any]
            if spaces?.isEmpty == false {
                return true
            }
        }

        return false
    }
}
