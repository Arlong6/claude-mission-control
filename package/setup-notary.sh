#!/bin/bash
#
# One-time helper: store your Apple notarytool credentials in the keychain
# under a profile name so package/release.sh can use them non-interactively.
#
# What you need before running:
#   1. Apple Developer Program membership ($99/yr)
#   2. Apple ID email (probably the same one as App Store Connect)
#   3. Your 10-character Team ID (developer.apple.com → Membership)
#   4. An app-specific password
#         appleid.apple.com → Sign-in & Security → App-Specific Passwords
#         → Generate → label it "Mission Control notary"
#      OR an App Store Connect API key (.p8 file). Either works.
#   5. The "Developer ID Application" certificate installed in Keychain
#         developer.apple.com/account/resources/certificates → "+" →
#         "Developer ID Application" → follow the CSR/install steps
#
# Then run:
#     ./package/setup-notary.sh
#
# This script stores everything via `xcrun notarytool store-credentials`,
# which puts the secrets in Keychain under the profile name "mc-notary".
# release.sh references that profile by name, never seeing the secret.

set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE_NAME="mc-notary"

read -p "Apple ID email: " APPLE_ID
read -p "Team ID (10 chars): " TEAM_ID
echo ""
echo "Pick auth method:"
echo "  1) App-specific password (easiest)"
echo "  2) App Store Connect API key (.p8 file)"
read -p "[1/2]: " AUTH_METHOD

case "$AUTH_METHOD" in
  1)
    echo ""
    read -s -p "App-specific password (no echo): " APP_PWD
    echo ""
    xcrun notarytool store-credentials "$PROFILE_NAME" \
      --apple-id "$APPLE_ID" \
      --team-id "$TEAM_ID" \
      --password "$APP_PWD"
    ;;
  2)
    read -p "API Key ID (10 chars): " KEY_ID
    read -p "API Issuer UUID: " ISSUER
    read -p "Path to .p8 key file: " P8_PATH
    if [ ! -f "$P8_PATH" ]; then
      echo "❌ No file at $P8_PATH"; exit 1
    fi
    xcrun notarytool store-credentials "$PROFILE_NAME" \
      --team-id "$TEAM_ID" \
      --key-id "$KEY_ID" \
      --issuer "$ISSUER" \
      --key "$P8_PATH"
    ;;
  *)
    echo "❌ Unknown option"; exit 1
    ;;
esac

echo ""
echo "✓ Credentials stored in keychain under profile '$PROFILE_NAME'."

# Verify the Developer ID Application certificate is present.
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo ""
  echo "⚠️  No 'Developer ID Application' identity found in your keychain."
  echo "    Go to developer.apple.com/account/resources/certificates and"
  echo "    download + install it before running ./package/release.sh."
else
  echo ""
  echo "Available Developer ID Application identities:"
  security find-identity -v -p codesigning | grep "Developer ID Application"
  echo ""
  echo "Note the part in parentheses — that's your TEAMID. release.sh picks"
  echo "it up automatically, but you can override with DEV_ID_TEAM=XXXX."
fi

echo ""
echo "Next step: ./package/release.sh"
