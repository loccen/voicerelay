#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/VoiceRelayMenu.app"
SIGN_IDENTITY="VoiceRelay Local Code Signing"
NODE_BIN="${NODE_BIN:-$(command -v node)}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-$(command -v cloudflared || true)}"
CLOUDFLARED_CONFIG="${CLOUDFLARED_CONFIG:-$HOME/.cloudflared/config.yml}"
PUBLIC_URL="${PUBLIC_URL:-http://127.0.0.1:5454/}"

if [ -z "$CLOUDFLARED_BIN" ]; then
  CLOUDFLARED_BIN="/opt/homebrew/bin/cloudflared"
fi

bash "$ROOT/scripts/build-helper.sh"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/menuapp/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/menuapp/Assets/VoiceRelayIcon.icns" "$APP/Contents/Resources/VoiceRelayIcon.icns"
cp "$ROOT/menuapp/Assets/StatusIconTemplate.png" "$APP/Contents/Resources/StatusIconTemplate.png"
cp "$ROOT/bin/mac-input-writer" "$APP/Contents/MacOS/mac-input-writer"
/usr/libexec/PlistBuddy -c "Add :VoiceRelayProjectRoot string $ROOT" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :VoiceRelayNodePath string $NODE_BIN" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :VoiceRelayCloudflaredPath string $CLOUDFLARED_BIN" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :VoiceRelayCloudflaredConfig string $CLOUDFLARED_CONFIG" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :VoiceRelayPublicURL string $PUBLIC_URL" "$APP/Contents/Info.plist"
swiftc "$ROOT/menuapp/main.swift" "$ROOT/menuapp/VoiceRelayMenu.swift" -o "$APP/Contents/MacOS/VoiceRelayMenu"
chmod +x "$APP/Contents/MacOS/VoiceRelayMenu"
chmod +x "$APP/Contents/MacOS/mac-input-writer"
if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" >/dev/null
else
  codesign --force --deep --sign - "$APP" >/dev/null
fi

echo "已构建 $APP"
