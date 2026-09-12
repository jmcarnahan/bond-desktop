#!/usr/bin/env bash
#
# Regenerate the Sparkle update feed for the DMG that was just released.
#
# The feed is `docs/appcast/appcast.xml`, served by GitHub Pages from `main`
# `/docs`, and every installed copy of Bond reads it about once a day. An item
# in it carries the version, the download URL and an EdDSA signature of the
# exact bytes at that URL; an installed copy verifies that signature against
# the SUPublicEDKey baked into its own Info.plist and installs nothing that
# fails. So this script's only real job is to make a signed item that names the
# DMG that actually shipped.
#
# It is a SEPARATE step from `make dist-dmg` and takes no prerequisite, because
# `dist-app` rebuilds the whole app on every run: re-running the appcast after
# a failed upload must not rebuild and re-notarize an identical binary. What it
# needs is the notarized DMG sitting in dist/out/, which it checks for.
#
# AD_HOC=1 is the rehearsal: everything runs against whatever key DIST_ENV
# names — point DIST_ENV at a scratch dist.env with a throwaway key, because
# the default dist.env names the real one — the notarization and build-number
# checks become notes, and the result is left in dist/stage/appcast/ rather
# than written over the real feed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERSION="${VERSION:?VERSION is required (make dist-appcast derives it from app/pubspec.yaml)}"
BUILD="${BUILD:?BUILD is required (make dist-appcast derives it from app/pubspec.yaml)}"
AD_HOC="${AD_HOC:-}"
DIST_ENV="${DIST_ENV:-$ROOT/dist/local/dist.env}"

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; BLUE='\033[34m'; RESET='\033[0m'
ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
bad()  { printf "  ${RED}✗${RESET} %s\n" "$*"; }
note() { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }
step() { printf "${BLUE}==>${RESET} %s\n" "$*"; }

step "[1/5] preconditions"
# shellcheck disable=SC1090
[ -f "$DIST_ENV" ] && . "$DIST_ENV"

KEY="${DIST_SPARKLE_PRIVATE_KEY_PATH:-}"
if [ -z "$KEY" ]; then
  bad "DIST_SPARKLE_PRIVATE_KEY_PATH is not set — docs/distribution.md → Updates"
  exit 1
fi
if [ ! -f "$KEY" ]; then
  bad "DIST_SPARKLE_PRIVATE_KEY_PATH names no file — docs/distribution.md → Updates"
  exit 1
fi
# A note rather than a failure: a loose mode is a thing to fix, not a reason to
# refuse a release the maintainer is in the middle of.
# -L: the path may be a symlink into ~/.bond-signing/, and the mode that
# matters is the file's, not the link's.
mode="$(stat -L -f '%Lp' "$KEY")"
if [ "$mode" = "600" ]; then
  ok "the Sparkle key is present, mode 600"
else
  note "the Sparkle key is mode $mode — run: chmod 600 on the path in DIST_SPARKLE_PRIVATE_KEY_PATH"
fi

PREFIX="${DIST_DOWNLOAD_URL_PREFIX:-}"
if [ -z "$PREFIX" ]; then
  bad "DIST_DOWNLOAD_URL_PREFIX is not set — docs/distribution.md → Updates"
  exit 1
fi
case "$PREFIX" in
  https://*) ;;
  *) bad "DIST_DOWNLOAD_URL_PREFIX must start with https:// — an update served over http is one anybody on the network can replace"; exit 1 ;;
esac
# A GitHub release URL carries the tag, so the prefix is per-release. One
# placeholder in dist.env beats a maintainer editing the file before every
# release and forgetting once.
PREFIX="${PREFIX//\{version\}/$VERSION}"
case "$PREFIX" in
  */) ;;
  *) bad "DIST_DOWNLOAD_URL_PREFIX must end with / — generate_appcast appends the file name to it directly"; exit 1 ;;
esac
# "set", never the value: the house rule for anything out of dist.env.
ok "DIST_DOWNLOAD_URL_PREFIX is set"

DMG="$ROOT/dist/out/Bond-Desktop-$VERSION.dmg"
if [ ! -f "$DMG" ]; then
  bad "no dist/out/Bond-Desktop-$VERSION.dmg — the feed points at the image that was released; run: make dist"
  exit 1
fi
ok "Bond-Desktop-$VERSION.dmg"

# Sparkle decides "newer" on sparkle:version, which is CFBundleVersion — the
# +BUILD half of pubspec's `version:` line, NOT the 1.0.x half. A release that
# bumped only the version string keeps the build number, and generate_appcast
# then OVERWRITES the feed's existing item for that build instead of adding
# one: every check below still passes, and no installed copy ever moves. So
# the build number has to be above every one already published.
FEED="$ROOT/docs/appcast/appcast.xml"
# The comparison below is `[ "$BUILD" -le "$highest" ] 2>/dev/null`, and that
# 2>/dev/null is the problem: a non-numeric BUILD makes the test ERROR rather
# than answer, the error is swallowed, and the else branch reports the release
# as newer than the feed. So BUILD's shape is settled here, before anything
# reads it as a number. A malformed pubspec `version:` line is the way it gets
# here empty.
case "$BUILD" in
  ''|*[!0-9]*)
    bad "BUILD is not a number: '$BUILD' — write \`version: <major.minor.patch>+<n>\` in app/pubspec.yaml"
    exit 1
    ;;
