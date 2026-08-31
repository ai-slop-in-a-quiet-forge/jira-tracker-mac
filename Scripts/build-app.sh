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
#   Scripts/build-app.sh --universal  # arm64 + x86_64, for a release artifact
#   Scripts/build-app.sh --zip        # also produce dist/Chrono-<version>.zip

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

CONFIGURATION="release"
DO_INSTALL=0
DO_RUN=0
DO_UNIVERSAL=0
DO_ZIP=0

for arg in "$@"; do
  case "$arg" in
    --debug)     CONFIGURATION="debug" ;;
    --release)   CONFIGURATION="release" ;;
    --install)   DO_INSTALL=1 ;;
    --run)       DO_RUN=1 ;;
    --universal) DO_UNIVERSAL=1 ;;
    --zip)       DO_ZIP=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

APP_NAME="Chrono"
BUNDLE_ID="in.chrono.tracker"
# The single source of truth for the app version: it becomes CFBundleShortVersionString, which
# is what Settings > Advanced displays and what the release workflow checks the git tag against.
VERSION="0.1.0"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
# Must stay in step with LSMinimumSystemVersion below and with the platform in Package.swift.
MACOS_MIN="14.0"

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

mkdir -p "$DIST"

if [ "$DO_UNIVERSAL" = "1" ]; then
  # A downloaded build has to run on Intel Macs too, and LSMinimumSystemVersion 14.0 still
  # includes plenty of them. This SwiftPM has no --arch, so each slice is built against its
  # own triple and merged with lipo. Chrono links nothing but Apple frameworks, so building
  # the Intel slice on Apple Silicon is an ordinary build rather than a toolchain hunt.
  SLICES=()
  for ARCH in arm64 x86_64; do
    TRIPLE="$ARCH-apple-macosx$MACOS_MIN"
    echo "==> Building ChronoApp ($CONFIGURATION, $ARCH)"
    swift build -c "$CONFIGURATION" --product ChronoApp --triple "$TRIPLE"
    SLICE_DIR="$(swift build -c "$CONFIGURATION" --product ChronoApp --triple "$TRIPLE" --show-bin-path)"
    SLICES+=("$SLICE_DIR/ChronoApp")
  done

  echo "==> Merging the slices"
  BUILT_BINARY="$DIST/ChronoApp-universal"
  rm -f "$BUILT_BINARY"
  lipo -create "${SLICES[@]}" -output "$BUILT_BINARY"
  echo "    $(lipo -archs "$BUILT_BINARY")"
else
  echo "==> Building ChronoApp ($CONFIGURATION)"
  swift build -c "$CONFIGURATION" --product ChronoApp
  BUILT_BINARY="$(swift build -c "$CONFIGURATION" --product ChronoApp --show-bin-path)/ChronoApp"
fi

echo "==> Generating the app icon"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
swift run -c "$CONFIGURATION" GenerateIcons "$ICONSET" >/dev/null

echo "==> Assembling the bundle"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RESOURCES"

cp "$BUILT_BINARY" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
# The merged binary only existed to be copied in; the bundle owns it now.
if [ "$DO_UNIVERSAL" = "1" ]; then
  rm -f "$BUILT_BINARY"
fi

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
if [ "$DO_UNIVERSAL" = "1" ]; then
  echo "    architectures: $(lipo -archs "$MACOS_DIR/$APP_NAME")"
fi

if [ "$DO_ZIP" = "1" ]; then
  # ditto, not zip: a plain zip does not preserve the bundle's symlinks or resource forks,
  # and unpacking one breaks even the ad-hoc signature. This is the same archiver Finder's
  # "Compress" uses, so the artifact behaves the way people expect when they double-click it.
  ZIP="$DIST/$APP_NAME-$VERSION.zip"
  echo "==> Packaging $ZIP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "    $(du -h "$ZIP" | cut -f1)  sha256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
fi

INSTALLED_AT=""

if [ "$DO_INSTALL" = "1" ]; then
  # Prefer /Applications, but fall back to ~/Applications when it is not writable. On a
  # managed or corporate Mac it usually is not, and requiring sudo to install a menu bar
  # utility is a poor trade — a per-user install works identically, including launch at login.
  if [ -w "/Applications" ]; then
    INSTALL_DIR="/Applications"
  else
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
    echo "    /Applications is not writable; installing per-user instead"
  fi

  echo "==> Installing to $INSTALL_DIR"
  # Quit any running copy first, or the copy fails on a busy binary.
  osascript -e 'quit app "Chrono"' >/dev/null 2>&1 || true
  sleep 1
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
  cp -R "$APP" "$INSTALL_DIR/"
  INSTALLED_AT="$INSTALL_DIR/$APP_NAME.app"
  echo "    installed $INSTALLED_AT"
fi

if [ "$DO_RUN" = "1" ]; then
  TARGET="${INSTALLED_AT:-$APP}"
  echo "==> Launching"
  open "$TARGET"
fi
