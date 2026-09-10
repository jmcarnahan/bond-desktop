#!/usr/bin/env bash
#
# Package the signed bundle as Bond-Desktop-<version>.dmg.
#
# UDZO (zlib) rather than a fancier format: it mounts on every macOS the app
# supports with no extra decompressor, and hdiutil produces it with no third
# party tooling. The staging directory holds exactly the app and a symlink to
# /Applications, which is the drag-to-install window every Mac user knows.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERSION="${VERSION:?VERSION is required (make dist-dmg derives it from app/pubspec.yaml)}"
AD_HOC="${AD_HOC:-}"

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; BLUE='\033[34m'; RESET='\033[0m'
ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
bad()  { printf "  ${RED}✗${RESET} %s\n" "$*"; }
note() { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }
step() { printf "${BLUE}==>${RESET} %s\n" "$*"; }

APP="$ROOT/dist/stage/Bond Desktop.app"
DMG_STAGE="$ROOT/dist/stage/dmg"
OUT="$ROOT/dist/out/Bond-Desktop-$VERSION.dmg"

[ -d "$APP" ] || { bad "no bundle to package — run: make dist-sign"; exit 1; }

step "[1/2] stage the disk image contents"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE" "$ROOT/dist/out"
# ditto, so the signature survives the copy.
ditto "$APP" "$DMG_STAGE/Bond Desktop.app"
ln -s /Applications "$DMG_STAGE/Applications"
ok "Bond Desktop.app + Applications"

step "[2/2] hdiutil create"
rm -f "$OUT"
hdiutil create -volname "Bond Desktop" -srcfolder "$DMG_STAGE" -ov -format UDZO "$OUT" >/dev/null
ok "$(du -h "$OUT" | cut -f1)  $OUT"

# Phase 5: sign + notarize + staple the DMG here — codesign the .dmg with
# DIST_SIGN_IDENTITY, then dist/notarize.sh (notarytool submit --wait, log,
# stapler staple), then `xcrun stapler validate` the image.

printf "\n"
if [ -n "$AD_HOC" ]; then
  note "AD_HOC=1 — DMG is unsigned and not notarized; testers use System Settings → Privacy & Security → Open Anyway"
fi
