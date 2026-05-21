#!/bin/bash
# ─────────────────────────────────────────────────────────
#  build.sh — 编译 ActivityTracker Swift 版并构建 App Bundle
# ─────────────────────────────────────────────────────────
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SRC="$SCRIPT_DIR/Sources"
BUILD="$SCRIPT_DIR/build"
APP_NAME="ActivityTracker"
VERSION="2.0.0"
SDK="$(xcrun --show-sdk-path 2>/dev/null)"

rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "==> 编译 Swift 源码..."
swiftc \
  "$SRC/main.swift" \
  "$SRC/Database.swift" \
  "$SRC/ConfigStore.swift" \
  "$SRC/APIHandlers.swift" \
  "$SRC/SchemeHandler.swift" \
  "$SRC/ActivityDialog.swift" \
  "$SRC/AppDelegate.swift" \
  "$SRC/LaunchAgent.swift" \
  -sdk "$SDK" \
  -framework AppKit \
  -framework WebKit \
  -framework Foundation \
  -lsqlite3 \
  -module-name ActivityTracker \
  -O \
  -o "$BUILD/$APP_NAME"

echo "==> 构建 App Bundle..."
APP="$BUILD/$APP_NAME.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
mkdir -p "$MACOS" "$RES"

cp "$BUILD/$APP_NAME" "$MACOS/"
cp "$PROJECT_DIR/templates/index.html" "$RES/"

# 图标（若存在）
ICON="$PROJECT_DIR/ActivityTracker.app/Contents/Resources/AppIcon.icns"
[ -f "$ICON" ] && cp "$ICON" "$RES/"

cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key>             <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>      <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>       <string>com.tychebian.activitytracker</string>
  <key>CFBundleVersion</key>          <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key>         <string>AppIcon</string>
  <key>CFBundlePackageType</key>      <string>APPL</string>
  <key>CFBundleExecutable</key>       <string>${APP_NAME}</string>
  <key>LSMinimumSystemVersion</key>   <string>13.0</string>
  <key>NSHighResolutionCapable</key>  <true/>
  <key>LSUIElement</key>              <true/>
  <key>NSUserNotificationAlertStyle</key><string>banner</string>
</dict></plist>
PLIST

echo "==> Ad-hoc 签名..."
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  ✓ 构建完成：build/${APP_NAME}.app       ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "测试运行："
echo "  open $APP"
