#!/bin/bash
# Builds DynamicWall.app from the command line (Xcode or just the Command Line Tools).
# Most of the time you'll use Xcode instead: open DynamicWall.xcodeproj and press Run.
#
#   scripts/build.sh                 → local test build in build/DynamicWall.app (ad-hoc signed)
#   scripts/build.sh release "Developer ID Application: Your Name (TEAMID)"
#                                    → signed, notarized build/DynamicWall.dmg ready to share
#     (first run once: xcrun notarytool store-credentials dynamicwall --apple-id you@example.com --team-id TEAMID)
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-dev}"
IDENTITY="${2:--}"
SRC=DynamicWall
OUT=build
APP="$OUT/DynamicWall.app"
PBX=DynamicWall.xcodeproj/project.pbxproj

# Version numbers live in the Xcode project, so there's one place to bump them.
VERSION=$(grep -m1 'MARKETING_VERSION' "$PBX" | sed -E 's/.*= *([^;]+);.*/\1/')
BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION' "$PBX" | sed -E 's/.*= *([^;]+);.*/\1/')

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary (Apple Silicon + Intel), optimized.
TMP=$(mktemp -d)
swiftc -O -parse-as-library -target arm64-apple-macos14.0  "$SRC/DynamicWall.swift" -o "$TMP/arm64"
swiftc -O -parse-as-library -target x86_64-apple-macos14.0 "$SRC/DynamicWall.swift" -o "$TMP/x86_64"
lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$APP/Contents/MacOS/DynamicWall"

# App icon, made from the same PNGs the Xcode asset catalog uses.
mkdir -p "$TMP/AppIcon.iconset"
cp "$SRC"/Assets.xcassets/AppIcon.appiconset/icon_*.png "$TMP/AppIcon.iconset/"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$SRC/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/"
rm -rf "$TMP"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>DynamicWall</string>
  <key>CFBundleDisplayName</key><string>DynamicWall</string>
  <key>CFBundleIdentifier</key><string>com.shantanukhedar.dynamicwall</string>
  <key>CFBundleExecutable</key><string>DynamicWall</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright 2026 Shantanu Khedar. Pictures are copyright their respective owners.</string>
</dict></plist>
EOF

# Hardened runtime + sandbox entitlements.
TS="--timestamp"; [ "$IDENTITY" = "-" ] && TS="--timestamp=none"
codesign --force $TS --options runtime --entitlements "$SRC/DynamicWall.entitlements" --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [ "$MODE" = "release" ]; then
  [ "$IDENTITY" = "-" ] && { echo "Release needs a Developer ID identity."; exit 1; }
  DMG="$OUT/DynamicWall-$VERSION.dmg"
  rm -f "$DMG"
  hdiutil create -volname DynamicWall -srcfolder "$APP" -ov -format UDZO "$DMG"
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile dynamicwall --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  echo "✅ $DMG is signed, notarized and ready to publish."
else
  echo "✅ Built $APP (version $VERSION, build $BUILD). Move it to /Applications and open it."
fi
