#!/bin/zsh
# Builds and signs dist/Just Be a Quitter.app. Sourced by the install and release scripts.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="Just Be a Quitter"
EXECUTABLE_NAME="JustBeAQuitter"
PRODUCT_NAME="AutoQuitBackground"
VERSION="${VERSION:-0.2.0}"
BUILD_NUMBER="$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
AGENT_LABEL="com.hankyone.JustBeAQuitter.agent"
BUNDLE_ID="${BUNDLE_ID:-com.hankyone.JustBeAQuitter}"
DIST_DIR="$PROJECT_DIR/dist"
STAGING_APP="$DIST_DIR/$APP_NAME.app"

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
  echo "No developer certificate found; signing ad hoc."
  echo "macOS may ask for Accessibility access again after each rebuild."
  SIGN_IDENTITY="-"
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

# Universal binary so it runs on Apple silicon and Intel Macs.
BUILD_FLAGS=(-c release --arch arm64 --arch x86_64)
swift build "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"

mkdir -p "$DIST_DIR"

if [[ -e "$STAGING_APP" ]]; then
  trash "$STAGING_APP"
fi

mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources" "$STAGING_APP/Contents/Library/LaunchAgents"
ditto "$BIN_DIR/$PRODUCT_NAME" "$STAGING_APP/Contents/MacOS/$EXECUTABLE_NAME"
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
    <string>${BUILD_NUMBER}</string>
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

SIGN_FLAGS=(--force --options runtime --sign "$SIGN_IDENTITY")
[[ "$SIGN_IDENTITY" != "-" ]] && SIGN_FLAGS+=(--timestamp)
codesign "${SIGN_FLAGS[@]}" "$STAGING_APP"
codesign --verify --strict "$STAGING_APP"
echo "Built: $STAGING_APP ($VERSION, build $BUILD_NUMBER)"
