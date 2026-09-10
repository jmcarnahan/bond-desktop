# Settings

Everything the owner gets to say about how the app behaves, on one pane.

`SettingsScreen` (`app/lib/widgets/settings_screen.dart`) is a main-pane view,
hosted the way the activity log is: a `bool _showingSettings` on
`_InboxScreenState`, cleared by every other selector, and first in the
`_main()` ladder. There is no router and no `Navigator.push` — nothing is
stacked on top of anything.

**Two ways in**, and one builder behind both (`_settingsScreen`):

- **The avatar menu's Settings.** The icon rail's account button
  (`IconRail.accountMenuKey`) opens a `PopupMenuButton` whose items are the
  account, Settings, Activity log and Sign out — see `docs/shell.md`. This is
  `_openSettings`, the whole screen, `SettingsScope.all`.
- **The AI stop.** `RailSection.ai` renders the same screen with
  `SettingsScope.ai`: titled **AI**, and narrowed to the six sections that are
  about how the model reads this mailbox — About me, Models, Needs You,
  Activity log, Storylines and Context directories. The Microsoft connection, Notifications,
  Sync & data and About are about the app or the account rather than the
  model, and stay behind the avatar menu. Its Back goes to the Inbox rather
  than to a `_showingSettings`
  that was never set: the AI pane is a SECTION, not an overlay — nothing opened
  it, the user is standing on that stop.

A scope rather than a second screen, because every section here is wired
through forty callbacks the host assembles, and a second screen would be a
second copy of that wiring drifting out of step with this one.

It replaced an `AlertDialog`, which was the last popup in the app. **The house
rule is full screens with a back arrow, never popups**, and
`app/test/no_dialogs_test.dart` pins it: the test walks every `.dart` file under
`app/lib/` and fails on `showDialog(` or `AlertDialog(`. A new popup cannot be
added without deleting that test.

## The shape

`PaneSurface` (`app/lib/widgets/pane_surface.dart`) draws the header: a back
arrow tooltipped **Back**, the title (**Settings**, or **AI** under
`SettingsScope.ai`), and — because Settings is
deep enough that Back alone is a poor way out — a labelled **Inbox** link that
goes straight to `RailSection.home` (the enum keeps its name; the label is
'Inbox'). `onHome` is optional on `PaneSurface`; a host with nowhere to send the
reader passes null and no affordance renders at all.

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

The Microsoft connection row is not one of those `_section(...)` calls: it is
its own widget, `MicrosoftConnectionSection`
(`app/lib/widgets/settings_connection_section.dart`), which builds its own
`SettingsSection`. It owns the most state on the screen — the backend mode, the
server preset and field, three held futures, the session snapshot, a sign-in
flag and its error — and its collapsed summary is built from that state, so the
state lives with the summary rather than a screen away from it. The screen stays
prop-only and passes the thirteen connection props straight through. The Models
body has the same shape in `settings_models_body.dart`.

## The sections, in order

| Section | Renders when | Collapsed summary |
|---|---|---|
| About me | always | the saved text, whitespace collapsed to one line, cut at 80 characters with `…`; `Not written yet` when empty |
| Microsoft connection | any of `onBackendModeChanged`, `connectionStatus`, `hasScope`, `onSignIn` is wired | `MCP` or `This device`, then (MCP only) `Deployed` / `Local` / `Custom`, then `Checking…` / `Not signed in` / `Signed in as <label>` / `Signed in`, joined by ` · ` |
| Models | `onSlotTargetChanged` wired | `[<local server summary> · ]Fast <model> @ <host:port> · Prose <model> @ <host:port> · Embeddings <host:port>` — the prefix is present only when the host wires the Local server card (`localServerSummary`), so a screen without one reads exactly as it always did |
| Needs You | always | the threshold wording, plus ` · custom rules` or ` · default rules` when `onNeedsYouRulesSaved` is wired, plus ` · judging N message(s)` while `needsYouRejudging` (the whole needs-you queue, from `needsYouPendingProvider`) is above zero — "judging", not "re-judging", because the count cannot tell a Save's rows from a sync's |
| Notifications | `onNotifyStyleChanged` wired | `Off` / `In-app ribbon` / `System notifications when in background` |
| Activity log | `onShowActivityLogChanged` wired | `Shown in the sidebar` / `Hidden` |
| Storylines | `onStorylineNewestFirstChanged` wired | `Newest first` / `Oldest first` |
| Context directories | when wired (both scopes) | `No directories yet` / `N directories · M files` |
| Sync & data | `onRefreshNow` wired | `Not synced yet`; `Mail synced <rel> · Teams <rel>`; a side that never ran says `not synced yet` in words (`Mail synced 4m ago · Teams not synced yet`, `Mail not synced yet · Teams synced 2h ago`) |
| About | `appVersion` or `databasePath` is known | `Bond <version>` / `Version unknown` |

