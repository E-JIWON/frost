#!/bin/sh
# Builds Frost.app next to this script, checks it, and installs it to /Applications.
set -e
cd "$(dirname "$0")"
[ -f AppIcon.icns ] || swift icon.swift
rm -rf Frost.app
mkdir -p Frost.app/Contents/MacOS Frost.app/Contents/Resources
swiftc -O main.swift -o Frost.app/Contents/MacOS/Frost
Frost.app/Contents/MacOS/Frost --selftest
cp AppIcon.icns Frost.app/Contents/Resources/
cat > Frost.app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Frost</string>
  <key>CFBundleIdentifier</key><string>local.frost</string>
  <key>CFBundleName</key><string>Frost</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
# A real identity keeps permissions across rebuilds; ad-hoc if there is none.
codesign -s "Apple Development" --force Frost.app 2>/dev/null || codesign -s - --force Frost.app
osascript -e 'quit app "Frost"' 2>/dev/null || true
rm -rf /Applications/Frost.app
ditto Frost.app /Applications/Frost.app
echo "installed /Applications/Frost.app"
