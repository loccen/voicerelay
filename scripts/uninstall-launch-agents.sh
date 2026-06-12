#!/usr/bin/env bash
set -euo pipefail

LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
SERVER_LABEL="com.loccen.voicerelay.server"
TUNNEL_LABEL="com.loccen.voicerelay.tunnel"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$SERVER_LABEL" 2>/dev/null || true
launchctl bootout "$DOMAIN/$TUNNEL_LABEL" 2>/dev/null || true

rm -f "$LAUNCH_AGENTS/$SERVER_LABEL.plist"
rm -f "$LAUNCH_AGENTS/$TUNNEL_LABEL.plist"

echo "VoiceRelay LaunchAgents 已停止并移除。"
