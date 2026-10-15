#!/bin/bash
#
# build_app.sh — builds MissionControlBuddy.app (a proper bundle).
#
# A real .app bundle is required for:
#   * "Launch at Login" (SMAppService needs a registered bundle)
#   * a stable Accessibility permission entry (tied to the bundle, not Terminal)
#
# Usage:
#   ./build_app.sh              # build the .app into ./dist
#   ./build_app.sh --install    # also copy it to /Applications
#   ./build_app.sh --universal  # build for Apple Silicon and Intel
#
# The version shown in About comes from VERSION (default 1.0.2), for example:
#   VERSION=1.0.2-local.1 ./build_app.sh --universal
#

set -euo pipefail

APP_NAME="MissionControlBuddy"
BUNDLE_ID="com.local.missioncontrolbuddy"
DIST_DIR="dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
VERSION="${VERSION:-1.0.2}"

INSTALL=0
ARCH_FLAGS=()
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

echo "🔨 Building release binary…"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}

BIN_PATH="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/$APP_NAME"
if [ ! -f "$BIN_PATH" ]; then
    echo "❌ Built binary not found at $BIN_PATH"
    exit 1
fi

echo "📦 Assembling $APP_NAME.app…"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"

# App icon (generate if missing).
if [ ! -f "Resources/AppIcon.icns" ]; then
    echo "🎨 Generating app icon…"
    swift make_icon.swift || echo "⚠️  icon generation failed (continuing without icon)"
fi
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Mission Control Buddy</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc code signature so the Accessibility permission sticks across launches.
echo "🔏 Ad-hoc signing…"
codesign --force --deep --sign - "$APP_DIR" || echo "⚠️  codesign failed (continuing unsigned)"

echo "✅ Built: $APP_DIR"

if [ "$INSTALL" == 1 ]; then
    echo "🚚 Installing to /Applications…"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_DIR" "/Applications/"
    echo "✅ Installed: /Applications/$APP_NAME.app"
    echo "💡 Launch it from Applications, then grant Accessibility permission."
fi
