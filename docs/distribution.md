# Distributing Bond Desktop

How a checkout becomes a DMG someone else can install. One command does all of
it — `make dist` — and what comes out is signed with a Developer ID
certificate, notarized by Apple and stapled, so it opens on a stranger's Mac
with no warning and no detour. The same command ends by regenerating the
Sparkle update feed, so an installed copy of the previous release finds the new
one on its own.

The machine-local half of this — what lives in `dist/local/`, and the
new-laptop checklist — is in `dist/README.md`.

## Prerequisites

Xcode with its command line tools, Flutter 3.47 or newer, `cmake`, and — the
one that is easy to miss — **Xcode's Metal toolchain**, which Xcode 26 does
not install by default:

```sh
xcodebuild -downloadComponent MetalToolchain
```

Without it the ggml Metal shaders cannot be compiled and `dist-llama` fails
partway through with a linker error that does not name this as the cause.
`make dist-check` reports every prerequisite with the command that fixes it.

## The pipeline

```sh
make dist-check              # what this machine still needs
make dist-dmg AD_HOC=1       # a DMG for testers, no certificate needed
make dist                    # signed, notarized, stapled
```

`make dist` is seven steps:

0. **strict `dist-check`** (`_dist-preflight`). The same report as
   `make dist-check`, run with `STRICT=1` so a red row stops the build before
   it starts. Half an hour of compiling and then a missing notary key is the
   failure this exists to refuse. It also refuses `AD_HOC=1`: `make dist` is
   the release, and the tester build is `make dist-dmg AD_HOC=1`. The preflight
   is **not** run with `DIST_CHECK_OFFLINE=1`, so it includes the one row that
   talks to Apple — `notarytool history` against the .p8, the key id and the
   issuer — and a release build therefore proves the notarization credentials
   before the twenty-minute build rather than after it. `DIST_CHECK_OFFLINE=1`
   is for running `make dist-check` on a plane, not for a release.
1. **`dist-llama`** builds `llama-server` from a SHA-256-pinned llama.cpp
   source tarball and stages it under `dist/stage/llama/`.
2. **`dist-app`** runs `flutter build macos --release` and copies the sidecar
   into `dist/stage/Bond Desktop.app`.
3. **`dist-sign`** signs the bundle inside out with the Developer ID identity
   and the hardened runtime, then asserts everything notarization requires.
4. **`dist-notarize`** zips the app, submits it, waits for Apple's verdict,
   saves the log and staples the ticket into the bundle.
5. **`dist-dmg`** builds `dist/out/Bond-Desktop-<version>.dmg` from the
   **stapled** app, signs the image, notarizes it in its own right and staples
   that ticket too.
