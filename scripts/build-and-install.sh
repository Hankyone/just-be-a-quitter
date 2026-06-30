#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="Just Be a Quitter"
EXECUTABLE_NAME="JustBeAQuitter"
PRODUCT_NAME="AutoQuitBackground"
VERSION="${VERSION:-0.1.0}"
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
swift build -c release

mkdir -p "$DIST_DIR"

if [[ -e "$STAGING_APP" ]]; then
  trash "$STAGING_APP"
fi

mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources"
ditto "$PROJECT_DIR/.build/release/$PRODUCT_NAME" "$STAGING_APP/Contents/MacOS/$EXECUTABLE_NAME"

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
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

if [[ -e "$INSTALL_APP" ]]; then
  trash "$INSTALL_APP"
fi

ditto "$STAGING_APP" "$INSTALL_APP"

codesign \
  --force \
  --deep \
  --options runtime \
  --sign "$SIGN_IDENTITY" \
  "$INSTALL_APP"

codesign --verify --deep --strict "$INSTALL_APP"

echo "Installed: $INSTALL_APP"
echo "Signed with: $SIGN_IDENTITY"
