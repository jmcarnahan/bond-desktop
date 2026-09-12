#!/usr/bin/env bash
#
# Is this machine able to build and ship a release? One row per prerequisite,
# each with the command that fixes it.
#
# By default this is a REPORT and always exits 0: a red row is information, not
# a failed build, and `make dist-check` on a laptop that only ever builds ad-hoc
# DMGs is expected to show the signing rows red.
#
# STRICT=1 turns it into a gate that exits 1 while any row is still failing.
# `make dist` runs it that way as its first step, so a release never begins on
# a machine that cannot finish it — twenty minutes of building and then a
# missing key is the shape of failure this prevents.
#
# DIST_CHECK_OFFLINE=1 skips the one row that talks to Apple.
# BOND_DIST_ALLOW_NO_MCP=1 turns the missing-MCP-URL row into a skip.
#
# The sections are: the build toolchain, signing, notarization, updates (the
# Sparkle key pair, the two URLs and the version pin the appcast needs) and
# the app build inputs.
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
row_ok()  { printf "  ${GREEN}✓${RESET} %-34s %s\n" "$1" "${2:-}"; }
row_bad() { printf "  ${RED}✗${RESET} %-34s %s\n" "$1" "${2:-}"; fails=$((fails + 1)); }
# Not counted: a row deliberately not run, because what it would ask about
# cannot be answered here yet.
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

# One llama.cpp per release, both platforms. macOS builds it from a pinned
# source tarball and Windows downloads a pinned release asset, and if the two
# tags drift the two installers ship different servers under one version
# number. Both literals are read with anchored patterns, so a tag mentioned in
# a comment cannot answer for the real one.
# `|| true` on both: under set -e/pipefail a missing file would end the whole
# report at sed, and this is a report that always finishes.
mac_tag="$(sed -n 's/^LLAMA_TAG=//p' "$ROOT/dist/build-llama.sh" 2>/dev/null | head -1 || true)"
win_tag="$(sed -n "s/^\\\$LlamaTag *= *'\([^']*\)'.*/\1/p" "$ROOT/dist/windows/fetch-llama.ps1" 2>/dev/null | head -1 || true)"
if [ -z "$mac_tag" ]; then
  row_bad "Windows llama pin" "no LLAMA_TAG literal in dist/build-llama.sh"
elif [ -z "$win_tag" ]; then
  row_bad "Windows llama pin" "no \$LlamaTag literal in dist/windows/fetch-llama.ps1"
elif [ "$win_tag" = "$mac_tag" ]; then
  row_ok "Windows llama pin" "$win_tag (matches dist/build-llama.sh)"
else
  row_bad "Windows llama pin" "build-llama.sh pins $mac_tag, fetch-llama.ps1 pins $win_tag — edit dist/windows/fetch-llama.ps1 to $mac_tag and re-measure its SHA"
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
  mode="$(stat -L -f '%Lp' "$key")"
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

step "updates"
# `make dist` ends with dist-appcast, so every row here is a release
# prerequisite like any other: a release with no signed appcast is a release no
# installed copy of the app ever hears about.
sparkle="${DIST_SPARKLE_PRIVATE_KEY_PATH:-}"
sparkle_ready=""
if [ -z "$sparkle" ]; then
  row_bad "DIST_SPARKLE_PRIVATE_KEY_PATH" "not set — docs/distribution.md → Updates"
elif [ ! -f "$sparkle" ]; then
  row_bad "DIST_SPARKLE_PRIVATE_KEY_PATH" "no file at that path — docs/distribution.md → Updates"
else
  row_ok "DIST_SPARKLE_PRIVATE_KEY_PATH" "present"
  sparkle_ready=1
  # The same rule the .p8 gets, and for a stronger reason: whoever holds this
  # file can sign an update every installed copy of Bond installs without
  # asking.
  smode="$(stat -L -f '%Lp' "$sparkle")"
  if [ "$smode" = "600" ]; then
    row_ok "  mode" "600"
  else
    row_bad "  mode" "$smode — run: chmod 600 '$sparkle'"
  fi
fi

# 32 bytes base64 is 43 characters and one '=' of padding. Checked in shape
# only, because the key-pair row below is what checks it for real.
pub="${DIST_SPARKLE_PUBLIC_KEY:-}"
pub_ready=""
if [ -z "$pub" ]; then
  row_bad "DIST_SPARKLE_PUBLIC_KEY" "not set — docs/distribution.md → Updates"
elif ! printf '%s' "$pub" | grep -qE '^[A-Za-z0-9+/]{43}=$'; then
  row_bad "DIST_SPARKLE_PUBLIC_KEY" "does not look like a Sparkle public key (44 base64 characters)"
else
  row_ok "DIST_SPARKLE_PUBLIC_KEY" "set"
  pub_ready=1
fi

