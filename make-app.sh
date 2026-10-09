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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Siphon "$APP/Contents/MacOS/Siphon"

# App icon. Siphon.icon is an Icon Composer document: vector layers that
# macOS 26 renders as Liquid Glass at runtime (Assets.car), plus a pre-rendered
# Siphon.icns for older systems. actool needs Xcode 26 or later; without it the
# app simply ships without an icon rather than failing the build.
ICON_OUT="$(mktemp -d)"
if "$(xcode-select -p)/usr/bin/actool" Siphon.icon \
      --compile "$ICON_OUT" \
      --platform macosx --target-device mac --minimum-deployment-target 26.0 \
      --app-icon Siphon --standalone-icon-behavior all \
      --output-partial-info-plist "$ICON_OUT/partial.plist" \
      --output-format human-readable-text --errors >/dev/null 2>&1 \
   && [ -f "$ICON_OUT/Assets.car" ]; then
  cp "$ICON_OUT/Assets.car" "$ICON_OUT/Siphon.icns" "$APP/Contents/Resources/"
  ICON_KEYS='    <key>CFBundleIconFile</key>       <string>Siphon</string>
    <key>CFBundleIconName</key>       <string>Siphon</string>'
else
  echo "⚠️  actool could not compile Siphon.icon (needs Xcode 26+); building without an icon"
  ICON_KEYS=''
fi
rm -rf "$ICON_OUT"

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
${ICON_KEYS}
</dict>
</plist>
PLIST

codesign --force -s - "$APP"
echo "✅ Built $APP (v${VERSION})"
echo "   Launch:         open $APP"
echo "   Start at login: System Settings → General → Login Items"
