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
# An ad-hoc build is therefore a test of the layout and of this script, never
# a rehearsal of the signature that ships.
#
# Under a real identity the run ends with a block of DISTRIBUTION CHECKS: the
# things the notary service rejects an upload for, asserted here where the fix
# is a one-line change, rather than twenty minutes later in a submission log.
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

  # Resolve the identity against the keychain BEFORE twenty signatures are
  # attempted with it. A renewed Developer ID certificate keeps the NAME of the
  # one it replaces, so a name can match two identities at once and codesign
  # refuses an ambiguous one; the certificate's SHA-1 always picks exactly one.
  # Whatever form dist.env holds, a missing or ambiguous identity is caught
  # here, with a fix, rather than as codesign's error on the first .so.
  ident="$(security find-identity -v -p codesigning 2>/dev/null | grep -F -- "$DIST_SIGN_IDENTITY" || true)"
  # Counted from the text already fetched, so the count and the line below
  # can never come from two different keychain answers.
  ident_n="$(printf '%s' "$ident" | grep -c . || true)"
  if [ "${ident_n:-0}" -eq 0 ]; then
    bad "DIST_SIGN_IDENTITY is not in the login keychain — import the Developer ID .p12 (dist/README.md)"
    exit 1
  elif [ "$ident_n" -gt 1 ]; then
    bad "DIST_SIGN_IDENTITY matches $ident_n identities — set it to the certificate's SHA-1 hash from: security find-identity -v -p codesigning"
    exit 1
  fi

  ID="$DIST_SIGN_IDENTITY"
  # --timestamp contacts Apple's timestamp server once per signature, which is
  # about twenty round trips in this script: a machine with no network cannot
  # produce a distribution signature at all, and AD_HOC=1 is the offline path.
  # Notarization rejects a signature without a secure timestamp, so this is not
  # a flag to drop when the network is slow.
  RT=(--options runtime --timestamp)
  # The display name, not the hash: the hash is in dist.env and saying it twice
  # adds nothing, while the name is what a reader recognises.
  ok "signing as $(printf '%s\n' "$ident" | sed -E 's/.*"(.*)".*/\1/')"
fi

sign() {
  local what="$1"; shift
  # ${RT[@]+"${RT[@]}"} rather than plain "${RT[@]}": macOS ships bash 3.2,
  # where expanding an EMPTY array under `set -u` is an unbound-variable
  # error. That is exactly the ad-hoc path, where RT is empty.
  codesign -f -s "$ID" ${RT[@]+"${RT[@]}"} "$@" "$what"
}

