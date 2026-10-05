# Settings

Everything the owner gets to say about how the app behaves, on one pane.

`SettingsScreen` (`app/lib/widgets/settings_screen.dart`) is a main-pane view,
hosted the way the activity log is: a `bool _showingSettings` on
`_InboxScreenState`, cleared by every other selector, and first in the
`_main()` ladder. There is no router and no `Navigator.push` — nothing is
stacked on top of anything.

The screen's own host is `SettingsHost`
(`app/lib/screens/settings_host.dart`), a `ConsumerStatefulWidget` of its own
since Round H Phase 4. It owns the probe and every writer only settings calls;
the inbox binds it in one place and keeps the inbox.

**Two ways in**, and one binding behind both (`_settingsHost`):

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
page has the same shape in `settings_models_page.dart`.

## The sections, in order

| Section | Renders when | Collapsed summary |
|---|---|---|
| About me | always | the saved text, whitespace collapsed to one line, cut at 80 characters with `…`; `Not written yet` when empty |
| Microsoft connection | any of `onBackendModeChanged`, `connectionStatus`, `hasScope`, `onSignIn` is wired | `MCP` or `This device`, then (MCP only) `Deployed` / `Local` / `Custom`, then `Checking…` / `Not signed in` / `Signed in as <label>` / `Signed in`, joined by ` · ` |
| Models | `onUseDecision` wired | where each role runs, then the app's own server's state sentence, joined by ` · `: `Decision on this Mac` / `Decision on your server`, then `Generative on this Mac` / `Generative at <host>` / `Generative on your server` (no address yet), then e.g. `Running` |
| Cloud drafts | `onUseCloudDrafts` wired (both scopes) | `Off`, or `<model> at <host>` for the target in force |
| Needs You | always | `At 35% or more` — the slider's threshold as a percentage, `(threshold * 100).round()` |
| Suggested replies | `onDraftPolicyChanged` wired (both scopes) | `For messages that need you` / `For every reply-worthy message` / `Only when asked` |
| Notifications | `onNotifyStyleChanged` wired | `Off` / `In-app ribbon` / `System notifications when in background` |
| Activity log | `onShowActivityLogChanged` wired | `Shown in the sidebar` / `Hidden` |
| Storylines | `onStorylineNewestFirstChanged` wired | `Newest first` / `Oldest first` |
| Labels | `labels` wired, avatar-menu scope only | `No labels yet` / `1 label` / `3 labels · 12 uses` — the use clause only once something has been filed |
| Context directories | when wired (both scopes) | `No directories yet` / `N directories · M files` |
| Processing | any of `onProcessingChanged`, `onClearAiResults`, `onForgetAndResync` is wired (both scopes) | `On` / `Off` |
| Sync & data | `onRefreshNow` wired | `Not synced yet`; `Mail synced <rel> · Teams <rel>`; a side that never ran says `not synced yet` in words (`Mail synced 4m ago · Teams not synced yet`, `Mail not synced yet · Teams synced 2h ago`) |
| About | `appVersion` or `databasePath` is known | `Bond <version>` / `Version unknown` |

**A section whose wiring is absent is absent** — the same discipline every
optional row in the old dialog followed, and what lets the permissions tests
wire `hasScope` alone. Under `SettingsScope.ai` five of them are absent for a
second reason: the AI pane keeps About me, Models, Needs You, Suggested
replies, Activity log, Storylines, Context directories and Processing, in this
same order, and drops the rest.

**These strings are pinned by tests** (`settings_screen_test.dart`,
`settings_connection_test.dart`, `settings_models_page_test.dart`,
`settings_sync_about_test.dart`). This table and those tests must agree; when
one moves, move both.

The Needs You slider is the owner's ONE control over the cut on what lands in
Needs You (the thread bar's Remove and Add presses answer for kinds of mail, below):
a threshold on the decision model's needs-you probability (`needs_you_threshold`,
default **0.35**; see [pipeline/11-needs-you.md](pipeline/11-needs-you.md)). A
message needs you when its probability is at or above it. The slider runs
**right = more mail**, which is a LOWER threshold, so it is drawn over
`[0.05, 0.95]` with `value = 0.95 + 0.05 − threshold` and **18 divisions**, one
per 0.05 notch the stored pref can hold. Its ends read **Only the surest**
(left) and **Anything plausible** (right). Under it, one line states the number,
**Needs you at 35% or more** (keyed `settings-needs-you-threshold-line`), and a
caption says what the number is: *The decision model's confidence that a message
needs you. Each message shows its own percentage.* The percentage is the same
one every message shows in its Why panel and history row and every thread shows
beside its reason, and it is FLOORED, never rounded (0.296 shows 29%, not 30%),
so a row showing 72% is in Needs You exactly when this line says 70% or less,
and a row never shows 30% beside "below your 30% line". A message nothing has
re-decided since v21 carried the old yes/no verdict across as exactly 1.0 or
0.0; it still counts against the slider, but shows no percentage (the Why panel
reads "— (earlier model)"). There is no editable Needs You text: no language model is asked
about needs-you, so there is no prompt to edit. When an older build left custom
rules text in `needs_you_rules`, the section says so in one quiet caption,
*Your earlier Needs You rules are no longer used; the slider is the one
control.* (keyed `settings-old-needs-you-rules`), and never reads the text. The old `attention_threshold`
setting is not carried over: its scale was the 0..2 attention score, not a
probability, so the Needs You slider starts at its default of 35% and the old
value is simply never read again.

