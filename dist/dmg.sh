#!/usr/bin/env bash
#
# Package the signed bundle as Bond-Desktop-<version>.dmg, then sign, notarize
# and staple the image itself.
#
# UDZO (zlib) rather than a fancier format: it mounts on every macOS the app
# supports with no extra decompressor, and hdiutil produces it with no third
# party tooling. The staging directory holds exactly the app and a symlink to
# /Applications, which is the drag-to-install window every Mac user knows.
#
# The image is a second signed, notarized artifact, not a wrapper around the
# first: Gatekeeper checks the DMG the user downloaded before anything inside
# it, so it needs its own signature and its own ticket.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERSION="${VERSION:?VERSION is required (make dist-dmg derives it from app/pubspec.yaml)}"
AD_HOC="${AD_HOC:-}"
DIST_ENV="${DIST_ENV:-$ROOT/dist/local/dist.env}"
DIST_NOTARY_TIMEOUT="${DIST_NOTARY_TIMEOUT:-30m}"

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; BLUE='\033[34m'; RESET='\033[0m'
ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
bad()  { printf "  ${RED}✗${RESET} %s\n" "$*"; }
note() { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }
step() { printf "${BLUE}==>${RESET} %s\n" "$*"; }

APP="$ROOT/dist/stage/Bond Desktop.app"
DMG_STAGE="$ROOT/dist/stage/dmg"
OUT="$ROOT/dist/out/Bond-Desktop-$VERSION.dmg"

[ -d "$APP" ] || { bad "no bundle to package — run: make dist-sign"; exit 1; }

if [ -z "$AD_HOC" ]; then
  # shellcheck disable=SC1090
  [ -f "$DIST_ENV" ] && . "$DIST_ENV"
  if [ -z "${DIST_SIGN_IDENTITY:-}" ]; then
    bad "Developer ID signing is not configured — set AD_HOC=1 or create dist/local/dist.env (see dist/README.md)"
    exit 1
  fi
  # The image has to be built from the STAPLED app. A ticket is written into
  # the bundle, so a copy taken before stapling carries none, and the app the
  # user drags out of the image would need Apple's servers to open.
  if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
    bad "the app is not notarized — run: make dist-notarize (make dist does this in order)"
    exit 1
  fi
  ok "the staged app carries a stapled ticket"
fi

step "[1/4] stage the disk image contents"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE" "$ROOT/dist/out"
# ditto, so the signature survives the copy.
ditto "$APP" "$DMG_STAGE/Bond Desktop.app"
ln -s /Applications "$DMG_STAGE/Applications"
ok "Bond Desktop.app + Applications"

step "[2/4] hdiutil create"
rm -f "$OUT"
hdiutil create -volname "Bond Desktop" -srcfolder "$DMG_STAGE" -ov -format UDZO "$OUT" >/dev/null
ok "$(du -h "$OUT" | cut -f1)  $OUT"

# Steps [3/4] and [4/4] are the Developer ID half and stop here: there is no
# identity to sign the image with and nothing Apple would accept.
if [ -n "$AD_HOC" ]; then
  printf "\n"
  note "AD_HOC=1 — steps 3 and 4 skipped; the DMG is unsigned and not notarized"
  note "testers open it through System Settings → Privacy & Security → Open Anyway"
  exit 0
fi

step "[3/4] sign the image"
# No --options runtime here. The hardened runtime is a property of executing
# code, and a disk image does not execute; codesign accepts the flag and it
# means nothing. --timestamp still matters: the notary service rejects a
# signature with no secure timestamp, image or not.
codesign -f -s "$DIST_SIGN_IDENTITY" --timestamp "$OUT"
if out="$(codesign -vvv "$OUT" 2>&1)"; then
  ok "signed and verified"
else
  bad "the image's own signature does not verify"
  printf '%s\n' "$out" | sed 's/^/      /'
  exit 1
fi

step "[4/4] notarize and staple the image"
# AD_HOC= explicitly: this branch is the real one, and an AD_HOC inherited from
# the environment must not turn the submission into a silent no-op.
AD_HOC= DIST_ENV="$DIST_ENV" DIST_NOTARY_TIMEOUT="$DIST_NOTARY_TIMEOUT" \
  "$ROOT/dist/notarize.sh" "$OUT"

printf "\n"
ok "$OUT — signed, notarized, stapled"
