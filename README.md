# Just Be a Quitter

Small macOS utility that stays alive in the background and quits selected apps when their last window closes.

Current MVP:

- Launch opens a settings window.
- Closing the window leaves the watcher running.
- Relaunching the app shows the settings window again.
- No menu bar item.
- No long-lived dock presence after launch.
- Tracks selected apps by bundle identifier.
- Uses Accessibility APIs to watch for window lifecycle changes.

Notes:

- The app needs Accessibility permission.
- The first version uses a generic "no windows left" rule. Apps with unusual hidden utility windows may need app-specific handling later.
