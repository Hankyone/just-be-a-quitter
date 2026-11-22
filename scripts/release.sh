#!/bin/zsh
# Builds a signed, notarized DMG in dist/. Pass --publish to upload it as a GitHub release.
#
# Needs a "Developer ID Application" certificate and a notarytool keychain profile:
#   xcrun notarytool store-credentials JustBeAQuitter --key <AuthKey.p8> --key-id <id> --issuer <issuer>

set -euo pipefail

source "${0:A:h}/build-app.sh"

NOTARY_PROFILE="${NOTARY_PROFILE:-JustBeAQuitter}"
DMG="$DIST_DIR/Just-Be-a-Quitter.dmg"

if [[ "$SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "A Developer ID Application certificate is required for releases (found: $SIGN_IDENTITY)."
  exit 1
fi

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m
}

echo "Notarizing app..."
ZIP="$DIST_DIR/notarize.zip"
ditto -c -k --keepParent "$STAGING_APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$STAGING_APP"
trash "$ZIP"

echo "Building disk image..."
[[ -e "$DMG" ]] && trash "$DMG"
uvx --quiet --from dmgbuild dmgbuild \
  -s "$PROJECT_DIR/scripts/dmg-settings.py" \
  -D app="$STAGING_APP" \
  -D background="$PROJECT_DIR/Resources/dmg-background.tiff" \
  "$APP_NAME" "$DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

echo "Notarizing disk image..."
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

echo "Release ready: $DMG"

if [[ "${1:-}" == "--publish" ]]; then
  TAG="v$VERSION"
  if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG" --clobber
  else
    gh release create "$TAG" "$DMG" --title "Just Be a Quitter $VERSION" --generate-notes
  fi
fi
