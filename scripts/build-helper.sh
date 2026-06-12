#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/bin"
swiftc "$ROOT/tools/mac-input-writer.swift" -o "$ROOT/bin/mac-input-writer"
echo "已构建 bin/mac-input-writer"
