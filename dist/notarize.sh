#!/usr/bin/env bash
#
# Submit a signed .app or .dmg to Apple's notary service, wait for the answer,
# fetch the log, and staple the ticket.
#
#   dist/notarize.sh "dist/stage/Bond Desktop.app"
#   dist/notarize.sh dist/out/Bond-Desktop-1.0.0.dmg
#
# WHAT NOTARIZATION IS. Apple scans the upload for malware and for signing
# mistakes — an unsigned nested binary, a missing secure timestamp, the
# get-task-allow entitlement — and, if it finds none, issues a TICKET for that
# exact code. STAPLING writes the ticket into the bundle (or the disk image),
# so Gatekeeper on the user's Mac can check it with no network at all. An
# unstapled but notarized build still opens, provided the user's Mac can reach
# Apple at that moment; a stapled one always does.
#
# WHY TWICE. The .app is notarized and stapled FIRST, and only then is the DMG
# built from that stapled copy — a DMG built earlier would carry an app with no
# ticket inside it. The DMG is then signed and notarized in its own right,
# because it is a separate piece of code with its own signature, and it is what
# the user actually downloads and what Gatekeeper checks first.
#
# THE LOG IS ALWAYS FETCHED, including for an Accepted submission. Accepted
# does not mean silent: warnings live in the same `issues` array as errors, and
# a warning is how Apple announces the thing that becomes a hard rejection in a
# later macOS. It is saved to dist/out/ under the target's file name with
# spaces turned into dashes, then the submission id:
#
#   dist/out/notary-Bond-Desktop.app-<submission id>.json
#   dist/out/notary-Bond-Desktop-1.0.0.dmg-<submission id>.json
#
# That path is what goes into a bug report.
#
# QUOTA. Apple allows about 75 notarizations per team per day. This is not a
# loop to run in a watch; each release is two submissions, the app and the DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AD_HOC="${AD_HOC:-}"
DIST_ENV="${DIST_ENV:-$ROOT/dist/local/dist.env}"
# Apple usually answers in a few minutes. The wait is bounded so that an outage
# on their side fails the build with a message instead of hanging a terminal.
DIST_NOTARY_TIMEOUT="${DIST_NOTARY_TIMEOUT:-30m}"

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; BLUE='\033[34m'; RESET='\033[0m'
ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
bad()  { printf "  ${RED}✗${RESET} %s\n" "$*"; }
note() { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }
step() { printf "${BLUE}==>${RESET} %s\n" "$*"; }

# The ad-hoc rehearsal has nothing Apple would accept — no Developer ID
# signature, no timestamp — so this is a no-op rather than an error, and
# `make dist-dmg AD_HOC=1` stays one command.
if [ -n "$AD_HOC" ]; then
  note "AD_HOC=1 — nothing to notarize; testers use Open Anyway"
  exit 0
fi

TARGET="${1:-}"
[ -n "$TARGET" ] || { bad "usage: dist/notarize.sh \"<path to .app or .dmg>\""; exit 1; }
# A tab-completed bundle path ends in a slash, and the extension test below
# would then see neither .app nor .dmg.
TARGET="${TARGET%/}"

step "[1/5] preconditions"
case "$TARGET" in
  *.app)
    [ -d "$TARGET" ] || { bad "no bundle at $TARGET — run: make dist-sign"; exit 1; }
    ;;
  *.dmg)
    [ -f "$TARGET" ] || { bad "no disk image at $TARGET — run: make dist-dmg"; exit 1; }
    ;;
  *)
    bad "$TARGET is neither a .app nor a .dmg — notarytool takes .app (zipped), .dmg or .pkg"
    exit 1
    ;;
esac
ok "target: $TARGET"

# shellcheck disable=SC1090
[ -f "$DIST_ENV" ] && . "$DIST_ENV"

if [ -z "${DIST_NOTARY_KEY_PATH:-}" ]; then
  bad "DIST_NOTARY_KEY_PATH is not set — the AuthKey_<id>.p8 from App Store Connect (dist/local.env.example)"
  exit 1
fi
if [ ! -f "$DIST_NOTARY_KEY_PATH" ]; then
  bad "no key file at DIST_NOTARY_KEY_PATH — restore it from the password manager (dist/local.env.example)"
  exit 1
