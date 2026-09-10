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
| `make dist-sign` | `sign.sh` | Signs the bundle inside out |
| `make dist-dmg` | `dmg.sh` | Wraps the bundle in `dist/out/Bond-Desktop-<version>.dmg` |
| `make dist-check` | `check.sh` | Reports what this machine still needs; changes nothing |
| `make dist-clean` | — | `rm -rf dist/stage dist/out` |
| `make dist` | — | **Phase 5.** The whole chain, signed and notarized |
| `make dist-notarize` | `notarize.sh` | **Phase 5.** Submit to Apple, wait, staple |
| `make dist-appcast` | `appcast.sh` | **Phase 6.** Sign the DMG for Sparkle and regenerate the appcast |

The four build targets chain: `dist-dmg` needs `dist-sign` needs `dist-app`
needs `dist-llama`, so `make dist-dmg` runs the whole thing. `dist-check` and
`dist-clean` stand alone and depend on nothing.

`AD_HOC=1` makes every step work with no certificate at all:

```sh
make dist-dmg AD_HOC=1
```

That produces an unsigned, unnotarized DMG. It is the right command for a
tester build and for any change to the pipeline itself. It is not a rehearsal
of the real thing: an ad-hoc signature cannot carry the hardened runtime,
because library validation refuses ad-hoc-signed dylibs.

A tester build also needs a `BOND_MCP_SERVER_URL`, or it cannot sign in.
`dist-app` refuses to build without one, so point `MS_ENV` at an env file that
has it:

```sh
make dist-dmg AD_HOC=1 MS_ENV=/path/to/.env
```

To exercise the pipeline itself without one — checking a script change, not
producing something anyone will install — set `BOND_DIST_ALLOW_NO_MCP=1`. The
build then says so and carries on.

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
   `chmod 600 dist/local/*.p8`.
5. Import the Developer ID `.p12` into the login keychain and allow `codesign`
   to use it.
6. Write `.env` next to the `Makefile` with `BOND_MCP_SERVER_URL`, and with
   **no** `MICROSOFT_CLIENT_SECRET` — `dist-app` refuses to build otherwise,
   because that secret would be readable in the shipped binary.
7. `make dist-check` until every row is green.
8. `make dist`.

## Files here

- `build-llama.sh`, `bundle.sh`, `sign.sh`, `dmg.sh`, `check.sh` — the steps above.
- `llama-server.entitlements` — an empty dict. The bundled helper gets no
  entitlements; the hardened runtime is a codesign flag `sign.sh` applies,
  not an entitlement and not an Xcode build setting.
- `local.env.example` — the template for `dist/local/dist.env`. Named this way
  round because `*.env` is gitignored and the commit hook refuses to stage it.
