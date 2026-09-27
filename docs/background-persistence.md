# Keeping bond-desktop running in the background

Investigation only — nothing here is implemented yet. This document maps the
"keep the app running even after the user closes it" request onto what
bond-desktop actually is today, the macOS mechanisms available, and a staged
recommendation.

## The question behind the question

"Even if the user closes the app" splits into two very different asks, and the
right mechanism depends on which one is meant:

- **Closes the *window*** — the app should keep working with no visible window,
  and reopen on demand. Still quits on `Cmd+Q`.
- **Fully *quits* (or crashes / force-quits / reboots)** — the work should come
  back on its own.

These need different machinery. The first is a runner-lifecycle change; the
second is a supervised process (launchd) or a separate headless helper.

## What "the app" actually is

bond-desktop is not a thin UI over a server — the long-running work lives
**inside the single Flutter process**. Three things would need to keep running:

| Work | Where it lives | Current lifecycle coupling |
| --- | --- | --- |
| Managed `llama-server` child | `app/lib/services/server/model_server_supervisor.dart` | Spawned `ProcessStartMode.normal` (not detached), health-checked on a 2s timer. **Killed on quit** by `AppDelegate.applicationWillTerminate` and `ServerBootstrap`'s `AppLifecycleListener(onExitRequested:)`. |
| AI pipeline drains + triage | `app/lib/services/ai_workers.dart`, `ai_worker.dart`, `triage_queue.dart` | Three `AiWorker` lanes (fast / storyline / draft) as Riverpod providers. Claim rows from the Drift DB, so **state is durable** — `main.dart` resets interrupted claims on launch. |
| Microsoft Graph sync poll | `app/lib/services/sync_service.dart` | The 60s periodic driver is a `Timer.periodic` **on the `InboxScreen` widget** (the `_poll` field, started in `_InboxScreenState` with `_pollInterval` and calling `_refresh`), cancelled in `dispose()`. Most tightly coupled to a window being alive. |

Because the pipeline is DB-backed, restarts are safe — the concern is
continuity, not data loss.

**What survives a restart today.** On launch, `main.dart` resets interrupted
triage and work claims (`resetInterruptedTriage`, `resetInterruptedWork`), so
nothing in flight is lost. At every sync, `reviveOwedMessageStages` re-offers
the extract, needs-you and embed work of kept messages whose triage finished
but whose work the rolling sync window overtook, at most 150 per kind per
pass for mail and 100 for Teams. See [pipeline/04-extraction.md](pipeline/04-extraction.md) and
[pipeline/11-needs-you.md](pipeline/11-needs-you.md). None of this runs while
the app is closed; it catches up on the next launch and sync.

## Facts that shape the options

**Favorable**

- The app is **explicitly unsandboxed** (`Release.entitlements` /
  `DebugProfile.entitlements` omit `com.apple.security.app-sandbox` on purpose —
  it spawns `llama-server` and reads a user-chosen models folder). This removes
  the biggest obstacle to launchd / login-item work.
- A **full local-notification layer already exists** (`app/lib/services/notify/`,
  `flutter_local_notifications: ^22.3.0`, `UNUserNotificationCenterDelegate`
  wired in `AppDelegate`). Setup copy already says notifications work "when the
  app is running in the background."
- Precedent for a macOS 12-vs-13 runtime split already exists in
  `SystemChannel.swift` (`openNotificationSettings`).

**Constraints**

- `applicationShouldTerminateAfterLastWindowClosed` currently **returns `true`**
  (`AppDelegate.swift:103`) — closing the last window quits today.
- **Deployment target is macOS 12.0** (`project.pbxproj`); `SMAppService`
  requires **13+**. Any `SMAppService` use needs an `@available` fallback or a
  raised floor.
- **Teams endpoints forbid background polling** — every Teams call must trace to
  a user action (`teams_sync.dart`, `graph_teams.dart`, `mcp_teams_backend.dart`).
  A background mode must keep Teams sync user-triggered.
- App Nap is only held off during downloads / model-load
  (`SystemChannel.beginActivity`), not persistently.
- No launch-at-login / launchd / tray / menu-bar code exists today.

**Environment:** Flutter 3.47.3 / Dart 3.13.3, SPM-based Flutter integration (no
`Podfile`).

## The four mechanisms

### A. Survive the window closing (still quits on `Cmd+Q`)

Lightest option; likely what's actually wanted.

- Flip `applicationShouldTerminateAfterLastWindowClosed` → `false`
  (`AppDelegate.swift:103`).
- Add a **menu-bar item** (`tray_manager`, macOS 10.15+) and likely set
  `LSUIElement` so there's a way back to the window with no Dock icon.
- **Required rework:** decouple `llama-server` teardown and the sync poll from
  window lifecycle. Today, closing the window would kill the server
  (`applicationWillTerminate` + `ServerBootstrap._onExit`) and stop sync
  (`InboxScreen.dispose`). Both must move to an app-lifetime owner that tears
  down only on *true* quit.

No new process, no sandbox or deployment-target issues.

### B. Start automatically at login

- `launch_at_startup` package (wraps sindresorhus/LaunchAtLogin, macOS 10.13+),
  or `SMAppService.mainApp.register()` on macOS 13+.
- **Fires once at login only** — does not relaunch after crash or quit.
- macOS 12 floor means a fallback to `SMLoginItemSetEnabled`, or raise the target.

### C. Truly always-on (relaunch on exit / crash / kill)

- A launchd **LaunchAgent** plist in `~/Library/LaunchAgents` with
  `KeepAlive=true` + `RunAtLoad=true`. launchd supervises the process and
  restarts it (paced by `ThrottleInterval`).
- Only this survives `Cmd+Q` / force-quit / reboot. Legal because the app is
  unsandboxed.

### D. Headless background helper (the "proper" always-on architecture)

- Split the model server + drains + sync into a **separate headless executable**
  managed by launchd or `SMAppService.agent`, with the Flutter app as a UI
  client that attaches when open.
- Cleanest fit given the work — not the GUI — is what matters, but a significant
  refactor: the pipeline is currently Riverpod-in-process.

## Recommendation: stage it

1. **Start with A.** Keep the *process* alive when the window closes (AppDelegate
   flip + menu-bar item), and move server teardown + the sync poll to an
   app-lifetime service. Delivers "closes the window, keeps working" with no new
   process and no sandbox / deployment-target issues.
2. **Add B** (launch-at-login) as a user-toggleable setting once A works.
3. **Only reach for C / D** if the requirement is genuinely "survives quit and
   reboot, restarts itself." That's a real daemon and a much bigger lift — and it
   must still honor the Teams no-background-polling terms.

The single decision that determines the whole design: **does "closes the app"
mean closes the window (→ A) or fully quits and it should come back on its own
(→ C / D)?** Everything else follows from that.

## Sources

- Apple, [`SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice)
  — login items / agents / daemons, macOS 13+.
- [launchd.info](https://www.launchd.info/) — `KeepAlive` / `RunAtLoad`, user
  LaunchAgents in `~/Library/LaunchAgents`.
- [`launch_at_startup`](https://pub.dev/packages/launch_at_startup) — Flutter
  launch-at-login (wraps LaunchAtLogin; macOS 10.13+).
- [`tray_manager`](https://pub.dev/packages/tray_manager) — Flutter menu-bar /
  tray icon (macOS 10.15+).
- [`window_manager`](https://pub.dev/packages/window_manager) — window
  close-behavior / event interception for Flutter desktop.
