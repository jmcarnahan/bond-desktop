# Settings

Everything the owner gets to say about how the app behaves, on one pane.

`SettingsScreen` (`app/lib/widgets/settings_screen.dart`) is a main-pane view,
hosted the way the activity log is: a `bool _showingSettings` on
`_InboxScreenState`, set by the rail footer's gear (`_openSettings`), cleared by
every other selector, and first in the `_main()` ladder. There is no router and
no `Navigator.push` — nothing is stacked on top of anything.

It replaced an `AlertDialog`, which was the last popup in the app. **The house
rule is full screens with a back arrow, never popups**, and
`app/test/no_dialogs_test.dart` pins it: the test walks every `.dart` file under
`app/lib/` and fails on `showDialog(` or `AlertDialog(`. A new popup cannot be
added without deleting that test.

## The shape

`PaneSurface` (`app/lib/widgets/pane_surface.dart`) draws the header: a back
arrow tooltipped **Back**, the title **Settings**, and — because Settings is
deep enough that Back alone is a poor way out — a labelled **Home** link that
goes straight to `RailSection.home`. `onHome` is optional on `PaneSurface`; a
host with no Home to offer passes null and no affordance renders at all.

Under the header is a `SingleChildScrollView` over a `Column` of sections.
**Never a `ListView`**: two sections hold a `TextField`, and a lazy list may
dispose an off-screen child, which would drop an unsaved edit the moment the
user scrolled past it.

Each row is a `SettingsSection` (`app/lib/widgets/settings_section.dart`):
title, a one-line summary of the current state, and an Expand/Collapse button
keyed by `SettingsSection.toggleKey(title)`. The section is **stateless over
props** — the screen owns a `Set<String> _open` of titles. Several sections may
be open at once, every one starts collapsed, and none of that is persisted:
where the disclosures were left is a scroll position, not a preference. The
summary stays visible while the body is open, because it is the answer and
hiding it would make Collapse the only way to check what the controls did.

## The sections, in order

| Section | Renders when | Collapsed summary |
|---|---|---|
| About me | always | the saved text, whitespace collapsed to one line, cut at 80 characters with `…`; `Not written yet` when empty |
| Microsoft connection | any of `onBackendModeChanged`, `connectionStatus`, `hasScope`, `onSignIn` is wired | `MCP` or `This device`, then (MCP only) `Deployed` / `Local` / `Custom`, then `Checking…` / `Not signed in` / `Signed in as <label>` / `Signed in`, joined by ` · ` |
| Models | `onSlotTargetChanged` wired | `Fast <model> @ <host:port> · Prose <model> @ <host:port> · Embeddings <host:port>` |
| Needs You | always | the threshold wording, plus ` · custom rules` or ` · default rules` when `onNeedsYouRulesSaved` is wired |
| Notifications | `onNotifyStyleChanged` wired | `Off` / `In-app ribbon` / `System notifications when in background` |
| Activity log | `onShowActivityLogChanged` wired | `Shown in the sidebar` / `Hidden` |
| Home & feed | `onHomeShowDroppedChanged` wired | `Dropped messages shown` / `Dropped messages hidden` |
| Storylines | `onStorylineNewestFirstChanged` wired | `Newest first` / `Oldest first` |
| Sync & data | `onRefreshNow` wired | `Not synced yet`, or `Mail synced <rel> · Teams <rel>` |
| About | `appVersion` or `databasePath` is known | `Bond <version>` / `Version unknown` |

**A section whose wiring is absent is absent** — the same discipline every
optional row in the old dialog followed, and what lets the permissions tests
wire `hasScope` alone.

**These strings are pinned by tests** (`settings_screen_test.dart`,
`settings_connection_test.dart`, `settings_models_test.dart`,
`settings_sync_about_test.dart`). This table and those tests must agree; when
one moves, move both.

The Needs You wording is a five-step ladder on the stored threshold: `≥0.8`
**Only the critical**, `≥0.6` **Close to critical**, `≥0.4` **A middle cut**,
`≥0.2` **Leaning generous**, otherwise **Anything plausible**. Five words for
ten stops, because the slider is a feel and a summary reading "0.7" would report
an implementation detail at somebody who moved a slider.

## What commits, and when

**Toggles, segments and the slider apply instantly.** The activity-log switch,
the notification segments, both feed switches and the backend segments all call
their host callback the moment they move: what each one changes is visible
behind or beside this pane, and a control whose effect only lands on Back cannot
be checked by the person who flipped it. The threshold slider writes on release
(`onChangeEnd`), not per pixel — each write persists a preference and reloads
the list.

**The two free texts commit on their own Save and on nothing else.** About me
and the Needs You rules each have a Cancel/Save footer. Cancel puts the last
saved text back in the field and stays; Save writes and stays, and the saved
text becomes the new baseline, so a second edit is dirty against the first save.
Both buttons are disabled while the field is clean.

