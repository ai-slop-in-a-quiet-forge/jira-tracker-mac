#!/bin/bash
#
# Assembles Chrono.app from the SwiftPM build products.
#
# There is no .xcodeproj on purpose: the whole app builds from the command line with the Swift
# toolchain, which keeps the repository reviewable, keeps CI trivial, and means nobody has to
# reconcile a 3000-line pbxproj in a merge. This script is the "Xcode target" — it produces the
# bundle layout, the Info.plist and the code signature.
#
# Usage:
#   Scripts/build-app.sh              # release build into dist/
#   Scripts/build-app.sh --debug      # faster build, for iterating
#   Scripts/build-app.sh --install    # also copy into /Applications
#   Scripts/build-app.sh --run        # launch it when done

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

CONFIGURATION="release"
DO_INSTALL=0
DO_RUN=0

for arg in "$@"; do
  case "$arg" in
    --debug)   CONFIGURATION="debug" ;;
    --release) CONFIGURATION="release" ;;
    --install) DO_INSTALL=1 ;;
    --run)     DO_RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

APP_NAME="Chrono"
BUNDLE_ID="in.chrono.tracker"
# Keep these in step with the version reported in Settings > Advanced.
VERSION="1.0.0"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Building ChronoApp ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product ChronoApp
BIN_PATH="$(swift build -c "$CONFIGURATION" --product ChronoApp --show-bin-path)"

echo "==> Generating the app icon"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
swift run -c "$CONFIGURATION" GenerateIcons "$ICONSET" >/dev/null

echo "==> Assembling the bundle"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RESOURCES"

cp "$BIN_PATH/ChronoApp" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

# iconutil is part of the developer tools and produces the multi-resolution .icns.
iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>           <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>            <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>

    <!-- Menu bar app: no Dock icon, no app menu of its own. -->
    <key>LSUIElement</key>                   <true/>

    <!-- Only requested when the user enables the Bluetooth phone remote. -->
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Chrono uses Bluetooth to let your iPhone pause and stop the timer when you step away from your Mac.</string>

    <!-- Only requested when the user enables the phone web remote. -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>Chrono serves a small control page to your phone on your local network so you can pause the timer from another room.</string>

    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key>   <false/>
</dict>
</plist>
PLIST

# Ad-hoc signature. Enough for the app to run locally, hold Keychain items and be granted
# Bluetooth and Local Network permissions. A distributed build would substitute a Developer ID
# here and notarise the result.
echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null 2>&1 || {
  echo "    codesign failed; the app will still run but may re-prompt for permissions" >&2
}

SIZE="$(du -sh "$APP" | cut -f1)"
echo "==> Built $APP ($SIZE)"

if [ "$DO_INSTALL" = "1" ]; then
  echo "==> Installing to /Applications"
  # Quit any running copy first, or the copy will fail on a busy binary.
  osascript -e 'quit app "Chrono"' >/dev/null 2>&1 || true
  sleep 1
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/"
  echo "    installed /Applications/$APP_NAME.app"
fi

if [ "$DO_RUN" = "1" ]; then
  TARGET="$APP"
  [ "$DO_INSTALL" = "1" ] && TARGET="/Applications/$APP_NAME.app"
  echo "==> Launching"
  open "$TARGET"
fi
