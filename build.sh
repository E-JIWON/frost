#!/bin/sh
# Builds Frost.app next to this script, checks it, and installs it to /Applications.
# Given a path, only builds the app there (Homebrew uses this): ./build.sh /some/where/Frost.app
set -e
cd "$(dirname "$0")"
app=${1:-Frost.app}
case "$app" in *.app) ;; *) echo "the path must end in .app" >&2; exit 1 ;; esac
[ -f AppIcon.icns ] || swift icon.swift
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O main.swift -o "$app/Contents/MacOS/Frost"
"$app/Contents/MacOS/Frost" --selftest
cp AppIcon.icns "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Frost</string>
  <key>CFBundleIdentifier</key><string>local.frost</string>
  <key>CFBundleName</key><string>Frost</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2.0</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
# A real identity keeps permissions across rebuilds; ad-hoc if there is none.
codesign -s "Apple Development" --force "$app" 2>/dev/null || codesign -s - --force "$app"
if [ -n "$1" ]; then exit 0; fi
osascript -e 'quit app "Frost"' 2>/dev/null || true
rm -rf /Applications/Frost.app
ditto "$app" /Applications/Frost.app
echo "installed /Applications/Frost.app"
