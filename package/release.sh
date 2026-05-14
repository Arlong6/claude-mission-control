#!/bin/bash
#
# Full release pipeline:
#   swift build (release) → bundle .app → sign → DMG → notarize → staple
#
# Output: dist/MissionControl-<version>.dmg, ready for GitHub release page.
#
# Prereqs (one-time):
#   1. Apple Developer Program member, with "Developer ID Application" cert installed
#   2. ./package/setup-notary.sh has been run (stores notarytool creds in keychain
#      under profile "mc-notary")
#
# Usage:
#   ./package/release.sh                       # build + sign + DMG + notarize + staple
#   ./package/release.sh --skip-notarize       # everything except notarization
#                                              # (useful for local-only testing)
#   ./package/release.sh --version 0.2.0       # override version
#
# Env vars (auto-detected if unset):
#   DEV_ID_TEAM       Team ID for "Developer ID Application: X (TEAMID)" cert
#   SIGN_IDENTITY     Full name of the cert; defaults to first Developer ID found
#   NOTARY_PROFILE    Keychain profile name; defaults to "mc-notary"

set -euo pipefail
cd "$(dirname "$0")/.."

# ─── Defaults ──────────────────────────────────────────────────────────────

SKIP_NOTARIZE=false
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo "0.1.0")"
APP="MissionControl.app"
DIST_DIR="dist"
ENTITLEMENTS="package/MissionControl.entitlements"
NOTARY_PROFILE="${NOTARY_PROFILE:-mc-notary}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-notarize) SKIP_NOTARIZE=true; shift ;;
    --version) VERSION="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

DMG_NAME="MissionControl-${VERSION}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
STAGING="$DIST_DIR/staging"

mkdir -p "$DIST_DIR"
rm -rf "$STAGING"
mkdir -p "$STAGING"

# ─── Step 1: Resolve signing identity ─────────────────────────────────────
# Bash 3.2 (macOS default) treats failures in $(...) pipelines under
# `set -e -o pipefail` aggressively; relax just for this lookup so an
# empty result becomes "" rather than an early exit.

set +e
IDENTITY_LIST="$(security find-identity -v -p codesigning 2>/dev/null)"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && echo "$IDENTITY_LIST" | grep -q "Developer ID Application"; then
  SIGN_IDENTITY="$(echo "$IDENTITY_LIST" \
    | grep "Developer ID Application" | head -1 \
    | sed -E 's/.*"(Developer ID Application: [^"]+)".*/\1/')"
fi
set -e

if [ -z "$SIGN_IDENTITY" ]; then
  if [ "$SKIP_NOTARIZE" = "false" ]; then
    echo "❌ No 'Developer ID Application' identity in keychain."
    echo "   Install one from developer.apple.com → Certificates."
    echo "   Or rerun with: ./package/release.sh --skip-notarize"
    exit 1
  fi
  echo "⚠️  No Developer ID cert found — falling back to ad-hoc signing."
fi

if [ -z "${DEV_ID_TEAM:-}" ] && [ -n "$SIGN_IDENTITY" ]; then
  DEV_ID_TEAM="$(echo "$SIGN_IDENTITY" | sed -E 's/.*\(([A-Z0-9]+)\).*/\1/')"
fi
DEV_ID_TEAM="${DEV_ID_TEAM:-}"

echo "─── release.sh ──────────────────────────────────────────"
echo "  version  : $VERSION"
echo "  identity : ${SIGN_IDENTITY:-<ad-hoc>}"
echo "  team     : ${DEV_ID_TEAM:-<none>}"
echo "  notarize : $( [ "$SKIP_NOTARIZE" = "true" ] && echo no || echo yes )"
echo "  output   : $DMG_PATH"
echo "─────────────────────────────────────────────────────────"

# ─── Step 2: Build release binary + bundle .app ────────────────────────────

echo "→ swift build -c release"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/MissionControl"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/MissionControl"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%s)" "$APP/Contents/Info.plist"

# ─── Step 3: Sign with Developer ID + hardened runtime ─────────────────────

if [ -n "$SIGN_IDENTITY" ]; then
  echo "→ codesign with $SIGN_IDENTITY (hardened runtime + timestamp)"
  codesign --force --deep \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "→ ad-hoc sign (no notarization will be possible)"
  codesign --force --deep --sign - "$APP"
fi

# ─── Step 4: Build DMG via hdiutil ─────────────────────────────────────────

echo "→ build DMG"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Optional background image — drop one at package/dmg-background.png if you want it.
# Otherwise hdiutil just makes a plain DMG, which is fine.

rm -f "$DMG_PATH"
hdiutil create -volname "Mission Control" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG_PATH" >/dev/null

rm -rf "$STAGING"

# Re-sign the DMG itself so Gatekeeper recognizes the wrapper too.
if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
fi

echo "✓ Built $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"

# ─── Step 5: Notarize ──────────────────────────────────────────────────────

if [ "$SKIP_NOTARIZE" = "true" ]; then
  echo ""
  echo "⚠️  Skipped notarization. Users will see Gatekeeper warnings."
  echo "   To notarize later: xcrun notarytool submit $DMG_PATH --keychain-profile $NOTARY_PROFILE --wait"
  exit 0
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "❌ Keychain profile '$NOTARY_PROFILE' not found."
  echo "   Run: ./package/setup-notary.sh"
  exit 1
fi

echo "→ submit to notary (this usually takes 1–5 minutes)"
SUBMIT_OUTPUT="$(xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait --output-format json 2>&1)"
echo "$SUBMIT_OUTPUT"

STATUS="$(echo "$SUBMIT_OUTPUT" | grep -oE '"status":"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
if [ "$STATUS" != "Accepted" ]; then
  SUBMISSION_ID="$(echo "$SUBMIT_OUTPUT" | grep -oE '"id":"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
  echo "❌ Notarization status: $STATUS"
  if [ -n "$SUBMISSION_ID" ]; then
    echo "→ fetching log:"
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE"
  fi
  exit 1
fi

# ─── Step 6: Staple the ticket so the DMG verifies offline ─────────────────

echo "→ staple"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo ""
echo "✅ Done. $DMG_PATH is signed, notarized, and stapled."
echo ""
echo "Upload to GitHub:"
echo "  gh release create v$VERSION $DMG_PATH \\"
echo "    --title \"Mission Control v$VERSION\" \\"
echo "    --notes-file CHANGELOG.md"
