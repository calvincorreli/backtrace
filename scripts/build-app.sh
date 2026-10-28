#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/Backtrace.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$PROJECT_DIR"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/Backtrace" "$MACOS_DIR/Backtrace"
strip -S -x "$MACOS_DIR/Backtrace"
cp "$PROJECT_DIR/packaging/Info.plist" "$CONTENTS_DIR/Info.plist"

# The in-app updater pulls and rebuilds this checkout, and compares against this commit.
if SOURCE_COMMIT="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)"; then
  /usr/libexec/PlistBuddy -c "Add :BacktraceSourcePath string $PROJECT_DIR" "$CONTENTS_DIR/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :BacktraceSourceCommit string $SOURCE_COMMIT" "$CONTENTS_DIR/Info.plist"
fi

ASSET_WORK="$(mktemp -d)"
trap 'rm -rf "$ASSET_WORK"' EXIT

mkdir -p "$RESOURCES_DIR/AgentIcons"
qlmanage -t -s 256 -o "$ASSET_WORK" "$PROJECT_DIR/packaging/AgentIcons/"*.svg >/dev/null
swift "$SCRIPT_DIR/remove-svg-matte.swift" "$ASSET_WORK" "$RESOURCES_DIR/AgentIcons"

ICONSET="$ASSET_WORK/AppIcon.iconset"
swift "$SCRIPT_DIR/generate-icon.swift" "$PROJECT_DIR/packaging/AppIcon-v2.png" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/AppIcon.icns"

codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