6. **`dist-appcast`** signs that DMG with the Sparkle EdDSA key and rewrites
   `docs/appcast/appcast.xml`, the feed every installed copy reads. See
   [Updates](#updates).

The dependency shape is worth stating outright, because it is where the order
is enforced rather than in any script:

```make
dist-dmg: dist-sign $(if $(AD_HOC),,dist-notarize)
dist: _dist-preflight dist-dmg dist-appcast
```

`dist-dmg` pulls in `dist-notarize` **unless `AD_HOC=1`**, and `.NOTPARALLEL`
at the top of the Makefile keeps prerequisites in the order they are written.
There are no `$(MAKE)` sub-invocations: a sub-make would rebuild the app once
per call.

`dist-appcast` is a goal of `dist` rather than a prerequisite of anything, and
it declares no prerequisite of its own on purpose: `dist-app` rebuilds the app
every time it runs, so a feed regenerated after a failed upload would otherwise
rebuild and re-notarize a binary that had not changed. It reads the DMG already
in `dist/out/`.

`VERSION` and `BUILD` are read from the single `version:` line in
`app/pubspec.yaml` and passed to Flutter as `--build-name` and
`--build-number`, so `1.0.0+1` is the only place either number is written.

### Why llama.cpp is built from source

Homebrew's `llama-server` cannot be bundled. Its install names are absolute
(`/opt/homebrew/opt/ggml/…`, `openssl@3`), it is ad-hoc signed by someone
else, and its ggml backends sit under
`/opt/homebrew/Cellar/ggml/*/libexec`. A binary inside an app bundle has to
find its own libraries relative to itself, which means building it with an
`@loader_path` rpath.

The tag and the tarball's SHA-256 are literals in `dist/build-llama.sh`, in
the same style and for the same reason as `make vec-vendor`: there is nothing
upstream to verify a source tarball against, so the digest was measured once
by hand and every rebuild is checked against it. `build-llama.sh` also
hard-fails if `otool -L` finds `/opt/homebrew` or `/usr/local` anywhere in
what it staged, which is the check that catches a build flag regressing.

Three flags are worth naming:

- `-DGGML_BACKEND_DL=ON` makes each ggml backend a separately loaded `.so`.
- `-DGGML_METAL_EMBED_LIBRARY=OFF` ships real compiled shaders instead of
  compiling them from source at every process start, which is slow and has
  deadlocked on new GPU generations.
- `-DLLAMA_OPENSSL=OFF` and `-DLLAMA_USE_PREBUILT_UI=OFF` turn off two things
  that are on by default and both break a bundled build: OpenSSL links
  Homebrew's `openssl@3` into the binary, and the prebuilt web UI is
  downloaded from Hugging Face *during the build*, which makes a pinned build
  depend on a mutable remote. Neither is used — the app downloads its own
  weights and speaks HTTP to the server.

### The bundle layout, and why

```
Bond Desktop.app/Contents/
  MacOS/Bond Desktop              the Flutter app
  MacOS/llama-server              the sidecar
  MacOS/libggml-*.so              backend modules
  MacOS/default.metallib          → symlink to ../Resources/default.metallib
  MacOS/ggml-tensor.metallib      → symlink, when the SDK produced one
  Frameworks/libllama*.dylib      the shared libraries, plus libmtmd, libggml*
  Resources/default.metallib      the real compiled Metal shaders
  Resources/ggml-tensor.metallib
```

**The `.so` backends must sit beside the executable.** `ggml_backend_load_all()`
scans the compile-time backend directory, then the directory of the running
executable, then the working directory. `GGML_BACKEND_PATH` loads exactly one
file and cannot point at a directory, so there is no environment variable that
would let them live somewhere tidier.

**The metallibs are real files in `Resources/` with symlinks in `MacOS/`,**
because ggml looks for the shaders twice: first by asking `NSBundle` for
`default.metallib`, which resolves inside `Contents/Resources/`, and then for
a `default.metallib` sitting next to `argv[0]` with symlinks resolved. Shipping
both spellings means neither lookup order matters. A missing
`ggml-tensor.metallib` silently disables the tensor kernels rather than
failing, so its absence is worth noticing.

The copy happens in `dist/bundle.sh` rather than in an Xcode Copy Files phase
because the macOS runner project is Flutter-regenerable, and a build phase
added by hand is exactly what a project refresh drops without saying so.

**What the app writes at runtime.** Nothing above is written to after the
build — the bundle is read-only and code-signed. Everything the running app
produces lives under `~/Library/Application Support/com.bondinbox.app/`:

- `servers/` — the router preset the supervisor writes (`router.ini`), the pid
  file the next launch reaps (`router.json`), and `empty-cache/`, an empty
  directory the child is deliberately pointed at as `LLAMA_CACHE`.
- `logs/llama-server.log` — the sidecar's own output, and the one folder a user
  is ever asked to open and send. **Show log** on the Local server card opens
  it.
- `models/` — the GGUF files, tens of gigabytes of them, unless the user pointed
  the card at a folder of their own. The only folder here worth deleting by
  hand.

That root is also a change of address. The app used to be sandboxed, which put
its data inside `~/Library/Containers/com.bondinbox.app/`; it is not sandboxed
any more, because it has to spawn a child process and read model files the user
chose. `migrateSandboxContainerData` (`app/lib/data/app_paths.dart`) runs on the
first unsandboxed launch, BEFORE the database is opened, and copies the database
with its `-wal` and `-shm` sidecars and the attachments tree across. It copies
rather than moves — a bad migration then costs the user nothing — never throws,
and removes a partial copy from the target rather than leaving one that the next
launch would read as "already migrated". What it did is recorded in
`setup_state` under `container_migration`. Keychain items do not migrate; the
user signs in once more.

### Signing

Two rules, both from Apple's distribution-signing guidance:

- **Inside out.** `.so` backends, then `.dylib` files, then frameworks, then
  the `llama-server` helper, then the app. Signing the app first seals a hash
  of unsigned contents, and every signature after that invalidates it.
- **Never `codesign --deep` to sign.** It applies one identity and one set of
  entitlements to everything it finds, including the helper that needs its
  own. `--deep` is for verifying, and `dist/sign.sh` ends with exactly that:
  `codesign -vvv --deep --strict`.

Loose Mach-O files get an explicit `-i com.bondinbox.app.<basename>`: with no
`Info.plist` they have no identifier of their own, and two unrelated bundles
must not end up claiming the same one.

The app is **unsandboxed** and keeps the **hardened runtime**. The sandbox had
to go: it allows `process-exec` only inside the app bundle and a few system
directories, a child always inherits the parent's sandbox, and a models folder
the user picks cannot be reached from that child at all. Notarization has
never required the sandbox. The hardened runtime is neither an entitlement
nor an Xcode build setting: it is the `--options runtime` flag that
`dist/sign.sh` passes in its Developer ID branch, and nowhere else. Release
carries only the two network keys.

Under `AD_HOC=1` the hardened runtime is deliberately **off**: it turns on
library validation, and library validation refuses ad-hoc-signed dylibs, so an
ad-hoc build with the runtime on cannot load its own backends. An ad-hoc build
is therefore a test of the layout and the pipeline, never a rehearsal of the
real signature.

**The identity is named by its SHA-1, not by its name.** `DIST_SIGN_IDENTITY`
holds the 40-hex hash `security find-identity -v -p codesigning` prints at the
start of each line. A renewed Developer ID certificate carries the *same name*
as the one it replaces — this project's G2 certificate and the superseded G1
one are both "Developer ID Application: John Carnahan (5AHEW8393H)" — and a
name matching two identities is one codesign refuses to use at all. `sign.sh`
resolves the value against the keychain before it signs anything, so a missing
or ambiguous identity is a message with a fix rather than an error on the first
`.so`.

**`--options runtime` and `--timestamp`** are the two flags the Developer ID
branch adds, and notarization requires both. The timestamp is a round trip to
Apple's timestamp server for *every* signature, about twenty of them here, so a
machine with no network cannot produce a distribution signature; that is what
`AD_HOC=1` is for.

**The distribution checks.** `sign.sh` ends its Developer ID run with a block
of assertions — the things the notary service rejects an upload for, checked
where the fix is a one-line change instead of twenty minutes later in a
submission log:

| Check | Why it matters |
|---|---|
| `Authority=Developer ID Application` | The notary service accepts no other kind of certificate; an Apple Development signature builds something that runs on this Mac alone |
| `flags=0x…(runtime)` on the app and on `llama-server` | Notarization requires the hardened runtime |
| `TeamIdentifier` equals `DIST_TEAM_ID` | `dist.env` and the certificate disagreeing is caught before the upload |
| No `app-sandbox`, no `get-task-allow` | `get-task-allow` lets a debugger attach and is a hard rejection; the sandbox would bring back the container this app deliberately left |
| `llama-server` carries no entitlements at all | `dist/llama-server.entitlements` is an empty dict, and anything else means the helper picked up the app's |
| Every nested `.so`, `.dylib` and `.framework` carries the team | Library validation comes on **with** the hardened runtime and refuses to load a library whose team differs from the loading process's. A binary validly signed by somebody else is exactly this failure, and without the check it appears as a launch that dies loading its own backends |
| `syspolicy_check notary-submission` | Apple's own pre-flight: the same checks the service runs, offline, in a second |

`spctl` is deliberately *not* run there. Until a ticket is stapled it answers
"rejected (source=Unnotarized Developer ID)", which is correct and tells nobody
anything; `dist/notarize.sh` runs it after stapling, where the answer is the
one a user's Mac will give.

## Notarization

Apple scans the upload for malware and for signing mistakes and, finding none,
issues a **ticket** for that exact code. **Stapling** writes the ticket into the
bundle or the image, so Gatekeeper on the user's Mac can check it with no
network at all. An unstapled but notarized build still opens — provided that
Mac can reach Apple at that moment. A stapled one always does.

`dist/notarize.sh <path to .app or .dmg>` is five steps:

1. **Preconditions.** The target exists and is a `.app` or a `.dmg`;
   `DIST_NOTARY_KEY_PATH` names a file and `DIST_NOTARY_KEY_ID` is set; and
   `codesign -dvv` on the target shows a Developer ID authority. An ad-hoc
   upload would be rejected after the whole file had transferred and several
   minutes had passed, and it would spend one of the day's submissions.
2. **Package.** An `.app` is zipped with `ditto -c -k --keepParent`, the one
   archive form that preserves the bundle's symlinks, extended attributes and
   signature — `zip -r` flattens symlinks and the upload arrives broken. A
   `.dmg` is already one file and is submitted as it is.
3. **Submit.** `xcrun notarytool submit --wait --timeout $DIST_NOTARY_TIMEOUT`
   (default `30m`). `--wait` exits non-zero when the verdict is `Invalid`, so
   the *status* is what the script branches on, never the exit code.
4. **The log, always.** `notarytool log <id>` is fetched for every submission,
   `Accepted` included, and saved to
   `dist/out/notary-<target name>-<submission id>.json` — the target's file
   name with spaces turned into dashes. `Accepted` does not mean silent:
   warnings live in the same `issues` array as errors, and a warning is how
   Apple announces the thing that becomes a hard rejection in a later macOS.
   Each issue names a `severity`, a `path` and a `message`, and the path is the
   offending file inside the upload. That JSON path is what goes into a bug
   report.
5. **Staple and verify.** `xcrun stapler staple`, then `stapler validate`, then
   Gatekeeper's own answer — `spctl -a -vv -t exec` for an app, `spctl -a -vv
   -t open --context context:primary-signature` for an image — which must say
   `source=Notarized Developer ID`. For an app, `syspolicy_check distribution`
   finishes it off.

**Twice, in that order.** The `.app` is notarized and stapled first; only then
is the DMG built from that stapled copy. A DMG built earlier would contain an
app with no ticket in it. The image is then signed and notarized *in its own
right*, because it is separate code with its own signature and it is what the
user actually downloads — Gatekeeper checks the DMG before anything inside it.
The image is signed **without** `--options runtime`: the hardened runtime is a
property of executing code, and a disk image does not execute. `--timestamp`
still applies.

**Team key or individual key.** An App Store Connect **Team** key requires
`--issuer`; an **individual** key rejects the request when one is passed.
`dist.env` records which this is by having a `DIST_NOTARY_ISSUER` or leaving it
blank, and `dist-check` reports either as green. This project uses a Team key.

**The quota** is about 75 notarizations per team per day. A release is two of
them, the app and the image, and so is every re-run of `make dist`: the
rebuild invalidates the previous ticket, so the app is submitted again. The
steps are idempotent in effect, not in quota. It is not a thing to put in a
retry loop.

## Apple account setup

One-time, done on 2026-09-10 for this project. It is written down because the
next person to do it will be doing it for the first time.

1. **A paid Apple Developer Program membership.** Individual is enough for
   Developer ID; an Organization membership is only needed for things this
   project does not do. Developer ID signing is not available on a free account
   at all.
2. **The certificate.** *Certificates, Identifiers & Profiles → Certificates →
   `+` → Developer ID Application.* Apple asks for a CSR: in **Keychain
   Access**, *Certificate Assistant → Request a Certificate From a Certificate
   Authority*, saved to disk. Upload it, download the issued `.cer`, and
   double-click it into the **login** keychain. Certificates issued now chain
   through Apple's **G2** intermediate.
3. **Back the certificate up.** In Keychain Access, export it **with its
   private key** as a `.p12` and put that in the password manager. The private
   key exists in exactly one place until you do; Apple cannot reissue it.
4. **The notary key.** *App Store Connect → Users and Access → Integrations →
   App Store Connect API → **Team Keys** → Generate.* **Developer** access is
   enough for notarization. The `.p8` downloads **once and only once**. Note
   the **Key ID** on its row and the **Issuer ID** at the top of the page, then
   `chmod 600` the file and keep it outside the repo (see `dist/README.md`).
5. **The Sparkle key** is not an Apple item and is not created here — see
   [Updates](#updates) → *Generating the key pair*. A second machine needs the
   key **file** copied to it (`~/.bond-signing/sparkle_ed25519.key`, mode 600);
   without it that machine can build a release but cannot publish an update
   for it.
6. **A second machine** needs the certificate imported and made reachable
   without a prompt:

   ```sh
   security import "<path>.p12" -k ~/Library/Keychains/login.keychain-db \
     -T /usr/bin/codesign -T /usr/bin/security
   security set-key-partition-list -S apple-tool:,apple: -s \
     -k "<login password>" ~/Library/Keychains/login.keychain-db
   ```

   Without the partition list, macOS asks for the keychain password on every
   one of the twenty signatures, and a `make dist` in a terminal that cannot
   show the prompt simply hangs.

## Updates

Bond updates itself with [Sparkle](https://sparkle-project.org) 2.9.6. An
installed copy reads a small signed XML feed about once a day, and when the feed
names a newer version than its own it offers it, downloads it and replaces
itself. Everything below is what makes that both work and safe.

### How Sparkle gets into the app

**SwiftPM, pinned exactly.** `app/macos/Runner.xcodeproj/project.pbxproj`
carries an `XCRemoteSwiftPackageReference` on `sparkle-project/Sparkle` with
`kind = exactVersion; version = 2.9.6`, a product dependency on `Sparkle` in the
Runner target, and a build file for it in the Runner's Frameworks phase. The
resolved version is committed as `Package.resolved` — Xcode writes it twice,
under `app/macos/Runner.xcworkspace/xcshareddata/swiftpm/` (the workspace
`flutter build macos` builds) and under
`app/macos/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`, with
identical contents, and both copies are committed — so what a fresh checkout
builds is what this one built. The first
`make dist-app` on a machine **downloads the package**, so a fresh checkout
needs network for that build — Xcode verifies the download against the checksum
inside Sparkle's own `Package.swift`.

Xcode embeds the framework into `Contents/Frameworks/Sparkle.framework` by
itself; nothing in `dist/bundle.sh` copies it. It does have to be **re-signed**,
though, which is `dist/sign.sh` step `[3/6]`:

```
Versions/B/XPCServices/Installer.xpc     ← --preserve-metadata=entitlements
Versions/B/XPCServices/Downloader.xpc    ← --preserve-metadata=entitlements
Versions/B/Autoupdate
Versions/B/Updater.app
Sparkle.framework                        ← the frameworks loop, step [4/6]
```

Innermost first, like everything else in that script. The reason is library
validation, which comes on with the hardened runtime: it refuses to load a
framework whose nested executables carry somebody else's team identifier, and
the Sparkle project's own perfectly valid signature is exactly that. Without
this step the app launches and dies the moment it touches the updater. The two
XPC services ship with **no** entitlements in 2.9.6;
`--preserve-metadata=entitlements` is there for the version that sandboxes the
downloader again, where stripping them would leave a service that cannot do its
job. `sign.sh`'s distribution checks count these four alongside the `.so` files
and the dylibs.

**The four `Info.plist` keys** come from `dist/bundle.sh` step `[5/6]`, written
with `PlistBuddy` out of `dist.env`, and from nowhere else — not from the Xcode
project, which is Flutter-regenerable and must not hold machine-local settings:

| Key | From | What it does |
|---|---|---|
| `SUFeedURL` | `DIST_APPCAST_URL` | Where to look |
| `SUPublicEDKey` | `DIST_SPARKLE_PUBLIC_KEY` | The only key whose signatures this copy will accept |
| `SUEnableAutomaticChecks` | literal `true` | Without it Sparkle **asks the user** on the second launch whether to check automatically |
| `SUScheduledCheckInterval` | literal `86400` | Daily |

They are written **before signing**, because the signature seals `Info.plist`
and a key added afterwards invalidates it. A release build with either of the
two `dist.env` values missing is refused outright: a release that cannot update
itself is one that can never be corrected. A tester build (`AD_HOC=1`) gets a
note instead and ships without them.

**Two pins that move together.** `dist/sparkle-tools.sh` pins the version of
the command line tools that WRITE the feed; the pbxproj and `Package.resolved`
pin the framework that READS it. A tools version ahead of the framework can
write a feed the shipped app will not accept. `sparkle-tools.sh` cross-checks
the two itself and refuses to run when they disagree, and `make dist-check` has
a `Sparkle pins` row for the same comparison.

### Generating the key pair

Once, ever. Do it on the machine that will publish releases.

```sh
make dist-sparkle-tools
dist/stage/sparkle-tools/bin/generate_keys
```

It prints the **public** key (44 base64 characters) and stores the private key
in the login keychain. Export the private half to a file the release scripts
can read, and lock it down:

```sh
dist/stage/sparkle-tools/bin/generate_keys -x ~/.bond-signing/sparkle_ed25519.key
chmod 600 ~/.bond-signing/sparkle_ed25519.key
```

Then two lines in `dist/local/dist.env`:

```sh
DIST_SPARKLE_PRIVATE_KEY_PATH=/Users/<you>/.bond-signing/sparkle_ed25519.key
DIST_SPARKLE_PUBLIC_KEY=<the 44 characters generate_keys printed>
```

`make dist-check` derives the public half of that key file with
`dist/sparkle-pubkey.py` and compares it against `DIST_SPARKLE_PUBLIC_KEY`. That
row exists because a mismatched pair is a failure with **no symptom**: every
build succeeds, every signature is made, and every installed copy silently
refuses every update.

**Put the key file in the password manager.** Sparkle cannot re-issue it, and
every copy of Bond that has ever been installed trusts this key and no other.

### Hosting the feed

GitHub → the repo's **Settings → Pages → Deploy from a branch → `main`,
`/docs`**. The file then lives at:

```
https://jmcarnahan.github.io/bond-desktop/appcast/appcast.xml   ← DIST_APPCAST_URL
https://github.com/jmcarnahan/bond-desktop/releases/download/v{version}/
                                                    ↑ DIST_DOWNLOAD_URL_PREFIX
```

The download prefix must end in `/` — `generate_appcast` appends the DMG's file
name to it directly — and a literal `{version}` in it is substituted with the
release's version, which is what lets one line in `dist.env` name a per-tag
release URL. `docs/appcast/README.md` says the same thing to whoever opens that
directory first.

### What the user sees

**Settings → About** gains three things, all of them wired only when the updater
actually started (`docs/settings.md` → About):

- **Check for updates**, and beside it `Last checked 3h ago` or
  `Never checked for updates`.
- **Check for updates automatically**, a switch showing Sparkle's own
  preference — the screen re-reads it after every move rather than keeping a
  copy.
- In a development build, the sentence `Updates are not configured in this
  build.` and neither control, because the four keys above are written at
  package time.

Everything after the button is **Sparkle's own window** — the release notes, the
progress bar, the relaunch. That is the one non-Flutter surface in the app, and
it is deliberate: the no-dialogs house rule is a rule about Flutter screens
(`app/test/no_dialogs_test.dart` scans `lib/`, and Sparkle is Swift), and
reimplementing an installer in Flutter would buy nothing but risk.

Sparkle **never checks on a first launch**. The interval starts counting from
the second one, so a release reaches its users over the day after it is pushed,
not the minute of it.

### Switching keys

Don't, unless the key has leaked. `SUPublicEDKey` is baked into every build that
has ever shipped, and an installed copy accepts signatures from that key and no
other — so a new key pair leaves every existing installation permanently unable
to update, with no in-app way to tell them. Recovering means asking every user
to download and install a new DMG by hand. If the private key is compromised,
that is the price and it has to be paid; if it is merely lost, there is no price
that helps, which is why the file belongs in a password manager.

## Secrets

Full inventory and storage rules: `dist/README.md`. In short, everything
machine-local lives in the gitignored `dist/local/`, and three items are real
secrets — the Developer ID private key (in the login keychain, `.p12` in the
password manager), the App Store Connect `.p8` (downloadable once), and the
Sparkle EdDSA private key.

The `.p8` does not have to sit in `dist/local/`: `dist.env` names its path, and
anywhere mode-600 and outside the repo will do. This project's copy lives in
`~/.bond-signing/`, beside the certificate backups, so that removing a worktree
after a merge cannot delete the only local copy of a file Apple will not issue
twice.

The Sparkle private key follows the same rule and for a stronger reason:
`DIST_SPARKLE_PRIVATE_KEY_PATH` names it, it is kept mode 600 and outside the
repo (`~/.bond-signing/sparkle_ed25519.key` here), and it is the one secret in
this project that **nobody can reissue** — see [Updates](#updates) →
*Switching keys*. `make dist-check` reports its mode along with everything
else.

The Windows design adds no fourth item on the release Mac: its signing lives
in Azure, so no certificate file exists to keep anywhere (a `.pfx` would be
refused by `.gitignore` and by the commit hook regardless), and the Sparkle key
stays on the release Mac and never becomes a CI secret. What it does add is
four **repository secrets** on GitHub, whose values live only there:
`BOND_MCP_SERVER_URL` and the three Azure identity ids — see
`dist/windows/README.md` → CI.

One secret must never ship: **`MICROSOFT_CLIENT_SECRET`**. A build carrying it
has it readable in the binary, which is why `dist/bundle.sh` refuses to run
while the env file has a non-empty value for it. Distributed builds use MCP
mode, which needs only `BOND_MCP_SERVER_URL`.

## Bumping a model

The three checkpoints are named in exactly one place: `app/assets/models/
manifest.json`. A bump is an edit to that file and to nothing else — no Dart
changes, and a diff a reviewer can read.

1. Get the size and the digest from the tree API. `size` is the byte count and
   `lfs.oid` is the sha256:

   ```sh
   curl -s https://huggingface.co/api/models/<repo>/tree/main | \
     python3 -m json.tool
   ```

2. Get the revision — the commit the file is pinned to. **Never `main`:** a
   branch is a moving target, and a download resolved through one would fetch
   bytes that no longer match the digest.

   ```sh
   curl -sI https://huggingface.co/<repo>/resolve/main/<file> | \
     grep -i x-repo-commit
   ```

3. Edit the entry: `repo`, `file`, `revision`, `sizeBytes`, `sha256`,
   `displayName`, and the licence fields if the licence changed. **Keep the
   three `id`s** (`bond-embed`, `bond-bulk`, `bond-prose`) — they are what the
   router routes on, what the slots resolve to, and what the ledger is keyed
   by. Keep the file order smallest first.

4. `cd app && flutter test test/model_manifest_test.dart`. It parses the real
   asset, checks the digests and revisions, and pins the INI the preset writes.
   Update the size and digest literals in that file in the same commit — they
   are the second pair of eyes on a copy-paste.

### What an installed copy does with the bump

The manifest's `sha256` is the **identity** of a checkpoint, not just a
checksum over it. The setup ledger (`setup_state['download']`) records the
digest each file was downloaded against, and that record is what makes a bump
reach a machine where setup already finished.

On every launch of an existing install the setup gate compares the ledger's
digests with the manifest. A digest that changed — or a model id the ledger has
never seen — reopens setup at the **Download models** step on the next launch,
with the other steps already green. The downloader deletes a destination file
whose recorded digest no longer matches and fetches the new one from zero; a
`.part` from the previous checkpoint is discarded rather than resumed into.
**Finish** restarts the model server, so the process that comes back is serving
the new weights (`docs/pipeline/10-model-routing.md`, **Managed mode: one
router**).

One thing this does **not** do: a bump that changes `repo` or `file` — a new
quantisation, say — writes the new file **beside** the old one, and nothing
prunes the old one. The download folder keeps both, and the disk stays spent
until someone clears it. Note it in the release notes: the user may delete the
old `<repo with / → _>` folder under the models folder by hand.

## Releasing

1. Bump **both halves** of `version:` in `app/pubspec.yaml` — `1.0.1+2`, not
   `1.0.1+1`. It is the only place either number is written, and Sparkle
   decides "newer" on the build number (`CFBundleVersion`), not the version
   string; `dist-appcast` refuses a build number that is not above every one
   already in the feed.
2. `make dist-check` — the summary reads `all clear`.
3. `make dist` — preflight, build, sign, notarize, staple, DMG, and finally the
   appcast. It ends by naming `dist/out/Bond-Desktop-<version>.dmg` and the
   regenerated `docs/appcast/appcast.xml`.
4. Walk the **Verifying a release** checklist below.
5. `gh release create v<version> dist/out/Bond-Desktop-<version>.dmg`
   (a release upload is one of the commands this repo's hooks hand to the
   user).
6. `git add docs/appcast/appcast.xml && git commit && git push`. GitHub Pages
   redeploys, and installed copies see the release on their next daily check —
   within a day, not within a minute.

Something wrong with only the feed — a bad download prefix, a re-signed image?
`make dist-appcast` on its own re-runs that one step against the DMG already in
`dist/out/`. It rebuilds nothing and spends no notarization.

## Verifying a release

Eight checks, none of which needs the app to be launched. The first seven run
on the build machine; the last one is the only one that answers the question a
user is actually asking.

```sh
codesign -dvv "dist/stage/Bond Desktop.app"
codesign -d --entitlements - "dist/stage/Bond Desktop.app"
spctl -a -vv -t exec "dist/stage/Bond Desktop.app"
/usr/bin/syspolicy_check distribution "dist/stage/Bond Desktop.app"
xcrun stapler validate dist/out/Bond-Desktop-<version>.dmg
plutil -p "dist/stage/Bond Desktop.app/Contents/Info.plist" | grep SU
codesign -dvv "dist/stage/Bond Desktop.app/Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate"
```

1. `codesign -dvv` shows `Authority=Developer ID Application` and a `flags=`
   value containing `(runtime)`.
2. `codesign -d --entitlements -` shows the two network keys and **no**
   `app-sandbox` and no `get-task-allow`.
3. `spctl -a -vv -t exec` says `source=Notarized Developer ID`. (It prints to
   stderr.)
4. `syspolicy_check distribution` reports no `Severity: Fatal` — the
   companion of the `notary-submission` check `dist-sign` ran before the
   upload. It exits 70 for warnings too, so read the severities rather than
   the exit code; both scripts do.
5. `xcrun stapler validate` on the **DMG** — the image carries its own ticket,
   separate from the app's.
6. `plutil -p … | grep SU` shows all four Sparkle keys: `SUFeedURL`,
   `SUPublicEDKey`, `SUEnableAutomaticChecks` and `SUScheduledCheckInterval`.
   A release build cannot get this far without them, but the plist is what
   actually ships, so it is what is read.
7. `codesign -dvv` on Sparkle's `Autoupdate` shows `TeamIdentifier` equal to
   ours, not the Sparkle project's. `sign.sh` asserts this already; it is here
   because it is the one failure that surfaces as an app that launches fine and
   dies later.
8. On a Mac that has never run Bond — or, at a minimum, a second user account
   on this one — download the DMG the way a user would, open it, drag the app
   across and launch it. No Gatekeeper prompt, no Privacy & Security detour.
   Anything less than a clean first launch means the ticket is not where it
   needs to be.

To exercise the update path itself without shipping a release: point a copy of
the app at a test feed naming a higher `sparkle:version` than its own
`CFBundleVersion`, open **Settings → About → Check for updates**, and Sparkle
offers it. An item whose signature does not verify against the build's own
`SUPublicEDKey` is refused — which is the behaviour worth seeing at least
once.

## Tester builds

`make dist-dmg AD_HOC=1` produces a DMG that is not signed by a known
developer, so macOS refuses it on the first double-click. That refusal is
expected — and it is the only kind of build it ever applies to; a release from
`make dist` opens on the first try. The way past it is:

> Open the DMG and drag **Bond Desktop** to Applications. Double-click it once
> and let macOS refuse. Then open **System Settings → Privacy & Security**,
> scroll to the message naming Bond Desktop, and click **Open Anyway**.
> Confirm once more and the app starts. macOS remembers the decision.

Someone comfortable in a terminal can instead strip the quarantine flag before
the first launch:

```sh
/usr/bin/xattr -dr com.apple.quarantine "/Applications/Bond Desktop.app"
```

Neither step is needed once a build is notarized.

A tester build needs **no update keys**: `AD_HOC=1` with
`DIST_APPCAST_URL` and `DIST_SPARKLE_PUBLIC_KEY` unset writes nothing into
`Info.plist`, says so on the way past (with them set, as on the release
machine, they are written like any other build's), and the resulting app's About section
reports `Updates are not configured in this build.` Testers replace a tester
build by downloading the next DMG. `AD_HOC=1 dist/appcast.sh` is the matching
rehearsal for the feed itself: it runs the whole generation against whatever key
`dist.env` names, skips the notarization check, and leaves the result in
`dist/stage/appcast/` instead of writing over the published feed.

## Windows

**Design only — nothing in it has ever run.** Flutter builds Windows only on
Windows, this project has no Windows machine, and neither `iscc` nor `pwsh` is
installed on the Mac the design was written on. The shape it settles on:

- A **per-user Inno Setup installer** (`PrivilegesRequired=lowest`, into
  `%LOCALAPPDATA%\Programs\Bond Desktop`), with the sidecar beside the app
  executable for the same reason it sits in `Contents/MacOS/` here, and app
  data under `%LOCALAPPDATA%\Bond Desktop\` — local, never roaming.
- **llama.cpp from the project's own Windows release binaries** rather than
  built from source: the Vulkan x64 asset at the same tag `dist/build-llama.sh`
  pins, downloaded against a measured SHA-256. One llama.cpp per release on
  both platforms, and `make dist-check` has a row that says so.
- **Azure Artifact Signing** for every shipped `.exe` and `.dll`, not just the
  installer: Windows 11 Smart App Control blocks what it has no verdict on
  unless it is validly signed, DLLs included, which is the Windows shape of
  the library-validation rule behind `dist/sign.sh`.
- **The same appcast**, with a second `<item>` per release whose enclosure
  carries `sparkle:os="windows"`, signed by the same Ed25519 key on the
  release Mac and inserted after the macOS item, where `generate_appcast`
  leaves it alone. Sparkle on macOS drops that item; a Dart feed reader on
  Windows verifies it and offers the update as a Flutter screen.
- **GitHub Actions `windows-latest`** as the build host.

What exists: `dist/windows/` (the design, an Inno Setup skeleton and
`fetch-llama.ps1`) and `.github/workflows/windows.yml.disabled`, disabled by
its file name. Start at **[`dist/windows/README.md`](../dist/windows/README.md)**,
whose *To verify on the build host* list is everything the design asserts
without evidence.
