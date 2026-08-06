#!/bin/zsh
set -euo pipefail

mkdir -p .build/clang-cache .build/cache
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
SWIFTPM_CUSTOM_CACHE_PATH="$PWD/.build/cache" \
swift build -c release
APP="dist/NiceGrab.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp ".build/release/FrameGrab" "$APP/Contents/MacOS/NiceGrab"
cp "Resources/NiceGrab.icns" "$APP/Contents/Resources/NiceGrab.icns"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string NiceGrab "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string NiceGrab "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.appblit.nicegrab "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "Built $APP"
