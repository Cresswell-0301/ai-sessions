#!/usr/bin/env bash
# Stops AI Sessions and removes its LaunchAgent and ~/Applications/AISessions.app.
# --purge also deletes ~/.ai-sessions/state (logs, read state, snapshot);
# config.json and the sources are kept either way.
set -euo pipefail

LABEL="local.ai-sessions.menubar"
SERVICE="gui/$(id -u)/$LABEL"
APP="$HOME/Applications/AISessions.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

case "${1:-}" in
  "") PURGE=0 ;;
  --purge) PURGE=1 ;;
  *) echo "usage: $0 [--purge]" >&2; exit 64 ;;
esac

echo "==> stopping $SERVICE"
launchctl bootout "$SERVICE" 2>/dev/null || true
rm -f "$AGENT"
pkill -f "$APP/Contents/MacOS/AISessions" 2>/dev/null || true

if [[ -d "$APP" ]]; then
  echo "==> removing $APP"
  "$LSREGISTER" -u "$APP" 2>/dev/null || true
  rm -rf "$APP"
fi

if (( PURGE )); then
  echo "==> removing $HOME/.ai-sessions/state"
  rm -rf "$HOME/.ai-sessions/state"
fi
echo "Uninstalled."
