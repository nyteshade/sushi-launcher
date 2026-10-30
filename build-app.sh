#!/bin/zsh
# Build Sushi Launcher.app
#
# Sources live under Sources/SushiLauncher/ (SwiftPM layout); this script
# compiles a release build, assembles the .app bundle and signs it ad-hoc.
set -euo pipefail
cd "${0:A:h}"

# 1. Compile (release).
swift build -c release

# 2. Assemble the .app bundle.
APP_NAME="Sushi Launcher"
APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SushiLauncher "$APP/Contents/MacOS/SushiLauncher"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Icons: the bundle icon (AppIcon.icns) is the PLATE-FREE 832 artwork,
# correct for macOS < 26 where the window server rounds app icons itself.
# On macOS 26+ the app swaps in the pre-rendered squircle at runtime
# (AppIcon.installIfNeeded in SushiLauncherApp.swift).
cp -X icons/sushi-launcher-plain-832.icns "$APP/Contents/Resources/AppIcon.icns"
cp -X icons/sushi-launcher-squircle.png "$APP/Contents/Resources/sushi-launcher-squircle.png"

# Menu bar glyph. ANY PNG works — the app masks it to a template at runtime
# (dark strokes become the glyph, light areas become transparent). Ideal:
# black artwork on white or transparent, square-ish. Preference order:
#   icons/sushi-menuTemplate.png  (checked-in artwork)
#   ~/Desktop/sushi-launcher.png  (local drop)
#   icons/sushi-launcher-plain.png (fallback)
MENU_ICON="icons/sushi-menuTemplate.png"
[[ -f "$MENU_ICON" ]] || MENU_ICON="${HOME}/Desktop/sushi-launcher.png"
[[ -f "$MENU_ICON" ]] || MENU_ICON="icons/sushi-launcher-plain.png"
cp -X "$MENU_ICON" "$APP/Contents/Resources/menu-icon.png"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# 3. Strip Finder metadata the artwork may have brought along
# (com.apple.FinderInfo / com.apple.metadata on Desktop-sourced PNGs make
# codesign fail: "resource fork, Finder information, or similar detritus
# not allowed").
xattr -cr "$APP"

# 4. Sign.
#    Default: ad-hoc — perfect for building and running on your own machine
#    (locally-built files carry no quarantine xattr, so Gatekeeper is never
    # asked).
#    NOTARIZE=1: Developer ID + hardened runtime + Apple notarization +
#    staple — what you need to distribute to OTHER Macs. Requires:
#      - Apple Developer membership and a
#        "Developer ID Application: Name (TEAMID)" certificate in Keychain
#        (check: security find-identity -v -p codesigning)
#      - a one-time credentials profile:
#          xcrun notarytool store-credentials NOTARY_SUSHI \
#              --apple-id you@example.com --team-id TEAMID
#        (password = app-specific password from appleid.apple.com; or use
#         --key AuthKey.p8 --key-id K --issuer I for an App Store Connect
#         API key)
#    Overridable: SIGNING_IDENTITY, TEAM_ID, NOTARY_PROFILE env vars.
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
TEAM_ID="${TEAM_ID:-4HK2NGRWKW}"
NOTARY_PROFILE="${NOTARY_PROFILE:-NOTARY_SUSHI}"

if [[ "${NOTARIZE:-0}" == "1" ]]; then
  # Resolve the full identity string from the keychain: the Developer ID
  # Application cert carrying our team id. `|| true` keeps set -e honest
  # when the greps find nothing (we surface that with our own error).
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY=$(security find-identity -p codesigning -v 2>/dev/null \
      | grep "Developer ID Application" | grep "(${TEAM_ID})" | head -1 \
      | sed -E 's/.*"(.*)".*/\1/' || true)
  fi
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "✗ No Developer ID Application certificate for team ${TEAM_ID} found." >&2
    echo "  Check: security find-identity -v -p codesigning" >&2
    echo "  (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application)" >&2
    exit 1
  fi

  echo "▸ Hardened-runtime signing with '$SIGNING_IDENTITY'…"
  codesign --force --options runtime --timestamp \
           --entitlements Resources/SushiLauncher.entitlements \
           --sign "$SIGNING_IDENTITY" "$APP"

  echo "▸ Zipping for notarization…"
  ARCHIVE="build/$(basename "$APP")-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ARCHIVE"

  echo "▸ Submitting to notarytool (waits for Apple's scan)…"
  xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "▸ Stapling ticket to the bundle…"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  echo "▸ Gatekeeper verdict:"
  spctl --assess --type execute -vv "$APP" || true
  rm -f "$ARCHIVE"
else
  codesign --force --sign - "$APP"
fi

echo ""
echo "✅ Built: $APP"
echo "   Run:     open '$APP'"
echo "   Install: mv '$APP' ~/Applications/"
