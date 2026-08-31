#!/bin/bash
# Build Siphon and assemble a minimal .app bundle (menu bar app, no Dock icon).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

# Version: explicit override > git tag > fallback. `|| true` keeps set -e from
# aborting on tarball builds with no git metadata.
GIT_VERSION="$( { git describe --tags --always 2>/dev/null || true; } | sed 's/^v//')"
VERSION="${SIPHON_VERSION:-${GIT_VERSION:-0.0.0}}"

APP=build/Siphon.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Siphon "$APP/Contents/MacOS/Siphon"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleExecutable</key>       <string>Siphon</string>
    <key>CFBundleIdentifier</key>       <string>com.chucai.siphon</string>
    <key>CFBundleName</key>             <string>Siphon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>           <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <key>LSUIElement</key>              <true/>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"
echo "✅ Built $APP (v${VERSION})"
echo "   Launch:         open $APP"
echo "   Start at login: System Settings → General → Login Items"
