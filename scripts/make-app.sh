#!/bin/bash
# Build "Complete Reference Library.app" into ./dist (release build, ad-hoc signed).
#
# The app is self-contained: the library decoded from the disc is copied into
# Contents/Resources/library, so the finished app needs no ISO.
#
#   scripts/make-app.sh --iso "Complete Reference Library (1995)(Mindscape).iso"   # decode the disc, then embed
#   scripts/make-app.sh                       # embed an existing library (default: the app's Application Support one)
#   scripts/make-app.sh --library DIR         # embed a library built with `crltool import`
#   scripts/make-app.sh --no-embed            # app without content; it asks for the disc on first launch
#
# The embedded content is the copyrighted disc material: the resulting app is for personal use,
# not for sharing. Nothing from the disc goes into the repository.
set -euo pipefail
cd "$(dirname "$0")/.."

LIB="$HOME/Library/Application Support/Complete Reference Library/library"
ISO=""; EMBED=1
while [ $# -gt 0 ]; do
  case "$1" in
    --iso) ISO="$2"; shift 2 ;;
    --library) LIB="$2"; shift 2 ;;
    --no-embed) EMBED=0; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

swift build -c release --product CRLApp
swift build -c release --product crltool
BIN=$(swift build -c release --show-bin-path)

if [ -n "$ISO" ]; then
  LIB="build/library"
  "$BIN/crltool" import "$ISO" "$LIB"
fi
if [ "$EMBED" = 1 ] && [ ! -f "$LIB/library.sqlite" ]; then
  echo "no library at $LIB — pass --iso <disc image>, --library <dir>, or --no-embed" >&2
  exit 1
fi

APP="dist/Complete Reference Library.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/CRLApp" "$APP/Contents/MacOS/CRLApp"
cp -R "$BIN/CRLMac_CRLApp.bundle" "$APP/Contents/Resources/"
if [ "$EMBED" = 1 ]; then
  # -c makes APFS clones, so embedding ~1 GB costs almost no extra disk space.
  cp -cR "$LIB" "$APP/Contents/Resources/library" 2>/dev/null || cp -R "$LIB" "$APP/Contents/Resources/library"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Complete Reference Library</string>
  <key>CFBundleDisplayName</key><string>Complete Reference Library</string>
  <key>CFBundleIdentifier</key><string>com.clairemara.crl-mac</string>
  <key>CFBundleExecutable</key><string>CRLApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.reference</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "built $APP ($( [ "$EMBED" = 1 ] && echo "content embedded" || echo "no content: imports a disc on first launch" ))"
