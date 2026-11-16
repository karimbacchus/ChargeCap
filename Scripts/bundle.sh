#!/bin/bash
# Builds ChargeCap and ChargeCapHelper with SwiftPM and wraps them in a Developer ID signed .app bundle.
# Usage: Scripts/bundle.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${DEVELOPER_DIR:-}" ] && ! xcodebuild -version >/dev/null 2>&1 && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

CONFIG="${1:-release}"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

APP="build/ChargeCap.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"

cp "$BIN/ChargeCap" "$APP/Contents/MacOS/ChargeCap"
cp "$BIN/ChargeCapHelper" "$APP/Contents/MacOS/ChargeCapHelper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/com.chargecap.app.helper.plist "$APP/Contents/Library/LaunchDaemons/com.chargecap.app.helper.plist"

if [ ! -f Resources/AppIcon.icns ]; then
    swift Scripts/generate_icon.swift Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ensure any Apple Developer certificates in ~/Documents are imported and select Developer ID Application
for cer in "$HOME"/Documents/*.cer; do
    [ -f "$cer" ] && security import "$cer" -k "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true
done

if [ -z "${CODESIGN_IDENTITY:-}" ] && [ -f "$HOME/Documents/developerID_application.cer" ]; then
    CODESIGN_IDENTITY="$(openssl x509 -inform DER -in "$HOME/Documents/developerID_application.cer" -noout -subject 2>/dev/null \
        | sed -n 's/.*CN=\(Developer ID Application:[^/]*\).*/\1/p')"
fi

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development|Apple Distribution/ {print $2; exit}')"
fi
IDENTITY="${IDENTITY:--}"

codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    --identifier com.chargecap.app.helper "$APP/Contents/MacOS/ChargeCapHelper"

codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    --identifier com.chargecap.app "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built $APP (signed with: $IDENTITY)"
