# Distributing Bond Desktop

How a checkout becomes a DMG someone else can install. Draft: the signing and
notarization steps are written but not yet exercised — they wait on a
Developer ID certificate (Phase 5), and the update feed waits on Sparkle
(Phase 6). Everything up to and including an unsigned tester DMG works today.

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
make dist                    # Phase 5: signed, notarized, stapled
```

Each target depends on the previous one, in this order:

1. **`dist-llama`** builds `llama-server` from a SHA-256-pinned llama.cpp
   source tarball and stages it under `dist/stage/llama/`.
2. **`dist-app`** runs `flutter build macos --release` and copies the sidecar
   into `dist/stage/Bond Desktop.app`.
3. **`dist-sign`** signs the bundle inside out.
4. **`dist-dmg`** produces `dist/out/Bond-Desktop-<version>.dmg`.

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

## Secrets

Full inventory and storage rules: `dist/README.md`. In short, everything
machine-local lives in the gitignored `dist/local/`, and three items are real
secrets — the Developer ID private key (in the login keychain, `.p12` in the
password manager), the App Store Connect `.p8` (downloadable once), and the
Sparkle EdDSA private key.

One secret must never ship: **`MICROSOFT_CLIENT_SECRET`**. A build carrying it
has it readable in the binary, which is why `dist/bundle.sh` refuses to run
while the env file has a non-empty value for it. Distributed builds use MCP
mode, which needs only `BOND_MCP_SERVER_URL`.

## Releasing

1. Bump `version:` in `app/pubspec.yaml`.
2. `make dist-check` — every row green.
3. `make dist` — builds, signs, notarizes and staples. *(Phase 5.)*
4. `make dist-appcast` — signs the DMG for Sparkle and regenerates
   `docs/appcast/appcast.xml`, which is committed. *(Phase 6.)*
5. Upload the DMG to a GitHub release for the tag.
6. Verify on a machine that has never run the app: `spctl -a -vv -t exec` says
   Notarized Developer ID, and the DMG opens with no Gatekeeper prompt.

## Tester builds

`make dist-dmg AD_HOC=1` produces a DMG that is not signed by a known
developer, so macOS refuses it on the first double-click. That refusal is
expected, and the way past it is:

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

## Windows

Design only, in a later phase: Flutter's Windows builds run on Windows, and
there is no build host yet. See `dist/windows/README.md` when it lands.
