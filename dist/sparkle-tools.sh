#!/usr/bin/env bash
#
# Fetch Sparkle's command line tools into dist/stage/sparkle-tools/.
#
# Three binaries matter: `generate_appcast` (dist/appcast.sh), `sign_update`
# (the same script's verification), and `generate_keys`, which a maintainer
# runs ONCE by hand to create the EdDSA key pair (docs/distribution.md →
# Updates). Staged rather than installed, so nothing is added to the machine
# and `make dist-clean` takes it all away again.
#
# The tarball's SHA-256 is a LITERAL below, in the style of dist/build-llama.sh
# and `make vec-vendor`, and for the same reason: there is nothing upstream to
# check a release asset against, so the digest was measured by hand once at pin
# time. A mismatch means the asset changed under the tag — investigate, do not
# wave it through.
#
# The tools are Developer ID signed by the Sparkle project and curl sets no
# quarantine flag, so they run with no Gatekeeper detour.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The tools version and the SwiftPM pin in the Xcode project move TOGETHER, and
# the cross-check below is what enforces it. `sign_update` here and the
# verifier inside the embedded framework have to agree on the key format and on
# what an appcast item may contain; a tools version ahead of the framework can
# write a feed the shipped app will not accept, and one behind can fail to sign
# what it should.
#
# Measured 2026-09-11 against
# https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz
SPARKLE_VERSION=2.9.6
SPARKLE_TOOLS_SHA256=52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; BLUE='\033[34m'; RESET='\033[0m'
ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
bad()  { printf "  ${RED}✗${RESET} %s\n" "$*"; }
note() { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }
step() { printf "${BLUE}==>${RESET} %s\n" "$*"; }

DEST="$ROOT/dist/stage/sparkle-tools"
PIN="$DEST/.pin"
PIN_STAMP="$SPARKLE_VERSION $SPARKLE_TOOLS_SHA256"
# Xcode writes the pin file twice — once under the workspace `flutter build
# macos` actually builds (Runner.xcworkspace) and once under the project's own
# implicit workspace — with identical contents, and both are committed. The
# workspace copy is read first because it is the one the build resolved.
RESOLVED="$ROOT/app/macos/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved"
[ -f "$RESOLVED" ] || RESOLVED="$ROOT/app/macos/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

step "[1/2] the app's Sparkle pin"
# Package.resolved is written by the first `flutter build macos` and committed,
# so on a fresh checkout that has never built there is nothing to compare
# against yet — a note, not a failure, because `make dist` builds the app long
# before it reaches the appcast.
if [ ! -f "$RESOLVED" ]; then
  note "no Package.resolved yet — make dist-app resolves it (skipping the cross-check)"
else
  embedded="$(python3 - "$RESOLVED" <<'PY' || true
import json, sys
with open(sys.argv[1]) as handle:
    doc = json.load(handle)
# Both schema versions of the file keep the pins under "pins"; v1 spelled the
# identity "package" instead, so either key is read.
for pin in doc.get("pins", []):
    identity = pin.get("identity") or pin.get("package", "")
    if identity.lower() == "sparkle":
        print(pin.get("state", {}).get("version", ""))
        break
PY
)"
  if [ -z "$embedded" ]; then
    bad "Package.resolved has no sparkle pin — the Xcode project should reference sparkle-project/Sparkle (docs/distribution.md → Updates)"
    exit 1
  elif [ "$embedded" != "$SPARKLE_VERSION" ]; then
    bad "this script pins $SPARKLE_VERSION, the app embeds $embedded — the tools and the framework move together (docs/distribution.md → Updates)"
    exit 1
  fi
  ok "the app embeds Sparkle $embedded"
fi

step "[2/2] Sparkle $SPARKLE_VERSION tools"
if [ -f "$PIN" ] && [ "$(cat "$PIN")" = "$PIN_STAMP" ] && [ -x "$DEST/bin/generate_appcast" ]; then
  ok "already staged (delete $DEST to force)"
  ok "$DEST/bin"
  exit 0
fi

rm -rf "$DEST"
mkdir -p "$DEST"
part="$DEST.tar.xz.part"
rm -f "$part"
if ! curl -fsSL -o "$part" "$SPARKLE_URL"; then
  rm -f "$part"
  bad "download failed: $SPARKLE_URL"
  exit 1
fi
got="$(shasum -a 256 "$part" | awk '{print $1}')"
if [ "$got" != "$SPARKLE_TOOLS_SHA256" ]; then
  # Deleted rather than left behind: a half-trusted archive on disk is the one
  # a hurried re-run reaches for.
  rm -f "$part"
  bad "SHA256 mismatch for Sparkle-$SPARKLE_VERSION.tar.xz"
  printf "        want %s\n" "$SPARKLE_TOOLS_SHA256"
  printf "        got  %s\n" "$got"
  exit 1
fi
ok "$got"

# bin/ only. The tarball also carries Sparkle.framework, its symbols and the
# sample app; the framework that SHIPS comes from SwiftPM and Xcode embeds it,
# and a second copy staged here would be a second thing to keep in step.
tar -xJf "$part" -C "$DEST" bin
rm -f "$part"
printf '%s\n' "$PIN_STAMP" > "$PIN"

ok "generate_appcast, sign_update, generate_keys"
# Printed because the key-generation step in the docs is a path away: this is
# where `generate_keys` is, without installing anything globally.
ok "$DEST/bin"