**The two model editors commit on Save only**, exactly like the two texts. A
slot's URL and its model name travel together in one write — a URL sent with the
previous model's name against it is an HTTP 400 on an MLX runtime, which is
fatal and never retried. Cancel puts the last saved pair back, `Use build
defaults` puts the compiled pair back, and a failed server check never blocks
either.

**Nothing is saved on dispose.** The dialog this replaced saved about-me on the
way out, which needed a `scheduleMicrotask` to survive being unmounted by its
own backend-switch callback. With no write in `dispose`, that whole hazard is
gone — and Cancel means cancel, leaving means leaving.

**An identity wipe is adopted only by a clean field.** A sign-in from inside
Settings can change the identity, which clears the previous person's about-me
and rules to `''`. Both editors adopt the new prop in `didUpdateWidget` when —
and only when — their field is not dirty. An unsaved edit is the user's and is
never overwritten.

**The custom server URL is the exception**, because it has no Save of its own.
It commits on Enter, on focus leaving the field, and on the three clicks that
take the field off the screen without moving focus: Back, Home, and collapsing
the section. Flutter fires no unfocus when a subtree is disposed — measured, not
assumed — so `Focus.onFocusChange` alone would lose a typed URL on the way out.
`_commitPendingServerUrl` runs in those three event handlers rather than in
`dispose`, so the provider write it causes happens outside the frame that is
unmounting the tree.

## About me

Read by exactly two steps of the pipeline: the reply decision
(`app/lib/services/llm/reply_decision_task.dart`) and draft generation
(`app/lib/services/llm/draft_task.dart`), both reached through
`DraftHandler` and both clamping the text to **600 characters**. Nothing else
reads it — not triage, not storylines, and deliberately not the Needs You
judgement, which excludes it on purpose (see
[pipeline/11-needs-you.md](pipeline/11-needs-you.md)).

The field enforces `maxLength: 600` so the cap the prompt applies is visible.
A cap the screen did not show would silently drop the end of what somebody
typed.

## Microsoft connection

The mode segments are **MCP** and **This device**. They were renamed from
'Bond server' and 'This Mac': the first collided with the dropdown label
directly under it, and the second named the wrong thing on a machine that is not
a Mac. The server dropdown is labelled **MCP server** and offers:

- **Deployed** — the `BOND_MCP_SERVER_URL` endpoint, present only in a build
  that carries the define.
- **Local** — `mcpLocalUrl`, a bond-mcps server on this machine.
- **Custom…** — reveals a URL field for anything else.

Under them sits the session block: a `BondChip.semantic` reading `Signed in` or
`Not signed in`, the sentence beside it, and **Sign in…** / **Sign out of this
server**. Sessions are managed here because the gate in front of the app decides
at launch only — a target with no session is a thing to fix in place, not a
reason to swap the screen out. A sign-in failure renders as an `InlineAlert`
with `InlineAlertSeverity.error` beneath the button that caused it.

The Microsoft permissions rows fold in at the bottom of the same section: they
are a report about this connection, and a person reading them has just read
which server they belong to. Which source answers follows the mode the screen is
**showing**, not which closures the host wired.

The screen stays put across a backend switch. The host swaps the session
underneath and the section re-asks, so the user sees what their own click did.

## Host wiring

`_settings()` in `app/lib/screens/inbox_screen.dart` builds it, and
**`ref.watch(appPrefsProvider)`, not `ref.read`**. The Needs You summary reads
the stored rules to say whether they are custom, so a Save inside the screen
only moves that line because the host rebuilds. Optimising the watch back to a
read would silently stop the summary following saves.

`onHomeShowDroppedChanged` writes **twice**: the preference, and
`ref.read(homeFeedProvider.notifier).setIncludeDropped(on)`. The feed reads that
preference once, when its notifier is built, so the pref alone would leave Home
unchanged until the next launch. `settings_needs_you_test.dart` pins both
halves.

Every closure that touches `ref` keeps its `mounted` guard. The work behind them
outlives the pane — a sign-in still out in the browser, a sign-out from the rail
— and a dead host must answer with nothing rather than with "ref after
dispose".

## Models

Which model each step of the pipeline uses, and the two slots the user may
move. The body lives in its own file — `app/lib/widgets/settings_models_body.dart`
— because `settings_screen.dart` was already thirteen hundred lines.

**The stage table is AUTHORED**, not derived. The stage → slot mapping is decided
in `app_providers.dart` when the clients are constructed, and there is no
per-call router anything can interrogate at runtime, so `pipelineStages` in
`app/lib/services/llm/model_slots.dart` is the app telling the user what its own
wiring is. `model_slots_test.dart` is what keeps that table honest against the
handler list. Ten rows: four on the fast slot, five on prose, one on embeddings.

**Two editors, one per switchable slot.** `ModelSlotEditor`
(`app/lib/widgets/model_slot_editor.dart`) is prop-only: it takes the effective
target, the compiled default, whether the slot is on that default, a probe
closure and two callbacks. Both editors sit on one screen with identical button
labels, so every control is keyed by slot — `ModelSlotEditor.saveKey(slot)` and
friends. The probe closure is optional: a host that wires none gets editors with
no **Check server** at all (and no check on the embeddings card), the model
stays a typed name, and everything else works — the same discipline as every
other optional control on the screen.

