# `dist/` — building the macOS installer

Everything that turns a checkout into `Bond-Desktop-<version>.dmg`. Each step
is a script here, driven by a `make` target, and each is idempotent — safe to
re-run, though not always fast: `dist-llama` skips when its `.pin` stamp still
matches, but `dist-app` rebuilds the app every time.

`docs/distribution.md` is the maintainer's build guide (the end-user install
guide is `docs/install.md`, Phase 4). This file covers what the scripts need
from the machine they run on.

## Targets

| Target | Script | What it does |
|---|---|---|
| `make dist-llama` | `build-llama.sh` | Builds `llama-server` from a SHA-pinned llama.cpp source tarball into `dist/stage/llama/` |
| `make dist-app` | `bundle.sh` | `flutter build macos`, then lays the sidecar into `dist/stage/Bond Desktop.app` |
| `make dist-sign` | `sign.sh` | Signs the bundle inside out, then asserts what notarization requires |
| `make dist-notarize` | `notarize.sh` | Submits the signed app to Apple, waits for the verdict, saves the log, staples the ticket |
| `make dist-dmg` | `dmg.sh` | Wraps the bundle in `dist/out/Bond-Desktop-<version>.dmg`, then signs, notarizes and staples the image |
| `make dist-check` | `check.sh` | Reports what this machine still needs; changes nothing |
| `make dist-clean` | — | `rm -rf dist/stage dist/out` |
| `make dist-appcast` | `appcast.sh` | Signs the released DMG for Sparkle and regenerates `docs/appcast/appcast.xml` |
| `make dist-sparkle-tools` | `sparkle-tools.sh` | Stages Sparkle's pinned command line tools, including the `generate_keys` that makes the update key pair |
| `make dist` | — | The release: a strict `dist-check`, then the whole chain, signed, notarized, stapled and published to the update feed |

The build targets chain: `dist-dmg` needs `dist-notarize` needs `dist-sign`
needs `dist-app` needs `dist-llama`, so `make dist-dmg` runs the whole thing.
Under `AD_HOC=1` the `dist-notarize` link is dropped, because an ad-hoc
signature is not something Apple would accept. `make dist` is that chain with
a step at each end: strict `dist-check` in front, so a release never begins on
a machine that cannot finish it, and `dist-appcast` behind, so the release the
DMG represents is one every installed copy hears about.

`dist-appcast` deliberately takes **no prerequisite**. `dist-app` rebuilds the
whole app on every run, and re-running the appcast after a failed upload must
not rebuild and re-notarize an identical binary; what it needs instead is the
notarized DMG already sitting in `dist/out/`, which it checks for. So
regenerating only the feed is `make dist-appcast` on its own. `dist-check`,
`dist-clean` and `dist-sparkle-tools` also stand alone and depend on nothing.

`dist-check` takes two switches of its own: `STRICT=1` makes it exit non-zero
while any row is red (that is how `make dist` runs it), and
`DIST_CHECK_OFFLINE=1` skips the one row that talks to Apple.

`AD_HOC=1` makes every step work with no certificate at all:

```sh
make dist-dmg AD_HOC=1
```

That produces an unsigned, unnotarized DMG. It is the right command for a
tester build and for any change to the pipeline itself. It is not a rehearsal
of the real thing: an ad-hoc signature cannot carry the hardened runtime,
because library validation refuses ad-hoc-signed dylibs. `make dist` refuses
`AD_HOC=1` outright rather than produce an unsigned image under the name of the
release target, and says which command to use instead.

A tester build also needs a `BOND_MCP_SERVER_URL`, or it cannot sign in.
`dist-app` refuses to build without one, so point `MS_ENV` at an env file that
has it:

```sh
make dist-dmg AD_HOC=1 MS_ENV=/path/to/.env
```

To exercise the pipeline itself without one — checking a script change, not
producing something anyone will install — set `BOND_DIST_ALLOW_NO_MCP=1`. The
build then says so and carries on.

A tester build needs **no update keys**: with `DIST_APPCAST_URL` and
`DIST_SPARKLE_PUBLIC_KEY` unset, `AD_HOC=1` writes no Sparkle keys into
`Info.plist`, says so, and the resulting app's About section reports that
updates are not configured in this build (with them set, as on the release
machine, a tester build carries them like any other). (A **release** build refuses to
continue without them — a release that cannot update itself is one that can
never be corrected.) `AD_HOC=1 dist/appcast.sh` is the matching rehearsal: it
runs the whole feed generation against whatever key `dist.env` names — so
point `DIST_ENV` at a scratch env with a throwaway key rather than the real
one — skips the notarization and build-number checks, and leaves the result
in `dist/stage/appcast/` rather than writing over the published
`docs/appcast/appcast.xml`.

`DIST_NOTARY_TIMEOUT` (default `30m`) bounds the wait for Apple's verdict, so
an outage on their side fails the build with a message instead of hanging the
terminal overnight.

## Prerequisites

- Xcode and its command line tools.
- **The Metal toolchain**, which Xcode 26 does not install by default:
  `xcodebuild -downloadComponent MetalToolchain`. Without it the ggml Metal
  shaders cannot be compiled and `dist-llama` fails at the metallib step.
