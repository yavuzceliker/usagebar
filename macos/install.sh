#!/bin/bash
# Builds UsageBar and installs it into ~/Applications, then launches it.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

DEST="$HOME/Applications/UsageBar.app"
pkill -x UsageBar 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R build/UsageBar.app "$DEST"
open "$DEST"
echo "Installed to $DEST. Use the gear icon → 'Launch at login' to start it automatically."
