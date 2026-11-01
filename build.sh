#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/Swyp.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Compile (link the private frameworks so the menu-bar agent runs the engine).
swiftc -O "$DIR/src/main.swift" -o "$APP/Contents/MacOS/Swyp" \
  -framework AppKit -framework CoreAudio \
  -F /System/Library/PrivateFrameworks

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Swyp</string>
  <key>CFBundleDisplayName</key><string>Swyp</string>
  <key>CFBundleIdentifier</key><string>app.swyp.clone</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>Swyp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Swyp — trackpad edge controls</string>
</dict>
</plist>
PLIST

# Ad-hoc codesign so it launches without quarantine complaints on this machine.
codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "Built: $APP"
