#!/usr/bin/env bash
#
# Is this machine able to build and ship a release? One row per prerequisite,
# each with the command that fixes it.
#
# By default this is a REPORT and always exits 0: a red row is information, not
# a failed build, and `make dist-check` on a laptop that only ever builds ad-hoc
# DMGs is expected to show the signing rows red.
#
# STRICT=1 turns it into a gate that exits 1 while anything counted is still
# failing. `make dist` runs it that way as its first step, so a release never
# begins on a machine that cannot finish it — twenty minutes of building and
# then a missing key is the shape of failure this prevents.
#
# DIST_CHECK_OFFLINE=1 skips the one row that talks to Apple.
#
# It never prints a secret. An identity name, a team id and a key id are
# printed because they are on every signed binary anyway; a key's CONTENTS,
# a client secret, a private key or an MCP server URL never appear, only
# whether the file exists and whether its mode is right.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DIST_ENV="${DIST_ENV:-$ROOT/dist/local/dist.env}"
MS_ENV="${MS_ENV:-$ROOT/.env}"
STRICT="${STRICT:-}"
DIST_CHECK_OFFLINE="${DIST_CHECK_OFFLINE:-}"
BOND_DIST_ALLOW_NO_MCP="${BOND_DIST_ALLOW_NO_MCP:-}"

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; BLUE='\033[34m'; RESET='\033[0m'
fails=0
pending=0
row_ok()  { printf "  ${GREEN}✓${RESET} %-34s %s\n" "$1" "${2:-}"; }
row_bad() { printf "  ${RED}✗${RESET} %-34s %s\n" "$1" "${2:-}"; fails=$((fails + 1)); }
# Counted apart from the failures: a row that is not needed for `make dist`
# yet, so a machine showing only these is ready to ship today.
row_todo() { printf "  ${YELLOW}-${RESET} %-34s %s\n" "$1" "${2:-}"; pending=$((pending + 1)); }
# Not counted at all: a row deliberately not run.
row_skip() { printf "  ${YELLOW}-${RESET} %-34s %s\n" "$1" "${2:-}"; }
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

step "signing"
if [ -f "$DIST_ENV" ]; then
  row_ok "dist/local/dist.env" "$DIST_ENV"
else
  row_bad "dist/local/dist.env" "copy dist/local.env.example to $DIST_ENV"
fi

# DIST_SIGN_IDENTITY may hold either the certificate's name or its SHA-1, so
# nothing here assumes a name: the value is matched against find-identity's
# output as a literal, and the row is the count of what it matched. A renewed
# certificate keeps the name of the one it replaced, which is how a name comes
# to match two lines and codesign comes to refuse the run as ambiguous.
ident=""
ident_n=0
if [ -z "${DIST_SIGN_IDENTITY:-}" ]; then
  row_bad "DIST_SIGN_IDENTITY" "set it in dist.env from: security find-identity -v -p codesigning"
else
  ident="$(security find-identity -v -p codesigning 2>/dev/null | grep -F -- "$DIST_SIGN_IDENTITY" || true)"
  # Counted from the text already fetched, never from a second keychain call.
  ident_n="$(printf '%s' "$ident" | grep -c . || true)"
  ident_n="${ident_n:-0}"
  if [ "$ident_n" -eq 0 ]; then
    row_bad "DIST_SIGN_IDENTITY" "not in the login keychain — import the Developer ID .p12 (dist/README.md)"
  elif [ "$ident_n" -gt 1 ]; then
    row_bad "DIST_SIGN_IDENTITY" "matches $ident_n identities — use the SHA-1 hash from find-identity"
  else
    row_ok "DIST_SIGN_IDENTITY" "$(printf '%s\n' "$ident" | sed -E 's/.*"(.*)".*/\1/')"
  fi
fi

if [ -z "${DIST_TEAM_ID:-}" ]; then
  row_bad "DIST_TEAM_ID" "set it in dist.env (the parenthesised id in find-identity)"
