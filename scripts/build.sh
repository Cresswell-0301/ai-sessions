#!/usr/bin/env bash
# Builds build/AISessions.app: the release binary, Info.plist and icon,
# ad-hoc signed. Works from any directory; prints the bundle path last.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/AISessions.app"
ICON="$ROOT/Resources/AppIcon.icns"
cd "$ROOT"

echo "==> swift build -c release --product AISessions" >&2
swift build -c release --product AISessions >&2
BIN_DIR="$(swift build -c release --product AISessions --show-bin-path)"

if [[ ! -f "$ICON" ]]; then
  echo "==> rendering Resources/AppIcon.icns" >&2
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  swift "$ROOT/scripts/make-icon.swift" "$WORK/AppIcon.iconset" >&2
  iconutil -c icns "$WORK/AppIcon.iconset" -o "$ICON"
fi

echo "==> assembling $APP" >&2
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AISessions" "$APP/Contents/MacOS/AISessions"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

echo "==> signing (ad hoc) and checking" >&2
codesign --force --sign - "$APP" >&2
codesign --verify --strict --verbose=2 "$APP" >&2
plutil -lint "$APP/Contents/Info.plist" >&2

echo "$APP"