esac
if [ -f "$FEED" ]; then
  # Only the numeric ones are comparable; ours are always integers from pubspec.
  highest="$(grep -o '<sparkle:version>[0-9]*</sparkle:version>' "$FEED" | grep -o '[0-9]\{1,\}' | sort -n | tail -1 || true)"
  if [ -n "$highest" ] && [ "$BUILD" -le "$highest" ] 2>/dev/null; then
    if [ -n "$AD_HOC" ]; then
      note "build $BUILD is not above the feed's highest sparkle:version $highest — a release would be refused here"
    else
      bad "build $BUILD is not above the feed's highest sparkle:version $highest — bump BOTH halves of version: in app/pubspec.yaml (1.0.1+2, not 1.0.1+1); Sparkle compares CFBundleVersion"
      exit 1
    fi
  else
    ok "build $BUILD is newer than anything in the feed"
  fi
fi

if [ -n "$AD_HOC" ]; then
  note "AD_HOC=1 — rehearsal: the appcast is built into dist/stage/appcast/ and NOT copied to docs/appcast/"
else
  # The signature is over the bytes at the download URL, and those bytes are
  # the NOTARIZED image. A feed generated from an un-notarized build would
  # advertise a download every user's Gatekeeper refuses.
  if ! xcrun stapler validate "$DMG" >/dev/null 2>&1; then
    bad "the DMG is not notarized — the feed must point at the DMG that was released; run: make dist"
    exit 1
  fi
  ok "the DMG carries a stapled ticket"
fi

step "[2/5] Sparkle tools"
"$ROOT/dist/sparkle-tools.sh"
BIN="$ROOT/dist/stage/sparkle-tools/bin"

step "[3/5] stage the archives directory"
W="$ROOT/dist/stage/appcast"
rm -rf "$W"
mkdir -p "$W"
cp "$DMG" "$W/"
# generate_appcast looks for an existing appcast.xml IN THE ARCHIVES DIRECTORY
# and updates it in place, keeping the items already in it. Copying the
# published feed in is therefore what makes this an append rather than a feed
# with one item in it — and what keeps the older versions a machine that has
# not updated in a while may still be offered.
if [ -f "$ROOT/docs/appcast/appcast.xml" ]; then
  cp "$ROOT/docs/appcast/appcast.xml" "$W/appcast.xml"
  ok "the published feed, plus Bond-Desktop-$VERSION.dmg"
else
  ok "Bond-Desktop-$VERSION.dmg (no published feed yet — this is the first item)"
fi

step "[4/5] generate_appcast"
# --maximum-versions 5: enough that someone who skipped a few releases still
# finds a path forward, few enough that the feed stays small. Everything it
# drops is moved to old_updates/ beside the archives, not deleted.
#
# Version, short version string, minimum system version and the hardware
# requirements all come out of the app's own Info.plist inside the image;
# nothing here restates them, which is why they cannot disagree with the build.
rc=0
out="$("$BIN/generate_appcast" \
  --ed-key-file "$KEY" \
  --download-url-prefix "$PREFIX" \
  --maximum-versions 5 \
  "$W" 2>&1)" || rc=$?
printf '%s\n' "$out" | sed 's/^/      /'
if [ "$rc" -ne 0 ]; then
  bad "generate_appcast failed"
  exit 1
fi
# generate_appcast reports this as a WARNING and still writes the feed — an
# unsigned item, or one signed by a key no installed copy trusts. Treated as a
# failure here, because a feed like that is worse than no feed: it looks
# published and updates nobody.
if printf '%s\n' "$out" | grep -q 'Warning: SUPublicEDKey in the app'; then
  bad "the app's SUPublicEDKey does not match the key at DIST_SPARKLE_PRIVATE_KEY_PATH — an installed copy would refuse this update"
  exit 1
fi
ok "appcast written"

step "[5/5] verify the item"
XML="$W/appcast.xml"
[ -f "$XML" ] || { bad "generate_appcast produced no appcast.xml"; exit 1; }
vfail=0
want() {
  local what="$1" needle="$2"
  # grep -F: every needle here is a literal with /, + and = in it.
  if grep -qF -- "$needle" "$XML"; then
    ok "$what"
  else
    bad "$what — not in the generated appcast"
    vfail=1
  fi
}

# Signed independently of the tool that just wrote the feed: this is the one
# check that the signature in the XML is a signature of THIS image, made with
# THIS key. sign_update prints the base64 signature and nothing else.
# `|| true` on the assignment read, for dist/sign.sh's reason: under set -e a
# failing sign_update would end the script with no row, and the empty result
# is what gets diagnosed here instead.
sig="$("$BIN/sign_update" --ed-key-file "$KEY" -p "$DMG" 2>&1 || true)"
case "$sig" in
  ""|*" "*|*Error*)
    bad "sign_update could not sign the DMG with the key at DIST_SPARKLE_PRIVATE_KEY_PATH"
    printf '%s\n' "$sig" | sed 's/^/      /'
    exit 1 ;;
esac
want "sparkle:edSignature matches this DMG and this key" "sparkle:edSignature=\"$sig\""
want "the enclosure points at the released DMG" "${PREFIX}Bond-Desktop-$VERSION.dmg"
want "sparkle:version $BUILD" "<sparkle:version>$BUILD</sparkle:version>"
want "sparkle:shortVersionString $VERSION" "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>"
[ "$vfail" -eq 0 ] || exit 1

printf "\n"
if [ -n "$AD_HOC" ]; then
  ok "dist/stage/appcast/appcast.xml — rehearsal item $VERSION ($BUILD)"
  exit 0
fi

mkdir -p "$ROOT/docs/appcast"
cp "$XML" "$ROOT/docs/appcast/appcast.xml"
ok "docs/appcast/appcast.xml — item $VERSION ($BUILD)"
printf "    Next: gh release create v%s dist/out/Bond-Desktop-%s.dmg\n" "$VERSION" "$VERSION"
printf "          then: git add docs/appcast/appcast.xml && git commit … && git push — the feed is live once GitHub Pages redeploys (docs/distribution.md → Releasing)\n"
