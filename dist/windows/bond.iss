; Bond Desktop - Inno Setup 6.7 installer script.
;
; DESIGN SKELETON. This has never been compiled: iscc is a Windows tool and is
; not installed on the Mac this was written on, and no Windows build of the app
; exists yet. It is written to compile unchanged once one does.
;
; Two things have to happen before it does compile. app/windows/CMakeLists.txt
; still sets BINARY_NAME to "bond_inbox" and app/windows/runner/Runner.rc still
; carries ProductName "bond_inbox"; the build phase renames both to
; bond_desktop / "Bond Desktop", which is what MyAppExeName below already
; assumes (and app/lib/services/notify/local_desktop_notifier.dart's toast
; appName "Bond Inbox" goes with them). And dist/windows/fetch-llama.ps1 has
; to have staged the sidecar.
;
; The reasoning behind every decision here is dist/windows/README.md ->
; The installer. Comments below say which decision, not why in full.
;
; Built by .github/workflows/windows.yml.disabled as:
;   ISCC.exe /DMyAppVersion=<version> dist\windows\bond.iss

#define MyAppName "Bond Desktop"

; CI passes /DMyAppVersion=1.0.0 from the single version: line in
; app/pubspec.yaml. The fallback exists so the script compiles by hand for a
; syntax check, and 0.0.0 is chosen to be obviously not a release.
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

#define MyAppPublisher "Bond"
#define MyAppExeName "bond_desktop.exe"

; Fixed forever. Windows keys upgrades and the Apps & Features entry on this
; GUID, so changing it makes the next release install ALONGSIDE the old one
; instead of over it.
#define MyAppId "{7BC29B6A-27B8-450C-A52A-F08C0719A16C}"

; Flutter's release output, relative to this file.
#define MyBuildDir "..\..\app\build\windows\x64\runner\Release"

; What dist\windows\fetch-llama.ps1 staged: llama-server.exe and the DLL
; allowlist, flat.
#define MyLlamaDir "stage\llama"

[Setup]
; The doubled brace is Inno's escape: {{ produces a literal {, so AppId gets
; the GUID in braces that Windows expects.
AppId={{#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}

; Per-user install: no UAC prompt, no admin account, nothing written outside
; the user's profile. The app has no service, no driver and no shared
; component, so an admin install would buy nothing.
PrivilegesRequired=lowest
; With PrivilegesRequired=lowest this resolves to
; %LOCALAPPDATA%\Programs\Bond Desktop.
DefaultDirName={autopf}\{#MyAppName}
; One Start Menu entry. Asking the user to name a folder for it is a question
; with no wrong answer, which means it should not be asked.
DisableProgramGroupPage=yes

; x64 only. x64compatible rather than x64os so the installer still runs under
; emulation on Arm - the app's own device step refuses Arm with an explanation,
; which is a better answer than Windows saying "this app cannot run on your PC".
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; Windows 10 1809. Below it the toast APIs and the console host behave
; differently enough not to be worth supporting untested.
MinVersion=10.0.17763

OutputDir=out
; Matches the macOS Bond-Desktop-<version>.dmg naming, and it is the file name
; the appcast's Windows enclosure points at.
OutputBaseFilename=Bond-Desktop-{#MyAppVersion}-Setup

; The payload is one large tree of DLLs and Flutter assets, which solid LZMA2
; compresses well. Build time is CI's problem; download size is the user's.
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern

; Restart Manager closes whatever holds a file in {app} before replacing it -
; both the app and any llama-server.exe it left running. Without this an update
; over a running copy fails on a locked DLL.
CloseApplications=yes
; The [Run] entry with skipifnotsilent relaunches the app after the updater's
; silent install. Restart Manager could only restart a process that registered
; itself for restart, and doing both would open two copies.
RestartApplications=no

UninstallDisplayIcon={app}\{#MyAppExeName}
; An install that fails on someone else's machine leaves a log in %TEMP%, which
; is the only diagnostic anyone will have.
SetupLogging=yes

; No SignTool= line, deliberately. Signing is three separate steps in CI - the
; app's files, the sidecar's files, then the finished installer - so this
; script compiles on a machine with no credentials at all. See
; dist/windows/README.md -> Signing and trust.

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
; Unchecked: a desktop icon nobody asked for is clutter, and the Start Menu
; entry is the one that has to exist (it carries the AppUserModelID).
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The whole Flutter release tree: bond_desktop.exe, flutter_windows.dll, the
; plugin DLLs and data\ (icudtl.dat, the app snapshot, assets).
Source: "{#MyBuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

; The sidecar lands in the SAME directory as the app executable, not in a
; subdirectory: LlamaBinary.resolve looks beside Platform.resolvedExecutable,
; and ggml loads its ggml-*.dll backends from the running executable's own
; directory. This is the Windows spelling of Contents/MacOS/ on macOS. Flat,
; because the staged tree is flat.
Source: "{#MyLlamaDir}\*"; DestDir: "{app}"; Excludes: ".pin"; Flags: ignoreversion

[Icons]
; AppUserModelID is load-bearing, not cosmetic: an unpackaged Windows app can
; raise a toast only if a Start Menu shortcut carries one, and it must be the
; same id flutter_local_notifications is initialised with.
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; AppUserModelID: "com.bondinbox.app"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Two entries, and the flags make them exclusive. After a visible install the
; finish page offers a launch the user can untick. After a silent install -
; which is what the in-app updater runs, as /SILENT /CLOSEAPPLICATIONS - the
; app has already quit itself, Restart Manager will not bring it back, and the
; second entry is how it comes back.
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\{#MyAppExeName}"; Flags: nowait skipifnotsilent

; There is deliberately no [UninstallDelete] section.
;
; The uninstaller removes {app} and the shortcuts, and stops. Everything the
; app wrote lives under {localappdata}\Bond Desktop - the database and its -wal
; and -shm sidecars, attachments\, servers\, logs\ and, by default, models\
; holding about twenty-two gigabytes of weights. Those are the user's, they
; take a long time to download again, and an uninstaller that quietly took them
; would be the wrong default exactly once. The install guide has to name the
; path so someone who does want it gone can delete it, the way
; docs/install.md -> Uninstalling does on macOS; its Windows subsection is
; build-phase work (dist/windows/README.md -> What the app needs).
;
; This comment exists because an absent line is otherwise indistinguishable
; from a forgotten one.
