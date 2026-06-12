#!/usr/bin/env bash
set -euo pipefail

if [ -d /Applications/VoiceRelayMenu.app ]; then
  open /Applications/VoiceRelayMenu.app
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  open "$ROOT/dist/VoiceRelayMenu.app"
fi