**A section whose wiring is absent is absent** — the same discipline every
optional row in the old dialog followed, and what lets the permissions tests
wire `hasScope` alone. Under `SettingsScope.ai` four of them are absent for a
second reason: the AI pane keeps About me, Models, Needs You, Activity log,
Storylines and Context directories, in this same order, and drops the rest.

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
take the field off the screen without moving focus: Back, Inbox, and collapsing
the section. Flutter fires no unfocus when a subtree is disposed — measured, not
assumed — so `Focus.onFocusChange` alone would lose a typed URL on the way out.
`MicrosoftConnectionSectionState.commitPendingServerUrl` runs in those three
event handlers rather than in `dispose`, so the provider write it causes happens
outside the frame that is unmounting the tree. The section calls it itself on
Collapse; Back and Inbox are the screen's, which reaches it through a `GlobalKey`
on the section — the state is the only thing that knows whether the field is
showing and what is in it.

**The custom lookback date keeps the same contract**, through
`LookbackFieldState.commitPending` and a `GlobalKey` per side. Enter, focus
leaving the field, and the same three clicks — Back, Inbox, collapsing **Sync &
data** — with one difference from the URL above it: **a date that does not parse
commits nothing.** A half-typed URL is still a server somebody could mean, but
`2026-08` is a year and a month with nothing to sync between them, so the field
keeps its `errorText` and the stored window is left exactly as it was.

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

The whole section — state, asks and body — is
`app/lib/widgets/settings_connection_section.dart`. The mode segments are
**MCP** and **This device**. They were renamed from
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
handler list. Fourteen rows: eight on the fast slot, five on prose, one on
embeddings.

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
together. While the **Local server** switch is on, "Default" in the two editors
is the router target rather than the compiled one (`AppPrefs.slotBaseline`), so
an unedited Save still leaves the slot following the router and a later port
change still moves it. **A probe never blocks a Save**: somebody about to start
a server has to be able to point the app at it first.

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

**Local server card.** The first thing in the section, above the stage table
and separated from it by a divider, is `SettingsLocalServerBody`
(`app/lib/widgets/settings_local_server_card.dart`). It is injected as
`SettingsScreen.modelsHeader` rather than built by the section, so
`settings_models_body.dart` keeps knowing nothing about a supervisor: the
section is about where model calls go, and what is running is the host's answer
to hand over. It is prop-only like everything else here, and a null callback
hides its control.

It shows, top to bottom:

- **`Bond runs the model server`** — the switch over `AppPrefs.managedServer`,
  subtitled "One llama-server serves all three models from this Mac. Off, the
  app expects servers you started yourself." It is the only control that stays
  live when the preference is off; everything below it is disabled, not hidden,
  so the row does not jump about while the server stops. Flipping it writes the
  preference and then starts or stops the process — `_setManagedServer` on
  `_InboxScreenState`, in that order, because `ensureRunning`/`stop` both ask
  the preference and would read the old answer if they went first.
