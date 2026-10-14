#!/bin/bash
# Builds UsageBar.app (universal: Apple Silicon + Intel) into macos/build/.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/UsageBar.app
VERSION="${VERSION:-1.0.0}"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/UsageBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/UsageBar"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>UsageBar</string>
  <key>CFBundleDisplayName</key><string>UsageBar</string>
  <key>CFBundleIdentifier</key><string>io.github.usagebar</string>
  <key>CFBundleExecutable</key><string>UsageBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS runs it locally; use a Developer ID for public releases.
codesign --force --deep --sign - "$APP"
echo "Built $APP"
