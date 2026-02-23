#!/bin/bash
# build-dmg.sh — Build NetScan.app (Release) and package it as a DMG.
#
# Usage:
#   ./scripts/build-dmg.sh [version]
#
# Requirements:
#   brew install create-dmg   (optional, falls back to hdiutil)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
XCODEPROJ="$PROJECT_DIR/NetScan.xcodeproj"
SCHEME="NetScan-Release"
CONFIGURATION="Release"
BUILD_DIR="$PROJECT_DIR/.build/xcode"
ARCHIVE_PATH="$BUILD_DIR/NetScan.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
DMG_DIR="$PROJECT_DIR/.build/dmg"
APP_NAME="NetScan"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  # Read from project.pbxproj
  VERSION=$(grep -m1 'MARKETING_VERSION' "$XCODEPROJ/project.pbxproj" \
    | sed 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/' | tr -d ' ')
fi
echo "==> Building $APP_NAME $VERSION"

# 1. Clean
echo "--- Cleaning build directory"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DMG_DIR"

# 2. Archive
echo "--- Archiving (Release)"
xcodebuild archive \
  -project "$XCODEPROJ" \
  -scheme  "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  CODE_SIGN_STYLE=Automatic \
  | xcpretty 2>/dev/null || true

# 3. Export
echo "--- Exporting app"
cat > "$BUILD_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string></string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -exportPath "$EXPORT_PATH" \
  | xcpretty 2>/dev/null || true

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
# Fallback: copy directly from archive
if [ ! -d "$APP_PATH" ]; then
  APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
fi

DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="$DMG_DIR/$DMG_NAME"

# 4. Create DMG
echo "--- Creating $DMG_NAME"
if command -v create-dmg &>/dev/null; then
  create-dmg \
    --volname "$APP_NAME $VERSION" \
    --volicon "$APP_PATH/Contents/Resources/AppIcon.icns" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "$APP_NAME.app" 175 190 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 425 190 \
    "$DMG_PATH" \
    "$APP_PATH"
else
  # Fallback: plain hdiutil
  TMP_DMG_DIR=$(mktemp -d)
  cp -R "$APP_PATH" "$TMP_DMG_DIR/"
  ln -s /Applications "$TMP_DMG_DIR/Applications"
  hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$TMP_DMG_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"
  rm -rf "$TMP_DMG_DIR"
fi

echo ""
echo "==> Done: $DMG_PATH"
echo "    Size: $(du -sh "$DMG_PATH" | cut -f1)"
