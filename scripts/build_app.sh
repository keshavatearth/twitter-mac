#!/usr/bin/env bash
#
# Build, bundle, ad-hoc sign, and (optionally) launch TwitterMac.app using only the
# Command Line Tools — no Xcode project, no xcodebuild.
#
# Usage:
#   scripts/build_app.sh                # debug build, assemble + sign
#   scripts/build_app.sh release        # release build
#   scripts/build_app.sh debug run      # build then `open` the app
#   scripts/build_app.sh debug test     # build then run the headless filter selftest
#
set -euo pipefail

APP_NAME="TwitterMac"
BUNDLE_ID="com.keshavatearth.twittermac"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-debug}"
ACTION="${2:-}"

# ---------------------------------------------------------------- app icon
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
    echo "==> generating app icon"
    swift "$ROOT/scripts/make_icon.swift"
    iconutil -c icns "$ROOT/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
    rm -rf "$ROOT/AppIcon.iconset"
fi

# ---------------------------------------------------------------- compile
echo "==> swift build (-c $CONFIG)"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

# ---------------------------------------------------------------- assemble
APP="$ROOT/build/$APP_NAME.app"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# The filter JS ships as loose files, not a compiled resource bundle, so it stays
# editable inside the installed app. UserScripts.swift prefers
# ~/.config/twitter-mac/userscripts/ over these when it exists.
echo "==> copying user scripts"
cp -R "$ROOT/Resources/userscripts" "$APP/Contents/Resources/userscripts"
cp "$ROOT/Resources/config.example.json" "$APP/Contents/Resources/config.example.json"

# ---------------------------------------------------------------- sign
# Prefer a stable identity when one exists: an ad-hoc signature's cdhash changes on
# every build, and macOS keys the WebKit data store + TCC grants to the signature, so
# ad-hoc rebuilds can log you out of x.com. Override with CODESIGN_IDENTITY=...
SIGN_ID="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_ID" ]]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F\" '/Apple Development|Developer ID Application|Apple Distribution/ {print $2; exit}')"
fi
if [[ -z "$SIGN_ID" ]]; then
    SIGN_ID="-"
    echo "==> codesign (ad-hoc — no stable identity found; x.com login may not survive rebuilds)"
else
    echo "==> codesign (identity: $SIGN_ID)"
fi

codesign --force --sign "$SIGN_ID" \
    --identifier "$BUNDLE_ID" \
    --entitlements "$ROOT/TwitterMac.entitlements" \
    "$APP"

echo "==> done: $APP"
codesign -dv "$APP" 2>&1 | sed 's/^/    /' || true

# ---------------------------------------------------------------- run / test
case "$ACTION" in
    run)
        echo "==> launching"
        open "$APP"
        ;;
    test)
        echo "==> filter selftest"
        "$APP/Contents/MacOS/$APP_NAME" selftest
        ;;
esac