Under them, **Your answers**: one line counting the owner's thread-bar presses
(`MessageStore.needsYouPressCounts`, one press per `created_at` stamp however many
messages it labelled), **You've removed N kinds of mail from Needs You and added
M kinds.** (keyed `settings-needs-you-answers-line`; `1 kind` for one, on either
count), or *You haven't answered for any
mail yet.* when there are none, and, when there are, a two-step quiet button
**Forget all Needs You answers** → **Really forget?** (keyed
`settings-forget-needs-you-answers`; no dialog, the label turns into the second
step). The second press calls `SettingsHost.forgetNeedsYouAnswers()`, which undoes
every press at once (`NeedsYouEdits.retractAll`: every label deleted, then every
message carrying an owner's answer written again from its stored decision), so
each message they answered for takes the model's own number back, then reloads
the list and the line. No model is asked. It needs processing ON; off reads
*Your answers couldn't be forgotten just now — processing has to be on.* under
the button. The line is drawn only once the host has read the counts, and
it is not in the section summary. See
[pipeline/11-needs-you.md](pipeline/11-needs-you.md).

Above it sits **Remind me in To Do about deadlines** — *A Needs You thread
with a deadline gets a To Do reminder that morning* — keyed
`settings-remind-deadlines`, wired by `onRemindDeadlinesChanged` and stored
as `remind_deadlines` (`AppPrefs.remindDeadlines`). It is **on by default**:
the reminder lands in the owner's own Microsoft To Do and emails nobody. While
To Do cannot carry a reminder (`tasksAvailability` is not `available`, which
is every install until the consent round) the caption gains ` · Needs the To
Do permission` — or, on the SDK backend, where To Do is never reachable,
` · Needs the Bond server connection` — and the switch stays live, because
the pref is the owner's wish and holds until the permission arrives. What it turns on is the deadline
planner ([pipeline/15-reminders.md](pipeline/15-reminders.md#the-deadline-planner)).

The section's last control is a switch, **Sending a reply marks it done** — *A
thread leaves Needs You as soon as you answer it, instead of waiting for you to
mark it done.* — keyed `settings-reply-send-marks-done` and wired by
`onReplySendMarksDoneChanged`. It is **off by default**, because a sent reply and
a cleared thread are two different claims: an answer that asks a question back is
still the reader's to watch. It is last in the section because everything above
it decides what ENTERS the pile and this one says when a thread leaves. It does
not appear in the section summary: the threshold is the thing a reader scans that
line for.

With it on, a sent reply on a thread of the Needs You pile is marked done the
way `e` does it, so the view lands on the next row and the progress count
moves. A thread opened from Archive or Home is marked done in place and stays
open. Either way the toast reads `Reply sent · Marked done.` with an Undo. A
mark-done whose write fails reads `Reply sent. Couldn't mark it done.` with no
Undo, and the reader stays where they are. See
[pipeline/07-replies.md](pipeline/07-replies.md).

## What commits, and when

**Toggles, segments and the slider apply instantly.** The activity-log switch,
the notification segments, both feed switches and the backend segments all call
their host callback the moment they move: what each one changes is visible
behind or beside this pane, and a control whose effect only lands on Back cannot
be checked by the person who flipped it. The threshold slider writes on release
(`onChangeEnd`), not per pixel — each write persists a preference and reloads
the list.

**The free text commits on its own Save and on nothing else.** About me has a
Cancel/Save footer. Cancel puts the last saved text back in the field and stays;
Save writes and stays, and the saved text becomes the new baseline, so a second
edit is dirty against the first save. Both buttons are disabled while the field
is clean.

**Each server form commits on Connect only.** One address, its discovered
model name and its key travel together in one write, because an address sent
with the previous server's model name against it is an HTTP 400 on an MLX
runtime, which is fatal and never retried. That is also why the name is
discovered rather than typed: Connect asks the server what it serves and
writes what it answered. The Decision model, the Generative model and Cloud
drafts each have their own form and their own Connect.

**Nothing is saved on dispose.** The dialog this replaced saved about-me on the
way out, which needed a `scheduleMicrotask` to survive being unmounted by its
own backend-switch callback. With no write in `dispose`, that whole hazard is
gone — and Cancel means cancel, leaving means leaving.

**An identity wipe is adopted only by a clean field.** A sign-in from inside
Settings can change the identity, which clears the previous person's about-me
to `''`. The editor adopts the new prop in `didUpdateWidget` when — and only
when — its field is not dirty. An unsaved edit is the user's and is
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

Read by exactly one step of the pipeline: draft generation
(`app/lib/services/llm/draft_task.dart`, and Improve a draft, which sends the
same prompt), reached through `DraftHandler` and clamping the text to **600
characters**. (The 27B reply decision read it too until the decision model's
`reply_expected` replaced it.) Nothing else
reads it — not triage, not storylines, and not the Needs You probability,
which is the decision model's (see
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
reason to swap the screen out. Against a server that asks for a login,
**Sign in…** registers the app with that server's authorization server before
it opens the browser, so nothing has to be pre-registered there; a local
`make dev` server asks for nothing and gets no browser. A sign-in failure
renders as an `InlineAlert`
with `InlineAlertSeverity.error` beneath the button that caused it.

The Microsoft permissions rows fold in at the bottom of the same section: they
are a report about this connection, and a person reading them has just read
which server they belong to. Which source answers follows the mode the screen is
**showing**, not which closures the host wired.

The rows are `microsoftPermissions` in `settings_connection_section.dart`, in
this order: **Send mail** (`mail.send`), **Save drafts** (`mail.readwrite`),
**Teams chats** (`chat.read`, satisfied by `Chat.ReadWrite`), **Calendar
(read and write)** (`calendars.readwrite`: the app answers, moves, cancels and
creates meetings, so the row names both halves of the grant) and **To Do
reminders** (`tasks.readwrite`, satisfied by nothing else; dark until the
consent round — every install shows a cross there until the owner's consent
round adds the scope and each user reconnects, see
[pipeline/15-reminders.md](pipeline/15-reminders.md#dark-until-consent)).
Only the first two count toward the **Sign in again to enable** offer: Teams,
Calendar and To Do arrive through a platform-side Microsoft reconnect in MCP
mode, which this app's sign-in cannot deliver, so a cross on any of them is
reported and never offered. The section's `_subsumedBy` copy
(`calendars.read` ← `calendars.readwrite` among them) must agree with
`McpAuthSession._subsumedBy`.

The screen stays put across a backend switch. The host swaps the session
underneath and the section re-asks, so the user sees what their own click did.

## Host wiring

`SettingsHost` in `app/lib/screens/settings_host.dart` builds it, and
**`ref.watch(appPrefsProvider)`, not `ref.read`**. A write from inside the
screen (the About me Save, a role's Connect) only moves the summary lines
because the host rebuilds. Optimising the watch back to a read would silently
stop the summaries following saves.

Every closure that touches `ref` keeps its `mounted` guard. The work behind them
outlives the pane — a sign-in still out in the browser, a sign-out from the rail
— and a dead host must answer with nothing rather than with "ref after
dispose".

**What the host owns, and the two seams it does not.** Everything only
settings calls lives on `_SettingsHostState`: `_clearAiResults`, `_forgetAndResync`, `_resetPipeline`,
`_reloadAfterBackendChange`, `_connectionStatus` and `_connectMicrosoft`. A new
settings-only writer goes here, not on the inbox. The three server mutators
went with the Local server card in Round H: the managed-server switch became a
build define, the port moves itself, and the models folder changes through
**Set up again**.

What the inbox still answers arrives as the host's twelve required
constructor parameters — `scope`, `onBack`, `onHome`, `onCloseSettings`,
`fileDialogs`, `onSetProcessing`, `waitForPullsToSettle`, `onRefreshNow`,
`onSignOut`, `onOpenActivityLog`, `onForgetThumbnails`, `onToast` — plus the
optional `probe` a test hands in.
Two of those are seams rather than conveniences, and they are the reason the
methods behind them did NOT move:

- `_setProcessing` stays on `_InboxScreenState` because the sidebar's own
  switch (`_processingToggle`) calls it too, and one switch is one writer. The
  host binds it to `SettingsScreen.onProcessingChanged`.
- `_waitForPullsToSettle`, with its `_quietTimeout`, stays because it reads
  `_mailPulling` and `_teamsPulling`, the two flags `_notePulling` writes as
  the inbox's own syncs go out and come back. `_resetPipeline` awaits it
  before it deletes anything.

`onCloseSettings` is a third, smaller one: the SDK permissions table's **Sign
in again** leaves the pane without moving the section, which is not `onBack` —
on the AI rung Back goes home.

**The Models section's own wires.** The host reads them off the preferences,
so the page's prefill and its report come from one resolver rather than from
two guesses:

- `decisionPlacement: prefs.decisionPlacement` and `generativePlacement:
  prefs.modelPlacement` (the generative placement reuses Round H's key), with
  `generativeManagedId` resolved by `managedGenerativeIdFor(tier,
  prefs.generativeManagedModel)` and `inboxTier` from `machineTierProvider`
  (watched; read as full for the two seconds a test's hardware channel takes).
- The six values the two forms open on: `decisionUrl:
  prefs.effectiveDecisionUrl`, `decisionModel: prefs.effectiveDecisionModel`,
  `generativeUrl: prefs.effectiveGenerativeUrl`, `generativeModel:
  prefs.effectiveGenerativeModel`, each already resolved to the stored value
  where there is one and the build's otherwise, and the two presence flags
  `decisionKeyStored` and `generativeKeyStored` (`prefs.boxBigKeyStored`).
  Never a key.
- `onUseDecision` calls `notifier.useDecision(placement:, url:, model:, key:,
  clearKey:)`, after, for Your server, `refuseWrongDecisionServer`: the
  decision client's identity probe (`/tokenize` must answer ModernBERT's
  `[CLS] … [SEP]`), whose sentence the form draws under its field with
  nothing written; `onUseGenerative` reads this Mac's hardware tier AT THE PRESS
  and calls `notifier.useGenerative(placement:, managedModel:, url:, model:,
  key:, clearKey:, hardwareTier:)`. Both then fire
  `supervisor.ensurePreset()`, which restarts the router only when the preset
  hash moved, and `ensure()` on the model ensurer (`modelEnsurerProvider`), so
  whatever the new placement needs and the disk lacks is downloaded.
  `onRemoveKey` is `notifier.clearRoleKey`, by target id (`box-decide`,
  `box-prose` or `cloud-drafts`).
- `onCheckDecision` is the host's `_checkDecision`: it fires
  `supervisor.ensurePreset()` so a file that landed while the app runs is
  picked up (the preset left the decision model out while its files were
  missing, so the hash moves), fires `ensure()` for whatever is still
  missing, and invalidates and re-reads `managedModelsStatusProvider`. It does
  NOT invalidate `decisionHeadsProvider`: that would rebuild the decision
  client and the triage queue under it mid-drain, and `DecisionHeadsFile`
  re-reads the heads by itself when the file's mtime changes (and never caches
  a missing file).
- `onDownloadModels` is the host's `_downloadModels`: `ensure()`, not awaited.
  `ensureState` is `modelEnsureStateProvider` (the ensurer's
  `ValueListenable<EnsureState>`), watched, so a download's percentage moves
  on the decision line while the pane is open.
- The Model registry's wires: `registryUrl` is
  `prefs.effectiveRegistryUrl`, with the presence flags `registryTokenStored`
  and `registryTokenFromBuild` (never a token). `onSaveRegistry` calls
  `notifier.useRegistry(url:, token:, clearToken:)` (which validates before it
  writes and moves the keychain before the address), returns the address
  refusal for an `ArgumentError` on the address and the writer's own sentence
  for a token no header can carry, then fires `ensure()`.
  `onRemoveRegistryToken` is `notifier.clearRegistryToken()` then `ensure()`.
  `onCheckRegistry` asks `registryProbeProvider` (`probeRegistry` in
  `services/models/registry_probe.dart`; a test overrides it) for the decide
  entry's `headsRegistryUri(effectiveRegistryUrl)`, with
  `bearerFor('model-registry')` resolved at the press, and answers
  `notConfigured` without a request when there is no address.
- `serverState` is `ref.watch(serverStateProvider)` with the supervisor's own
  field as the fallback for the frame before the stream's first value lands,
  and `modelStatuses` is `managedModelsStatusProvider` watched ONCE. Both
  watched, so a load that finishes behind an open pane moves the bar and the
  three roles' lines without the reader touching anything.
- The Cloud drafts section's wires: `cloudDraftsUrl`, `cloudDraftsModel`,
  `cloudDraftsKeyStored` and `cloudDraftsConsent` off the preferences, and
  `onUseCloudDrafts` is `notifier.useCloudDrafts(url:, model:, key:,
  clearKey:)`.
- `processingOn: ref.watch(processingProvider)`, the same value the Processing
  section's switch shows, so the status line can say the switch is off instead
  of repeating a park.
- `parked: ref.watch(parkedProvider).valueOrNull`, the whole fact rather than
  the two words the old placement block could answer for. The page decides
  which reasons it can speak to.
- `onSetUpAgain` is `restartSetup(ref)` and `onShowLog` hands
  `supervisor.logFile` to `launchUrl`. `onCloudDraftsConsent` is
  `notifier.setCloudDraftsConsent(true)`, called by the consent pane before
  the Cloud drafts connect it is standing in front of.

`managedModelsStatusProvider` reads `modelManifestProvider`, which THROWS
unless a host overrides it. Nothing breaks in a widget test that does not —
the future simply carries the error and `valueOrNull` is null, so each role's
line names the model this Mac would run and nothing more — but a test that
wants the sizes and the disk states overrides it with `testManifest()`.

**The Labels section's own wires.** Six props, all optional, all off one
`ref.watch(labelsProvider)` — which the host **watches** rather than reads, so a
label applied from a thread behind an open pane moves the use counts without the
reader touching anything:

- `labels: state.labels` — always a list, because `LabelsState.labels` is
  never null, so the section is always present in the avatar scope. `null` is
  what hides it, and only a host without the wiring (a widget test) passes
  that. An empty list renders the section saying nothing has been filed yet.
- `labelsLoading: !state.loaded` and `labelsError: state.error`. Until the
  first read lands the section draws `Loading…` under its rows rather than
  the nothing-filed line. The error is
  the same field a refused rename lands in, which is why the section draws it
  under the open field when there is one and at the top of the body otherwise.
- `onRenameLabel: notifier.rename` — it already returns `Future<bool>`, and
  false means the name is taken and `state.error` now says so.
- `onLabelToneChanged: notifier.setTone` and `onDeleteLabel: notifier.delete`,
  both fire-and-forget: the notifier writes `state.error` on a failure and the
  section is already watching it.

## Models

**Three roles, top to bottom.** The **Decision model** sorts and flags every
message; the **Generative model** writes summaries, drafts and storylines;
**Embeddings** find related messages. The first two each answer one question,
where they run: **This Mac** or **Your server**. Embeddings always run on
this Mac and are a status line only. The page is
`app/lib/widgets/settings_models_page.dart`; the one-address form it, the
Cloud drafts section and the first-run wizard all render is
`app/lib/widgets/model_servers_form.dart`.

Round H deleted the **Advanced** fold and the Local server card, and the
decision-model round made the routing a RULE (`AppPrefs.specForStage` resolves
every stage by role), so there is nothing else to show: no stage table, no
slot editors, no targets list.

**The server line comes first.** Under the heading **Model server on this
Mac**, a line keyed `settings-models-status`: `Processing is off. Turn it on
under Processing, or in the sidebar, and the work starts.` while the session's
switch is off (a park sentence promises a retry nothing makes while it is),
and otherwise the app's own server's state: `Not running`, `Starting…`,
`Loading models · N of M`, `Running`, `Not running: <reason>`, `Port <p> is in
use[ by <holder>]`, or `Servers are started by hand for this build.` on a
build that passed `BOND_DEV_HAND_SERVERS`. The embedding model is always here,
so this line always matters. Under it, a `LinearProgressIndicator` keyed
`settings-models-progress` while the server starts (indeterminate) or loads
(the fraction `ServerLoading.loaded` reports), and **Show log**, keyed
`settings-show-log`, only under a failure.

**The two placement controls** are `SettingsSegments<ModelPlacement>` keyed
`settings-decision-mode` and `settings-generative-mode`, each with **This
Mac** and **Your server**, under the captions `Sorts and flags every message.
It reads every message, so it runs on this Mac or on a server of your own.`
and `Writes summaries, drafts and storylines.`

**The segments ACT one way and wait the other.** Choosing **This Mac** on a
role that runs on your server writes it at once (`useDecision(placement:
local)` or `useGenerative(placement: local)`): there is nothing else to fill
in. Choosing **Your server** opens that role's form and writes NOTHING; the
address and the key are the rest of that answer, and **Connect** is where it
is given. Until then the role's own status says `Running on this Mac until you
connect.`

**Decision model on This Mac** is a name-and-size line (`Bond decision model ·
<size>`) and a status keyed `settings-decision-status`. The decision model is
DOWNLOADED from the model registry (the manifest's `artifactory` entry), so
the status reads `On disk · loaded` or `On disk · not loaded` once both its
files are here; `Downloading NN%` while the model ensurer is fetching it; the
download's own failure sentence (`describeDownloadError`, below) when the last
run failed for it; and `Not downloaded yet.` otherwise. Whenever it is not on
disk and no download is running, a **Download** button keyed
`settings-decision-download` sits beside the status and calls `ensure()`.
Under Your server the same rule applies to the heads file while the server is
ModernBERT (the heads run here): missing, it reads the download status and
offers **Download**. A Kev server answers there and needs no file on this
Mac, so it reads `Connected · …` without one, and a `decision_not_installed`
park left from before is treated as overtaken. While the kind is not known
yet the status says `Connected · …` too and names no download: the host is
asking. A hand-installed (`source: local`) decide entry, which a build may
still carry, keeps its own words: `Installed · loaded`, `Installed · not
loaded`, or `Not installed. Copy the model files into the models folder.`,
and no Download button. A **Check** button keyed
`settings-role-check-decision` sits beside the status: it re-reads the disk,
asks the router for the placements' preset, which is how a file that landed
while the app runs is picked up, and asks the model ensurer for whatever is
still missing. The heads file is not re-read by the button: the decision
client re-reads it on its next claim when the file's mtime has moved. The
line reads `Checking…` while it is out. A heads file that is here and
REFUSED (the older schema's, or one that does not match this build) shows
the `decision_older_model` or `decision_misconfigured` park's sentence
(below) with **Download again** beside it (`settings-decision-redownload`,
on a downloaded entry, on This Mac or under a ModernBERT Your server): it
calls `ensure(reverify: {'bond-decide'})`, so the decide entry is fetched as
though missing and the downloader HASHES the files already there, keeping a
good one without a byte fetched and replacing a wrong or damaged one. The
entry stops being current the moment the pass starts (its download rows go
back to pending until each file verifies or lands), and the router and the
heads reader use a registry entry only while its rows are current
(`DownloadLedger.servable`), so during the press, and after one that failed,
the role parks as not downloaded rather than answering from a mismatched
pair. A file proven wrong is deleted before its replacement is fetched. The
older-model park adds the quieter line `Press Download again to replace it.`
(`settings-decision-older-hint`); a hand-installed entry says `Copy the
current model files into the models folder.` instead and has no button.

**While a download is running, whoever owns it**, every missing row reads
its own entry's `Downloading NN%` (`EnsureState.fractionFor`), or plain
`Downloading` while the model ensurer waits for another owner's run (the
wizard's, still going after it was left; `EnsureState.waiting`), and no
Download or Download again button shows. A run left PAUSED is never waited
for: the wizard cancels its own paused run as it leaves the download step,
and the ensurer cancels one it finds, keeping the parts, then downloads the
rest itself. A row reads `On disk` the moment
its own entry lands, while another is still coming. After a failure whose
fix is the registry block (`registry_not_configured`, `unauthorized`,
`registry_not_found`, `registry_not_a_model`) the row says the sentence and
offers no Download: the registry's Save retries.

**Generative model on This Mac** adds a second control,
`SettingsSegments<String>` keyed `settings-generative-managed`, choosing
**Qwen3.8 27B** (`bond-prose`) or **Qwen3 4B** (`bond-bulk`) under the caption
`The 27B writes better. The 4B is smaller and faster.` On the inbox tier the
27B segment is disabled and the caption is `This Mac has too little memory
for the 27B.` A pick writes `useGenerative(placement: local, managedModel:)`
and the router follows. The status, keyed `settings-generative-status`, is
`On disk · loaded`, `On disk · not loaded`, or, when the chosen file is not
here (a newly chosen 4B on a full Mac, for one), the decision line's download
words (`Downloading NN%`, a failure sentence, or `Not downloaded yet.`) with a
**Download** button keyed `settings-generative-download` that calls the same
`ensure()`; a pick that moves the model also asks for it on its own. Until it
arrives that model is LEFT OUT of the router
(`ModelManifest.withPresentFiles`, which also drops a decision model not yet
installed, or one whose download rows are not current), so the embedding and decision models keep running and only the
generative role waits, parked on its own reason. The supervisor tells the
preferences what it serves (`setServedManagedIds`), and a managed target
naming a model left out carries the sentence `The Qwen3 4B is not downloaded
on this Mac. Open Settings, Models to download it.` (or the 27B's, or `The
decision model is not downloaded yet. Open Settings, Models.`), which the
client throws
as unavailable before any request, so the role PARKS rather than taking the
router's fatal 400.

**Embeddings** are a caption (`Finds related messages. Always runs on this
Mac.`), the name-and-size line and a status keyed `settings-embed-status`,
which uses the same download words as the other two roles (`Not downloaded
yet.`, `Downloading NN%`, a failure sentence) and, while the model is missing
and nothing is running, a **Download** button keyed
`settings-embed-download`. On a `BOND_DEV_HAND_SERVERS` build the model
ensurer does not download it (`modelEnsureSetProvider` leaves it out): `make
embed` serves it from the Homebrew/Hugging Face cache, so the block shows no
**Download** and its status reads `Served by your own embedding server.`
(the host passes `managedServer` to the page). The decision model is
still ensured there, because the app reads its heads file from the models
folder and `make decide` reads the same folder.

**Model registry** follows Embeddings and sits above **Set up again**:
`ModelRegistryForm` (`widgets/model_registry_form.dart`), prop-only, shown
while the host wires `onSaveRegistry`. Its title is `Model registry`, its
caption `Where Bond downloads the decision model from.` Two fields: `Registry
address` (`settings-registry-url`, opening on the effective address, hint
`https://artifactory.example.com/artifactory/bond-models`) and `Access token`
(`settings-registry-token`, obscured, EMPTY whatever is stored and emptied
again after a Save). The token field's hint is `Stored. Type to replace` for
a keychain token, `Using the token from this build. Type to replace` for the
build's, and `A new address needs its own token` once the typed address is
on another origin than the one the form opened on. **Save**
(`settings-registry-save`) writes what was typed: a blank token keeps the
stored one, and a typed address on another origin with no token sends
`clearToken: true`, so one registry's token is never sent to another. An
address that is not one is refused under the field
(`settings-registry-refusal`, `The address needs to start with http:// or
https:// and name a server.`) with nothing written. **Remove token**
(`settings-registry-remove-token`) shows only while a token is in the
keychain; the build's applies again when it may. **Check**
(`settings-registry-check`) asks the SAVED address for the decision model's
heads file with `Range: bytes=0-0` and says, under `settings-registry-status`,
`Registry reachable.` (200 or 206 that is not a web page), `The model
registry answered with a web page, not a model. Check its address.` (200 or
206 with `text/html`, a sign-in page), `The registry answered with a
redirect. A download will follow it.` (a 3xx, which the probe does not
follow, so the token goes nowhere else), `The model registry refused
the access token.` (401/403), `The model registry does not have this model.
Check its address.` (404), `Registry unreachable.` (anything else), or `No
registry address yet. Type one and press Save.` A Save says `Saved.` there.
An http address on a host that is not this Mac shows the quiet line `Use the
https address when your registry has one.`: a proxy that upgrades it drops
the token on the way.

**Your server, for either role, is the one-address form:**

| Control | Key | Label |
|---|---|---|
| Address | `servers-<role>-url` | **Decision model address** / **Generative model address** |
| Access key | `servers-<role>-key` | **Access key**, obscured |
| Model picker | `servers-<role>-model` | generative only, only when that server lists several |
| Model name | `servers-<role>-model-text` | only under a Converse address (cloud drafts only in practice) |
| Refusal | `servers-<role>-refusal` | under the address |
| Error | `servers-<role>-error` | under the form |
| Connect | `servers-<role>-connect` | **Connect** here, **Continue** or **Connect** in the wizard |
| Remove key | `servers-<role>-remove-key` | only with a key stored |

`<role>` is `decision` or `generative`; the Cloud drafts form uses the prefix
`cloud-drafts` (`cloud-drafts-url`, `cloud-drafts-key`, `cloud-drafts-model`,
`cloud-drafts-connect`, `cloud-drafts-error`). The status under Your server is
`Access key needed. Paste it and press Connect.` while no key is at hand for an
address that is not on this machine (a loopback address needs none; a key is
at hand when one is in the keychain, or when the build carries one and the
address has the build's origin), and `Connected · <model> at <host>`
otherwise. The generative role on Your server with NO address at all (nothing
stored, and a build compiled without `BOND_BOX_URL`) says `The generative
model has no server address. Add one under Settings, Models.`, the same
sentence its parked work carries (park word `no_address`).

**The decision server's kind** is a caption under the decision form, keyed
`settings-decision-kind`, once the host knows it (`DecisionClient.kindOf`,
filled by a Connect, by a decision against the address, or by the one
listing GET the host asks, `detectKind` with the stored key, when Settings
opens on an address this run has not seen, redrawing when it answers; and
forgotten when the server stops answering):

- `Kev 4B on your server (answers there; no files needed on this Mac)` for a
  server whose `/v1/models` lists the question hash (the systemone kind);
- `ModernBERT on your server (uses this Mac's heads file)` for a llama-server
  embeddings endpoint (the encoder-heads kind).

Before the kind is known, and under This Mac, there is no caption. How the kind is found is in
`docs/pipeline/10-model-routing.md`, "The decision client".

**The model name is DISCOVERED, never typed.** Connect probes the address's
`/v1/models` with the key; an entry is named by its `id`, or by its `name`
where it has no `id` (a Kev server's listing). One id: used. Several: a `DropdownButton` appears
with the first id filled in, the caption says `This server lists several
models. Choose one and press Connect again.`, and nothing is written until the
second press. A decision server is never asked to pick: the decision model's
own name is taken where it is listed (`bond-decide`, the box's served
`bond-decide-mbl-v3`, this build's `DECIDE_MODEL`, or the name already
stored), and the first id only when none is, so a router that lists
`bond-embed` first is not taken at its embedding model. Before it writes, the
decision Connect asks the server's kind (`/v1/models`: a Kev server must list
this build's question hash and renderer) and, for ModernBERT, its `/tokenize`
whether it is the decision model at all (see the host's `onUseDecision` above); a server that is not is
refused with that sentence under the form, and nothing is written. None, or a
server that did not answer: the `ProbeStatus` line says so and nothing is
written.

**Refusals, under the address, before any request leaves:**

- `The address needs to start with http:// or https:// and name a server.`
  for anything `isBoxOrigin` refuses.
- Generative and cloud drafts: `The address needs to be the chat completions
  endpoint, ending in /v1/chat/completions.` when the path has no `/v1/`
  (a Converse address excepted).
- Decision: `The address needs to be the embeddings endpoint, ending in
  /v1/embeddings, or a Kev server's, ending in /v1/systemone.` unless the path
  ends in `/embeddings` or `/v1/systemone`.
- A third-party host (`isThirdPartyHost`: Bedrock, anthropic.com, openai.com,
  deepseek.com) or the Converse wire on a ROLE is refused outright, because
  both roles read every message: `The decision model reads every message, so
  it runs on this Mac or on a server of your own.` under the decision field,
  and `A cloud service can write drafts only. Set it up under Cloud drafts.`
  under the generative one. Nothing is sent to it, the stored key included.
  `useDecision` and `useGenerative` throw `ArgumentError` on the same address
  as their last line.

Typing anywhere in the form drops every answer from the last press and
invalidates it: a press outlived by an edit writes nothing, on `_connectSeq`.

**A connect that does not land says so**, under the form, keyed
`servers-<role>-error`: the `ArgumentError`'s own message for a refusal, and
`The server could not be saved. Try again.` for anything else (a locked
keychain answers the write with a `PlatformException`).

**The key.** The field opens EMPTY, always. When one is in the keychain it
carries the hint `Stored. Type to replace` and Connect goes through with the
field blank, the probe borrowing the stored token by id (`storedBearer`), never
by value. When the keychain holds none but the build was compiled with
`local.mk`'s `BOND_BOX_KEY` and the address has the build's origin
(`keyFromBuild`), the hint is `Using the key from this build. Type to replace`,
**Remove key** is not shown (there is nothing in the keychain to remove), and
Connect borrows the build's key the same way, by id; on another origin the
hint goes, nothing is sent and there is nothing to forget, because the build's
key only ever applies to the build's own origin. A typed key stored in the
keychain beats the build's, and **Remove key** returns to it. **A key belongs to the host it was typed for.** When the typed
address names a DIFFERENT origin from the stored one (scheme, host or port;
`https://h` and `https://h:443` are one origin), the hint becomes `The
stored key is for another server. Type this server's key.`, the probe goes
without the stored token, and a Connect with the field still blank passes
`clearKey: true`, which makes `useDecision` / `useGenerative` forget the
role's keychain entry, cache and flag (`clearRoleKey`) rather than keep a
token for another machine. Otherwise a blank field keeps the stored key, and
**Remove key** is the only other thing that forgets one. The key lives in the
form's `TextEditingController` and, for a Cloud drafts connect waiting on the
consent pane, in the `resume` closure that pane holds; it is emptied the
moment a connect lands and is never in a widget field after a save, a probe
result, a log line or a test name.

**Parks are said under the role they are about**, when processing is on and
something is waiting: `decision_unavailable` under the Decision model (`The
decision model is not answering. Work is waiting and will retry each
minute.`), `embed_unavailable` under Embeddings (`The embedding model on this
Mac is not answering. Work is waiting and will retry each minute.`), and
`model_unavailable` (`Your server is not answering. Work is waiting and will
retry each minute.`) and `unauthorized` (`Your server refused the access key.
Change it here.`) under the Generative model while it runs on your server.
With the generative model on this Mac the server line above already says what
the router is doing, and the rail says `Model server unreachable`.
`decision_not_installed` (the download status above: `Downloading NN%`, the
failure sentence, or `Not downloaded yet.`, with **Download**; for a
hand-installed entry `Not installed. Copy the model files into the models
folder.`), `decision_misconfigured` (`The decision server is not the
decision model, or its heads file does not match this build. Check its
address here, or press Download again.`, or for a hand-installed entry `…
or copy the current model files into the models folder.`, with no retry
promised),
`decision_older_model` (`The installed decision model is an older version
that this app no longer reads. Install the current decision model to resume
sorting new mail.`, plain words with no command, and under it one quieter
caption keyed `settings-decision-older-hint`: `Press Download again to
replace it.`) and `decision_unauthorized` (`The decision server refused the access
key. Change it here.`) are said under the Decision model whatever the
generative placement. A `decision_not_installed` park that the download has
overtaken (on this Mac, the GGUF and the heads file both on disk) reads `On
disk · loading` (`Installed · loading` for a hand-installed entry) until the
router serves it, rather than the missing line, because the park clears only
when triage next drains. `not_installed` (the managed generative model, which
the router does not serve because it is not on disk) is said on this Mac's
server line instead of the router state: `A model this Mac runs is not
downloaded. Press Download to get it.` A park word this page cannot answer
for, such as a sign-out, is left alone.

**The server follows the placements.** Every placement write is followed by
`ModelServerSupervisor.ensurePreset`, from the host and from the wizard's
Finish; the preset is embeddings plus the decision model when it runs here
(and is installed) plus the chosen generative model when it runs here. It
restarts only when the preset hash changed.

**The weights a switch left behind.** With the generative model on your
server and its managed file still on disk, a caption keyed
`settings-idle-models` under its status says `<name> · <size> · on disk · not
loaded`, so a person who has just switched sees the memory come back and the
download stay.

**Set up again**, keyed `settings-set-up-again`, sits at the foot of the
section. It is how the models folder changes and a download is retried, now
that the Local server card is gone.

It stashes a `done` that was there into `SetupStore.previousSetupKey`, clears
`setup_state` EXCEPT `SetupStore.keptOnRestart` — the container-migration
record, the download ledger and that stash — and then bumps
`setupRestartProvider`, which is what `SetupGate` re-decides on. The kept keys
are the point: starting over must not re-copy a mailbox that is already here or
re-download twenty-three gigabytes that already are. So the wizard opens at
**Welcome to Bond** with the models still on disk and the session still signed
in, and those two steps are a **Continue** each. The order matters and is
pinned by `setup_reentry_test.dart`: the keys go first, because the gate
re-reads the store the moment the counter moves.

**It is not a one-way door.** With the stash present the welcome step draws a
secondary **Back to the inbox** under **Get started**
(`SetupWelcomeBody.onReturnToInbox`, null on a first run — there is no inbox
behind THAT wizard). Pressing it calls `SetupController.returnToInbox`, which
writes `setup = 'done'` back, removes the stash and hands control to the gate
through the same `onFinished` callback Finish uses. A download this run started
is left running, on the controller's dispose reasoning: the run outlives the
screen, and cancelling one an hour in would be a steeper price than the button
implies. `finish()` removes the stash too, so a second run that was seen
through to the end leaves nothing behind.

**The probe's lifetime is the host's.** `_SettingsHostState` holds one
`ModelServerProbe`, built on first use and closed in `dispose`. A client per
button press would leak a connection pool per press, and this is a button a
user can hammer.

## Cloud drafts

**The one place a cloud service may write, and only the drafts.** A section
of its own beside Models, rendered when `onUseCloudDrafts` is wired. A caption
(`Suggested replies and Improve a draft can go to a cloud service. Everything
else stays on the Decision and Generative models.`), a line keyed
`cloud-drafts-target` naming the target in force (`Drafts go to <model> at
<host>.`, or `No cloud drafts. Drafts are written by the generative model.`),
then the one-address form with the `cloud-drafts` keys. Connect writes
`useCloudDrafts(url:, model:, key:, clearKey:)`, which routes `draft_reply`
and `draft_improve` there and nothing else.

**A third-party address asks first.** When the address is a vendor's or a
Converse host, the form raises `onThirdParty(spec, resume)`; the screen opens
the **Cloud drafts** consent pane in place of the sections. **Continue**
records the consent and THEN calls `resume()`, the same connect with the same
values: that order is the protection, because `useCloudDrafts` refuses a
third-party address while the flag is false. **Not now** and **Back** close
the pane and write nothing. A connect that refuses keeps the pane open with the
reason on it. An owner who has already consented connects without being asked
again; the owner's own server never asks. With no `onCloudDraftsConsent`
wired the form refuses a vendor with `Cloud services are connected under
Settings after setup.` instead: a question that can only be answered wrong is
worse than no question. A Converse service lists no models, so it gets a
typed **Model** field.

**Stop sending drafts anywhere** stays under Processing, and
the section says so.

**What pins all of this.** `model_servers_form_test.dart` for the form,
`settings_models_page_test.dart` for the page, `probe_status_test.dart` for the
three outcomes of a look at a server, `settings_models_host_test.dart` for the
wires (Connect per role, the managed pick, Check calling `ensurePreset`), and
`settings_cloud_drafts_test.dart` for the Cloud drafts section and the consent
pane through Connect.

## Suggested replies

When a reply is written **without anyone asking**. Three segments and a
sentence, between Needs You and Notifications, in **both scopes** — how much of
the generative model's time a backlog spends on replies nobody will read is a fact
about the model, so the AI stop is where someone would look for it.

| Segment | Stored `suggested_replies` | What extraction queues |
|---|---|---|
| **Needs you** | `needsYou` | the messages judged to need the owner, at most ten in flight — **the default** |
| **All** | `all` | every message that looks like it wants a reply |
| **When asked** | `onDemand` | nothing |

The caption says it in the same words:

> Needs you writes a reply ahead of time for messages judged to need you, at
> most ten at a time. All drafts every message that looks like it wants a
> reply. When asked writes nothing until you press Draft reply, which works in
> every mode.

That last clause is the one that has to be there: **Draft reply** is offered on
every thread in every mode, so "When asked" is a choice about prefetching, not
a way to turn drafting off. A draft a person asks for also skips the reply
decision — pressing the button is that decision — so it arrives about five
seconds sooner. The cap is soft: extraction drains three wide, so twelve is the
real ceiling rather than ten.

Under the segments is one switch, **Improve drafts for messages that need you
and are urgent** (`settings-cloud-standing`, stored `cloud_drafts_standing`,
default off). It is the standing rule: after a local draft is written for a
message at or above the Needs You slider (`needsYouAt`), with `urgency`
`urgent` or `high`, the same prompt goes again to whichever target the
**Improve a draft** stage points at, and that answer replaces the draft. It
needs such a target to be turned on at all — without one the switch is inert
and the caption reads *"Improve a draft has no server to run on. Check the
Models section."*; with one it names it: *"After the local draft is written, the same
prompt goes to `<name>` and its answer replaces the draft. Counts toward the
daily cap under Processing."*

The mechanism, the two pre-gates, the Improve button and the activity notes
are in [pipeline/07-replies.md](pipeline/07-replies.md), "When a draft is
written" and "Improve a draft". The policy control is
`SettingsSegments<DraftPolicy>`, the same widget Notifications and the Models
page's two modes use.

## Processing

Whether this install runs model work at all, and the two ways to throw away
what it has already produced. In both scopes, because all three are questions
about the model rather than about the app.

**AI processing** is the same switch as the one at the top of the sidebar,
drawn here as a `Switch` keyed `settings-processing-toggle` beside its name and
the word `On` or `Off`. It is REMEMBERED and it starts OFF: a fresh install
opens with the models idle, so the servers, the downloads and the keys can be
checked under **Models** before anything is spent, and the owner turns it on
once they are; a machine somebody turned on comes back on, and one stood down
comes back down. The preference is `processing_on`, and only the string
`true` reads as on (decision D8 of the default-setup round, 2026-10, with no
migration: an install that never touched the switch starts off once). It was
session state, off at every launch, until Round H, and a remembered switch
that started on from then until the default-setup round. Turning it off still
stands every drain down for the rest of the session. Flipping it here moves the
sidebar behind the pane, so the host hears about it the instant it moves rather
than on the way out. Mail and Teams keep syncing while it is off; only the
models stand down. See
[pipeline/10-model-routing.md](pipeline/10-model-routing.md).

Under it are three controls, a revoke and two resets, each an inline two-step
in the shape **Sign out and clear local data** and **Clear attachment cache**
already use: the first tap replaces the button with a red **Confirm: this
cannot be undone** beside a **Keep**, and the second click therefore lands on
a different button, in a
different place, that did not exist a moment ago. A failure renders as an
`InlineAlert` with the pair still up; **Keep** disarms and drops the failure
with it.

| Action | Keys | What goes | What stays |
|---|---|---|---|
| **Stop sending drafts anywhere** | `settings-stop-cloud-drafts{,-confirm,-keep}` | the cloud-drafts target (its address, its model and its `cloud-drafts` key) and then `cloud_drafts_consent`, so both drafting stages resolve to the generative model again | every row, and the Decision and Generative models' own settings and keys |
| **Clear AI results** | `settings-clear-ai-results{,-confirm,-keep}` | every triage verdict, summary, storyline, draft, digest and embedding — the seventeen `MessageStore.derivedTables`, the verdict columns on `messages` and `conversations`, and the stage markers on `attachments` and the library; the activity log is one of the seventeen, so today's **Cloud drafts** count starts again at zero, which the caption above the buttons says | mail, Teams messages, attachments, registered directories, the owner's storyline presses logged as labels (`decision_labels`, a kept table), the sign-in and every preference |
| **Forget everything and re-sync** | `settings-forget-resync{,-confirm,-keep}` | everything above **and** the mailbox itself — `MessageStore.wipeAll(keepIdentity: true)`, cursors and bootstrap floors included | the sign-in, the about-me text, the sender rules, the registered directories and every setting |

**Stop sending drafts anywhere** is the one-button revoke, in the same
two-step and above the two resets. It makes its writes in one order that
matters: `clearCloudDrafts()` (address, model and key), then
`setCloudDraftsConsent(false)`. The target goes first and the flag last, which
is the grant's order reversed, and for the grant's reason: `AppPrefs
.specForStage` sends the drafts to the generative model once there is no
cloud-drafts target, so they are already home by the moment consent goes.

Both drafting stages fall back to the generative model, never a third-party
address, since that is the operator the withdrawal just refused. It is
**not** refused while processing is on, unlike the two resets it sits above:
it writes preferences and touches no rows, so there is no drain it could race,
and somebody who has just realised their drafts are leaving the machine should
not have to find a switch first. Granting
again is the consent pane, one screen, so the second button says
`Confirm: this cannot be undone` for the reason both resets do rather than
because this one cannot be redone. The standing switch under Suggested replies
stops the automatic improves alone and leaves the rest.

Above the two resets, once the host has a count, is the cloud-draft ledger:
one line **Cloud drafts today: N of cap** (`settings-cloud-ledger`) and a
compact numeric **Daily cap** field beside it (`settings-cloud-cap`, stored
`cloud_drafts_daily_cap`, default 50, clamped 1..1000, committed on Enter and
on losing focus, an unreadable entry ignored). N is
`MessageStore.cloudDraftsSince(local midnight)` — the sum of the `cloud`
counts on today's `draft` and `draft_improve` activity rows, re-read on every
recorded event — so it covers all four doors a draft can leave by: the
Improve button, the standing rule above, a prefetched draft on a draft stage
pointed at a third-party target, and a draft a person presses for on such a
stage, which the composer refuses before anything is queued. Nothing more goes
once the count reaches the cap, and each of the four refuses with the same
sentence. The cap in force is also the
number the consent pane quotes before the first draft ever leaves.

**Both resets are refused while processing is on.** Their buttons are inert
and the caption under them says `Turn processing off first`; the host refuses
again for itself, because a reset races every drain it does not stop. With the
switch off, each handler quiesces the triage queue, all three lanes and the
draft handler — which is "finish the item at the server, then hand the claim
back", not merely "stop" — runs the store's reset, calls
`resetInterruptedWork`, and invalidates the sixteen providers holding rows in
memory. The draft handler is the fourth because `DraftHandler.improve` is a
button press rather than queue work, so the draft lane's own quiesce knows
nothing about it.

**Clear AI results queues the whole rerun itself**, in the transaction that
empties the tables: extraction, the needs-you judgement and the embedding for
every kept message of every source, unpaced and regardless of **How far back
to sync**, plus one `attachment_text` row per attachment left pending. That is
why its caption promises everything already synced rather than a slice a poll.
The sync's own backlog calls are bounded by the lookback floor — right for a
poll, wrong for a reset, which is the one path that re-pends mail older than
the window — and they still run on every pass, idempotent over what the reset
filed. **Forget everything and re-sync** queues nothing: it deletes the
mailbox, then starts the mail pull and the Teams pull together, through the
inbox's own refresh (`SettingsHost.onRefreshNow`, the Sync button's path,
which raises both pull flags a later reset waits out), so the window is
fetched again at once and ingest queues what it brings. Teams goes with mail because the minute
poll pulls mail only — without it a cold start's chats waited for a refresh
press or a resume and landed minutes behind the mail. See
[pipeline/01-sync-ingest.md](pipeline/01-sync-ingest.md).

**What the owner decided by hand survives a clear.** A message they restored
keeps its `gate_override`, and one they ignored keeps `gate_reason = 'user'`
and stays out; both are the owner's own hand on the gates, and nothing
recomputes either on a later triage claim. The gate verdicts written at ingest
survive too (`outbound`, `backlog`, and Teams' `auto_generated` and
`teams_source`); every other gate reason is cleared and re-derived on the next
claim.

**Everything comes back on its own**, each by the path that would have
written it the first time. Extraction, the needs-you judgement and the
per-message embedding are queued by the clear itself, for every kept message
and whatever its date; storylines ride the sync's `requeueSweep()`, drafts are
written when a thread next asks for one, and the library rides the reconcile,
which is requeued per directory on every sync. Attachments are the one kind
with no backlog call anywhere: `attachment_text` is enqueued at ingest, by a
detail fetch and by Restore, and a message already stored with a body reaches
none of the three, so the clear writes one `attachment_text` work row per
attachment left `pending` and the digest follows the text pass. A refusal is
not re-queued, because "too large" and "not text" are verdicts about the file
rather than about the model that read it.

**A marker that outlives its rows is the trap** the clear has to avoid, and
three of them are handled inside the same transaction. `message_progress` is
emptied and rebuilt from `messages` in the same breath, because every stage
writes that table with an UPDATE and only the ingest ever inserts — left
empty, the home feed would stay empty until the mailbox was fetched again.
`attachments.text_status` and `digest_status` go back to `pending` wherever
they said `done`, or the handlers would skip files whose words have just been
deleted; a refusal stays refused, because that is a verdict about the file
rather than about the model. And `context_files` loses `size`, `mtime` and
`sha256` along with its digest columns: they are the reconcile's cheap diff,
and a file whose stat still matched would never be opened again.

## Sync & data

**How far back to sync** sits at the top of the body, above the stamps, because
it is the question they raise: somebody reading when the last pull ran is asking
how much of their mail is in here. One `LookbackField`
(`app/lib/widgets/settings_lookback_field.dart`) per connector — `Mail` and
`Teams`, keyed `settings-mail-lookback` and `settings-teams-lookback` — each a
dropdown of day presets (**1 / 7 / 14 / 30 / 60 / 90**) plus **Custom…**, which
reveals an inline `YYYY-MM-DD` field prefilled with the day the current window
reaches. **Not a `showDatePicker`**: that is a dialog, and `no_dialogs_test.dart`
now fails on it too.

Both sides default to **one day**, which is the value that applies where
nothing is stored: a first sync on a new machine is a morning's mail, and
somebody who wants history raises it here. A mailbox that already stored a
choice keeps it.

Under the control, in every mode, is the line the setting exists for:
`Last 14 days · since Aug 22, 2026`, or `Last 1 day · since …` at the default.
A day count is a span; the thing a person
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

**Syncing is not processing.** Mail and Teams keep pulling while the **AI
processing** switch at the top of the sidebar is off — the inbox stays current
and the models stay idle — so a window widened during an off session is
fetched, stored and left waiting for the switch. The rail's caption says how
many are waiting. See
[pipeline/10-model-routing.md](pipeline/10-model-routing.md).

**The collapsed summary deliberately says nothing about it.** That line answers
"is what I am looking at current?", which is a question about the stamps; adding
a second clause about the window would make the summary two reports instead of
one, and the table above is pinned verbatim by tests either way.

The four stamps — `Mail`, `Mail reconcile`, `Teams`, `Storyline sweep` — come
from `syncStampsProvider` (`app/lib/providers/activity_provider.dart`), which
`SettingsHost` **watches** — it re-reads on every recorded event, so a sync
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
  passages nearest the question, and it is one extra generative-model call per
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
  earns one generative-model digest, which is what makes a question about *findings*
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


## Labels

The owner's own vocabulary — the words a person files their own threads under —
and the one place a label can be renamed, recoloured or thrown away. Putting a
word ON a thread happens on the thread; this section is the dictionary behind
that.

It is **not** `messages.label`, the model's verdict about one message. Nothing
the pipeline writes appears here, which is why the section sits in the
avatar-menu scope and **not** in the AI pane: a vocabulary somebody typed is not
a thing about the model, so it would answer the wrong question there.

Its own widget — `app/lib/widgets/settings_labels_section.dart` — in the
`ContextDirectoriesSection` shape: it owns which row has its name field open and
which row is asking a second time about Remove, and it builds its own
`SettingsSection`. Prop-only, so a test drives the whole section with a list of
labels and three closures.

The body opens with one sentence saying the words are the reader's own and that
a rename keeps every thread the label is already on. Then one block per label,
in the provider's order (**most used first**, which is the order the picker
offers them in too):

- A **tone swatch** and the **name**, in the owner's own casing.
- **`Used 9 times`**, or **`Not used yet`** for a word nobody has reached for.
  It is a popularity signal rather than a refcount — taking a label off one
  thread does not decrement it — which is what makes the ordering stable.
- **Rename**, which opens a field on the current name in place. Save closes it;
  a name already taken comes back refused, and the refusal is drawn **under the
  field** in the provider's own words with the field still open on what was
  typed. There is no dialog to refuse in, and retyping a name to find out it is
  still taken is the one thing an inline refusal exists to avoid.
- The **tint**, a `SettingsSegments<BondTone>` shown only **while that row is
  being renamed**: five segments per row would be five rows of buttons on a
  vocabulary of five words, and the swatch beside the name is what a reader
  needs the rest of the time. The five choices are Stone, Sea glass, Moss,
  Copper and Clay (`BondTone.neutral` through `error`). Choosing **Stone**
  clears the stored word rather than storing `neutral`, so a label with no tone
  and a label set back to plain are not two different rows in the table.
- **Remove**, the inline two-step every destructive control on this screen
  uses: the first tap replaces the button with a red **Remove label** beside a
  **Keep**, so the second click lands on a different button that did not exist a
  moment ago. The caption names what goes: `Removes the word and takes it off
  every thread it is on. The threads themselves are untouched.` The provider
  cascades the links; no message, thread or verdict is touched.

There is no **Add label** here, deliberately. A label is minted where it is
first needed — on a thread, from the picker — and a dictionary that could grow
words nothing is filed under would fill up with them.

The picker (`app/lib/widgets/label_picker.dart`) ranks an exact,
case-insensitive name match first, and Enter applies the top match. When the
typed word is not an existing name, a trailing `Create "<word>"` chip
(`LabelPicker.createChipKey`) is offered after the matches, so a word that is
only part of an existing label, "Vendor" beside "Vendor outreach", can still
be minted. A name containing a double quote is refused with `A label can't
contain a quote mark.`, because the `label:` facet in Find quotes a spaced
name with `"` and could never quote it back. The picker says so on its hint
line, and the store refuses the same name on create and on rename
(`createLabel`, `renameLabel` in `message_store.dart`). Minting closes the
picker and hands focus back before the write, so the new label files the
thread it was minted for even if the reader has moved on; until the create
settles the strip is busy and ignores every way out.

Nothing here reaches for a provider: the section takes a list and three
closures, and the host wires them to `labelsProvider`.


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

### Updates

Between the version line and the database block sit three controls, each wired
independently and each absent when its wire is null — the visibility rule for
the **section** is unchanged (`appVersion` or `databasePath` known, and never
under the AI scope):

- **`Check for updates`**, an `OutlinedButton`
  (`SettingsScreen.checkForUpdatesKey`), with a caption beside it reading
  `Last checked <relative>` or, when nothing ever has, exactly
  `Never checked for updates`.
- **`Check for updates automatically`**, a `SwitchListTile` subtitled
  `Bond looks once a day and asks before it installs anything.`
- The sentence `Updates are not configured in this build.`, when the updater
  could not start.

**Sparkle owns both values.** The automatic-checks preference and the
last-check time are Sparkle's, not this app's: the switch shows what the
updater answers, and the host `ref.invalidate`s `updaterStatusProvider` after
every move rather than keeping a local copy that could disagree. The screen
never flips the switch itself.

The wiring is `updaterProvider` / `updaterStatusProvider` over
`ChannelUpdater` (`app/lib/services/system/updater.dart`), and the host passes
the two callbacks **only** when the status says `available` — a control that
could not do anything is worse than no control.

**A development build shows the sentence and neither control**, and that is
correct rather than broken: `SUFeedURL`, `SUPublicEDKey`,
`SUEnableAutomaticChecks` and `SUScheduledCheckInterval` are written into
`Info.plist` by `dist/bundle.sh` at package time, so no `flutter run` build has
them. A widget test is different: the channel call never comes back inside
the fake-async zone, so `updaterStatusProvider` stays loading and About renders
**no update rows at all**. A test that wants a verdict overrides
`updaterProvider` with a fake (`settings_models_host_test.dart` does both:
a fake that answers, and `NullUpdater` for the not-configured sentence).

Everything after the button is **Sparkle's own window**: the release notes, the
download, the relaunch. It is the one non-Flutter surface in the app and it is
deliberate — the no-dialogs rule is a rule about Flutter screens, and
`test/no_dialogs_test.dart` scans `lib/`, where there is nothing to find
because Sparkle is Swift. Sparkle never checks on a first launch.

The full story — key generation, hosting, the release step that regenerates the
feed — is [distribution.md → Updates](distribution.md).

## First run

Before the sign-in gate and after the server bootstrap sits `SetupGate`
(`app/lib/screens/setup/setup_gate.dart`), which chooses the first-run wizard
or the rest of the app from one stored word — `setup_state['setup']`, holding
a `SetupStep.name` — and one check against the manifest. `'done'` is the only
value that lets the app through, AND the download ledger must describe the
three checkpoints this build ships and the writing model's MTP head
(`DownloadLedger.matches`, which wants the `bond-prose.draft` row as well as
`bond-prose`): a manifest bump that keeps the file names would otherwise leave
a machine serving the previous weights for ever, since nothing downstream
compares digests. A bumped digest
sends the wizard back to its **download** step, where `_onEnter` fetches what
has moved. Only the GATING entries decide it (`ModelManifest.gating`, the
Hugging Face files, decision D7): a model registry file that is missing or
failed never reopens the wizard, it parks its role and the model ensurer
fetches it. The gate answers ONCE, on `AuthGate`'s pattern, and re-decides
only when the flow reports itself finished or when **Set up again** bumps the
counter. Once its answer arrives it writes `setupShowingProvider` (true while
it shows the wizard, false once it shows the app; written in the callback the
answer lands in, never during a build), and whenever it lets the APP through
(a launch, the return after Finish or **Back to the inbox**, and
`BOND_DEV_SKIP_SETUP`) it kicks `ModelEnsurer.ensure()`, unawaited. When it
shows the WIZARD (and at once on **Set up again**) it raises the flag and
calls `ModelEnsurer.standDown()`: a run the ensurer owns is cancelled with
its parts kept, and the wizard's own run resumes from the byte. While the
flag is up the ensurer starts nothing.

`SetupFlow` (`app/lib/screens/setup/setup_flow.dart`) is the only file in the
flow that touches a provider. Every step body is prop-only, the settings
bodies' discipline: the host reads `setupControllerProvider`
and hands down values and closures, and a null callback hides its control.
One `PaneSurface`, whose title is the step's and whose trailing slot reads
`Step N of 9`. The back arrow is `null` on the first step — which is why
`PaneSurface.onBack` is nullable and renders DISABLED rather than absent.

| # | Title | Primary button | What it does |
|---|---|---|---|
| 1 | Welcome to Bond | `Get started` | What Bond is; the container-migration line when there was one |
| 2 | Your Mac | `Continue` | Chip, memory, macOS, and which models this Mac takes. Intel or Rosetta renders **no** button at all. At 40 GiB and up, one line: `This Mac can run every model: the decision model, the embedding model and the 27B generative model.`; below it, an alert naming the memory, saying this Mac runs the decision model, the embedding model and the 4B as its generative model, that the 27B is not downloaded here, and that a server of the user's own under Settings, Models is how to write with it. Under 16 GiB the same alert gains one sentence about slower triage. All of it is a warning that still continues |
| 3 | Where the models run | the generative form's `Continue`, or the step's `Continue` under This Mac | The same two questions the Models page asks, answered by the same form. `SetupWhereBody` is two roles of two cards each: **Decision model** with **This Mac · recommended** (`setup-where-decision-managed`) and **Your server** (`setup-where-decision-custom`), then **Generative model** with **This Mac** (`setup-where-managed`) and **Your server · recommended** (`setup-where-custom`), and a note that the embedding model always runs on this Mac. The DEFAULTS are the stored answers: the decision model on this Mac, the generative model on Your server whatever the build (`defaultModelPlacement`, decision D9 of the default-setup round), its form prefilled with `…/prose/v1/chat/completions` when the build carries `BOND_BOX_URL` and empty otherwise, with the hint `Using the key from this build. Type to replace` when the build carries `BOND_BOX_KEY` too. Generative This Mac shows `SettingsSegments<String>` keyed `setup-where-generative-model` with **Qwen3.8 27B** | **Qwen3 4B** (the 27B disabled on the inbox tier with `This Mac has too little memory for the 27B.`); the pick is `SetupState.generativeManaged` and decides what the download step fetches. Decision Your server renders the decision form with **Connect**: it writes `useDecision(box, …)` at once (`SetupController.connectDecision`) and stays, then says `Connected · <model> at <host>` (`setup-where-decision-connected`); until then the way forward is disabled and says `Connect the decision server first, or choose This Mac for it.` Generative Your server renders the generative form with `connectLabel: 'Continue'` and `onThirdParty: null`, so its press IS the way forward: it probes with the typed key (or the stored one by id, same host only), takes the listed name, refuses a vendor with `Cloud services are connected under Settings after setup.` (the decision form refuses one with its own role sentence), and calls `continueFromWhere(generative:)`, which checks the decision role, writes `useGenerative(box, url, model, key, clearKey, hardwareTier)`, writes `useDecision(local)` when the decision model stays here, and moves to Models. Under This Mac the step's own Continue calls `continueFromWhere()`, which writes `useGenerative(local, managedModel:, hardwareTier:)` with this Mac's HARDWARE tier. Both KEEP the stored addresses and keys: changing where the work runs is not forgetting how to reach the servers |
| 4 | Models | `Continue` | The RESOLVED manifest's downloadable rows — name, role sentence (`Finds related messages`; both chat models `Writes summaries, drafts and storylines`), size, licence button, and any `notice` verbatim — and the total. With the decision model on this Mac it is an ordinary download row from the model registry (its size counts the heads file, and it is in the sentence and the total). The first sentence names no source, because the set mixes the hub and the registry: `Bond downloads N models. They run on this Mac and never send your mail anywhere.` (`one model. It runs …` for one). Only a hand-installed (`source: local`) decide entry is listed apart (`setup-models-decision`) with `Installed` or `Not installed. Copy the model files into the models folder.` in place of a size, counting toward neither. Three rows on a full Mac that chose the 27B with the decision model here (the 27B's row says `+ MTP head, 1.6 GB` under its size), two when the generative model runs on your server (embed + decide), one when both roles do |
| 5 | Storage | `Continue` | The effective folder, **Change folder…**, and `checkDisk`. Dead until the preflight answers and passes; free space that could not be asked counts as passing, a folder that cannot be WRITTEN does not — `Bond can't write to this folder. Choose another one.` |
| 6 | Download | `Continue` | One bar per MODEL this Mac's tier wants, smallest first, under the caption `The models arrive one at a time, smallest first.` — the writing model's MTP head and the decision model's heads file ride on their model's bar rather than taking one of their own, so the bar counts both files and finishes once. Enabled when every GATING (Hugging Face) file is done — see below. A model registry row never holds Continue (decision D7): a failed one shows its `describeDownloadError` sentence and under it `Bond tries again after setup, and under Settings, Models. You can continue.` (`SetupDownloadBody.registryLaterText`), the button offers `Try again`, and `All models are on this Mac.` waits for every row. When another owner's run holds the downloader as the step is entered (the model ensurer's, cancelled as the wizard opened), the step reads as in progress with `Finishing the download already running, then starting.` and no buttons, waits for `ModelDownloader.idle`, then starts its own run, resuming from the kept parts. A PAUSED run is never waited for: one found on arrival is cancelled at once, and leaving the step with this step's run paused (Continue, Back, Finish, Back to the inbox) cancels it, parts kept, so the model ensurer resumes it after setup |
| 7 | Sign in | `Continue` | `SignInBody(showTitle: false)` when signed out (signing in advances, and there is no Continue); `You're signed in.` and a Continue when already signed in |
| 8 | Notifications | `Continue` | The press IS the ask. Exactly one button, and the word `Allow` appears nowhere — macOS is about to put its own Allow up |
| 9 | All set | `Finish` | Folder, port, account, notifications, then this Mac's tier defaults on the local placement only and `setup = 'done'`, and only then the server. Nothing writes `managedServer`: it is a build define since Round H. It does not touch processing either: that is a remembered preference and it starts off, so a finished wizard leaves the models idle until **AI processing** is turned on |

**`'done'` is written by Finish and by `returnToInbox`, and by nothing else.**
The second writer never INVENTS the word: it only puts back a value
`finish()` had written, stashed by **Set up again** at the moment it cleared
it. Arriving at **All set**
records `notifications` — the step BEFORE it — because `'done'` is the gate's
sentinel: a quit on the last screen would otherwise let the next launch
straight past the gate with no wizard left to walk. A relaunch lands on Notifications instead, whose Continue re-asks
(macOS answers a settled prompt instantly) and leads back to All set.
`SetupController.finish` returns whether BOTH writes landed; false keeps the
wizard on the screen with `Setup could not be saved. Try Finish again.` above
the button, because leaving for the inbox on a half-written finish would be the
app claiming a setup that is not on disk. On a finish that DID save, the server
is asked for fire-and-forget on `ServerBootstrap`'s reasoning — and it is
`restart()` rather than `ensureRunning()` when the models folder moved during
the run OR when any file reached `done` while the wizard was open, since
`ensureRunning` returns at once on a server that is already up: the preset
hash it compares covers paths and arguments rather than digests, so the router
would go on mmap'ing the copies in the old folder, or the weights the run has
just replaced.

**Changing the folder ends a run in flight.** `SetupController.setFolder`
cancels the downloader before the preference moves, because `ModelDownloader`
reads the folder once per run: a transfer left going would keep filling the
folder the user has just left. The parts stay where they are, exactly as a
Cancel leaves them.

**Continue on the download step waits for every GATING file this Mac's tier
asked for** (`SetupState.downloadsComplete`, over `resolvedManifest.gating`:
the Hugging Face entries, the writing model's MTP head included) and not for
`ModelManifest.usableIds` (embed + bulk, informational and gating nothing):
finishing early would leave a non-engineer looking at an idle inbox with no
progress bar left to explain it. The model registry's decision model is
best-effort (decision D7): its address is fixed in Settings, which the wizard
cannot reach, so a registry file that failed or is still missing does not
hold Continue, and the model ensurer retries it once the app shows. A
separate `SetupState.allDownloaded` (every row, registry included) decides
whether arriving at the step starts a run, and whether the step says every
model is here. `SetupController.startDownload` awaits the prefs notifier's
`ready` before the run (`prefsReady`), so a STORED registry token is in the
cache the downloader's lookup reads.

**`--dart-define=BOND_DEV_SKIP_SETUP=1`** skips the wizard entirely
(`SetupGate.skipDefine`). It is for the engineers who run `make model fast
embed` by hand: their models are in the Homebrew cache rather than this app's
folder, and a wizard offering to download models they already have would be
in the way of every `make app-run`. A define rather than a
preference because it describes the BUILD, not the person — `local.mk` passes
it through (see QUICKSTART step 3, "Skipping the wizard"). The models still arrive: the gate lets
the app through and kicks the model ensurer, which downloads in the
background whatever the placements need and the disk lacks, and Settings,
Models shows each one's progress.

**The notifications ask happens once.** `SetupController.continueFromNotifications`
calls `DesktopNotifier.ensureAuthorized`, then seeds the answer into
`DesktopNotificationService.seedAuthorization` so the first settled message
does not raise a second system prompt. A denial keeps the user on the step
exactly once, so the sentence naming System Settings is read; the next
Continue moves on. A seeded denial is memoized in memory and nowhere else —
the next launch asks again, which is what makes re-granting in System Settings
work with no stored flag to clear.

**Which tests pin which strings.** `setup_step_test.dart` — the nine titles,
the stored names, the counter. `setup_welcome`/`device`/`models`/`storage`/
`download`/`notifications` bodies are pinned by `setup_device_test.dart`,
`setup_models_test.dart` (including the committed Gemma notice, read off the
real asset), `setup_storage_test.dart`, `setup_download_test.dart` (both
`describeRemaining` and `describeDownloadError` tables) and
`setup_notifications_test.dart` (one button, `Allow` nowhere).
`setup_flow_test.dart` walks all nine and pins `Step N of 9`, the persisted
step and the disabled back arrow, and its `Where the models run` group pins the
two cards, the form preselected on a compiled address, the refusals under the
field, and what each Continue writes; `setup_gate_test.dart` pins which screen a
launch gets, the manifest bump included; `setup_controller_test.dart` and
`setup_resume_test.dart` pin the behaviour under the screens — the resume at
a `.part`'s byte offset, the folder change that ends a run, the restart after
weights land; `setup_reentry_test.dart` pins what **Set up again** keeps and
the way back out of it. The end-user walk-through of the same nine screens is
`docs/install.md`.

## Deliberate deferrals

- **`SegmentedButton` stays.** Both segmented controls could be
  `BondFilterPillRow`, but the existing tests read `.selected` off the
  `SegmentedButton` directly, and this round is about the container rather than
  the controls.