elif [ "$ident_n" -eq 1 ]; then
  # The 10-character id in parentheses at the end of the identity name is the
  # team the certificate actually belongs to; dist.env agreeing with it is what
  # keeps sign.sh's team assertions from failing after the whole app is signed.
  cert_team="$(printf '%s\n' "$ident" | sed -E 's/.*\(([A-Z0-9]{10})\)".*/\1/')"
  if [ "$cert_team" = "$DIST_TEAM_ID" ]; then
    row_ok "DIST_TEAM_ID" "$DIST_TEAM_ID"
  else
    row_bad "DIST_TEAM_ID" "dist.env says $DIST_TEAM_ID but the certificate is $cert_team"
  fi
else
  row_ok "DIST_TEAM_ID" "$DIST_TEAM_ID (no single identity to compare it against)"
fi

step "notarization"
key="${DIST_NOTARY_KEY_PATH:-}"
key_ready=""
if [ -z "$key" ]; then
  row_bad "DIST_NOTARY_KEY_PATH" "set it in dist.env — the AuthKey_<id>.p8 from App Store Connect"
elif [ ! -f "$key" ]; then
  row_bad "DIST_NOTARY_KEY_PATH" "no file at that path"
else
  mode="$(stat -f '%Lp' "$key")"
  if [ "$mode" = "600" ]; then
    row_ok "DIST_NOTARY_KEY_PATH" "present, mode 600"
    key_ready=1
  else
    row_bad "DIST_NOTARY_KEY_PATH" "mode $mode — run: chmod 600 '$key'"
  fi
fi

if [ -n "${DIST_NOTARY_KEY_ID:-}" ]; then
  row_ok "DIST_NOTARY_KEY_ID" "$DIST_NOTARY_KEY_ID"
else
  row_bad "DIST_NOTARY_KEY_ID" "set it in dist.env (the key id on the App Store Connect key row)"
  key_ready=""
fi

# Which kind of key this is decides whether --issuer is passed at all: a Team
# key requires it, an individual key rejects the request when it is present.
# Both are correct configurations, so neither spelling is a failure.
if [ -n "${DIST_NOTARY_ISSUER:-}" ]; then
  row_ok "DIST_NOTARY_ISSUER" "set (Team key)"
else
  row_ok "DIST_NOTARY_ISSUER" "blank (individual key — no --issuer)"
fi

if xcrun --find notarytool >/dev/null 2>&1; then
  row_ok "notarytool" "$(xcrun --find notarytool)"
else
  row_bad "notarytool" "needs a full Xcode, not just the command line tools"
  key_ready=""
fi

# The only row that leaves the machine. `notarytool history` is a read: it
# proves the key, the key id and the issuer combination authenticates, without
# spending one of the day's 75 submissions. notarytool's own errors name the
# key id and the reason and never echo the key, so its first line is safe to
# print verbatim.
if [ -n "$DIST_CHECK_OFFLINE" ]; then
  row_skip "notary credentials" "skipped (DIST_CHECK_OFFLINE)"
elif [ -z "$key_ready" ]; then
  row_skip "notary credentials" "skipped — the key rows above have to pass first"
else
  auth=(--key "$DIST_NOTARY_KEY_PATH" --key-id "$DIST_NOTARY_KEY_ID")
  issuer=()
  [ -n "${DIST_NOTARY_ISSUER:-}" ] && issuer=(--issuer "$DIST_NOTARY_ISSUER")
  auth=("${auth[@]}" ${issuer[@]+"${issuer[@]}"})
  err="$(mktemp)" || exit 1
  if xcrun notarytool history "${auth[@]}" >/dev/null 2>"$err"; then
    row_ok "notary credentials" "authenticated with Apple"
  else
    row_bad "notary credentials" "$(head -1 "$err")"
  fi
  rm -f "$err"
fi

if [ -x /usr/bin/syspolicy_check ]; then
  row_ok "syspolicy_check" "/usr/bin/syspolicy_check"
else
  row_bad "syspolicy_check" "absent — macOS 14+ ships it; skip the pre-flight distribution check"
fi