- `cmake` (`brew install cmake`).
- Flutter 3.47 or newer.

`make dist-check` reports all of these, plus the signing and notarization
settings below, one row each with the command that fixes it.

## `dist/local/`

Gitignored, and never in the repo under any name. Everything a release needs
that is specific to this developer rather than to the project:

| File | What it is | Secret |
|---|---|---|
| `dist.env` | The settings below, as shell assignments. Copy `dist/local.env.example` | no |
| `AuthKey_<id>.p8` | App Store Connect API key notarytool authenticates with. Downloadable exactly once. Keep it mode 600 | **yes** |
| `sparkle_ed25519.key` | Sparkle's EdDSA private key, from `generate_keys -x`. Whoever holds it can sign an update the app installs without asking | **yes** |

The two key files do not have to sit in `dist/local/` — `dist.env` names their
paths, and anywhere mode-600 and outside the repo will do. The author keeps the
`.p8` in `~/.bond-signing/` beside the certificate backups, so that removing a
worktree after a merge cannot delete the only local copy of a file Apple will
not issue twice.

The Developer ID Application certificate and its private key are not files
here: they live in the login keychain. The `.p12` export belongs in the
password manager beside these.

**All of `dist/local/` belongs in a password manager.** Two of the three items
cannot be recovered if lost: the `.p8` is downloadable once, and a lost Sparkle
private key means every installed copy of the app stops accepting updates.

`dist.env` holds `DIST_SIGN_IDENTITY`, `DIST_TEAM_ID`, `DIST_NOTARY_KEY_PATH`,
`DIST_NOTARY_KEY_ID`, `DIST_NOTARY_ISSUER` (Team keys only — an individual key
must leave it blank), `DIST_SPARKLE_PRIVATE_KEY_PATH`,
`DIST_SPARKLE_PUBLIC_KEY`, `DIST_APPCAST_URL` and `DIST_DOWNLOAD_URL_PREFIX`.
`dist/local.env.example` documents where each one comes from.

## A new laptop, from nothing to a release

1. Install Xcode, then `xcode-select --install`, then
   `xcodebuild -downloadComponent MetalToolchain`.
2. Install Flutter 3.47+ and `brew install cmake`.
3. `git clone` this repo.
4. Copy `dist/local/` out of the password manager, and
   `chmod 600 dist/local/*.p8`. Copy the Sparkle key file to
   `~/.bond-signing/sparkle_ed25519.key` as well and `chmod 600` it — it is
   the one secret here that nobody can reissue, and without it this machine can
   build a release but cannot publish an update for it.
5. Import the Developer ID `.p12` into the login keychain and let `codesign`
   reach it without a prompt:

   ```sh
   security import "<path>.p12" -k ~/Library/Keychains/login.keychain-db \
     -T /usr/bin/codesign -T /usr/bin/security
   security set-key-partition-list -S apple-tool:,apple: -s \
     -k "<login password>" ~/Library/Keychains/login.keychain-db
   ```

   The second command is the one that is easy to skip and painful to skip.
   Without a partition list, macOS asks for the keychain password on **every**
   signature — about twenty of them in one `make dist` — and a build running in
   a terminal that cannot show the prompt simply hangs.

   Then put the certificate's SHA-1, not its name, in `DIST_SIGN_IDENTITY`:
   `security find-identity -v -p codesigning` prints it at the start of the
   line. A renewed certificate shares the name of the one it replaces, and a
   name that matches two identities is one codesign refuses.
6. Write `.env` next to the `Makefile` with `BOND_MCP_SERVER_URL`, and with
   **no** `MICROSOFT_CLIENT_SECRET` — `dist-app` refuses to build otherwise,
   because that secret would be readable in the shipped binary.
7. `make dist-check` until the summary reads `all clear`.
8. `make dist`.

## Files here

- `build-llama.sh`, `bundle.sh`, `sign.sh`, `notarize.sh`, `dmg.sh`,
  `appcast.sh`, `check.sh` — the steps above. `notarize.sh` takes the path to a
  `.app` or a `.dmg` and is called twice in a release, once for each.
- `sparkle-tools.sh` — fetches Sparkle's SHA-pinned command line tools into
  `dist/stage/sparkle-tools/`. It also cross-checks its own pin against the
  version the app embeds (`Package.resolved`), because the tool that writes the
  feed and the framework that reads it have to move together.
- `sparkle-pubkey.py` — derives the public half of a Sparkle private key, in
  pure Python because macOS ships LibreSSL, which has no Ed25519. `dist-check`
  uses it for one row: whether `DIST_SPARKLE_PUBLIC_KEY` really is this key
  file's public key. `--self-test` runs the RFC 8032 vector.
- `llama-server.entitlements` — an empty dict. The bundled helper gets no
  entitlements; the hardened runtime is a codesign flag `sign.sh` applies,
  not an entitlement and not an Xcode build setting.
- `local.env.example` — the template for `dist/local/dist.env`. Named this way
  round because `*.env` is gitignored and the commit hook refuses to stage it.
