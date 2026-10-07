#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_DIR="$PROJECT_DIR/dist/Glance.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
MODULE_CACHE="${TMPDIR:-/private/tmp}/codex-touchbar-module-cache"

if [[ ! -d "$SDK_PATH" ]]; then
  SDK_PATH="$(xcrun --show-sdk-path)"
fi

# Sign with a fixed identity when CODESIGN_IDENTITY names one (see
# scripts/create_local_signing_identity.sh); otherwise sign ad hoc as before.
# A fixed identity keeps the designated requirement, and with it the
# Accessibility grant, stable across rebuilds.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

mkdir -p "$MODULE_CACHE"
cd "$PROJECT_DIR"

# Shared Command Line Tools workarounds. This app is AppKit-only, so it needs the
# build-system fix and the SDK stamp check, not the SwiftUI SDK selection.
source "$SCRIPT_DIR/clt-swift-env.sh"

env SDKROOT="$SDK_PATH" \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
  swift build --disable-sandbox -c release "${CLT_SWIFT_BUILD_SYSTEM_ARGS[@]}" --product CodexTouchBar

BUILD_DIR="$(env SDKROOT="$SDK_PATH" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" swift build --disable-sandbox -c release "${CLT_SWIFT_BUILD_SYSTEM_ARGS[@]}" --show-bin-path)"

SDKROOT="$SDK_PATH" clt_check_sdk_stamp "$BUILD_DIR/CodexTouchBar"

rm -rf -- "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
ditto "$BUILD_DIR/CodexTouchBar" "$MACOS_DIR/CodexTouchBar"
ditto "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
ditto "$PROJECT_DIR/Resources/CodexTouchBar.icns" "$RESOURCES_DIR/CodexTouchBar.icns"
chmod 755 "$MACOS_DIR/CodexTouchBar"
codesign --force --sign "$CODESIGN_IDENTITY" --timestamp=none "$APP_DIR"
plutil -lint "$CONTENTS_DIR/Info.plist"
codesign --verify --deep --strict "$APP_DIR"
codesign --display --requirements - "$APP_DIR" 2>/dev/null | grep 'designated' || true

print "$APP_DIR"