fi
if [ -z "${DIST_NOTARY_KEY_ID:-}" ]; then
  bad "DIST_NOTARY_KEY_ID is not set — the Key ID beside that key in App Store Connect (dist/local.env.example)"
  exit 1
fi

# A TEAM key needs --issuer; an INDIVIDUAL key rejects the request when one is
# passed. Which kind this is was decided when the key was generated, and
# dist.env records it by having an issuer id or not.
ISSUER=()
if [ -n "${DIST_NOTARY_ISSUER:-}" ]; then
  ISSUER=(--issuer "$DIST_NOTARY_ISSUER")
fi
# Built up one piece at a time rather than nested inside a single assignment:
# macOS ships bash 3.2, where expanding an empty array under `set -u` aborts,
# so the empty ISSUER has to be expanded with the ${arr[@]+…} guard.
AUTH=(--key "$DIST_NOTARY_KEY_PATH" --key-id "$DIST_NOTARY_KEY_ID")
AUTH=("${AUTH[@]}" ${ISSUER[@]+"${ISSUER[@]}"})
ok "notary key $DIST_NOTARY_KEY_ID${DIST_NOTARY_ISSUER:+ (team key)}"

# An ad-hoc or unsigned upload is rejected by Apple after the whole file has
# been transferred and a few minutes have passed. It costs nothing to say so
# here instead, and it saves one of the day's 75 submissions.
if codesign -dvv "$TARGET" 2>&1 | grep -q 'Authority=Developer ID Application'; then
  ok "signed with a Developer ID identity"
else
  bad "$TARGET is not signed with a Developer ID identity — run: make dist-sign"
  exit 1
fi

step "[2/5] package the upload"
work="$(mktemp -d)" || exit 1
trap 'rm -rf "$work"' EXIT

case "$TARGET" in
  *.app)
    base="$(basename "$TARGET" .app)"
    sub="$work/$base.zip"
    # `ditto -c -k --keepParent` is the one archive form that preserves the
    # bundle's symlinks, extended attributes and code signature. `zip -r`
    # flattens symlinks and the upload arrives with a broken signature.
    ditto -c -k --keepParent "$TARGET" "$sub"
    ;;
  *)
    # A disk image is already a single file, and it is uploaded as it is.
    sub="$TARGET"
    ;;
esac
ok "$(du -h "$sub" | cut -f1)  $(basename "$sub")"

step "[3/5] submit and wait (timeout $DIST_NOTARY_TIMEOUT)"
rc=0
xcrun notarytool submit "$sub" "${AUTH[@]}" \
  --wait --timeout "$DIST_NOTARY_TIMEOUT" --output-format json \
  > "$work/submit.json" 2> "$work/submit.err" || rc=$?

id="$(plutil -extract id raw -o - "$work/submit.json" 2>/dev/null || true)"
if [ -z "$id" ]; then
  bad "notarytool did not accept the upload"
  [ -s "$work/submit.json" ] && sed 's/^/      /' "$work/submit.json"
  [ -s "$work/submit.err" ] && sed 's/^/      /' "$work/submit.err"
  exit 1
fi
status="$(plutil -extract status raw -o - "$work/submit.json" 2>/dev/null || echo unknown)"
# `--wait` exits non-zero when the verdict is Invalid, so rc is not the signal;
# the STATUS is, and step [5/5] is where it is acted on. rc is kept only so a
# transport failure with no id still reaches the branch above.
ok "submission $id — $status (notarytool exit $rc)"

step "[4/5] the submission log"
mkdir -p "$ROOT/dist/out"
tname="$(basename "$TARGET")"
LOG="$ROOT/dist/out/notary-${tname// /-}-$id.json"
# A log that will not download is not a reason to leave an ACCEPTED build
# unstapled: the verdict is already in hand, and the log can be fetched again
# by id at any time. So this is a note, and step [5/5] still runs.
have_log=""
if xcrun notarytool log "$id" "${AUTH[@]}" "$LOG" >/dev/null 2>&1; then
  have_log=1
else
  note "could not fetch the log for $id — later: xcrun notarytool log $id --key <p8> --key-id $DIST_NOTARY_KEY_ID"
fi

