#!/usr/bin/env bash
set -euo pipefail

# Streifen build/sign/notarize/dmg pipeline.
#
# Usage:
#   ./scripts/build-app.sh                              # build + sign
#   ./scripts/build-app.sh 0.2.0                        # build + sign with explicit version
#   ./scripts/build-app.sh 0.2.0 --notarize             # + notarize the .app
#   ./scripts/build-app.sh 0.2.0 --notarize --dmg       # + build + notarize DMG
#   ./scripts/build-app.sh 0.2.0 --dmg                  # build .app + DMG (no notarization)
#
# Notarization requires APPLE_ID, APPLE_TEAM_ID, APPLE_APP_SPECIFIC_PASSWORD
# in the environment. For local runs, source them from hort.

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo '0.0.0-dev')}"
shift || true
APP_NAME="Streifen"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
ENT="$ROOT/scripts/entitlements.plist"
INFO_SRC="$ROOT/Sources/Streifen/Info.plist"

# Parse remaining flags
DO_NOTARIZE=0
DO_DMG=0
for arg in "$@"; do
    case "$arg" in
        --notarize) DO_NOTARIZE=1 ;;
        --dmg)      DO_DMG=1 ;;
        *) echo "Unknown flag: $arg" >&2; exit 1 ;;
    esac
done

echo "==> Streifen $VERSION"

# 1. Build release binary
echo "==> swift build -c release"
cd "$ROOT"
swift build -c release --arch arm64

BINARY=".build/arm64-apple-macosx/release/Streifen"
if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: binary not found at $BINARY" >&2
    exit 1
fi

# 2. Create .app bundle structure
echo "==> Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Streifen"
cp "$INFO_SRC" "$APP/Contents/Info.plist"

# Patch Info.plist with version
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

# 3. Sign with Developer ID + hardened runtime
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
if [[ -z "$IDENTITY" ]]; then
    echo "ERROR: no Developer ID Application certificate found in keychain" >&2
    exit 1
fi
echo "==> Signing as: $IDENTITY"

SIGN_OPTS=(--force --sign "$IDENTITY" --timestamp --options runtime --entitlements "$ENT")
codesign "${SIGN_OPTS[@]}" "$APP/Contents/MacOS/Streifen"
codesign "${SIGN_OPTS[@]}" "$APP"
codesign --verify --verbose=2 --strict "$APP"
echo "==> Signature verified"

# 4. Optional: notarize
if [[ "$DO_NOTARIZE" == "1" ]]; then
    : "${APPLE_ID:?APPLE_ID not set}"
    : "${APPLE_TEAM_ID:?APPLE_TEAM_ID not set}"
    : "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD not set}"

    APP_ZIP="$DIST/$APP_NAME.zip"
    echo "==> Notarizing app..."
    ditto -c -k --keepParent --sequesterRsrc "$APP" "$APP_ZIP"
    xcrun notarytool submit "$APP_ZIP" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --wait --timeout 30m
    rm -f "$APP_ZIP"

    echo "==> Stapling app..."
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi

# 5. Optional: build DMG
if [[ "$DO_DMG" == "1" ]]; then
    DMG="$DIST/$APP_NAME-$VERSION-arm64.dmg"
    echo "==> Building DMG: $DMG"
    rm -f "$DMG"
    hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG"

    if [[ "$DO_NOTARIZE" == "1" ]]; then
        echo "==> Notarizing DMG..."
        xcrun notarytool submit "$DMG" \
            --apple-id "$APPLE_ID" \
            --team-id "$APPLE_TEAM_ID" \
            --password "$APPLE_APP_SPECIFIC_PASSWORD" \
            --wait --timeout 30m
        echo "==> Stapling DMG..."
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG"
    fi
    echo "✓ DMG: $DMG"
fi

echo "✓ App: $APP"