**Save semantics.** Save is the only commit; nothing is written on dispose. A
value equal to the compiled default is sent as the **empty string**, because
empty means "follow the build" and is stored as empty — freezing today's
dart-define into the database would make a changed `FAST_LLAMA_MODEL` invisible
(see `prefs_models_test.dart`). The URL and the model name are always written
together. **A probe never blocks a Save**: somebody about to start a server has
to be able to point the app at it first.

**Three probe outcomes, rendered apart.** `ModelServerProbe.probe` never throws
and answers one of:

- **A URL it refuses** — `probedUrl` is null and no request was made, because
  nothing ending in `/v1/…` could be derived from it. That is a fault in the
  field, so it renders as the URL `TextField`'s own `errorText`, never as a
  claim about a server.
- **Not reachable** — `probedUrl` set and a sentence in `error`. Renders as an
  `InlineAlert` with `InlineAlertSeverity.error`, with `Asked <url>` under it.
  That small print matters: "not reachable" against a server that is
  demonstrably up is almost always a surprise about the derived listing URL.
- **Reachable with an empty list** — a live server with nothing loaded. It says
  `Reachable · nothing loaded yet` and keeps the typed model name. It is *not*
  unreachable and must never read as if it were.

**Picker or field.** With a listing of one or more ids the model becomes a
`DropdownButton<String>`; without one it stays a free `TextField` captioned
"Check the server to pick from what it serves; llama.cpp ignores this name, MLX
runtimes require it." A name already in the field that the server did not list
stays selectable, labelled ` (not listed)` and captioned with what each runtime
will do about it — llama.cpp ignores the field, an MLX runtime answers a fatal
HTTP 400. Editing the URL drops the listing: a listing belongs to the URL it was
asked of — and an answer that lands after the URL was edited away is dropped on
arrival for the same reason.

**Embeddings is read-only** and says so in the place somebody would go looking
for the missing control: every stored vector is tagged with the embedding
model's name (`EmbeddingsClient.modelTag`), so swapping it would silently
compare vectors from two different spaces. Changing it is a re-embed migration,
not a setting — `EMBED_URL` at build time. The card shows the URL and a Check
server button and nothing else.

**The probe's lifetime is the screen's.** `_InboxScreenState` holds one
`ModelServerProbe` and closes it in `dispose`. A client per button press would
leak a connection pool per press, and this is a button a user can hammer.

## Sync & data

The three stamps come from `activitySnapshotProvider`, which `_settings()`
**watches** — that provider re-reads on every recorded event, so a sync landing
behind an open Settings pane moves the numbers in it. Times are relative and in
one unit (`relativeTime` in `app/lib/widgets/time_format.dart`), and `null`
reads as `never`. The clock is a `now` parameter rather than a call to
`DateTime.now`, so a test can pin it and assert an exact string.

**Refresh now** is `_refreshAll` — mail, Teams and the parked read-acks, the
same pull the rail's Refresh makes.

**Sign out and clear local data** is an inline two-step, because the house rule
forbids a confirmation dialog. The first tap *replaces* the button with a red
**Yes, clear and sign out** beside a **Keep**; the second click therefore lands
on a different button, in a different place, that did not exist a moment ago —
which is the whole of the protection a modal would have given. Both buttons go
inert while the wipe is out, and a failure renders as an `InlineAlert` with the
pair still up, because the user is about to press it again.

It is wired to `_signOut`, the rail's own Sign out: the whole wipe. It is
deliberately **not** `onSignOutOfServer`, which ends one server's session and
keeps this device's copy of the mail.

## About

`appVersion` is composed by the host as `<version> (<build>)` from
`appInfoProvider`, a `FutureProvider` over `package_info_plus`'s
`PackageInfo.fromPlatform()`. `databasePath` comes from `databasePathProvider`,
a `FutureProvider` over `appDatabasePath()` in `app/lib/data/db.dart` — which
`openAppDb` also calls, so the literal `bond_inbox.db` is written exactly once
and the screen and the opener can never disagree.

Both are platform channels, and **a widget test has nobody on the other end**:
the call throws `MissingPluginException`, the provider turns that into an
`AsyncError`, and the host's `valueOrNull` reads it as null. About then quietly
says `Version unknown` rather than throwing. A test that wants real values
overrides the two providers — `settings_models_host_test.dart` does.


## Deliberate deferrals

- **The storyline pickers keep their private `_PaneSurface`.**
  `app/lib/widgets/storyline_pickers.dart` still has its own copy of the header
  `PaneSurface` was generalised from. Retrofitting its two call sites is a
  follow-up; keeping them separate here means the picker tests cannot break on a
  settings change.
- **`SegmentedButton` stays.** Both segmented controls could be
  `BondFilterPillRow`, but the existing tests read `.selected` off the
  `SegmentedButton` directly, and this round is about the container rather than
  the controls.