# The row that catches the failure with no symptom. A public key that is not
# this private key's half builds an app whose SUPublicEDKey verifies nothing
# the release signs: every check succeeds, every update is refused, and the
# only fix is another release.
if [ -n "$sparkle_ready" ] && [ -n "$pub_ready" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    # Counted, unlike the pins row: this is the one check whose failure has no
    # symptom, and the command line tools this report already requires ship
    # python3.
    row_bad "Sparkle key pair" "cannot be checked — python3 is not on PATH"
  else
    derived="$(python3 "$ROOT/dist/sparkle-pubkey.py" "$sparkle" 2>/dev/null || true)"
    if [ -z "$derived" ]; then
      row_bad "Sparkle key pair" "the file at DIST_SPARKLE_PRIVATE_KEY_PATH is not a Sparkle private key (generate_keys -x writes one)"
    elif [ "$derived" = "$pub" ]; then
      row_ok "Sparkle key pair" "the public key is the private key's"
    else
      row_bad "Sparkle key pair" "DIST_SPARKLE_PUBLIC_KEY is not the public half of the key at DIST_SPARKLE_PRIVATE_KEY_PATH — an app built with it would never accept an update"
    fi
  fi
fi

# Both URLs are printed as "set" and never as values: they are public in the
# shipped plist and in the feed, and this report still gets pasted into issues.
feed="${DIST_APPCAST_URL:-}"
if [ -z "$feed" ]; then
  row_bad "DIST_APPCAST_URL" "not set — docs/distribution.md → Updates"
elif ! printf '%s' "$feed" | grep -q '^https://'; then
  row_bad "DIST_APPCAST_URL" "must start with https:// — a feed served over http is one anybody on the network can rewrite"
else
  row_ok "DIST_APPCAST_URL" "set"
fi

prefix="${DIST_DOWNLOAD_URL_PREFIX:-}"
if [ -z "$prefix" ]; then
  row_bad "DIST_DOWNLOAD_URL_PREFIX" "not set — docs/distribution.md → Updates"
elif ! printf '%s' "$prefix" | grep -q '^https://'; then
  row_bad "DIST_DOWNLOAD_URL_PREFIX" "must start with https:// and end with / — generate_appcast appends the file name to it directly"
elif ! printf '%s' "$prefix" | grep -q '/$'; then
  row_bad "DIST_DOWNLOAD_URL_PREFIX" "must start with https:// and end with / — generate_appcast appends the file name to it directly"
elif printf '%s' "$prefix" | grep -qF '{version}'; then
  row_ok "DIST_DOWNLOAD_URL_PREFIX" "set · {version} substituted per release"
else
  row_ok "DIST_DOWNLOAD_URL_PREFIX" "set"
fi

# The two Sparkle pins have to move together: dist/sparkle-tools.sh fetches the
# command line tools that WRITE the feed, and the pbxproj pins the framework
# that READS it. A tools version ahead of the framework can write a feed the
# shipped app will not accept.
# The workspace copy first — it is the one `flutter build macos` resolves —
# then the project's own, which Xcode writes with the same contents.
resolved="$ROOT/app/macos/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved"
[ -f "$resolved" ] || resolved="$ROOT/app/macos/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
tools_pin="$(sed -n 's/^SPARKLE_VERSION=//p' "$ROOT/dist/sparkle-tools.sh" | head -1)"
if [ ! -f "$resolved" ]; then
  row_skip "Sparkle pins" "no build yet — make dist-app resolves it"
elif ! command -v python3 >/dev/null 2>&1; then
  row_skip "Sparkle pins" "skipped — python3 is not on PATH"
else
  embedded="$(python3 - "$resolved" <<'PY' || true
import json, sys
with open(sys.argv[1]) as handle:
    doc = json.load(handle)
for pin in doc.get("pins", []):
    identity = pin.get("identity") or pin.get("package", "")
    if identity.lower() == "sparkle":
        print(pin.get("state", {}).get("version", ""))
        break
PY
)"
  if [ -z "$embedded" ]; then
    row_bad "Sparkle pins" "Package.resolved has no sparkle pin — the Xcode project should reference sparkle-project/Sparkle"
  elif [ "$embedded" = "$tools_pin" ]; then
    row_ok "Sparkle pins" "$tools_pin (tools and framework)"
  else
    row_bad "Sparkle pins" "dist/sparkle-tools.sh pins $tools_pin, the app embeds $embedded — move them together"
  fi
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
if [ "$fails" -eq 0 ]; then
  printf "  ${GREEN}all clear${RESET}\n"
else
  printf "  ${RED}%d item(s) to fix${RESET}\n" "$fails"
fi

# The report exits 0 by design; only STRICT turns a red row into a failed
# command.
if [ -n "$STRICT" ] && [ "$fails" -gt 0 ]; then
  exit 1
fi
exit 0
