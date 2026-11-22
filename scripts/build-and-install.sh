#!/bin/zsh
# Builds the app, installs it to /Applications and restarts the background copy.

set -euo pipefail

source "${0:A:h}/build-app.sh"

INSTALL_APP="/Applications/$APP_NAME.app"

# Stop the running copy cleanly (a clean exit keeps launchd from restarting it mid-install).
if pgrep -x "$EXECUTABLE_NAME" >/dev/null; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
fi
for _ in {1..40}; do
  pgrep -x "$EXECUTABLE_NAME" >/dev/null || break
  sleep 0.1
done
pkill -x "$EXECUTABLE_NAME" 2>/dev/null || true

if [[ -e "$INSTALL_APP" ]]; then
  trash "$INSTALL_APP"
fi

ditto "$STAGING_APP" "$INSTALL_APP"

# Launching the app registers its launch agent (if needed) and hands off to launchd,
# which keeps it running from now on. -g keeps it from stealing focus.
if launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$AGENT_LABEL"
else
  open -g "$INSTALL_APP" --args --background
fi

echo "Installed: $INSTALL_APP"
echo "Signed with: $SIGN_IDENTITY"
