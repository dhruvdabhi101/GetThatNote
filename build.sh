#!/bin/bash
# GetThatNote build lifecycle.
#   ./build.sh            build GetThatNote.app
#   ./build.sh install    build + replace /Applications/GetThatNote.app + relaunch
#   ./build.sh release    build + GetThatNote-<version>.zip + git commit reminder/tag
#   ./build.sh clean      remove build products
set -e
cd "$(dirname "$0")"
APP="GetThatNote.app"
VER="$(cat VERSION 2>/dev/null || echo 0.0.0)"
GITHASH="$(git rev-parse --short HEAD 2>/dev/null || echo local)"
BUILDNUM="$(date +%Y%m%d%H%M)"
CMD="${1:-build}"

if [ "$CMD" = "clean" ]; then rm -rf build "$APP" GetThatNote-*.zip GetThatNote.zip; echo "✓ cleaned"; exit 0; fi

rm -rf build "$APP"
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"
echo "▸ GetThatNote v$VER ($GITHASH) — compiling (universal, macOS 13+)"
FLAGS="-O -swift-version 5 -parse-as-library -framework Cocoa -framework WebKit -framework Vision -framework Carbon -framework UserNotifications -framework CryptoKit -framework UniformTypeIdentifiers -lsqlite3"
swiftc $FLAGS -target arm64-apple-macos13.0  -o build/GetThatNote-arm64  GetThatNote.swift
swiftc $FLAGS -target x86_64-apple-macos13.0 -o build/GetThatNote-x86_64 GetThatNote.swift
lipo -create build/GetThatNote-arm64 build/GetThatNote-x86_64 -output "$APP/Contents/MacOS/GetThatNote"
sed "s/const APP_VERSION='dev'/const APP_VERSION='$VER ($GITHASH)'/" app.html > "$APP/Contents/Resources/app.html"
echo "▸ drawing icon"
mkdir -p build/AppIcon.iconset
"$APP/Contents/MacOS/GetThatNote" --make-icon build
for s in 16 32 128 256 512; do cp "build/icon_$s.png" "build/AppIcon.iconset/icon_${s}x${s}.png"; done
cp build/icon_32.png build/AppIcon.iconset/icon_16x16@2x.png; cp build/icon_64.png build/AppIcon.iconset/icon_32x32@2x.png
cp build/icon_256.png build/AppIcon.iconset/icon_128x128@2x.png; cp build/icon_512.png build/AppIcon.iconset/icon_256x256@2x.png; cp build/icon_1024.png build/AppIcon.iconset/icon_512x512@2x.png
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>GetThatNote</string>
  <key>CFBundleDisplayName</key><string>GetThatNote</string>
  <key>CFBundleIdentifier</key><string>com.free.getthatnote</string>
  <key>CFBundleVersion</key><string>$BUILDNUM</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundleExecutable</key><string>GetThatNote</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key><string>GetThatNote sends exported notes to Apple Notes.</string>
  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>GetThatNote</string><key>CFBundleURLSchemes</key><array><string>getthatnote</string><string>antinote</string></array></dict></array>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
echo "▸ signing (ad-hoc)"
codesign --force --deep --sign - "$APP" 2>/dev/null || true
rm -rf build
echo "✓ Built $APP  (v$VER, $GITHASH)"

if [ "$CMD" = "install" ]; then
  pkill -x GetThatNote 2>/dev/null || true; sleep 0.5
  rm -rf /Applications/GetThatNote.app
  cp -R "$APP" /Applications/GetThatNote.app
  open /Applications/GetThatNote.app
  echo "✓ Installed and launched /Applications/GetThatNote.app"
fi
if [ "$CMD" = "release" ]; then
  ZIP="GetThatNote-$VER.zip"
  rm -f "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
  echo "✓ $ZIP ready to share"
  if git rev-parse --git-dir >/dev/null 2>&1; then
    if git diff --quiet && git diff --cached --quiet; then git tag -f "v$VER" && echo "✓ tagged v$VER"; else echo "⚠ uncommitted changes — commit first, then re-run release to tag v$VER"; fi
  fi
fi
