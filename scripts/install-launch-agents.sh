#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
SERVER_LABEL="com.loccen.voicerelay.server"
TUNNEL_LABEL="com.loccen.voicerelay.tunnel"
DOMAIN="gui/$(id -u)"
NODE_BIN="${NODE_BIN:-$(command -v node)}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-$(command -v cloudflared || true)}"
CLOUDFLARED_CONFIG="${CLOUDFLARED_CONFIG:-$HOME/.cloudflared/config.yml}"
PUBLIC_URL="${PUBLIC_URL:-http://127.0.0.1:5454/}"

if [ -z "$CLOUDFLARED_BIN" ]; then
  CLOUDFLARED_BIN="/opt/homebrew/bin/cloudflared"
fi

mkdir -p "$LAUNCH_AGENTS"

bash "$ROOT/scripts/build-helper.sh"

SERVER_PLIST="$LAUNCH_AGENTS/$SERVER_LABEL.plist"
TUNNEL_PLIST="$LAUNCH_AGENTS/$TUNNEL_LABEL.plist"

launchctl bootout "$DOMAIN/$SERVER_LABEL" 2>/dev/null || true
launchctl bootout "$DOMAIN/$TUNNEL_LABEL" 2>/dev/null || true

cat >"$SERVER_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$SERVER_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE_BIN</string>
    <string>$ROOT/src/server.js</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$ROOT</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PORT</key>
    <string>5454</string>
    <key>PUBLIC_URL</key>
    <string>$PUBLIC_URL</string>
    <key>MAC_INPUT_WRITER_PATH</key>
    <string>$ROOT/bin/mac-input-writer</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$ROOT/.voicerelay.log</string>
  <key>StandardErrorPath</key>
  <string>$ROOT/.voicerelay.err.log</string>
</dict>
</plist>
PLIST

cat >"$TUNNEL_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$TUNNEL_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$CLOUDFLARED_BIN</string>
    <string>tunnel</string>
    <string>--config</string>
    <string>$CLOUDFLARED_CONFIG</string>
    <string>run</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$ROOT</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$ROOT/.cloudflared-voicerelay.log</string>
  <key>StandardErrorPath</key>
  <string>$ROOT/.cloudflared-voicerelay.err.log</string>
</dict>
</plist>
PLIST

launchctl bootstrap "$DOMAIN" "$SERVER_PLIST"
launchctl bootstrap "$DOMAIN" "$TUNNEL_PLIST"
launchctl kickstart -k "$DOMAIN/$SERVER_LABEL"
launchctl kickstart -k "$DOMAIN/$TUNNEL_LABEL"

echo "VoiceRelay LaunchAgents 已安装并启动。"
