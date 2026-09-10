#!/usr/bin/env bash
#
# Is this machine able to build and ship a release? One row per prerequisite,
# each with the command that fixes it.
#
# This is a REPORT, so it always exits 0: a red row is information, not a
# failed build, and `make dist-check` on a laptop that only ever builds ad-hoc
# DMGs is expected to show the signing rows red.
#
# It never prints a secret. An identity name, a team id and a key id are
# printed because they are on every signed binary anyway; a key's CONTENTS,
# a client secret or a private key never appear, only whether the file exists
# and whether its mode is right.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DIST_ENV="${DIST_ENV:-$ROOT/dist/local/dist.env}"
MS_ENV="${MS_ENV:-$ROOT/.env}"

GREEN='\033[32m'; RED='\033[31m'; BLUE='\033[34m'; RESET='\033[0m'
fails=0
row_ok()  { printf "  ${GREEN}✓${RESET} %-34s %s\n" "$1" "${2:-}"; }
row_bad() { printf "  ${RED}✗${RESET} %-34s %s\n" "$1" "${2:-}"; fails=$((fails + 1)); }
step()    { printf "${BLUE}==>${RESET} %s\n" "$*"; }

# dist.env is sourced in a subshell-safe way: unset vars stay unset, and
# `set -u` below must not trip over them, hence every ${X:-} read.
if [ -f "$DIST_ENV" ]; then
  # shellcheck disable=SC1090
  . "$DIST_ENV"
fi

step "build toolchain"
if xcode-select -p >/dev/null 2>&1; then
  row_ok "Xcode command line tools" "$(xcode-select -p)"
else
  row_bad "Xcode command line tools" "run: xcode-select --install"
fi

if command -v cmake >/dev/null 2>&1; then
  row_ok "cmake" "$(cmake --version | head -1 | awk '{print $3}')"
else
  row_bad "cmake" "run: brew install cmake"
fi

# Xcode 26 moved the Metal shader compiler into a separately downloaded
# component. Without it `xcrun metal` is a stub that errors, ggml's
# .metal kernels cannot be compiled, and dist-llama fails at the metallib
# step — with a message that does not obviously name this as the cause.
if xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  row_ok "Metal toolchain" "installed"
else
  row_bad "Metal toolchain" "run: xcodebuild -downloadComponent MetalToolchain"
fi

if command -v flutter >/dev/null 2>&1; then
  fv="$(flutter --version 2>/dev/null | sed -n 's/^Flutter \([0-9.]*\).*/\1/p' | head -1)"
  # Sort-based compare, so 3.47 vs 3.5 does not read as "smaller".
  if [ -n "$fv" ] && [ "$(printf '3.47\n%s\n' "$fv" | sort -V | head -1)" = "3.47" ]; then
    row_ok "flutter >= 3.47" "$fv"
  else
    row_bad "flutter >= 3.47" "found ${fv:-unknown} — run: flutter upgrade"
  fi
else
  row_bad "flutter >= 3.47" "not on PATH — see QUICKSTART.md"
fi

step "signing (Phase 5)"
if [ -f "$DIST_ENV" ]; then
  row_ok "dist/local/dist.env" "$DIST_ENV"
else
  row_bad "dist/local/dist.env" "copy dist/local.env.example to $DIST_ENV"
fi

if [ -z "${DIST_SIGN_IDENTITY:-}" ]; then
  row_bad "DIST_SIGN_IDENTITY" "set it in dist.env from: security find-identity -v -p codesigning"
else
  found="$(security find-identity -v -p codesigning 2>/dev/null | grep -c "Developer ID Application" || true)"
  if [ "${found:-0}" -ge 1 ]; then
    row_ok "DIST_SIGN_IDENTITY" "$DIST_SIGN_IDENTITY (${found} Developer ID cert(s) in the keychain)"
  else
    row_bad "DIST_SIGN_IDENTITY" "set, but no Developer ID Application certificate is in the login keychain"
  fi
fi

if [ -n "${DIST_TEAM_ID:-}" ]; then
  row_ok "DIST_TEAM_ID" "$DIST_TEAM_ID"
else
  row_bad "DIST_TEAM_ID" "set it in dist.env (the parenthesised id in find-identity)"
fi

step "notarization (Phase 5)"
key="${DIST_NOTARY_KEY_PATH:-}"
if [ -z "$key" ]; then
  row_bad "DIST_NOTARY_KEY_PATH" "set it in dist.env — the AuthKey_<id>.p8 from App Store Connect"
elif [ ! -f "$key" ]; then
  row_bad "DIST_NOTARY_KEY_PATH" "no file at that path"
else
  mode="$(stat -f '%Lp' "$key")"
  if [ "$mode" = "600" ]; then
    row_ok "DIST_NOTARY_KEY_PATH" "present, mode 600"
  else
    row_bad "DIST_NOTARY_KEY_PATH" "mode $mode — run: chmod 600 '$key'"
  fi
fi

if [ -n "${DIST_NOTARY_KEY_ID:-}" ]; then
  row_ok "DIST_NOTARY_KEY_ID" "$DIST_NOTARY_KEY_ID"
else
  row_bad "DIST_NOTARY_KEY_ID" "set it in dist.env (the key id on the App Store Connect key row)"
fi

if xcrun --find notarytool >/dev/null 2>&1; then
  row_ok "notarytool" "$(xcrun --find notarytool)"
else
  row_bad "notarytool" "needs a full Xcode, not just the command line tools"
fi

if [ -x /usr/bin/syspolicy_check ]; then
  row_ok "syspolicy_check" "/usr/bin/syspolicy_check"
else
  row_bad "syspolicy_check" "absent — macOS 14+ ships it; skip the pre-flight distribution check"
fi

step "updates (Phase 6)"
sparkle="${DIST_SPARKLE_PRIVATE_KEY_PATH:-}"
if [ -z "$sparkle" ]; then
  row_bad "DIST_SPARKLE_PRIVATE_KEY_PATH" "set it in dist.env — generate_keys then export with -x"
elif [ -f "$sparkle" ]; then
  row_ok "DIST_SPARKLE_PRIVATE_KEY_PATH" "present"
else
  row_bad "DIST_SPARKLE_PRIVATE_KEY_PATH" "no file at that path"
fi

step "app build inputs"
if [ ! -f "$MS_ENV" ]; then
  row_bad "MS_ENV" "$MS_ENV does not exist — the build would ship with no MCP server URL"
else
  secret="$(sed -n 's/^[[:space:]]*MICROSOFT_CLIENT_SECRET[[:space:]]*=[[:space:]]*//p' "$MS_ENV" | tail -1)"
  secret="${secret//\"/}"; secret="${secret//\'/}"
  if [ -n "$secret" ]; then
    row_bad "MICROSOFT_CLIENT_SECRET" "NON-EMPTY in $MS_ENV — dist-app refuses to build; blank it or point MS_ENV elsewhere"
  else
    row_ok "MICROSOFT_CLIENT_SECRET" "empty in $(basename "$MS_ENV"), as a distributed build requires"
  fi
fi

printf "\n"
if [ "$fails" -eq 0 ]; then
  printf "  ${GREEN}all clear${RESET}\n"
else
  printf "  ${RED}%d item(s) to fix${RESET}\n" "$fails"
fi
exit 0
