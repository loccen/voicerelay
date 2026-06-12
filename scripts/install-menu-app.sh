#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/VoiceRelayMenu.app"
TARGET="/Applications/VoiceRelayMenu.app"

bash "$ROOT/scripts/build-menu-app.sh"

pkill -f "$TARGET/Contents/MacOS/VoiceRelayMenu" 2>/dev/null || true
rm -rf "$TARGET"
cp -R "$APP" "$TARGET"
open "$TARGET"

echo "已安装并启动 $TARGET"
