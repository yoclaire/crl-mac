#!/bin/bash
# Build "Complete Reference Library.app" into ./dist (release build, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product CRLApp
BIN=$(swift build -c release --show-bin-path)
APP="dist/Complete Reference Library.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/CRLApp" "$APP/Contents/MacOS/CRLApp"
cp -R "$BIN/CRLMac_CRLApp.bundle" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Complete Reference Library</string>
  <key>CFBundleDisplayName</key><string>Complete Reference Library</string>
  <key>CFBundleIdentifier</key><string>com.clairemara.crl-mac</string>
  <key>CFBundleExecutable</key><string>CRLApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.reference</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"
