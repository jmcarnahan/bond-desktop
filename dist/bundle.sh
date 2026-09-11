#!/usr/bin/env bash
#
# Build Bond Desktop.app and lay the llama-server sidecar into it.
#
# The copy happens HERE and not in an Xcode Copy Files phase on purpose: the
# macOS runner project is Flutter-regenerable, and a build phase added by hand
# is the thing a `flutter create` refresh silently drops. A post-build ditto
# plus dist/sign.sh's inside-out signing achieves the same bundle with nothing
# to lose.
#
# Layout, and why each piece sits where it does:
#   Contents/MacOS/llama-server        the sidecar
#   Contents/MacOS/libggml-*.so        ggml_backend_load_all() scans the
#                                      directory of the RUNNING EXECUTABLE.
#                                      GGML_BACKEND_PATH loads exactly one
#                                      file, so it cannot replace this.
#   Contents/Frameworks/*.dylib        found through @loader_path/../Frameworks
#   Contents/Resources/*.metallib      ggml asks NSBundle for "default.metallib"
#   Contents/MacOS/*.metallib          → symlinks, for the argv[0] lookup that
#                                      runs when the NSBundle one misses
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERSION="${VERSION:?VERSION is required (make dist-app derives it from app/pubspec.yaml)}"
BUILD="${BUILD:?BUILD is required (make dist-app derives it from app/pubspec.yaml)}"
MS_ENV="${MS_ENV:-$ROOT/.env}"
FLUTTER="${FLUTTER:-flutter}"
BOND_DIST_ALLOW_NO_MCP="${BOND_DIST_ALLOW_NO_MCP:-}"
AD_HOC="${AD_HOC:-}"
DIST_ENV="${DIST_ENV:-$ROOT/dist/local/dist.env}"

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; BLUE='\033[34m'; RESET='\033[0m'
ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
bad()  { printf "  ${RED}✗${RESET} %s\n" "$*"; }
note() { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }
step() { printf "${BLUE}==>${RESET} %s\n" "$*"; }

STAGE="$ROOT/dist/stage"
LLAMA="$STAGE/llama"
APP="$STAGE/Bond Desktop.app"

step "[1/6] secrets check"
# A distributed build must never carry the Entra client secret: it is baked
# into the binary by --dart-define and anyone with the DMG can read it out.
# MCP mode needs no secret, which is why distributed builds use MCP mode.
if [ -f "$MS_ENV" ]; then
  secret="$(sed -n 's/^[[:space:]]*MICROSOFT_CLIENT_SECRET[[:space:]]*=[[:space:]]*//p' "$MS_ENV" | tail -1)"
  secret="${secret%\"}"; secret="${secret#\"}"
  secret="${secret%\'}"; secret="${secret#\'}"
  if [ -n "$secret" ]; then
    bad "$MS_ENV has a non-empty MICROSOFT_CLIENT_SECRET — a distributed build must not carry it"
    printf "        Blank that line (MCP mode needs no secret), or point MS_ENV at an env\n"
    printf "        file without it: make dist-dmg MS_ENV=/path/to/dist.env\n"
    exit 1
  fi
  ok "no MICROSOFT_CLIENT_SECRET in $(basename "$MS_ENV")"
fi

# The Sparkle inputs are checked HERE, before the twenty-minute build, and
# written into the plist in step [5/6], after it. A release build without them
# cannot update itself, and finding that out after `flutter build macos` is
# the failure this ordering refuses.
# shellcheck disable=SC1090
[ -f "$DIST_ENV" ] && . "$DIST_ENV"
if [ -n "${DIST_APPCAST_URL:-}" ] && [ -n "${DIST_SPARKLE_PUBLIC_KEY:-}" ]; then
  ok "Sparkle feed URL and public key are set"
elif [ -n "$AD_HOC" ]; then
  note "Sparkle keys not set — this tester build cannot update itself (dist.env: DIST_APPCAST_URL, DIST_SPARKLE_PUBLIC_KEY)"
else
  bad "a release build must be able to update itself — set DIST_APPCAST_URL and DIST_SPARKLE_PUBLIC_KEY in dist.env (docs/distribution.md → Updates), or build a tester DMG with AD_HOC=1"
  exit 1
fi

# The one define a distributed build carries. Everything else about the
# Microsoft connection is chosen by the user in Settings at runtime.
#
# Its absence is a HARD failure, not a note. A build with no MCP server URL
# cannot sign in at all, and nothing says so until someone has downloaded the
# DMG, installed it and reached the sign-in step — the worst possible moment
# to discover that this build was never going to work.
MCP_URL=""
if [ -f "$MS_ENV" ]; then
  MCP_URL="$(sed -n 's/^[[:space:]]*BOND_MCP_SERVER_URL[[:space:]]*=[[:space:]]*//p' "$MS_ENV" | tail -1)"
  MCP_URL="${MCP_URL%\"}"; MCP_URL="${MCP_URL#\"}"
  MCP_URL="${MCP_URL%\'}"; MCP_URL="${MCP_URL#\'}"
fi
if [ -z "$MCP_URL" ]; then
  if [ -n "$BOND_DIST_ALLOW_NO_MCP" ]; then
    note "BOND_DIST_ALLOW_NO_MCP=1 — building with no MCP server URL; this build cannot sign in"
  else
    bad "no BOND_MCP_SERVER_URL — a distributed build needs BOND_MCP_SERVER_URL; pass MS_ENV=/path/to/.env"
    printf "        To build one anyway (a pipeline test, not a tester build):\n"
    printf "        make dist-dmg AD_HOC=1 BOND_DIST_ALLOW_NO_MCP=1\n"
    exit 1
  fi
