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
# not allowed"), then ad-hoc sign. No sandbox: the app execs sushi, binds
# a port and reads ~/.sushi.
xattr -cr "$APP"
codesign --force --sign - "$APP"

echo ""
echo "✅ Built: $APP"
echo "   Run:     open '$APP'"
echo "   Install: mv '$APP' ~/Applications/"
