#!/bin/bash
# Stops UsageBar and removes it from ~/Applications.
set -euo pipefail
pkill -x UsageBar 2>/dev/null || true
rm -rf "$HOME/Applications/UsageBar.app"
defaults delete io.github.usagebar 2>/dev/null || true
echo "UsageBar removed. If it still appears under Login Items, remove it in System Settings."