fi

step "[2/6] sidecar"
if [ ! -x "$LLAMA/bin/llama-server" ]; then
  bad "no staged sidecar — run: make dist-llama"
  exit 1
fi
# First field only: the stamp is "<tag> <script digest>", and the digest is
# cache bookkeeping, not something to print at someone.
ok "llama.cpp $(awk '{print $1}' "$LLAMA/.pin" 2>/dev/null || echo '(unpinned)')"

step "[3/6] flutter build macos ($VERSION+$BUILD)"
defines=()
if [ -n "$MCP_URL" ]; then
  defines+=("--dart-define=BOND_MCP_SERVER_URL=$MCP_URL")
  ok "BOND_MCP_SERVER_URL is set"
fi
cd "$ROOT/app"
# ${defines[@]+...}: on macOS's bash 3.2, expanding an empty array under
# `set -u` is an unbound-variable error, and an env file without an MCP URL
# leaves this array empty.
"$FLUTTER" build macos --release --build-name="$VERSION" --build-number="$BUILD" ${defines[@]+"${defines[@]}"}
BUILT="$ROOT/app/build/macos/Build/Products/Release/Bond Desktop.app"
[ -d "$BUILT" ] || { bad "flutter did not produce $BUILT"; exit 1; }
ok "built $VERSION+$BUILD"

step "[4/6] lay the sidecar into the bundle"
# ditto, not cp -R: it is the only copy that carries resource forks, ACLs and
# code signatures across intact (Apple's own guidance for bundles).
rm -rf "$APP"
mkdir -p "$STAGE"
ditto "$BUILT" "$APP"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
ditto "$LLAMA/bin/llama-server" "$APP/Contents/MacOS/llama-server"
chmod +x "$APP/Contents/MacOS/llama-server"

for so in "$LLAMA"/backends/*.so; do
  [ -e "$so" ] || continue
  ditto "$so" "$APP/Contents/MacOS/$(basename "$so")"
done
for dylib in "$LLAMA"/lib/*.dylib; do
  [ -e "$dylib" ] || continue
  cp -P "$dylib" "$APP/Contents/Frameworks/"
done
shopt -s nullglob
metallibs=("$LLAMA"/metal/*.metallib)
shopt -u nullglob
if [ ${#metallibs[@]} -eq 0 ]; then
  note "no .metallib staged — Metal shaders would have to JIT-compile at every start"
else
  for m in "${metallibs[@]}"; do
    base="$(basename "$m")"
    ditto "$m" "$APP/Contents/Resources/$base"
    # Relative, so the link survives the move to /Applications and the DMG.
    ln -sf "../Resources/$base" "$APP/Contents/MacOS/$base"
  done
fi

# Quarantine and provenance xattrs ride in on every downloaded or copied file
# and make codesign refuse the bundle with "resource fork, Finder information,
# or similar detritus not allowed".
#
# /usr/bin/xattr by absolute path, not `xattr`: the PyPI package of the same
# name installs a DIFFERENT xattr command with no -r flag, and a pyenv or
# virtualenv shim ahead of /usr/bin on PATH turns this line into a build
# failure that has nothing to do with the build.
/usr/bin/xattr -cr "$APP"
ok "sidecar in place"

step "[5/6] Sparkle keys in Info.plist"
# HERE, and not in the Xcode project, for two reasons. The feed URL and the
# public key are machine-local settings out of dist.env (already sourced in
# step [1/6], where their absence refuses a release build), which the project
# is not allowed to know; and they must be in the plist BEFORE dist/sign.sh
# runs, because the signature seals Info.plist and a key written afterwards
# invalidates it.

plist="$APP/Contents/Info.plist"
# Set-then-Add: PlistBuddy has no upsert, `Set` fails when the key is absent
# and `Add` fails when it is present, and a bundle rebuilt from a previous run
# can be in either state.
plist_set() {
  local key="$1" kind="$2" value="$3"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$key $kind $value" "$plist"
}

if [ -n "${DIST_APPCAST_URL:-}" ] && [ -n "${DIST_SPARKLE_PUBLIC_KEY:-}" ]; then
  plist_set SUFeedURL string "$DIST_APPCAST_URL"
  plist_set SUPublicEDKey string "$DIST_SPARKLE_PUBLIC_KEY"
  # In the plist rather than left to Sparkle's own first-launch question: with
  # no value here Sparkle ASKS the user whether to check automatically the
  # second time the app opens, which is a permission prompt nobody needs for a
  # check that downloads nothing without asking again.
  plist_set SUEnableAutomaticChecks bool true
  # 86400 seconds — daily. Sparkle never checks on a first launch whatever this
  # says; the interval starts counting from the second one.
  plist_set SUScheduledCheckInterval integer 86400
  # Never the values: a feed URL and a public key are both readable in the
  # shipped plist, but this output gets pasted into issues and the house rule
  # is that nothing out of dist.env is printed.
  ok "Sparkle: SUFeedURL, SUPublicEDKey, SUEnableAutomaticChecks=true, SUScheduledCheckInterval=86400"
else
  # Step [1/6] already refused a release build without them, so this is the
  # tester build the note there described.
  note "no Sparkle keys in Info.plist — this tester build cannot update itself"
fi

step "[6/6] Contents/MacOS"
ls -la "$APP/Contents/MacOS"
printf "\n"
ok "$APP"