- **The state**, as `ServerStateDescribe.summary`: `Stopped`, `Starting… on
  port 8080`, `Loading models (1 of 3) on port 8080`, `Ready on
  127.0.0.1:8080`, `Failed: <reason>`, `Port 8080 is in use[ by <holder>]`, and
  `Off — servers are started by hand`. A failure or a held port renders as an
  error `InlineAlert`, a start or a load as an attention one, everything else
  as body text. Under a failure sit the **last 12 lines** of the server's log
  in mono — the reason alone never explains a crash. Under a held port sits
  `Pick a free port below, or stop the other program.` **The switch wins over
  the supervisor**: with the preference off the card says `Off` whatever the
  supervisor last reported, because stopping is asynchronous and a card still
  saying `Ready` would be describing a server the app has already stopped
  using.
- **The port** — a digits-only field, **Pick a free port** (fills the field
  from `ModelServerSupervisor.pickFreePort`, and saves nothing: a port that
  moved because somebody pressed a button labelled *Pick* would be a surprise
  restart), and **Save port**, live only when the number parses, sits in
  1024..65535 and differs from the stored one. Out of range shows `Use a port
  between 1024 and 65535`. Saving restarts the server, because a running
  process cannot change the socket it is bound to.
- **Models folder** — the effective path in mono (the host resolves "the app's
  own folder" through `AppPrefs.effectiveModelsFolder`) and **Change folder…**,
  which goes through the same `FileDialogs.chooseDirectory()` open panel every
  other folder in this app is chosen with. Cancelling changes nothing; a change
  restarts the server, because the preset names absolute paths.
- **Start / Stop / Restart**, offered by state — Start for stopped, failed and
  port-in-use; Stop for starting, loading and ready; Restart for loading and
  ready — plus **Show log**, which hands the log file to the operating system's
  own viewer (this app has no log pane and does not want one), and **Set up
  again**, unwired until Phase 4's first-run wizard exists and therefore absent.
- The caption `Changing the port or the folder restarts the server. Work in
  flight parks and resumes when it is back.`

`app/test/settings_local_server_test.dart` pins every one of those strings —
the nine state sentences, the switch's title and subtitle, the port error, the
held-port advice, the caption — plus which buttons each state offers and that
everything but the switch is dead while the preference is off.
`settings_models_test.dart` pins the join: the server's line leads the collapsed
summary, and the card renders above the stage table.

**The probe's lifetime is the screen's.** `_InboxScreenState` holds one
`ModelServerProbe` and closes it in `dispose`. A client per button press would
leak a connection pool per press, and this is a button a user can hammer.

## Sync & data

**How far back to sync** sits at the top of the body, above the stamps, because
it is the question they raise: somebody reading when the last pull ran is asking
how much of their mail is in here. One `LookbackField`
(`app/lib/widgets/settings_lookback_field.dart`) per connector — `Mail` and
`Teams`, keyed `settings-mail-lookback` and `settings-teams-lookback` — each a
dropdown of day presets (**7 / 14 / 30 / 60 / 90**) plus **Custom…**, which
reveals an inline `YYYY-MM-DD` field prefilled with the day the current window
reaches. **Not a `showDatePicker`**: that is a dialog, and `no_dialogs_test.dart`
now fails on it too.

Under the control, in every mode, is the line the setting exists for:
`Last 14 days · since Aug 22, 2026`. A day count is a span; the thing a person
asking for "three months" actually wants to know is which morning the mailbox
starts on. Both halves come from the same arithmetic the sync uses — UTC
midnight minus the count — so the day named here is the day the window reaches.

A preset commits the instant it is picked. The custom date commits on Enter, on
focus leaving the field, and on Back / Inbox / collapsing the section (see **What
commits, and when**). A date that does not parse, one today or later, or one
further back than a year commits nothing and shows `Use YYYY-MM-DD, a past date
within the last year` — refused rather than clamped, because silently syncing a
different span than the one on screen is worse than saying no. A stored value
outside the presets — 45 days, say — opens on **Custom…**; it is never handed to
the dropdown as a value of its own, which would be an assertion failure rather
than a blank row.

Nothing syncs on the strength of the change: the next sync — the sixty-second
poll at the latest — applies it. **Widening re-drains history** on that pass
through the bootstrap markers; **narrowing changes nothing retroactively**, since
the lookback is how much history to reach for and never a licence to delete.
A deep window (90+ days) therefore means a long first drain and more AI work
behind it, paced by the backlog caps rather than truncated by them — see
[pipeline/01-sync-ingest.md](pipeline/01-sync-ingest.md).

**The collapsed summary deliberately says nothing about it.** That line answers
"is what I am looking at current?", which is a question about the stamps; adding
a second clause about the window would make the summary two reports instead of
one, and the table above is pinned verbatim by tests either way.

The four stamps — `Mail`, `Mail reconcile`, `Teams`, `Storyline sweep` — come
from `syncStampsProvider` (`app/lib/providers/activity_provider.dart`), which
`_settings()` **watches** — it re-reads on every recorded event, so a sync
landing behind an open Settings pane moves the numbers in it. `Mail reconcile`
sits directly under `Mail` because it qualifies it: the 24-hour re-enumeration
that catches what the delta feed skipped runs on its own cadence, and a mail
sync minutes fresher than it is the normal state (see
[pipeline/01-sync-ingest.md](pipeline/01-sync-ingest.md)). The provider is
split from `activitySnapshotProvider` on purpose: the snapshot pays for the
whole activity pane (three hundred events and every conversation subject) per
event, and this section needs four preference reads.
`sync_stamps_provider_test.dart` pins it. Times are relative
and in one unit (`relativeTime` in `app/lib/widgets/time_format.dart`), and
`null` reads as `never` in the rows. The clock is a `now` parameter rather than
a call to `DateTime.now`, so a test can pin it and assert an exact string.

**Refresh now** is `_refreshAll` — mail, Teams and the parked read-acks, the
same pull the rail's Refresh makes. It is handed over as the future it is, so
the button reads **Refreshing…** and goes inert until both pulls are back, the
way the Storylines pane's Sync does; a pull that throws still lets go of the
button (every leg reports its own failure through the inbox banner).

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

**Clear attachment cache** sits above it and takes the same two clicks, for the
same reason: it is a smaller loss — files that come back on the next click — but
two destructive buttons on one section that behaved differently would teach
nobody anything. The line above it says what the cache is for and how much of
this disk it is using; `formatBytes` renders zero as no characters at all, so an
empty cache says **Empty.** rather than `0 B`, and a size nobody has answered yet
says nothing. Failure renders as an `InlineAlert` with the pair still up, and a
successful clear re-reads the size so the line agrees with what just happened.

The store itself is content-addressed, under
`<Application Support>/attachments/<sha[0:2]>/<sha>.<ext>`: the same file
forwarded three times is one file on disk, and it keeps the name's extension
because macOS decides what an unknown file is by its name. Clearing it here
empties the tree and drops the four path columns off every `attachments` row
(`MessageStore.clearAttachmentBlobs`) — the names, the extracted words, the
digests and the pins all survive, because none of them is a copy of the file.
The same tree is emptied by **Sign out and clear local data** and by an identity
wipe (`IdentityGuard`), which starts the delete rather than waiting on it: the
rows pointing at those files are already gone, so nothing can reach one.

## Context directories

The library of local folders the model may read when it drafts. The section is
its own widget — `app/lib/widgets/settings_context_section.dart` — in the
`MicrosoftConnectionSection` shape: it owns which row is asking a second time
about Remove and whether the open panel is out, and it builds its own
`SettingsSection`. It appears in **both scopes**, because what the model is
allowed to read is a question about the model.

The body opens with one sentence saying what a directory is for and that it is
re-read on every sync. Under it, one switch for the whole library rather than
for any one folder:

- **Let the model pick two sections to read in full before drafting** —
  `AppPrefs.contextSelectExpand`, key `context_select_expand` in `app_prefs`.
  **On by default**, unlike almost every switch on this screen: it is what
  makes a suggestion read the section that carries the number rather than the
  passages nearest the question, and it is one extra fast-slot call per
  suggestion that reads a directory at all. Off, a reply sees only the nearest
  passages. Prop-driven with no local state — the host watches the preference,
  so what the switch shows is what is stored. See
  [pipeline/13-context-directories.md](pipeline/13-context-directories.md).

Then one block per registered directory:

- The **display name** (the folder's own name), the **path** in muted type.
- The brief's **`about`** under the path, when one has been compiled — two or
  three sentences saying what the project is, in the model's own words,
  clamped to three lines. It is the only place in Settings that says what the
  app made of a folder, which is how a person tells a directory that was READ
  from one that was merely walked. Absent until the brief lands.
- A **status line**: `12 files · 30 passages · read 3m ago` once it has been
  read; `not read yet` before the first pass, `reading…` during one, and the
  stored sentence in the error colour for a folder that is `unavailable` or
  that failed — the counts are dropped there, because they describe a walk
  from before the folder went away. When vectors are still arriving the line
  gains ` · embedding 8 of 30`, and while the per-file summaries are behind it
  gains ` · summaries 3 of 12` — shown only when **Summaries** is on, because
  a count towards a total nothing is working on would never move. The total
  counts files of 200 characters or more that are still owed a summary or
  already hold one, so `K of M` counts towards a number it can reach: a file
  too short to be worth a call, and a file the model gave up on after both
  attempts, are in neither half because nothing will ever work them off. Singulars
  are singular: `1 file`, `1 passage`, and the collapsed summary says
  `1 directory · 12 files`.
- A **link count**: `Links: 3`, or `Not linked to any thread yet`. Registering
  is not linking (see
  [pipeline/13-context-directories.md](pipeline/13-context-directories.md)) —
  a directory is read whether or not any room points at it.
- **Re-read now**, which requeues the reconcile with `{"force":true}` and
  pumps the worker. Forced, because the person is standing in front of it: the
  handler's sixty-second freshness rung would otherwise answer `fresh` at a
  row that has not changed on screen.
- **Summaries** — the `digests` column. On by default: each changed text file
  earns one fast-slot digest, which is what makes a question about *findings*
  reach an analysis whose code shares none of its vocabulary.
- **Read ignored files** — `honor_gitignore`, **inverted**. The stored column
  asks "is `.gitignore` honoured"; the switch asks the question a person
  actually has. On by default, because Claude Code analyses land in ignored
  `output/` and `reports/` folders. The inversion lives in the section and
  nowhere else. A hard denylist (`.git`, `node_modules`, build output, keys)
  applies either way.
- **Remove**, an inline two-step for the reason every destructive control on
  this screen is: the first tap *replaces* the button with a red **Remove
  directory** beside a **Keep**, so the second click lands on a different
  button that did not exist a moment ago. A caption under the pair names what
  goes: `Removes its index and 3 links; the folder itself is untouched.` The
  index, the links and the directory's queued work are deleted; the folder on
  disk is not, and never has been written to.

At the foot of the body is **Add directory…**: the open panel
(`FileDialogs.chooseDirectory`), then a security-scoped bookmark taken
immediately — the sandbox's grant is on that pick, and a bookmark asked for a
moment later is an error rather than a bookmark — then `registerDirectory`, a
forced `context_reconcile`, and a pump. The button reads **Adding…** and goes
inert until all of that is back, the same contract **Refresh now** keeps. A
cancelled panel registers nothing and says nothing.

Nothing here reaches for a provider: the section takes rows and six closures,
and the host wires them through `ContextDirectoriesActions` in
`app/lib/providers/context_provider.dart`. The list itself is
`contextDirectoriesProvider`, which the screen **watches** and which re-reads
on every recorded activity event — so a reconcile landing behind an open
Settings pane moves `reading…` to `12 files · read just now` with no timer of
its own.


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

- **`SegmentedButton` stays.** Both segmented controls could be
  `BondFilterPillRow`, but the existing tests read `.selected` off the
  `SegmentedButton` directly, and this round is about the container rather than
  the controls.
