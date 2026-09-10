#!/usr/bin/env bash
#
# Sign Bond Desktop.app inside out.
#
# Two rules that are not negotiable, both from Apple's distribution-signing
# guidance:
#
#  1. INSIDE OUT. Every nested Mach-O is signed before the thing containing it:
#     the .so backends, then the dylibs, then the frameworks, then the
#     llama-server helper, then the app. Signing the app first would seal a
#     hash of unsigned contents and every later signature would invalidate it.
#  2. NEVER `codesign --deep` to SIGN. It applies one identity and one set of
#     entitlements to everything it finds, including the helper that needs its
#     own. `--deep` is for VERIFYING, which is what the last line here uses.
#
# AD_HOC=1 signs with the ad-hoc identity `-` and deliberately WITHOUT
# --options runtime. Hardened runtime turns on library validation, and library
# validation refuses ad-hoc-signed dylibs loaded by an ad-hoc-signed process —
# so an ad-hoc build with the hardened runtime cannot load its own backends.
# The real hardened-runtime rehearsal only exists once a Developer ID
# certificate does (Phase 5).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AD_HOC="${AD_HOC:-}"
DIST_ENV="${DIST_ENV:-$ROOT/dist/local/dist.env}"

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; BLUE='\033[34m'; RESET='\033[0m'
ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
bad()  { printf "  ${RED}✗${RESET} %s\n" "$*"; }
note() { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }
step() { printf "${BLUE}==>${RESET} %s\n" "$*"; }

APP="$ROOT/dist/stage/Bond Desktop.app"
[ -d "$APP" ] || { bad "no bundle to sign — run: make dist-app"; exit 1; }

work="$(mktemp -d)" || exit 1
trap 'rm -rf "$work"' EXIT

# codesign hands the entitlements file to AMFI, whose XML parser is far
# stricter than plutil's: an XML COMMENT anywhere in the file is a hard
# "AMFIUnserializeXML: syntax error near line N". Both entitlement files this
# script passes carry a comment block explaining why they hold what they hold,
# and that documentation is worth keeping.
#
# So round-trip each one through plutil, which reads the commented source and
# writes canonical comment-free XML, and hand codesign the copy. The committed
# files stay readable; AMFI gets what it can parse.
HELPER_ENT="$work/llama-server.entitlements"
APP_ENT="$work/Release.entitlements"
plutil -convert xml1 -o "$HELPER_ENT" "$ROOT/dist/llama-server.entitlements" \
  || { bad "not a valid plist: dist/llama-server.entitlements"; exit 1; }
plutil -convert xml1 -o "$APP_ENT" "$ROOT/app/macos/Runner/Release.entitlements" \
  || { bad "not a valid plist: app/macos/Runner/Release.entitlements"; exit 1; }

# RT is the whole difference between the two branches: an empty array ad-hoc,
# the two distribution flags under a real identity.
RT=()
if [ -n "$AD_HOC" ]; then
  ID="-"
  note "AD_HOC=1 — ad-hoc signature, no hardened runtime, no timestamp"
else
  # shellcheck disable=SC1090
  [ -f "$DIST_ENV" ] && . "$DIST_ENV"
  if [ -z "${DIST_SIGN_IDENTITY:-}" ]; then
    bad "Developer ID signing is not configured — set AD_HOC=1 or create dist/local/dist.env (see dist/README.md)"
    exit 1
  fi
  ID="$DIST_SIGN_IDENTITY"
  RT=(--options runtime --timestamp)
  ok "signing as $ID"
fi

sign() {
  local what="$1"; shift
  # ${RT[@]+"${RT[@]}"} rather than plain "${RT[@]}": macOS ships bash 3.2,
  # where expanding an EMPTY array under `set -u` is an unbound-variable
  # error. That is exactly the ad-hoc path, where RT is empty.
  codesign -f -s "$ID" ${RT[@]+"${RT[@]}"} "$@" "$what"
}

step "[1/5] ggml backends (Contents/MacOS/*.so)"
n=0
for so in "$APP"/Contents/MacOS/*.so; do
  [ -e "$so" ] || continue
  # -i: a loose Mach-O has no Info.plist, so it has no identifier of its own,
  # and two unrelated bundles must not end up claiming the same one.
  sign "$so" -i "com.bondinbox.app.$(basename "$so")"
  n=$((n + 1))
done
ok "$n backend module(s)"

step "[2/5] dylibs (Contents/Frameworks/*.dylib)"
n=0
for dylib in "$APP"/Contents/Frameworks/*.dylib; do
  # Regular files only: the symlinks in a dylib chain point at a file that is
  # signed in its own right, and codesign on the link signs the target twice.
  [ -f "$dylib" ] && [ ! -L "$dylib" ] || continue
  sign "$dylib" -i "com.bondinbox.app.$(basename "$dylib")"
  n=$((n + 1))
done
ok "$n dylib(s)"

step "[3/5] frameworks (Contents/Frameworks/*.framework)"
n=0
for fw in "$APP"/Contents/Frameworks/*.framework; do
  [ -d "$fw" ] || continue
  sign "$fw"
  n=$((n + 1))
done
ok "$n framework(s)"

step "[4/5] llama-server helper"
sign "$APP/Contents/MacOS/llama-server" -i com.bondinbox.app.llama-server \
  --entitlements "$HELPER_ENT"
ok "llama-server"

step "[5/5] the app"
sign "$APP" --entitlements "$APP_ENT"
ok "Bond Desktop.app"

printf "\n"
step "verify (codesign -vvv --deep --strict)"
if codesign -vvv --deep --strict "$APP"; then
  ok "signature is valid and complete"
else
  bad "verification failed"
  exit 1
fi