step "updates (Phase 6)"
# Sparkle is not in `make dist` yet, so these are pending rather than failing:
# a machine with every other row green can ship a release today. When
# dist-appcast joins `make dist` they become row_bad, because from then on a
# release without a signed appcast is a release nobody's installed copy sees.
sparkle="${DIST_SPARKLE_PRIVATE_KEY_PATH:-}"
if [ -z "$sparkle" ]; then
  row_todo "DIST_SPARKLE_PRIVATE_KEY_PATH" "Phase 6 — not needed for make dist yet"
elif [ -f "$sparkle" ]; then
  row_ok "DIST_SPARKLE_PRIVATE_KEY_PATH" "present"
else
  row_todo "DIST_SPARKLE_PRIVATE_KEY_PATH" "Phase 6 — set, but no file at that path"
fi

if [ -n "${DIST_APPCAST_URL:-}" ]; then
  row_ok "DIST_APPCAST_URL" "set"
else
  row_todo "DIST_APPCAST_URL" "Phase 6 — not needed for make dist yet"
fi

step "app build inputs"
if [ ! -f "$MS_ENV" ]; then
  row_bad "MS_ENV" "$MS_ENV does not exist — the build would ship with no MCP server URL"
else
  secret="$(sed -n 's/^[[:space:]]*MICROSOFT_CLIENT_SECRET[[:space:]]*=[[:space:]]*//p' "$MS_ENV" | tail -1)"
  # Stripped exactly as dist/bundle.sh strips it, so this row and that
  # refusal can never disagree.
  secret="${secret%\"}"; secret="${secret#\"}"
  secret="${secret%\'}"; secret="${secret#\'}"
  if [ -n "$secret" ]; then
    row_bad "MICROSOFT_CLIENT_SECRET" "NON-EMPTY in $MS_ENV — dist-app refuses to build; blank it or point MS_ENV elsewhere"
  else
    row_ok "MICROSOFT_CLIENT_SECRET" "empty in $(basename "$MS_ENV"), as a distributed build requires"
  fi

  # Parsed exactly as dist/bundle.sh parses it, so this row and that refusal
  # can never disagree. The URL itself is not printed: it names a customer's
  # server, and this report gets pasted into issues.
  mcp="$(sed -n 's/^[[:space:]]*BOND_MCP_SERVER_URL[[:space:]]*=[[:space:]]*//p' "$MS_ENV" | tail -1)"
  mcp="${mcp%\"}"; mcp="${mcp#\"}"
  mcp="${mcp%\'}"; mcp="${mcp#\'}"
  if [ -n "$mcp" ]; then
    row_ok "BOND_MCP_SERVER_URL" "set in $(basename "$MS_ENV")"
  elif [ -n "$BOND_DIST_ALLOW_NO_MCP" ]; then
    # Not counted: the caller has said out loud that this is a pipeline test,
    # and dist-app will build. A release still wants the URL, which is why
    # the row stays visible.
    row_skip "BOND_MCP_SERVER_URL" "missing — BOND_DIST_ALLOW_NO_MCP=1, so this build cannot sign in"
  else
    row_bad "BOND_MCP_SERVER_URL" "missing — dist-app refuses to build without it (or set BOND_DIST_ALLOW_NO_MCP=1 for a pipeline test)"
  fi
fi

printf "\n"
if [ "$fails" -eq 0 ] && [ "$pending" -eq 0 ]; then
  printf "  ${GREEN}all clear${RESET}\n"
elif [ "$fails" -eq 0 ]; then
  printf "  ${GREEN}all clear for make dist${RESET} (%d row(s) pending Phase 6)\n" "$pending"
else
  printf "  ${RED}%d item(s) to fix${RESET}\n" "$fails"
fi

# The report exits 0 by design; only STRICT turns a red row into a failed
# command, and only the counted failures do — a Phase 6 row never blocks a
# release that does not publish an appcast yet.
if [ -n "$STRICT" ] && [ "$fails" -gt 0 ]; then
  exit 1
fi
exit 0
