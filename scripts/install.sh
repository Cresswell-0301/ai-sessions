#!/usr/bin/env bash
# Builds the app, installs it as ~/Applications/AISessions.app and (re)starts
# its LaunchAgent, which also starts it at every login.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="local.ai-sessions.menubar"
DOMAIN="gui/$(id -u)"
SERVICE="$DOMAIN/$LABEL"
APP="$HOME/Applications/AISessions.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

BUILT="$("$ROOT/scripts/build.sh" | tail -n 1)"

echo "==> stopping $SERVICE (if loaded)"
launchctl bootout "$SERVICE" 2>/dev/null || true
# bootout returns before the job is gone, and bootstrap fails until it is.
for _ in $(seq 1 40); do
  launchctl print "$SERVICE" >/dev/null 2>&1 || break
  sleep 0.25
done
# A copy started by hand (Finder, open) would make the new one exit as a duplicate.
pkill -f "$APP/Contents/MacOS/AISessions" 2>/dev/null || true

echo "==> installing $APP"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/.ai-sessions/state"
rm -rf "$APP"
ditto "$BUILT" "$APP"
"$LSREGISTER" -f "$APP"

echo "==> installing $AGENT"
HOME_ESCAPED="$(printf '%s' "$HOME" | sed 's/[&|\\]/\\&/g')"
sed "s|__HOME__|$HOME_ESCAPED|g" "$ROOT/deploy/$LABEL.plist" > "$AGENT"
plutil -lint "$AGENT"

echo "==> starting $SERVICE"
launchctl bootstrap "$DOMAIN" "$AGENT"
launchctl kickstart -k "$SERVICE"
sleep 1
launchctl print "$SERVICE" | grep -E '^[[:space:]]*(state|pid|program|last exit code) = ' || true
echo "Installed. Log: ~/.ai-sessions/state/ai-sessions.log  (launchd output: launchd.log)"
