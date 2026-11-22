#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="Just Be a Quitter"
EXECUTABLE_NAME="JustBeAQuitter"
PRODUCT_NAME="AutoQuitBackground"
VERSION="${VERSION:-0.2.0}"
AGENT_LABEL="com.hankyone.JustBeAQuitter.agent"
BUNDLE_ID="${BUNDLE_ID:-com.hankyone.JustBeAQuitter}"
DIST_DIR="$PROJECT_DIR/dist"
STAGING_APP="$DIST_DIR/$APP_NAME.app"
INSTALL_APP="/Applications/$APP_NAME.app"

SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'\"' '
  /Developer ID Application:/ && developerID == "" { developerID = $2 }
  /Apple Distribution:/ && appleDistribution == "" { appleDistribution = $2 }
  END {
    if (developerID != "") {
      print developerID
    } else if (appleDistribution != "") {
      print appleDistribution
    }
  }
')}"

if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "No signing identity found. Set SIGN_IDENTITY manually and rerun."
  exit 1
fi

if ! command -v trash >/dev/null 2>&1; then
  echo "The 'trash' command is required for safe bundle replacement."
  exit 1
fi

cd "$PROJECT_DIR"

# SwiftUI macros ship with Xcode, not the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  for xcode in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [[ -d "$xcode" ]]; then
      export DEVELOPER_DIR="$xcode/Contents/Developer"
      break
    fi
  done
fi

swift build -c release

mkdir -p "$DIST_DIR"

if [[ -e "$STAGING_APP" ]]; then
  trash "$STAGING_APP"
fi

mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources" "$STAGING_APP/Contents/Library/LaunchAgents"
ditto "$PROJECT_DIR/.build/release/$PRODUCT_NAME" "$STAGING_APP/Contents/MacOS/$EXECUTABLE_NAME"
xcrun actool "$PROJECT_DIR/Resources/AppIcon.icon" \
  --compile "$STAGING_APP/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 15.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$DIST_DIR/icon-info.plist" >/dev/null
ditto "$PROJECT_DIR/Resources/$AGENT_LABEL.plist" "$STAGING_APP/Contents/Library/LaunchAgents/$AGENT_LABEL.plist"

cat > "$STAGING_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --options runtime --sign "$SIGN_IDENTITY" "$STAGING_APP"
codesign --verify --strict "$STAGING_APP"

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