# `plutil -extract issues raw` prints an ARRAY'S LENGTH, which is the count we
# want. A submission with nothing to report writes `"issues": null` — a JSON
# null plutil cannot extract in raw or json form and exits non-zero over — so a
# failure here means "no issues", not a broken log.
nissues=0
[ -n "$have_log" ] && nissues="$(plutil -extract issues raw -o - "$LOG" 2>/dev/null || echo 0)"
case "$nissues" in
  ''|*[!0-9]*) nissues=0 ;;
esac
if [ -z "$have_log" ]; then
  # Without the log there is nothing to count, and "no issues" would be a
  # claim about a file this run never got — the one sentence someone reads
  # before deciding not to look further.
  note "log not fetched — issues unknown"
elif [ "$nissues" -eq 0 ]; then
  ok "no issues in the log"
else
  # Not a failure row: warnings appear here on an Accepted submission too, and
  # the verdict is step [5/5]'s to give.
  note "$nissues issue(s) — severity, path, message:"
  # `|| true`: this is a printer, not a gate. A missing python3 or a shape the
  # loop does not expect must not end the run one step before the staple, on a
  # submission Apple has already accepted.
  python3 - "$LOG" <<'PY' 2>&1 | sed 's/^/      /' || true
import json, sys
for i in json.load(open(sys.argv[1])).get("issues") or []:
    print("%-8s %s" % (i.get("severity") or "?", i.get("path") or ""))
    print("         %s" % (i.get("message") or ""))
PY
fi
[ -n "$have_log" ] && ok "log: $LOG"

step "[5/5] staple and verify"
if [ "$status" != "Accepted" ]; then
  bad "notarization ended $status — read the issues above and $LOG"
  exit 1
fi

# stapler's own output is kept for the failure rows: a ticket lookup that has
# not propagated yet is the commonest transient here, and its message is the
# one thing that says so.
if out="$(xcrun stapler staple "$TARGET" 2>&1)"; then
  ok "ticket stapled"
else
  bad "xcrun stapler staple failed on $TARGET"
  printf '%s\n' "$out" | sed 's/^/      /'
  exit 1
fi
if out="$(xcrun stapler validate "$TARGET" 2>&1)"; then
  ok "xcrun stapler validate"
else
  bad "the stapled ticket does not validate"
  printf '%s\n' "$out" | sed 's/^/      /'
  exit 1
fi

# Gatekeeper's own answer, which is the one the user's Mac gives. An .app is
# assessed as something to EXECUTE; a .dmg as something to OPEN, and there
# against its primary signature rather than a quarantine record it has not got.
case "$TARGET" in
  *.app) gk="$(spctl -a -vv -t exec "$TARGET" 2>&1 || true)" ;;
  *)     gk="$(spctl -a -vv -t open --context context:primary-signature "$TARGET" 2>&1 || true)" ;;
esac
if printf '%s\n' "$gk" | grep -q 'source=Notarized Developer ID'; then
  ok "$(printf '%s\n' "$gk" | grep -m1 'source=')"
else
  bad "Gatekeeper did not accept it:"
  printf '%s\n' "$gk" | sed 's/^/      /'
  exit 1
fi

# Apple's post-notarization readiness check, the companion of the
# notary-submission one dist/sign.sh runs before the upload. As there, the exit
# code is 70 for warnings as well as fatals, so the severities are the verdict:
# refusing a stapled, accepted build over a warning would spend a submission
# and stop the release for nothing.
case "$TARGET" in
  *.app)
    if [ -x /usr/bin/syspolicy_check ]; then
      sp="$(/usr/bin/syspolicy_check distribution "$TARGET" 2>&1)" || true
      printf '%s\n' "$sp" | sed 's/^/      /'
      if printf '%s\n' "$sp" | grep -q 'Severity: *Fatal'; then
        bad "syspolicy_check distribution found a FATAL issue"
        exit 1
      elif printf '%s\n' "$sp" | grep -q 'Severity: *Warning'; then
        note "syspolicy_check distribution: warnings only"
      else
        ok "syspolicy_check distribution"
      fi
    else
      note "syspolicy_check is absent (macOS 14+ ships it) — distribution check skipped"
    fi
    ;;
esac

printf "\n"
ok "$TARGET is notarized and stapled"
