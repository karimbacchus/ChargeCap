#!/bin/zsh
# Builds a Developer ID–signed, notarized, stapled DMG.
#   Scripts/release.sh            → build/ChargeCap.dmg
#   Scripts/release.sh --publish  → also creates GitHub release v<version> with ChargeCap.dmg attached
#                                   (bump CFBundleShortVersionString in Resources/Info.plist first)
#
# Notarization credentials come from a notarytool keychain profile (default "XDRStat", any profile for
# team R8BK4688WV works). Create one with:
#   xcrun notarytool store-credentials <profile> --apple-id <Apple ID email> --team-id R8BK4688WV
# Override with NOTARY_PROFILE=...
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="karimbacchus/ChargeCap"
PROFILE="${NOTARY_PROFILE:-XDRStat}"
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
[[ -z "$IDENTITY" ]] && { echo "No 'Developer ID Application' identity in the keychain." >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG="build/ChargeCap.dmg"
PUBLISH=0; [[ "${1:-}" == "--publish" ]] && PUBLISH=1

# 0. Publishing checks up front: clean, pushed commit and a new version tag.
if (( PUBLISH )); then
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "Uncommitted changes: commit them before publishing." >&2; exit 1; }
  git fetch -q origin
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse '@{u}')" ]] || { echo "HEAD isn't pushed (or is behind origin): sync before publishing." >&2; exit 1; }
  if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    echo "Release v$VERSION already exists: bump CFBundleShortVersionString in Resources/Info.plist." >&2; exit 1
  fi
fi
COMMIT=$(git rev-parse HEAD)

# 1. Build + sign the app (hardened runtime, timestamp; helper and launchd plist sealed inside).
CODESIGN_IDENTITY="$IDENTITY" Scripts/bundle.sh release

# 2. Disk image with a drag-to-Applications layout.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/ChargeCap.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "ChargeCap $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# 3. Notarize and staple so it opens offline without Gatekeeper warnings.
echo "Submitting $DMG for notarization…"
if ! xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait; then
  echo "Notarization failed. See the log with: xcrun notarytool log <submission-id> --keychain-profile $PROFILE" >&2
  exit 1
fi
xcrun stapler staple "$DMG"

# 4. Gatekeeper check, as a downloaded file would get.
spctl -a -t open --context context:primary-signature -vv "$DMG"
echo "Ready: $DMG"

# 5. Optional: publish as the latest GitHub release.
if (( PUBLISH )); then
  NOTES_FILE=$(mktemp)
  cat > "$NOTES_FILE" <<EOF
Signed with Developer ID and notarized by Apple. Requires macOS 27 or later on Apple silicon.

**Install:** open the DMG, drag ChargeCap to Applications, launch it, then click **Install Helper** and approve ChargeCap in System Settings › General › Login Items (Touch ID works, no password). ChargeCap must live in /Applications for the helper registration to stick.

If you previously installed the old password-based helper, it's removed automatically the first time the new helper connects.

Turn off macOS's own Optimized Battery Charging / charge limit while using ChargeCap — the two fight each other.
EOF
  gh release create "v$VERSION" "$DMG" --repo "$REPO" --target "$COMMIT" \
    --title "ChargeCap $VERSION" --notes-file "$NOTES_FILE" --latest
  rm -f "$NOTES_FILE"
  echo "Published: https://github.com/$REPO/releases/tag/v$VERSION"
fi