step "[1/6] ggml backends (Contents/MacOS/*.so)"
n=0
for so in "$APP"/Contents/MacOS/*.so; do
  [ -e "$so" ] || continue
  # -i: a loose Mach-O has no Info.plist, so it has no identifier of its own,
  # and two unrelated bundles must not end up claiming the same one.
  sign "$so" -i "com.bondinbox.app.$(basename "$so")"
  n=$((n + 1))
done
ok "$n backend module(s)"

step "[2/6] dylibs (Contents/Frameworks/*.dylib)"
n=0
for dylib in "$APP"/Contents/Frameworks/*.dylib; do
  # Regular files only: the symlinks in a dylib chain point at a file that is
  # signed in its own right, and codesign on the link signs the target twice.
  [ -f "$dylib" ] && [ ! -L "$dylib" ] || continue
  sign "$dylib" -i "com.bondinbox.app.$(basename "$dylib")"
  n=$((n + 1))
done
ok "$n dylib(s)"

step "[3/6] Sparkle nested executables"
# Sparkle is the one framework in this bundle with executables INSIDE it, and
# codesign on the framework does not reach them. Library validation comes on
# with the hardened runtime and refuses to load a framework whose nested
# executables do not carry OUR team, so an un-re-signed Sparkle is a launch
# that dies loading the updater — with Sparkle's own valid signature on every
# piece of it.
#
# Innermost first, exactly as the whole script works: the XPC services, then
# the two things that run them, and the framework itself is sealed by the
# frameworks loop immediately below.
#
# This runs in the AD_HOC branch too. The ad-hoc signature proves nothing about
# teams, but it does exercise this order — and `codesign --deep --strict` at
# the end of the run is what says the nesting came out valid.
fw="$APP/Contents/Frameworks/Sparkle.framework"
if [ ! -d "$fw" ]; then
  note "no Sparkle.framework in this build"
else
  # Versions/Current is a symlink to the real version directory (B in 2.9.6).
  # Read it rather than hard-coding the letter: Sparkle has bumped it before
  # and a hard-coded path would fail as "no such file" rather than as a
  # version change.
  # The readlink is guarded rather than left bare: under `set -e` a failure
  # here would end the run silently, right after the .so and dylib passes
  # printed their rows, and the layout change that caused it would never be
  # named.
  cur="$(readlink "$fw/Versions/Current" || true)"
  if [ -z "$cur" ]; then
    bad "Sparkle.framework has no Versions/Current — the layout changed; update step [3/6]"
    exit 1
  fi
  v="$fw/Versions/$cur"
  # --preserve-metadata=entitlements on the two XPC services: 2.9.6 ships both
  # with NO entitlements at all, but a future Sparkle that sandboxes the
  # downloader again ships its own, and re-signing would otherwise strip them
  # and leave a service that cannot do its job.
  # A glob rather than the two names 2.9.6 ships, and the same glob the
  # distribution checks count: a service a future Sparkle adds is then signed
  # here rather than surfacing as an unexplained team-identifier miss.
  signed=""
  for x in "$v"/XPCServices/*.xpc; do
    [ -d "$x" ] || continue
    sign "$x" --preserve-metadata=entitlements
    signed="$signed$(basename "$x"), "
  done
  sign "$v/Autoupdate"
  sign "$v/Updater.app"
  ok "${signed}Autoupdate, Updater.app"
fi

step "[4/6] frameworks (Contents/Frameworks/*.framework)"
n=0
for fw in "$APP"/Contents/Frameworks/*.framework; do
  [ -d "$fw" ] || continue
  sign "$fw"
  n=$((n + 1))
done
ok "$n framework(s)"

step "[5/6] llama-server helper"
sign "$APP/Contents/MacOS/llama-server" -i com.bondinbox.app.llama-server \
  --entitlements "$HELPER_ENT"
ok "llama-server"

step "[6/6] the app"
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

# Everything below only means anything under a real identity: an ad-hoc bundle
# has no authority, no hardened runtime and no team by design, so asserting any
# of it would fail the rehearsal for the very reason the rehearsal exists.
if [ -z "$AD_HOC" ]; then
  printf "\n"
  step "distribution checks"
  dfail=0
  miss() { bad "$*"; dfail=1; }

  # `|| true` on every assignment-only read below: under `set -e` a codesign
  # that fails would end the script with no row, and the grep that follows is
  # the thing that turns its output into a diagnosed miss.
  info="$(codesign -dvv "$APP" 2>&1 || true)"

  # Notarization accepts exactly one kind of signature. An Apple Development
  # certificate signs a build that runs on this Mac and nowhere else.
  if printf '%s\n' "$info" | grep -q 'Authority=Developer ID Application'; then
    ok "authority is Developer ID Application"
  else
    miss "the app is not signed by a Developer ID Application certificate"
  fi

  # The line reads `CodeDirectory v=… flags=0x10000(runtime) …`, so the flag
  # word lives inside the parentheses beside the hex value.
  if printf '%s\n' "$info" | grep -qE 'flags=0x[0-9a-f]+\([^)]*runtime'; then
    ok "hardened runtime is on"
  else
    miss "the app is signed WITHOUT the hardened runtime — notarization refuses that"
  fi

  if [ -n "${DIST_TEAM_ID:-}" ]; then
    if printf '%s\n' "$info" | grep -q "^TeamIdentifier=$DIST_TEAM_ID\$"; then
      ok "team $DIST_TEAM_ID"
    else
      miss "TeamIdentifier is not $DIST_TEAM_ID — dist.env and the certificate disagree"
    fi
  else
    note "DIST_TEAM_ID is not set — team checks skipped"
  fi

  # get-task-allow lets a debugger attach, and a build carrying it is rejected
  # by the notary service. app-sandbox would come back with the container this
  # app deliberately left, and the sidecar could not be spawned.
  ent="$(codesign -d --entitlements - "$APP" 2>&1 || true)"
  if printf '%s\n' "$ent" | grep -qE 'app-sandbox|get-task-allow'; then
    miss "the app's entitlements carry app-sandbox or get-task-allow"
  else
    ok "no app-sandbox, no get-task-allow"
  fi

  helper="$APP/Contents/MacOS/llama-server"
  hinfo="$(codesign -dvv "$helper" 2>&1 || true)"
  if printf '%s\n' "$hinfo" | grep -qE 'flags=0x[0-9a-f]+\([^)]*runtime'; then
    ok "llama-server: hardened runtime is on"
  else
    miss "llama-server is signed without the hardened runtime"
  fi

  # An empty dict prints `[Dict]` and nothing else. Any `[Key]` (or `<key>`,
  # if a future codesign prints raw XML) means the helper picked up
  # entitlements it was never meant to have.
  hent="$(codesign -d --entitlements - "$helper" 2>&1 || true)"
  if printf '%s\n' "$hent" | grep -qE '\[Key\]|<key>'; then
    miss "llama-server carries entitlements — dist/llama-server.entitlements is an empty dict"
  else
    ok "llama-server carries no entitlements"
  fi

  # Library validation comes on WITH the hardened runtime, and it refuses to
  # load a library whose team identifier differs from the loading process's.
  # Every nested binary therefore has to carry OUR team — a valid signature by
  # somebody else is exactly the failure this catches, at build time rather
  # than as a launch that dies loading its own backends.
  if [ -n "${DIST_TEAM_ID:-}" ]; then
    nested=0
    total=0
    for f in "$APP"/Contents/MacOS/*.so "$APP"/Contents/Frameworks/*.dylib; do
      # Regular files only: a symlink in a dylib chain names a file already
      # counted in its own right.
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      total=$((total + 1))
      if codesign -dvv "$f" 2>&1 | grep -q "^TeamIdentifier=$DIST_TEAM_ID\$"; then
        nested=$((nested + 1))
      else
        miss "$(basename "$f") does not carry team $DIST_TEAM_ID"
      fi
    done
    # A framework answers for ITSELF here, not for executables nested inside
    # it, so Sparkle's are counted separately below: `codesign -dvv` on
    # Sparkle.framework reports the framework's own signature and says nothing
    # about the XPC services and the two helpers inside it, which are exactly
    # what library validation refuses the framework for.
    for fw in "$APP"/Contents/Frameworks/*.framework; do
      [ -d "$fw" ] || continue
      total=$((total + 1))
      if codesign -dvv "$fw" 2>&1 | grep -q "^TeamIdentifier=$DIST_TEAM_ID\$"; then
        nested=$((nested + 1))
      else
        miss "$(basename "$fw") does not carry team $DIST_TEAM_ID"
      fi
    done

    # The same question, asked of what step [3/6] signed. A bundle with no
    # Sparkle in it adds no rows: the glob simply matches nothing.
    sfw="$APP/Contents/Frameworks/Sparkle.framework"
    if [ -d "$sfw" ]; then
      # Guarded like step [3/6]'s read, and for the same reason: a bare
      # readlink failure would end the distribution checks mid-count.
      scur="$(readlink "$sfw/Versions/Current" || true)"
      if [ -z "$scur" ]; then
        bad "Sparkle.framework has no Versions/Current — the layout changed; update step [3/6]"
        exit 1
      fi
      sv="$sfw/Versions/$scur"
      for f in "$sv"/XPCServices/*.xpc "$sv/Autoupdate" "$sv/Updater.app"; do
        [ -e "$f" ] || continue
        total=$((total + 1))
        if codesign -dvv "$f" 2>&1 | grep -q "^TeamIdentifier=$DIST_TEAM_ID\$"; then
          nested=$((nested + 1))
        else
          miss "Sparkle's $(basename "$f") does not carry team $DIST_TEAM_ID"
        fi
      done
    fi
    if [ "$nested" -eq "$total" ]; then
      ok "$nested nested binaries carry team $DIST_TEAM_ID"
    else
      # Each failure is named above; this row only totals them.
      miss "$nested of $total nested binaries carry team $DIST_TEAM_ID"
    fi
  fi

  # Apple's own pre-flight: the same checks the notary service runs, offline
  # and in a second, against a bundle that has not been uploaded yet.
  #
  # The EXIT CODE is not the verdict: syspolicy_check exits 70 when its only
  # findings are `Severity: Warning`, and Apple accepts those uploads (a stock
  # Slack.app answers 70 with sixteen warnings and no fatal). Only a Fatal is
  # a reason to stop, so the severities are what this reads.
  if [ -x /usr/bin/syspolicy_check ]; then
    sp="$(/usr/bin/syspolicy_check notary-submission "$APP" 2>&1)" || true
    if printf '%s\n' "$sp" | grep -q 'Severity: *Fatal'; then
      miss "syspolicy_check notary-submission found a FATAL issue"
    elif printf '%s\n' "$sp" | grep -q 'Severity: *Warning'; then
      note "syspolicy_check notary-submission: warnings only — Apple accepts these"
    else
      ok "syspolicy_check notary-submission"
    fi
    printf '%s\n' "$sp" | sed 's/^/      /'
  else
    note "syspolicy_check is absent (macOS 14+ ships it) — pre-submission check skipped"
  fi

  # spctl is deliberately NOT run here. Until a ticket is stapled it answers
  # "rejected (source=Unnotarized Developer ID)", which is correct and tells
  # nobody anything; dist/notarize.sh runs it after stapling, where the answer
  # is the one a user's Mac will give.
  [ "$dfail" -eq 0 ] || exit 1
fi
