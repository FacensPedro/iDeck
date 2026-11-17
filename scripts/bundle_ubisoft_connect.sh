#!/usr/bin/env bash
# Puts Ubisoft Connect's installer into the app (iDeck.app/ubisoft). The Dock installs it
# silently into a Ubisoft game's prefix at the game's first start.
# usage: scripts/bundle_ubisoft_connect.sh <iDeck.app>
set -euo pipefail
APP="$1"
URL="${IDECK_UBISOFT_CONNECT_URL:-https://static3.cdn.ubi.com/orbit/launcher_installer/UbisoftConnectInstaller.exe}"
mkdir -p "$APP/ubisoft"
OUT="$APP/ubisoft/UbisoftConnectInstaller.exe"
if [[ -n "${IDECK_UBISOFT_CONNECT_INSTALLER:-}" ]]; then
  cp "$IDECK_UBISOFT_CONNECT_INSTALLER" "$OUT"
else
  curl -fsSL --retry 4 --retry-delay 5 -o "$OUT" "$URL"
fi
SIZE=$(wc -c < "$OUT" | tr -d ' ')
[[ "$(head -c 2 "$OUT")" == "MZ" && "$SIZE" -gt 1000000 ]] || {
  echo "ERROR: Ubisoft Connect installer is not a Windows program: $OUT ($SIZE bytes)" >&2; exit 2;
}
echo "Bundled Ubisoft Connect installer: $SIZE bytes"
