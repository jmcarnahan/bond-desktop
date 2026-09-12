# `dist/windows/` — the Windows design

The Windows counterpart of `dist/` and of `docs/distribution.md`: what a
Windows release would be made of, how each piece is chosen, and which of the
macOS pipeline's rules carry over unchanged. It is a design, not a pipeline.

## Status

**Design only.** Nothing in this directory has ever been executed. Flutter
builds Windows only on Windows, this project has no Windows machine and no
build host, and neither `iscc` (Inno Setup's compiler) nor `pwsh` is installed
on the Mac this was written on. `app/windows/` holds the Flutter runner
scaffold `flutter create` generated and nobody has ever built it.

What is real here, in the sense that it was measured rather than assumed:

- The llama.cpp Windows release asset for tag `b10896`: its exact name, its
  byte count, its SHA-256, and the list of files inside it. The zip was
  downloaded and opened on 2026-09-11.
- The versions in the CI workflow: Inno Setup 6.7.3 is current and the
  `windows-latest` image carries 6.7.1; the action tags are the latest as of
  2026-09-11.
- `Azure/artifact-signing-action@v2`'s input names, read from its `action.yml`.
- `path_provider`'s Windows answer — roaming `%APPDATA%\<CompanyName>\
  <ProductName>` — read from the `path_provider_windows` 2.3.0 source in the
  pub cache; and `dart:io`'s documented behaviour that `Process.kill` ignores
  the signal on Windows and simply terminates the process. That `wmic` is no
  longer installed by default since Windows 11 24H2 is Microsoft's own
  deprecation notice, not something measured here.
- How Sparkle 2.9.6 treats a feed that also describes Windows: read from its
  source, and `generate_appcast` was run against such a feed on this Mac —
  see *Updates*.
- That the pure-Dart `cryptography` package (^2.9) verifies a `sign_update`
  signature: run on this Mac against a throwaway key — see *Updates*.
- The sizes of the other llama.cpp Windows assets (CUDA, ROCm, SYCL,
  OpenVINO), from the GitHub release API for the tag.

What is stated from vendor documentation and NOT measured here: what Smart
App Control blocks and how it decides (Microsoft), that EV certificates no
longer bypass SmartScreen (Microsoft), the Azure Artifact Signing setup
sequence, its tiers and its identity validation (Microsoft), and the reason
behind `MinVersion=10.0.17763`. Each is written as the vendor's rule, not as
something this project has seen.

What is unverified is everything that needs a Windows machine to answer. Each
such item is in **To verify on the build host** below, and nowhere in this
document is one of them written as a fact.

Files here: this document, `bond.iss` (the Inno Setup script, never compiled)
and `fetch-llama.ps1` (stages the pinned llama.cpp Windows binaries, never
run). The build workflow is `.github/workflows/windows.yml.disabled`, disabled
by its file name.

## What ships

Two trees, and the split is the same one macOS makes between a read-only
signed bundle and `~/Library/Application Support/`.

**The program**, installed per user into `%LOCALAPPDATA%\Programs\Bond
Desktop\` (`{autopf}` under `PrivilegesRequired=lowest`):

```
%LOCALAPPDATA%\Programs\Bond Desktop\
  bond_desktop.exe              the Flutter app
  flutter_windows.dll           the engine
  data\                         icudtl.dat, app.so / kernel_blob.bin, assets
  *.dll                         plugin DLLs Flutter's build emits
  llama-server.exe              the sidecar
  llama-server-impl.dll         the server itself; the .exe is a 9 KB launcher
  llama.dll, llama-common.dll, mtmd.dll
  ggml.dll, ggml-base.dll
  ggml-vulkan.dll               the GPU backend
  ggml-cpu-*.dll                fourteen CPU variants, one picked at runtime
  libomp.dll, LICENSE-LLVM-OpenMP
  unins000.exe                  Inno's uninstaller
```

**The sidecar sits in the same directory as the app executable**, not in a
`sidecar\` or `bin\` subdirectory, for the same two reasons it sits in
`Contents/MacOS/` on macOS: `LlamaBinary.resolve`
(`app/lib/services/server/llama_binary.dart`) looks beside
`Platform.resolvedExecutable` and nowhere else, and ggml scans the running
executable's own directory for backend modules. On Windows the modules are
`ggml-*.dll` rather than `libggml-*.so`, and the rule is unchanged.

**The data**, under `%LOCALAPPDATA%\Bond Desktop\`:

```
%LOCALAPPDATA%\Bond Desktop\
  bond_inbox.db  (+ -wal, -shm)
  attachments\
  servers\       router.ini, router.json, empty-cache\
  logs\          llama-server.log
  models\        the GGUF files, unless the user pointed elsewhere
```

**`%LOCALAPPDATA%`, never `%APPDATA%`.** `path_provider`'s
`getApplicationSupportDirectory()` on Windows returns
`FOLDERID_RoamingAppData\<CompanyName>\<ProductName>` — roaming, and today
that would be `%APPDATA%\com.bondinbox\bond_inbox`. Roaming is wrong twice
over: a roaming profile copies the whole tree at logon and logoff, and this
tree is a SQLite database with live `-wal` and `-shm` sidecars plus an
attachments folder plus, by default, twenty-two gigabytes of model weights.
So `AppPaths.locate()` (`app/lib/data/app_paths.dart`) gets a Windows branch
that reads `%LOCALAPPDATA%` and appends `Bond Desktop`, instead of taking
path_provider's answer.

**The uninstaller removes the program directory and leaves the data.**
Twenty-two gigabytes of weights and the user's own database are theirs to
delete, and an uninstaller that quietly took them would be the wrong default
exactly once.
The path has to be named in the end-user install guide, the way
`docs/install.md → Uninstalling` names
`~/Library/Application Support/com.bondinbox.app/` today; `docs/install.md`
has no Windows section yet, and that subsection is a row in *What the app
needs* rather than something this document can claim exists.

## The sidecar

macOS builds `llama-server` from a SHA-pinned source tarball because Homebrew's
copy cannot be relocated into a bundle (`docs/distribution.md` → *Why
llama.cpp is built from source*). Windows does not have that problem: the
llama.cpp project publishes relocatable release binaries per tag, with no
absolute install names to rewrite and no signature of someone else's to work
around. So Windows **downloads a pinned release asset** and macOS **builds
from a pinned source tarball**, and both are pinned to the same tag.

The pin, measured 2026-09-11:

```
tag     b10896
asset   llama-b10896-bin-win-vulkan-x64.zip
url     https://github.com/ggml-org/llama.cpp/releases/download/b10896/llama-b10896-bin-win-vulkan-x64.zip
bytes   31661471
sha256  0ca7f1ae2edd1d4a822789f70148a167a02de393005a8f034a76c799592de92d
```

The zip is **flat** — no top-level directory — which is why `fetch-llama.ps1`
expands into a temp directory and copies by name rather than moving a folder.

### The allowlist

`fetch-llama.ps1` stages exactly these, and fails if the zip is missing one:

| Group | Files | Why |
|---|---|---|
| The server | `llama-server.exe`, `llama-server-impl.dll` | The `.exe` is a 9 KB launcher; the server is the DLL beside it, and shipping one without the other ships nothing |
| The libraries | `llama.dll`, `llama-common.dll`, `mtmd.dll` | What the server links against |
| ggml core | `ggml.dll`, `ggml-base.dll` | The tensor library and its backend loader |
| GPU backend | `ggml-vulkan.dll` (43 MB) | The reason this is the Vulkan asset |
| CPU backends | the fourteen `ggml-cpu-*.dll` — `x64`, `sse42`, `sandybridge`, `ivybridge`, `haswell`, `skylakex`, `cannonlake`, `icelake`, `cascadelake`, `cooperlake`, `sapphirerapids`, `alderlake`, `zen4`, `piledriver` | ggml picks the best one the running CPU supports at load time; shipping only `x64` would give every machine the baseline |
| OpenMP | `libomp.dll`, `LICENSE-LLVM-OpenMP` | The CPU backends link it, and the licence text has to travel with it |

Everything else in the zip is **not** shipped: `llama-cli.exe`,
`llama-bench.exe` and every other `*.exe`, the other `*-impl.dll` that belong
to those tools, `ggml-rpc.dll` and `ggml-rpc-server.exe` — nor
`fetch-llama.ps1`'s own `.pin` stamp, which `bond.iss` excludes. The app
speaks HTTP
to one server and needs nothing else, and every shipped binary is a binary
that has to be signed and a binary a user could be talked into running.

### `vulkan-1.dll` is not in the zip, and must not be

The Vulkan **loader** ships with the GPU driver and lives at
`C:\Windows\System32\vulkan-1.dll`. Bundling a copy is the classic way to
break Vulkan: the loader has to match the installed ICDs, not the build.
On a machine with no loader — a fresh VM, a machine whose driver predates
Vulkan — `ggml-vulkan.dll` simply fails to load, ggml skips that backend and
the server runs on the CPU variants. That is a slow Bond, not a broken one,
and it is why the CPU backends are in the allowlist rather than treated as
dead weight beside a GPU backend.

### Why Vulkan and not CUDA, ROCm, SYCL or OpenVINO

The tag publishes all of them. Vulkan is one 32 MB zip that covers NVIDIA, AMD
and Intel GPUs with no vendor runtime to install and nothing to detect at
install time. The alternatives each cost something this project will not
spend: `win-cuda-12.4-x64` is 254 MB and additionally needs a 391 MB `cudart`
zip and an NVIDIA card; `win-rocm-10.0-x64` is AMD only; `win-sycl-x64` and
`win-openvino-2026.3.1-x64` are Intel only. Shipping a vendor build would mean
either four installers or an installer that picks at run time, for a speed
difference that does not change which models fit.

`win-cpu-arm64` and `win-opencl-adreno-arm64` exist, and v1 still refuses
Windows on Arm — see *Setup wizard on Windows*.

### One llama.cpp per release

`$LlamaTag` in `fetch-llama.ps1` MUST equal `LLAMA_TAG` in
`dist/build-llama.sh`. The two platforms ship the same server at the same
revision or they ship two different products under one version number: the
router preset, the flags the supervisor passes and the behaviour the ledger in
`docs/model-bakeoff.md` records are all properties of a particular llama.cpp.

`make dist-check` has a **Windows llama pin** row that compares the two
literals and goes red on a mismatch, with the fix: edit
`dist/windows/fetch-llama.ps1` to the new tag and re-measure its SHA-256. It
is a counted row like any other, so `make dist` refuses a release where the
two have drifted.

### `fetch-llama.ps1`

The Windows counterpart of `dist/build-llama.sh`, and deliberately the same
shape: literals with a why-comment above them, a `.pin` stamp carrying the tag
and a digest of the script itself so that editing the allowlist invalidates a
staged tree exactly the way bumping the tag does, a download to a `.part`, a
SHA-256 compared before anything is unpacked, and a staged output under
`dist/windows/stage/llama/` that the installer script reads. PowerShell 5.1
compatible, because that is what a Windows box has without installing
anything; the `windows-latest` image also has `pwsh` 7 and the workflow calls
it through that.

## The installer

**Inno Setup 6.7**, `dist/windows/bond.iss`. 6.7.3 is the current release from
jrsoftware.org as of 2026-09-11; the GitHub `windows-latest` image has 6.7.1
preinstalled at `C:\Program Files (x86)\Inno Setup 6\ISCC.exe`, which is the
one the workflow uses. There is no Inno Setup 7.

Every `[Setup]` decision and its reason:

| Setting | Value | Why |
|---|---|---|
| `AppId` | `{7BC29B6A-27B8-450C-A52A-F08C0719A16C}` | Windows keys upgrades and the uninstall entry on this GUID. It must never change: a new one makes the next release install alongside the old one instead of over it |
| `PrivilegesRequired` | `lowest` | No UAC prompt, no admin account needed, and nothing is written outside the user's profile. The app has no service, no driver and no shared component, so there is nothing an admin install would buy |
| `DefaultDirName` | `{autopf}\Bond Desktop` | With `lowest`, `{autopf}` resolves to `%LOCALAPPDATA%\Programs`, which is where a per-user install belongs |
| `ArchitecturesAllowed` | `x64compatible` | x64 only, and `x64compatible` rather than `x64os` so the installer also runs under x64 emulation on Arm — the app itself still refuses Arm in its device step, with an explanation, which is a better answer than an installer that says "this app cannot run on your PC" |
| `ArchitecturesInstallIn64BitMode` | `x64compatible` | 64-bit install mode, so `{autopf}` and the registry views are the 64-bit ones |
| `MinVersion` | `10.0.17763` | Windows 10 1809. Below it the toast APIs and the console host behave differently enough not to be worth supporting untested |
| `CloseApplications` | `yes` | Restart Manager closes what holds files in `{app}` before replacing them — both the app and any `llama-server.exe` it left running. Without it an update over a running copy fails on a locked DLL |
| `RestartApplications` | `no` | The `[Run]` entry below relaunches the app after a silent install. Restart Manager could only restart a process that registered itself for restart, and doing both would open two copies |
| `OutputBaseFilename` | `Bond-Desktop-{#MyAppVersion}-Setup` | Matches the macOS `Bond-Desktop-<version>.dmg` naming, and it is the file name the appcast enclosure points at |
| `Compression` | `lzma2/ultra64`, `SolidCompression=yes` | The payload is one big tree of DLLs and Flutter assets, which solid LZMA2 compresses well. Build time is CI's problem, download size is the user's |
| `SetupLogging` | `yes` | An install that fails on someone else's machine leaves a log in `%TEMP%`, which is the only diagnostic anyone will have |
| `DisableProgramGroupPage` | `yes` | One Start Menu entry; asking the user to name a folder for it is a question with no wrong answer, which means it should not be asked |
| `UninstallDisplayIcon` | `{app}\bond_desktop.exe` | Otherwise Apps & Features shows a generic icon |

`[Icons]` writes the Start Menu shortcut with `AppUserModelID:
"com.bondinbox.app"`. That parameter is load-bearing rather than cosmetic: an
**unpackaged** Windows app can only raise a toast if a Start Menu shortcut
carries an AppUserModelID, and the ID the shortcut carries must be the one
`flutter_local_notifications` is initialised with. The desktop icon is a
`[Tasks]` entry, unchecked by default.

`[Run]` has two entries. After a visible install, a `postinstall skipifsilent`
launch the user can untick on the finish page. After a silent one — which is
what the in-app updater runs — a `nowait skipifnotsilent` launch, which is how
the app comes back after replacing itself without Restart Manager's help. The
two flags are exclusive, so exactly one entry fires.

**What the uninstaller does:** removes `{app}` and its Start Menu and desktop
shortcuts, and stops. There is no `[UninstallDelete]` entry for
`{localappdata}\Bond Desktop` and that omission is deliberate — see *What
ships*. `bond.iss` carries a comment saying so, because an absent line is
otherwise indistinguishable from a forgotten one.

**The installer does no signing.** There is no `SignTool=` directive in
`bond.iss`. Signing is three steps in CI — the app's files, the sidecar's
files, and then the finished installer — and keeping it out of the `.iss`
means the script compiles on a machine with no credentials at all.

## What the app needs

Each row is a place the macOS answer is currently the only answer. Almost
none of it is written yet; the build phase writes it. The one exception is the
notifier: `app/lib/services/notify/local_desktop_notifier.dart` already
initialises `flutter_local_notifications` for Windows with
`appUserModelId: 'com.bondinbox.app'` and already answers `ensureAuthorized`
with `true` there, and `bond.iss`'s `AppUserModelID` is matched to it.

| Seam | macOS today | Windows | Where |
|---|---|---|---|
| Binary name | `llama-server` beside the executable | `llama-server.exe`, same directory | `app/lib/services/server/llama_binary.dart` |
| Backend directory | child's cwd is the executable's directory, so ggml finds `libggml-*.so` | identical rule, `ggml-*.dll` | `model_server_supervisor.dart`, `workingDirectory:` |
| `isAlive` | `kill -0 <pid>` | `tasklist /FI "PID eq <pid>" /NH /FO CSV` — prints `INFO: No tasks are running…` when absent | `process_runner.dart` |
| `commandLineOf` | `ps -o command= -p <pid>` | PowerShell `Get-CimInstance Win32_Process -Filter "ProcessId = <pid>" \| Select-Object -ExpandProperty CommandLine`. **Not `wmic`** — not installed by default since Windows 11 24H2 | `process_runner.dart` |
| `listenerOn` | `lsof -nP -iTCP:<port> -sTCP:LISTEN` | `netstat -ano -p TCP` filtered to `LISTENING` and `:<port>`, then `tasklist` on the pid for the image name | `process_runner.dart` |
| `kill` | `Process.killPid(pid, signal)` | `taskkill /PID <pid>`, then `taskkill /PID <pid> /F` | `process_runner.dart` |
| TERM then KILL | SIGTERM, wait `terminateGrace`, SIGKILL | `Process.kill` accepts only sigterm and sigkill and **both call `TerminateProcess`**, so the ladder collapses to one rung and the grace period becomes a plain wait for the handle to close. The `taskkill` pair above is the only real two-rung path | `model_server_supervisor.dart`, `_terminate` |
| Reaping at quit | `AppDelegate.applicationWillTerminate` reads `servers/router.json`, confirms with `proc_pidpath` that the image ends in `llama-server`, SIGTERM, poll 2 s, SIGKILL, delete the file | the same, in `app/windows/runner/main.cpp` after the message loop returns and on `WM_ENDSESSION`: `OpenProcess`, `QueryFullProcessImageNameW`, check the image name ends in `llama-server.exe`, `TerminateProcess`, delete the file | `app/windows/runner/main.cpp` |
| App data root | `~/Library/Application Support/com.bondinbox.app/` via path_provider | `%LOCALAPPDATA%\Bond Desktop\`, read directly — path_provider answers roaming here | `app/lib/data/app_paths.dart`, `AppPaths.locate` |
| `system` channel: `hardware` | `sysctl` chip, memory, arch, Rosetta | `GlobalMemoryStatusEx` for memory, `GetNativeSystemInfo` for x64 vs arm64, and `llama-server.exe --list-devices` for the GPU | `app/macos/Runner/SystemChannel.swift` → a Windows `system_channel.cpp` |
| `system` channel: `freeBytes` | `NSFileManager` attributes | `GetDiskFreeSpaceExW` | same |
| `system` channel: `sha256` | CryptoKit | `BCryptHashData` (CNG). Not optional: the pure-Dart fallback takes minutes over a 17.7 GiB download | same |
| `system` channel: `beginActivity` / `endActivity` | `NSProcessInfo` App Nap assertion | `SetThreadExecutionState(ES_CONTINUOUS \| ES_SYSTEM_REQUIRED)` while downloading, cleared to `ES_CONTINUOUS` after | same |
| `system` channel: `openNotificationSettings` | `x-apple.systempreferences:` URL | `ms-settings:notifications` | same |
| `bookmarks` channel | unsandboxed, so it returns the plain path | the same — Windows has no security-scoped bookmarks, and there is nothing to scope | `app/macos/Runner/BookmarkChannel.swift`, `app/lib/services/context/directory_access.dart` |
| `updater` channel | Sparkle | no channel at all: a Dart feed reader and a Flutter screen, see *Updates* | — |
| Notifications | `flutter_local_notifications`, permission asked on the wizard's Notifications step | Windows toasts via `WindowsInitializationSettings(appName:, appUserModelId:, guid:)`. No permission prompt exists, so the wizard step is skipped; what the toast needs instead is the Start Menu shortcut's AppUserModelID | `app/lib/services/notify/local_desktop_notifier.dart`, `bond.iss` `[Icons]` |
| Directory picker | `file_selector` | `file_selector` — Windows supported | `app/lib/services/attachments/file_dialogs.dart` |
| Product strings | `Bond Desktop`, `com.bondinbox.app` | `app/windows/CMakeLists.txt` `BINARY_NAME` is `bond_inbox` and must become `bond_desktop`; `app/windows/runner/Runner.rc` has `ProductName "bond_inbox"`, `OriginalFilename "bond_inbox.exe"`, `CompanyName "com.bondinbox"` and must become `Bond Desktop`, `bond_desktop.exe`, `Bond`; and `local_desktop_notifier.dart` passes `appName: 'Bond Inbox'`, which Windows shows as the toast's header, and must become `Bond Desktop`. **Not changed now** — this is a build-phase edit, and `bond.iss` already refers to `bond_desktop.exe` | `app/windows/`, `app/lib/services/notify/local_desktop_notifier.dart` |
| Install guide | `docs/install.md`, macOS only | a Windows *Uninstalling* subsection naming `%LOCALAPPDATA%\Bond Desktop\` — the justification for the installer leaving that tree alone | `docs/install.md` |
| `sqlite_vec_ffi` | `hook/build.dart` compiles the vendored C through `native_toolchain_c`; the only OS-specific branch is the `-install_name` / `-headerpad_max_install_names` pair under `OS.iOS \|\| OS.macOS` | **There is no `windows/` directory and no CMake build.** `native_toolchain_c` targets Windows through MSVC, and the macOS-only flags are already guarded, so the likely answer is that the existing hook builds a `.dll` unchanged — but it has never been run for a Windows target, and the flags (`-O2`) are clang spellings MSVC does not take. A Windows build of `sqlite_vec_ffi` is a work item for the build phase, not a solved problem | `app/packages/sqlite_vec_ffi/hook/build.dart` |

**Plugins.** From `app/pubspec.yaml`, the packages with a platform side:

| Package | Windows |
|---|---|
| `path_provider` ^2.1.4 | yes — but its support directory is roaming, see above |
| `url_launcher` ^6.3.2 | yes |
| `flutter_secure_storage` ^11.0.0 | yes, backed by Windows Credential Manager |
| `file_selector` 1.1.0 | yes |
| `package_info_plus` ^10.2.1 | yes |
| `flutter_local_notifications` ^22.3.0 | yes, toasts; needs the AUMID shortcut |
| `pdfrx` 2.6.1 | yes, pdfium. The macOS side rides as an XCFramework, so the Windows side is a different build of the same library — **to confirm** on the build host that the pinned 2.6.1 fetches or builds pdfium for Windows without an extra step |
| `sqlite3` ^3.5.2 / `drift` 2.34.0 | **to confirm** — the app uses the `sqlite3` package's bundled library on macOS; which library it opens on Windows, and whether it needs `sqlite3_flutter_libs`, is a build-phase question |
| `sqlite_vec_ffi` (in-tree) | see the row above |
| `mcp_dart`, `http`, `crypto`, `intl`, `archive`, `xml`, `glob`, `yaml`, `path`, `flutter_riverpod` | pure Dart, nothing to port. `crypto` is SHA and HMAC only — it cannot verify an Ed25519 signature, which is why *Updates* adds a dependency |
| `cryptography` ^2.9 (**new**, Windows build phase) | pure Dart. Verifies the feed's `sparkle:edSignature`; measured on this Mac, see *Updates* |

## Setup wizard on Windows

The eight steps (`app/lib/screens/setup/`) become seven.

**Welcome** is unchanged.

**Your PC** replaces *Your Mac*. The facts shown are the chip or CPU name, the
memory, and the Windows version, from the `system` channel's `hardware`
method. The verdicts:

- **Windows on Arm is refused in v1**, with a stop screen and no Continue,
  exactly the way an Intel Mac is refused today (`setup_device_body.dart`:
  *"Intel-based Macs are currently not supported."*). The reason differs — the
  sidecar is an x64 build and the Arm assets are a separate untested pin — and
  the shape of the screen does not. `HardwareInfo.appleSilicon` and
  `HardwareInfo.rosetta` are the macOS spelling of this question; the Windows
  spelling is x64 plus a usable GPU, and the record carries whichever fields
  the platform it is running on can answer.
- **The GPU is probed by running the sidecar**, not by asking Windows:
  `llama-server.exe --list-devices` prints the devices ggml enumerated, which
  is the only answer that accounts for the driver's Vulkan loader actually
  being present. No Vulkan device is a warning, not a block: the CPU backends
  run the models slowly.
- **The same low-memory warning** as macOS, with the same threshold and the
  same sentence, because it says something true about the writing model rather
  than about an operating system.
- **A VRAM note** where the memory note sits. A 27B Q4 checkpoint is about
  17.7 GiB of weights, and llama.cpp's `--fit on` offloads as many layers as the
  device has room for and keeps the rest on the CPU. So an 8-12 GB card runs
  the writing model slowly rather than not at all, and the note should say
  that instead of implying a hardware requirement the app does not enforce.

**Models**, **Storage**, **Download**, **Sign-in** and **Done** are unchanged.
Storage still defaults to `AppPaths.models` — now `%LOCALAPPDATA%\Bond
Desktop\models` — and is still changeable through `file_selector`'s directory
picker. Download still verifies each GGUF against the manifest's SHA-256
through the platform channel, which is why the Windows `sha256` method is a
requirement and not a nicety.

**Notifications is skipped.** Windows toasts need no permission prompt, so the
macOS step — one **Continue** whose press *is* the ask — would be a screen
asking for something already granted. What the Windows toast needs instead is
the AppUserModelID on the Start Menu shortcut, which the installer writes
before the app ever runs.

## Signing and trust

**Azure Artifact Signing** — the service formerly called Trusted Signing. It
signs in the cloud with a certificate whose private key never exists on the
build machine, which is precisely what a public repo's CI needs: there is no
`.pfx` anywhere in this design, and nothing to leak in a workflow log.

One-time setup, in order:

1. An **Azure subscription**. The service is pay-as-you-go with a monthly fee
   for the Basic tier.
2. An **Artifact Signing account** in a supported region (Basic tier).
3. **Identity validation.** Microsoft verifies who the publisher is before any
   certificate profile can be created. Individual developers can complete it;
   it is the step with a waiting period, so it is the one to start first.
4. A **certificate profile** of type **Public Trust**. Its certificates are
   short-lived by design, which is why every signature is timestamped: an RFC
   3161 timestamp is what keeps a signature valid after the certificate behind
   it has expired.
5. A **federated credential** on an Entra app registration, scoped to this
   GitHub repository, so `azure/login@v3` can authenticate by OIDC and no
   client secret is stored. The workflow passes
   `exclude-workload-identity-credential: 'false'` to make the signing action
   use that login (its default is `'true'`, which expects an explicit client
   secret instead).

The identifiers live as **repository variables** — `AZURE_SIGNING_ENDPOINT`
(shaped `https://<region>.codesigning.azure.net`), `AZURE_SIGNING_ACCOUNT`,
`AZURE_SIGNING_PROFILE` — and the identity as **secrets**: `AZURE_TENANT_ID`,
`AZURE_CLIENT_ID`, `AZURE_SUBSCRIPTION_ID`. There is no client secret.

**Every `.exe` and every `.dll` is signed with our certificate.** Not just the
installer, and not just our own binaries: `flutter_windows.dll`, every plugin
DLL, and all twenty-odd llama.cpp DLLs. The reason is **Smart App Control** on
Windows 11. Microsoft's documented rule is: the cloud service predicts whether
a file is safe; if it cannot, the file runs only if it carries a valid
signature; and the check applies to DLLs as well as EXEs, regardless of where
the file came from — Mark-of-the-Web is irrelevant to it. An unsigned
llama.cpp DLL from a small publisher is exactly the file the service has no
verdict on. This is the same rule `dist/sign.sh` follows on macOS, where library
validation refuses to load a nested Mach-O carrying somebody else's team
identifier, and for the same reason: a third party's valid signature is not
our signature.

The order is files first, installer last:

1. Sign everything in `app\build\windows\x64\runner\Release` (`exe,dll`,
   recursive).
2. Sign everything in `dist\windows\stage\llama` (`exe,dll`).
3. Compile the installer, which packs the now-signed files.
4. Sign `Bond-Desktop-<version>-Setup.exe`.

Each with `file-digest: SHA256`, `timestamp-rfc3161:
http://timestamp.acs.microsoft.com`, `timestamp-digest: SHA256` — the action's
defaults, written out because a default that changes silently changes what
ships. Signing the installer before its contents would seal a hash of unsigned
files, which is the Windows shape of the macOS inside-out rule.

**SmartScreen.** Signing is necessary and not sufficient. SmartScreen's
reputation accrues per publisher, over downloads and over time, and a brand
new certificate still shows *"Windows protected your PC — unrecognized app"*
with a **More info → Run anyway** detour. **EV certificates no longer bypass
this**; there is no paid shortcut. The honest expectation is that the first
releases are behind that prompt and that the prompt goes away on its own, and
the end-user install guide should say so plainly the way `docs/distribution.md`
→ *Tester builds* says it for an ad-hoc DMG.

**What is never committed.** No certificate file exists in this design, so
there is nothing to commit; a `.pfx` arriving anyway is refused twice, by
`.gitignore` and by `.claude/hooks/commit-gate.py`'s secret-file rule.

## Updates

Sparkle has no Windows port, and the update feed stays one file anyway.

**One appcast, one item per platform.** `dist/appcast.sh` already writes
`docs/appcast/appcast.xml` as a Sparkle feed, and Sparkle drops every **item**
whose enclosure carries a
`sparkle:os` other than `macos` (`SUAppcastItem.isMacOsUpdate`, applied in
`SUAppcastDriver`'s filter — "we will never care about other OS's"). So a
Windows release is a second `<item>` for the same version, with
`sparkle:os="windows"` on its enclosure, and installed Macs never see it.

What does **not** work, and was the first draft of this design: two
`<enclosure>` elements inside one item. Sparkle 2.9.6 chooses between
repeated child elements by `xml:lang`, not by `sparkle:os` — it logs
`Error: Multiple nodes for enclosure element are present…` on every check and
takes whichever matches the user's language, which for two untagged
enclosures is the first. Read from `SUAppcast.m` (`bestNodeInNodes:name:`);
do not go back to it.

**The same Ed25519 key signs both.** `sign_update` from Sparkle's tools signs
the Windows installer on the release Mac, where
`DIST_SPARKLE_PRIVATE_KEY_PATH` already points at the key. The key never
leaves that machine and **never becomes a CI secret** — CI builds the
installer and uploads it as an artifact; a human signs it and publishes the
feed, which is the same division `docs/distribution.md` → *Releasing* already
describes for the DMG.

One release, two items — the macOS item exactly as `generate_appcast` writes
it, the Windows item after it:

```xml
<item>
  <title>1.0.1</title>
  <pubDate>Thu, 11 Sep 2026 18:00:00 +0000</pubDate>
  <sparkle:version>2</sparkle:version>
  <sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
  <enclosure
    url="https://github.com/jmcarnahan/bond-desktop/releases/download/v1.0.1/Bond-Desktop-1.0.1.dmg"
    sparkle:edSignature="<88 base64 characters from sign_update>"
    length="184320000"
    type="application/octet-stream" />
</item>
<item>
  <title>1.0.1</title>
  <pubDate>Thu, 11 Sep 2026 18:00:00 +0000</pubDate>
  <sparkle:version>2</sparkle:version>
  <sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>
  <enclosure
    url="https://github.com/jmcarnahan/bond-desktop/releases/download/v1.0.1/Bond-Desktop-1.0.1-Setup.exe"
    sparkle:os="windows"
    sparkle:edSignature="<88 base64 characters from sign_update>"
    length="96000000"
    type="application/octet-stream" />
</item>
```

`generate_appcast` writes only the macOS item — it scans a directory of DMGs
and knows nothing about `.exe` files — so the Windows item is inserted
afterwards by a small script named here as future work:
**`dist/windows/appcast-windows.sh`**, not written in this phase. It takes
the installer path, runs `sign_update` on it, reads the byte length, and
inserts the Windows item **immediately after** the macOS item with the same
`sparkle:version`. The position is a rule, not a preference, and it was
measured on this Mac with `generate_appcast` 2.9.6 on 2026-09-11:

- A Windows item that comes **before** the macOS item of the same version is
  overwritten in place on the next `dist/appcast.sh` run — `generate_appcast`
  matches on `sparkle:version`, reports "updated 1 existing update", and the
  Windows enclosure is gone.
- A Windows item that comes **after** it survives: `generate_appcast` updates
  the macOS item and leaves the second one untouched.

So the release order is `dist/appcast.sh` first (which also refuses a build
number that is not above every one already in the feed), then
`appcast-windows.sh`, and a later macOS-only re-run of `dist/appcast.sh` does
not lose the Windows item. Whether `--maximum-versions 5` counts the Windows
items against the five is on the build-host list. The build-number rule is
unchanged: the `+BUILD` half of `version:` in `app/pubspec.yaml` is
`CFBundleVersion` on macOS and `sparkle:version` in the feed on both
platforms, compared numerically.

**In the app.** No native updater, no platform channel:

1. On a daily timer and from **Settings → About → Check for updates**, Dart
   fetches the feed over HTTPS and parses it with the `xml` package that is
   already a dependency.
2. It takes the newest item whose enclosure carries `sparkle:os="windows"`
   and whose `sparkle:version` is numerically above this build's build number
   — the mirror image of Sparkle's own filter.
3. It downloads the `.exe` to a temp directory and **verifies
   `sparkle:edSignature` over the downloaded bytes** against the public key
   baked into the build — the same signature and the same key macOS checks.
   The app's `crypto` dependency cannot do this (SHA and HMAC only), so the
   build phase adds **`cryptography` ^2.9**, pure Dart. Measured on this Mac
   on 2026-09-11: `Ed25519().verify` accepts the signature `sign_update`
   produces over a file with a throwaway key and rejects the same file with
   one byte flipped. A file that does not verify is discarded and the check
   reports nothing found.
4. The offer is **a full Flutter screen**, with a back button, like every other
   screen in this app. The house no-dialogs rule holds here: Sparkle's own
   window on macOS is the one deliberate exception, justified by not
   reimplementing an installer, and there is nothing to reimplement on
   Windows.
5. **Accept** quits the app — through the same path Quit takes, so the sidecar
   is terminated and the pid file removed — and starts the downloaded
   installer with `/SILENT /CLOSEAPPLICATIONS`. Inno's Restart Manager closes
   anything still holding a file in `{app}`, and `[Run]`'s `skipifnotsilent`
   entry relaunches the app when the install finishes.

**WinSparkle was considered and rejected.** It reads the same feed format
and, since 0.8, verifies the same EdDSA signatures (`win_sparkle_set_eddsa_
public_key`), so it would not have needed a second key. What it would do is
put a native dialog in front of the user against the house rule, and add a
C++ dependency to the runner that `flutter create` refreshes do not know
about. Neither is worth it for a check the app can do in Dart.

## CI

There is no Windows machine here, so the build host is **GitHub Actions
`windows-latest`** — Windows Server 2025, image `20260907.255.1`, which
carries Inno Setup 6.7.1 at `C:\Program Files (x86)\Inno Setup 6\ISCC.exe`
and `pwsh` 7.

The workflow is `.github/workflows/windows.yml.disabled`. **It is disabled by
its file name**: GitHub only reads `.yml` and `.yaml` in that directory, so a
file ending `.disabled` is inert. Enabling it is `git mv` to `windows.yml`,
and it should not be enabled before the Azure resources exist, the secrets and
variables are set, and the `Runner.rc` / `BINARY_NAME` rename has happened —
without that rename the installer would look for `bond_desktop.exe` in a
build that produced `bond_inbox.exe`.

`workflow_dispatch` only. There is no release on every push: a release is a
deliberate act, and half of it happens on the release Mac.

The steps:

| # | Step | Why |
|---|---|---|
| 1 | `actions/checkout@v7` | |
| 2 | `subosito/flutter-action@v2`, `flutter-version: 3.47.2`, `channel: stable`, `cache: true` | Pinned to what the release Mac runs today, so a Flutter release cannot change what ships. The macOS side only enforces a floor (`dist-check`: 3.47 or newer), so the two platforms can drift apart; that is accepted for now and is the kind of drift the *One llama.cpp per release* row refuses for the server |
| 3 | Read `version:` from `app/pubspec.yaml`, split on `+`, export `VERSION` and `BUILD` | The single place either number is written, exactly as the Makefile does it for macOS |
| 4 | `flutter pub get` in `app` | |
| 5 | `flutter build windows --release --build-name --build-number --dart-define=BOND_MCP_SERVER_URL=…` | The **only** define. `MICROSOFT_CLIENT_SECRET` never ships, the same rule `dist/bundle.sh` enforces by refusing an env file that has one |
| 6 | `pwsh dist/windows/fetch-llama.ps1` | Stages the pinned sidecar into `dist/windows/stage/llama` |
| 7 | `azure/login@v3` with the three OIDC inputs | Needs `permissions: id-token: write` on the job |
| 8 | `Azure/artifact-signing-action@v2` over the Flutter build directory, `files-folder-filter: exe,dll`, recursive | Smart App Control evaluates DLLs too |
| 9 | The same action over `dist/windows/stage/llama` | The third-party binaries get our signature like everything else |
| 10 | Assert the Inno Setup compiler: `ISCC.exe` exists at its image path and its file version is 6.7.x | The one input the image provides rather than the workflow pins. Chocolatey's newest package is 6.7.1 too (checked 2026-09-11), so a version assertion with the fix in its message is what a pin can be here. Read from the file's version resource, not by running it: ISCC with no script exits non-zero, which the `pwsh` step wrapper turns into a failure |
| 11 | `ISCC.exe /DMyAppVersion=$env:VERSION dist\windows\bond.iss` | The version comes from the pubspec, never from the `.iss` default |
| 12 | The same action over the finished `Bond-Desktop-<version>-Setup.exe` | Installer last, so it seals signed contents |
| 13 | `actions/upload-artifact@v7`, `if-no-files-found: error` | The artifact is what a human downloads, signs for the feed on the release Mac, and attaches to the GitHub release |

Secrets and variables:

| Name | Kind | What it is |
|---|---|---|
| `BOND_MCP_SERVER_URL` | secret | The MCP server the build signs in against. A secret because the URL names a customer's server |
| `AZURE_TENANT_ID` | secret | Entra tenant |
| `AZURE_CLIENT_ID` | secret | The app registration with the repo's federated credential |
| `AZURE_SUBSCRIPTION_ID` | secret | |
| `AZURE_SIGNING_ENDPOINT` | variable | `https://<region>.codesigning.azure.net` |
| `AZURE_SIGNING_ACCOUNT` | variable | The Artifact Signing account name |
| `AZURE_SIGNING_PROFILE` | variable | The Public Trust certificate profile name |

There is no Azure client secret, and **the Sparkle private key is not here and
never will be.** CI produces an unsigned-for-Sparkle installer; the release Mac
signs it for the feed.

## To verify on the build host

None of this has been run. In roughly this order, because each answers a
question the next one assumes:

1. `iscc dist\windows\bond.iss` compiles — with the `#define`s as written, a
   real `Release` directory beside it, and at `lzma2/ultra64`, the most
   memory-hungry setting a 32-bit `ISCC.exe` offers — and the compiled
   installer's `AppId` is the GUID `{7BC29B6A-27B8-450C-A52A-F08C0719A16C}`
   in the uninstall registry key, not a literal `{#MyAppId}` from a
   mis-expanded `{{#MyAppId}`.
2. `pwsh dist\windows\fetch-llama.ps1` downloads the asset, the SHA-256
   matches the literal, and the staged directory contains every file in the
   allowlist and nothing else.
3. `llama-server.exe --list-devices` lists a Vulkan device on a machine with a
   current GPU driver, and lists only CPU on a machine without one — and the
   server still serves in the second case.
4. `Process.start` of `llama-server.exe` from the windowed Flutter app opens
   **no console window**. If it does, the fix is a native spawn with
   `CREATE_NO_WINDOW` behind the `system` channel rather than anything in
   Dart.
5. Quit leaves nothing behind:
   `tasklist /FI "IMAGENAME eq llama-server.exe"` reports no tasks, and
   `servers\router.json` is gone.
6. A fresh install on a Windows 11 machine with **Smart App Control enabled**
   installs and launches with no block. A block that names one file is the
   signing defect this checks for. SmartScreen's *unrecognized app* prompt on
   the installer is a different mechanism — reputation, with a *Run anyway*,
   under *Signing and trust* — and not a failure of this check.
7. A toast appears from a cold start, which is the check that the Start Menu
   shortcut's AppUserModelID matches the one
   `WindowsInitializationSettings` was given.
8. The update screen appears against a test feed naming a higher
   `sparkle:version`, an item whose `sparkle:edSignature` does not verify is
   refused, and accepting replaces the installed copy and relaunches it.
9. `generate_appcast --maximum-versions 5` over a feed carrying Windows items:
   whether they count against the five, or only the DMG items do.
10. Uninstalling removes `%LOCALAPPDATA%\Programs\Bond Desktop\` and leaves
    `%LOCALAPPDATA%\Bond Desktop\` with the database and the weights intact.
11. `flutter build windows --release` succeeds at all with `sqlite_vec_ffi` in
    the dependency graph — question 3 below.

## Open questions

1. **The console window.** Whether `Process.start` of a console executable
   from a windowed Flutter app pops a console on Windows is not verified. It
   is the one unknown that would be visible to every user on every launch.
2. **`AppLifecycleListener.onExitRequested` on Windows.** On macOS the Dart
   side awaits `supervisor.stop()` before the app exits, and the native
   `applicationWillTerminate` reaper is the backstop. Whether Flutter's
   Windows runner routes a window close through `onExitRequested` at all is
   unverified — which is why the native hook in `main.cpp` is written as the
   one that must work regardless, not as a belt-and-braces addition.
3. **`sqlite_vec_ffi` on Windows.** There is no `windows/` directory and no
   CMake build in the package. Its `hook/build.dart` uses
   `native_toolchain_c`, which does support MSVC, and the macOS-only link
   flags are already behind an `OS.iOS || OS.macOS` guard — but `-O2` is a
   clang flag and the hook has never been run for a Windows target. Whether
   this is a no-op or a real port is unknown until someone runs the build.
4. **Roaming versus local is decided; path_provider disagrees.** The data root
   is `%LOCALAPPDATA%\Bond Desktop\`, and `getApplicationSupportDirectory()`
   answers a roaming path. The Windows branch in `AppPaths.locate` is the fix,
   and the open part is migration: if any build ever ships taking
   path_provider's answer, it leaves a tree in `%APPDATA%` that a later build
   has to find and move, the way `migrateSandboxContainerData` does on macOS.
   The cheap answer is never to ship that build.
5. **The SmartScreen wait.** How many downloads and how long before the
   unrecognized-app prompt stops appearing is not something anyone publishes.
   It is a real cost of a first Windows release and it has no workaround.
6. **Whether a memory-tier ladder is needed sooner on Windows.** On a Mac,
   unified memory means RAM is the constraint and the device step's one
   warning covers it. On Windows the constraint is VRAM, which varies far more
   and is not the same number as system RAM, so the honest recommendation may
   need to be a ladder (this card runs the writing model; this one runs only
   the inbox models) rather than one warning. That is a product question for
   after the first Windows build actually runs.
