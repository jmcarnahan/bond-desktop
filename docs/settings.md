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
body has the same shape in `settings_models_body.dart`.

## The sections, in order

| Section | Renders when | Collapsed summary |
|---|---|---|
| About me | always | the saved text, whitespace collapsed to one line, cut at 80 characters with `…`; `Not written yet` when empty |
| Microsoft connection | any of `onBackendModeChanged`, `connectionStatus`, `hasScope`, `onSignIn` is wired | `MCP` or `This device`, then (MCP only) `Deployed` / `Local` / `Custom`, then `Checking…` / `Not signed in` / `Signed in as <label>` / `Signed in`, joined by ` · ` |
| Models | `onSlotTargetChanged` wired | `GPU server · <host> · embeddings on this Mac` on the box placement, `This Mac · <local server summary>` on this Mac, and `This Mac` alone when the host wires no server card. The line says where the work RUNS; where the three slots point moved into the section's Advanced fold with everything else |
| Needs You | always | the threshold wording, plus ` · custom rules` or ` · default rules` when `onNeedsYouRulesSaved` is wired, plus ` · judging N message(s)` while `needsYouRejudging` (the whole needs-you queue, from `needsYouPendingProvider`) is above zero — "judging", not "re-judging", because the count cannot tell a Save's rows from a sync's |
| Suggested replies | `onDraftPolicyChanged` wired (both scopes) | `For messages that need you` / `For every reply-worthy message` / `Only when asked` |
| Notifications | `onNotifyStyleChanged` wired | `Off` / `In-app ribbon` / `System notifications when in background` |
| Activity log | `onShowActivityLogChanged` wired | `Shown in the sidebar` / `Hidden` |
| Storylines | `onStorylineNewestFirstChanged` wired | `Newest first` / `Oldest first` |
| Context directories | when wired (both scopes) | `No directories yet` / `N directories · M files` |
| Processing | any of `onProcessingChanged`, `onClearAiResults`, `onForgetAndResync` is wired (both scopes) | `On` / `Off` |
| Sync & data | `onRefreshNow` wired | `Not synced yet`; `Mail synced <rel> · Teams <rel>`; a side that never ran says `not synced yet` in words (`Mail synced 4m ago · Teams not synced yet`, `Mail not synced yet · Teams synced 2h ago`) |
| About | `appVersion` or `databasePath` is known | `Bond <version>` / `Version unknown` |

**A section whose wiring is absent is absent** — the same discipline every
optional row in the old dialog followed, and what lets the permissions tests
wire `hasScope` alone. Under `SettingsScope.ai` four of them are absent for a
second reason: the AI pane keeps About me, Models, Needs You, Suggested
replies, Activity log, Storylines, Context directories and Processing, in this
same order, and drops the rest.

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

The screen stays put across a backend switch. The host swaps the session
underneath and the section re-asks, so the user sees what their own click did.

## Host wiring

`SettingsHost` in `app/lib/screens/settings_host.dart` builds it, and
**`ref.watch(appPrefsProvider)`, not `ref.read`**. The Needs You summary reads
the stored rules to say whether they are custom, so a Save inside the screen
only moves that line because the host rebuilds. Optimising the watch back to a
read would silently stop the summary following saves.

Every closure that touches `ref` keeps its `mounted` guard. The work behind them
outlives the pane — a sign-in still out in the browser, a sign-out from the rail
— and a dead host must answer with nothing rather than with "ref after
dispose".

**What the host owns, and the two seams it does not.** Everything only
settings calls lives on `_SettingsHostState`: `_saveNeedsYouRules`,
`_clearAiResults`, `_forgetAndResync`, `_resetPipeline`, `_setManagedServer`,
`_setRouterPort`, `_chooseModelsFolder`, `_reloadAfterBackendChange`,
`_connectionStatus` and `_connectMicrosoft`. A new settings-only writer goes
here, not on the inbox.

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

**The Models section's own wires**, added 2026-09-19 with routing-as-data. The
host reads them off the prefs so the picker's items and its selection come from
one resolver rather than two guesses:

- `targets: prefs.allTargets` and `stageTargetIds: {for (final stage in
  pipelineStages) stage.id: prefs.targetIdForStage(stage.id)}`, with
  `cloudDraftsConsent: prefs.cloudDraftsConsent`.
- `onTargetSaved` awaits `notifier.upsertTarget(spec, bearer: bearer)` and THEN,
  only when one of the three presets is set, `notifier.applyPreset(...)` — that
  order because `applyPreset` refuses a target id it cannot find, and until the
  upsert lands a new target is not in the list.
- `onTargetRemoved: notifier.removeTarget`, which also deletes the keychain entry
  and clears every stage that pointed at it, in one write.
- `onStageTargetChanged` calls `clearStageTarget` for a null target id and
  `setStageTarget` otherwise; `onCloudDraftsConsent` is
  `notifier.setCloudDraftsConsent(true)`.
- `proseParallel` and `proseParallelTargetName` come from
  `prefs.specForStage('draft_reply')`, and `onProseParallelChanged` writes
  `setProseParallel` for a built-in target and `upsertTarget(spec.copyWith(
  parallel: width))` for any other. See **Drafts in flight** below.

**And the simple page's own wires**, added in Round H:

- `boxUrl: prefs.effectiveBoxUrl` and `boxKeyStored: prefs.boxKeyStored`. The
  first is the stored address when there is one and the compiled `BOND_BOX_URL`
  otherwise, already resolved, so the form prefills and never asks twice. The
  second is a presence flag and never the token.
- `onUseBox` reads this Mac's hardware tier at the press and calls
  `notifier.useBox(baseUrl:, key:, hardwareTier:)`; `onUseLocal` does the same
  and calls `notifier.usePlacement(ModelPlacement.local, hardwareTier:)`. The
  tier is read at the press rather than closed over, so a press cannot write
  last frame's answer.
- `roleLines` is `RoleLine.fromPrefs(prefs)`, one pure function beside the
  widget that the host calls and `settings_models_simple_test.dart` pins on
  both placements. A role's steps are every non-optional stage the placement's
  rule sends to the same default target as its lead stage, `draft_reply` for
  the big model and `triage` for the small. Membership is read off
  `prefs.defaultTargetIdForStage` rather than off `roleOfStage`, because the two
  disagree on purpose: storyline membership is the big model's work on the box
  and the small model's on this Mac, so grouping by the enum would read every
  local install as Custom. Optional stages are skipped, for the reason
  `usePlacement` keeps their entries: an unrouted `draft_improve` is the Improve
  button being off, not a step pointing elsewhere. The row describes the target
  most of the role's steps resolve to, compared by the spec `specForStage`
  answers rather than by the stored id, so a third-party pick with consent
  withheld reads as the fallback it actually reaches.
- `processingOn: ref.watch(processingProvider)`, the same value the Processing
  section's switch shows, so the status line can say the switch is off instead
  of repeating a park.
- `parked: ref.watch(parkedProvider).valueOrNull`, the whole fact rather than
  the two words the old placement block could answer for. The page decides
  which reasons it can speak to.
- `hardwareLine: SettingsModelsBody.hardwareLine(hardware, machineTier)` and
  `embedServerLine`, which is the string `Embedding model: ` followed by
  `SettingsLocalServerBody.summary`.
- `onProseParallelChanged` is null when the resolved draft target `isBox`. A
  derived box target is fixed at four, the width is that server's slot count
  rather than a preference, and a control that wrote nowhere would be a lie
  about a number this install does not own.

`pipelineStages` is imported directly in `settings_host.dart`:
`prefs_provider.dart` re-exports `ModelSlot`, `LlmTarget`, `LlmTargetSpec` and
`LlmWire` but not the stage table, and the host needs it to ask where every
stage currently points.

## Models

**One question, and everything else behind one fold.** The section a tester
opens asks where the models run, reports three answers, and keeps the sixteen
controls that used to be on top level in an **Advanced** fold below them. The
page is `app/lib/widgets/settings_models_simple.dart`; the fold's body is the
section this replaced, `app/lib/widgets/settings_models_body.dart`, rendered
with its placement block and its header unwired because the page above now owns
both.

**Where the models run.** The heading, then `SettingsSegments<ModelPlacement>`
keyed `settings-placement` with two labels: **GPU server · recommended** and
**This Mac**. The segment opens on the placement this install is on and is local
state from there, so it moves under the finger. Choosing one writes NOTHING, and
the caption says so: `Choosing here changes nothing yet. Save, or Use this Mac,
is what moves the work.`

**Under GPU server, the one box form.** It is `SetupWhereBody` with
`showChoices: false` and the primary button relabelled **Save**, which is the
same widget the first-run wizard's Where step renders, so the three controls
carry the same three keys in both places: `setup-box-url` for **Box address**,
`setup-box-key` for **Access key**, obscured, and `setup-box-check` for **Check
server**. Two copies of a form that takes a secret is exactly the kind of drift
that ends with one of them logging it.

The form also owns the one ADDRESS RULE, which is why neither host carries a
copy of it. A press on **Save** or on **Check server** with an address that is
not an origin, `isBoxOrigin` in `model_slots.dart`, is refused by the form
itself: nothing is called, and an error `InlineAlert` appears directly under
the address field reading `The address needs to start with http:// or https://
and name a server.` Typing in the field clears it. It is the same rule
`setBoxUrl` throws on, said before the press reaches it, because both presses
are fire-and-forget and a throw past one of them is an unhandled error and, to
the person, a button that did nothing. The button stays live over a bad address
on purpose, so the press can say why it is refused rather than going quiet. The
wizard's Where step gets the same refusal, in the same words, from the same
widget.

The address arrives prefilled from `AppPrefs.effectiveBoxUrl`, which is the
stored address when there is one and the compiled `BOND_BOX_URL` otherwise. The
key field opens EMPTY, always. When one is already in the keychain it carries
the hint `Stored. Type to replace` and **Save** goes through with the field
blank, which is the target editor's own contract: a token that has reached the
keychain is never read back onto a screen, so "unchanged" has to be a state the
empty field can be in. With no key stored, Save waits for one, disabled rather
than absent. Save hands the host the normalised address and either the typed key
or null, and null is what the host reads as "keep the stored one".

Under the form sits the one caption a tester needs before pasting anything:
`Message text and drafts travel to the project’s GPU server over an encrypted
connection. The embedding model stays on this Mac.`

**Check server asks BOTH slots.** The box serves both roles from one host, under
`/prose` and `/bulk`, so one check that asked only the writing slot would miss an
inbox slot that is down. The two answers render as two captioned `ProbeStatus`
lines, **Writing model** first and **Inbox model** under it. Both captions are
on screen from the first frame of a check, not only once the second answer
lands, so nobody is handed a relabelled line halfway through one: the flag that
says so is `SetupWhereBody.twoSlots`, and both hosts pass it. An address edited
while a check is out turns the busy lines off at once and drops that check's
answers when they land, in both hosts, because two servers asked in sequence is
long enough for a person to have retyped the address. The key that rides
those two requests is the one typed in front of the person when there is one and
the stored one otherwise, looked up by id through `AppPrefsNotifier.bearerFor` at
the moment of the press. It reaches two `Authorization` headers and nothing else:
not a probe result, not a log line, not a widget field.

**Under This Mac**, the button **Use this Mac**, keyed `settings-use-local`,
then the Local server card and then one line saying what this Mac is. The button
is above the card because it is the answer to the question the segments asked and
the card is the detail underneath it, and it goes inert rather than absent once
the install is already here: a way forward that vanished would read as a dead
end. Pressing it calls `usePlacement(ModelPlacement.local)` with this Mac's
HARDWARE tier, which removes the entries the app itself wrote and applies the
tier's own picks. The hardware line is
`SettingsModelsBody.hardwareLine`: `This Mac: Apple M1 Max, 64.0 GB, runs all
three models`, or `This Mac: memory could not be read`, or nothing at all while
the machine is still being read.

**The status line**, keyed `settings-models-status`, is always exactly one line,
and it is the first thing a stalled tester reads. It answers in this order, and
the order is the order the jobs come in:

A refused ADDRESS is not on this list. The form owns that rule and answers
under the field it is about, so the status line goes on saying whatever it was
saying.

1. On this Mac, `Models run on this Mac.` and nothing else, because the
   server's own state sentence is in the card directly above and saying it
   twice would be the screen arguing with itself.
2. `Access key needed. Paste it above and press Save.` on the GPU server with no
   key stored. Before any park, because a park about a refused key is answered
   by pasting one.
3. `Processing is off. Turn it on under Processing, or in the sidebar, and the
   work starts.` while the session's switch is off. Before any park, because a
   park sentence says work is retrying and nothing retries while the switch is
   off: the last parked fact stays in its provider after the drains stop, and
   the rail's own line guards the same way.
4. A park this page can answer for, when something is waiting.
   `model_unavailable` reads `The box is not answering. Work is waiting and
   will retry each minute.`, `unauthorized` reads `The box refused the access
   key. Change it here.`, and `embed_unavailable` reads `The embedding model on
   this Mac is not answering. Work is waiting and will retry each minute.` It
   is the same fact the inbox rail reads, from the drains' own progress
   streams, and nothing polls the box to produce it. A park word this page
   cannot answer for, such as a sign-out, is left alone: the inbox already
   routes it.
5. `Not checked yet. Press Check server.` when nothing has been asked this
   session.
6. `Checked: both models answered`, after a check both slots came back from,
   or `Checked: ` followed by the failing slot's own sentence after a check one
   of them did not.

On the GPU server one more small line sits under the status:
`Embedding model: ` followed by the local server's own summary. That process is
running the embedding model alone on this placement, and its state is the one
thing the box's status line cannot say.

**Three role lines.** **Big model**, **Small model** and **Embeddings**, each a
title and one phrase. On the box the two chat roles read `qwen3.8 on the GPU
server` and `qwen3-4b on the GPU server`, the model name the box's own vLLM
servers serve. On this Mac they read `Qwen3.8 27B on this Mac` and `Qwen3 4B on
this Mac`, named by the built-in target the role resolves to rather than by the
role, so a small Mac whose six prose steps run on the 4B reads `Qwen3 4B` for
the big model too. Embeddings reads `Qwen3 Embedding 0.6B on this Mac` on either
placement, because that model is here whatever the rest of the pipeline is
doing. A role pointed at somebody's own target names the model and the host it
dials. A role whose steps do not all resolve to one target reads `Custom · N
steps point elsewhere · see Advanced`, singular at one, and points at the one
place that can show which ones. N is counted against the target most of the
role's steps share, so one odd step reads as one wherever it sits, the lead
stage included, and the row's Check asks the shared target rather than the odd
one.

The two local chat names are a const map in `settings_models_simple.dart`,
keyed by built-in target, with the embedding name one constant beside it, rather
than a read of `assets/models/manifest.json`. The manifest does carry a
`displayName` per file, but `modelManifestProvider` throws unless a host
overrides it and no inbox test overrides it, so reaching for it from the
settings wiring would turn every one of those tests red for a label. The
manifest spells the small one `Qwen3 4B Instruct`; this page says `Qwen3 4B`.

Each row carries a **Check**, keyed `settings-role-check-big`, `-small` and
`-embed`, which probes that role's own resolved URL with that target's stored
token and renders a `ProbeStatus` beneath the row. A host that wires no probe
gets no Check anywhere on the page, the form's and the rows' alike, the same
discipline every optional control here follows.

**Advanced** is a `SettingsSection` inside the section, collapsed on arrival,
titled `Advanced` and summarised `Per-step picks, extra servers, port and
folder`. Its expansion lives in the screen's own open-sections set by title, so
it collapses and re-opens exactly the way a section does and a person who left
it open finds it open. Its body is every control below, unchanged from Round E
and Round G apart from one relabelled button.

### Advanced

The fold's body is `SettingsModelsBody`, the section Round E and Round G built,
rendered with `header: null` and with no placement controls. Everything below is
what it has always said.

**The stage table is AUTHORED**, not derived, and since Round E each row has a
**picker**. `pipelineStages` in `app/lib/services/llm/model_slots.dart` is the
app telling the user what its own wiring is, and `model_slots_test.dart` is what
keeps that table honest against the handler list. Sixteen rows: eight on the
fast slot, seven on prose, one on embeddings. What changed is the meaning of the
`slot` column — it is now each stage's **default target**, not its wiring. Where
a stage actually goes is data in `stage_targets`, resolved per call through
`stageLlmClientProvider`, and re-pointing one costs no code at all
(`docs/pipeline/10-model-routing.md`).

Each row's right-hand cell is a `DropdownButton<String>` keyed
`SettingsModelsBody.stagePickerKey(stageId)` over every target, labelled with the
target's name. An **optional** stage — `draft_improve` today — gets a first item
`None` whose value is the empty string, and picking it reports null, which is
what "the Improve button is not there" looks like in the data. `embeddings` keeps
its chip and model name and gets no picker for the reason it gets no editor:
every stored vector carries a corpus tag, so there is nothing to choose between.
A stored id that names a target which has since been removed falls back to the
stage's own default rather than throwing — a `DropdownButton` asserts on a value
that is not among its items, and a settings screen may not crash on stale data.
A host that wires no `onStageTargetChanged` gets the chips the table always had.

**The golden notes.** Under a picker, where the ledger has measured that stage,
sits one caption from `stage_golden_notes.dart` — `Golden set: verdict 92 on the
local 4B, 93 on the 27B` and six more. Numbers and model sizes only: this is a
public repo and the golden set is real mail, so the table is pinned by a test
that every key is a `pipelineStages` id and that no value contains `@`, `http`,
`.com` or a newline. A stage the ledger never measured renders no line at all,
which is the honest state rather than a blank one.

**Reset per-step picks.** One button, keyed `settings-tier-defaults`. What this
Mac IS is said once, on the page above this fold, out of
`SettingsModelsBody.hardwareLine`: the chip, the memory and what the machine
runs, which is `runs all three models` at 40 GiB of memory or more and `runs the
inbox models` below that. That line is about the MACHINE and reads
`machineTierProvider`, which never answers `remote`, so it says the same thing on
either placement. Where the work actually goes is the question the segments
above it ask. The caption under the button
names exactly what a press rewrites. On a small Mac that is naming, refresh,
recap, grouping, the reply decision and drafts, all moved to `Local fast`, with
suggested replies moved to Only when asked. On a big Mac it is those same six
stage picks cleared back to `Local prose`, with suggested replies back to For
messages that need you. Both captions use the words the controls they move
actually carry, so the mode named here is the mode shown under Suggested
replies. Nothing else moves: the eight bulk stages, storyline confirm among
them, Improve a draft, the targets themselves, the cloud-drafts consent and
every bearer are untouched, and a second press changes nothing.

On the GPU server placement the press is `usePlacement(ModelPlacement.box)`
rather than this Mac's tier defaults, because the machine's tier is not what the
picks go back to there: every step the app itself pointed goes back to the box,
suggested replies back to For messages that need you, and a step pointed at a
server you added keeps it. The caption reads `Puts every step back on the GPU
server and sets drafts to For messages that need you. A step pointed at a server
you added keeps it.` On this Mac the host makes the same `usePlacement` call
with the local placement, which drops the entries the app itself wrote and ends
in `applyTierDefaults`.

A Mac whose memory could not be read gets neither. The system channel usually
answers `unknown` rather than failing, and when it throws anything else or
goes quiet past the two-second probe timeout the hardware read is a rejection
while the tier, read off the same future, still resolves to the full tier by
the never-refuse rule. Either way the machine is unreadable, and writing
defaults chosen from a number nobody read is not something to offer: the page
above reads `This Mac: memory could not be read` and the fold offers no button,
with a caption pointing at the stage table above it.

It is not a two-step, unlike Remove and Clear AI results, because nothing is
destroyed. The six picks it overwrites are six rows a person can see in the
table above, and any of them can be re-picked on the spot. While the app is
still reading the machine the button is disabled and its caption reads `Reading
this Mac…`; a host that cannot write the change gets no button at all. The tier is read from this Mac's memory each time it is asked for and
stored nowhere, so a models folder carried to another Mac gets that Mac's
answer. The wizard writes the same defaults once at Finish, through the same
`AppPrefsNotifier.applyTierDefaults`.

**Targets.** Below the two slot editors, under the heading **Targets**, is
`SettingsTargetsBody` (`app/lib/widgets/settings_targets_body.dart`) — every
server a stage may be pointed at, `AppPrefs.allTargets`, built-ins first. One row
per target, keyed `llm-target-row-<id>`: the name, `hostPort(url)`, the model, a
chip for the wire (`OpenAI` / `Converse`), a chip saying `Bearer set` or `No
bearer`, and `Parallel N` when the width is not one. Beside them **Check server**
(`llm-target-check-<id>`, the same probe closure the slot editors use, with a
`ProbeStatus` under the row; a row whose chip says `Bearer set` has its stored
key looked up by id and sent on that one request), and for a user's own target **Edit**
(`llm-target-edit-<id>`) and **Remove** (`llm-target-remove-<id>`). Remove is the
Processing section's two-step: the first press swaps the button for **Confirm
remove** beside **Keep**, and the row's buttons go inert while the write is out.
Under the rows, **Add target** (`llm-target-add`).

The two built-ins have no Edit and no Remove. They are derived from the four slot
prefs rather than stored, so their row carries the caption `Edited above, under
Fast and Prose` and the two `ModelSlotEditor`s further up the section are where
they change. `AppPrefsNotifier.removeTarget` refuses a built-in id on its own
account as well, so the missing button is a courtesy rather than the protection.

**Add and Edit are PANES**, not dialogs — the house rule. `SettingsScreen` holds
which sub-pane is open as state and swaps its own child for a `PaneSurface`
titled **Add target** or **Edit target**, so the sections and their expansion
state are still there when the back arrow closes it. The body is
`LlmTargetEditor` (`app/lib/widgets/settings_target_editor.dart`), prop-only like
everything else here, with controls keyed `llm-target-name`, `-url`, `-model`,
`-wire`, `-bearer`, `-parallel`, `-streams`, `-check`, `-save`, `-cancel`. Save
waits for a name, a URL and a model, and for a URL that parses with a host;
until then it is disabled with the reason as a caption under it. A probe never
blocks a Save, on the slot editors' rule. A new target's id is `t-` and eight hex
characters, never derived from the name: the stage map and the keychain entry are
keyed on that string, and two targets a person happened to call the same thing
would otherwise share a token.

**The bearer is a secret and is treated as one.** The field is obscured. On an
edit it opens EMPTY with the hint `Stored. Type to replace`, because a token that
has reached the keychain is never read back onto a screen — which is why
"unchanged" has to be a state the empty field can be in. The three outcomes:
typing a token sends it with `hasBearer` true; leaving the field empty sends
`bearer: null` with `hasBearer` true, which keeps the stored one; **Remove
bearer** (`llm-target-bearer-clear`) sends `bearer: null` with `hasBearer` false,
which clears it. The value reaches the host once and appears in no key, no
summary, no log and no row — the list says only `Bearer set` or `No bearer`.

**The three presets**, on the ADD pane only, under **Use this target for**:
*Prose stages* (`llm-target-preset-prose`, `proseStageIds` — storyline naming,
refresh, recap and grouping, the reply decision and drafts), *Storyline confirm*
(`llm-target-preset-confirm`, `storyline_membership`) and *All bulk stages*
(`llm-target-preset-bulk`, the eight fast-slot rows). The first two are
**pre-checked for every new target** and the user unticks. That is deliberate and
it is not a guess about the host: the GPU box arrives over an ssh tunnel at
`localhost:18100`, so "not loopback" would miss the one machine these presets
exist for, and a Bedrock endpoint proxied onto loopback would read as local.
Bulk is not pre-checked, because moving eight stages onto a paid target is not a
default anybody should arrive at by pressing Save. They are absent on an EDIT: a
preset is a write rather than a property of the target, so a checkbox showing the
current grouping would need a fourth state. The host applies them with
`AppPrefsNotifier.applyPreset` AFTER the upsert, because `applyPreset` refuses a
target id it cannot find.

**What *Prose stages* does on a Bedrock target, and what it sends.** Ticking it
moves the six prose stages onto that model: storyline naming, storyline
refresh, the storyline recap, the grouping stage, the reply decision and Draft
reply, except that `applyPreset` holds `draft_reply` back on a third-party
target while `cloud_drafts_consent` is false, so drafts keep being written
locally until the consent pane has been answered, and the preset is not a way
around it. Improve a draft is in no preset. What leaves the machine for a naming call is the thread cards of
one cluster: each thread's subject, the display names of its participants and
its triage summary; the naming card carries no topics. No message body,
no attachment and no directory excerpt is in that prompt, which is why naming
sits behind the prose preset rather than behind the drafts consent. This is the
one place a cloud model measurably changes the filing, and the numbers, taken on
the golden set on 2026-09-20 with the confirm and the embedding local in every
row, are these:

| namer | storyline.id | correct positives | forbidden hits |
|---|---|---|---|
| local 27B Q4_K_M with MTP | 45/98 | 5 | 4 |
| the GPU box 27B-FP8 with MTP | 50/98 | 9 | 5 |
| Bedrock Sonnet 5, pass 1 | 57/98 | 10 | 3 |
| Bedrock Opus 5, pass 1 | 53/98 | 8 | 2 |

A cloud pass is one of two reads and the two differ, because Converse carries no
temperature: Opus 5's second pass filed 55 of 98 with 9 correct positives and 3
forbidden hits, and Sonnet 5's second pass 54 of 98 with 12 and 8. The local and
the box namers reproduce to the count.

Nothing in the app picks a cloud namer for anybody. The measurement is a reason
to offer the setting, not a default, and `docs/model-bakeoff.md` carries the
second passes and the reading.

**Cloud drafts consent.** Picking a **third-party** target for `draft_reply` or
`draft_improve` while `cloud_drafts_consent` is false writes NOTHING. Instead the
screen opens a third pane, `PaneSurface` titled **Cloud drafts** over
`CloudDraftsConsentPane` (`app/lib/screens/consent_screen.dart`), whose back
arrow is the same answer as **Not now**. Third party means the `converse` wire or
a host under `anthropic.com`, `openai.com` or `deepseek.com`, or a Bedrock
runtime host, one starting `bedrock` and ending `.amazonaws.com`
(`isThirdPartyHost`); AWS as a whole stopped being the test in Round G, because
the shared GPU box is an instance the owner rents and runs. Loopback is not a
signal in either direction. The flag
is one flag, so a yes covers `draft_reply` and `draft_improve` alike, and the
pane says so in its second line. No other
stage ever asks — a triage or a storyline-name prompt carries a subject line and
a summary, and a draft prompt carries the message, the tail of its thread and
excerpts from the user's own directories.

The pane says what goes and what never goes, shows the two measured numbers in a
table (`Local 27B | 6 of 25 drafts passed`, `Opus 5 | 17 of 25 drafts passed`,
measured on 25 replies from the golden set, 2026-09-17) and names the daily cap.
The cap it names is the one in force — `cloud_drafts_daily_cap`, the field
under Processing — not a number compiled into the pane, so the promise the
person reads is the promise the ledger keeps.
**I understand, continue** (`consent-continue`) records the consent FIRST and
writes the stage after it — that order is the protection, because
`AppPrefs.specForStage` sends a third-party draft target back to the local one
while the flag is false, so a stage written first would resolve locally until
something else rebuilt it. **Not now** (`consent-not-now`) and the back arrow
write nothing. The prefs enforce the same rule independently of this screen, so a
`stage_targets` restored from a backup or edited by hand cannot route a draft off
the machine on its own.

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

**Drafts in flight** — a `SegmentedButton<int>` of 1 / 2 / 4 / 8 directly under
the prose editor, captioned "For &lt;name&gt;. One per slot the server was started
with (SLOTS in local.mk, --max-num-seqs on vLLM). Extra requests queue at the
server rather than fail." Since Round E the width is the **draft target's**,
not the prose slot's: the host passes the `draft_reply` stage's resolved
`parallel` and its name, because a GPU-served box has slots this Mac does not
and a caption still saying "the prose server" would be describing a machine the
number no longer governs. Where the number is WRITTEN forks on the same
resolution: for the built-in `Local prose` target it is `AppPrefs.proseParallel`
(`prose_parallel`, 1–8, default 1) exactly as before, and for a user's target it
is that spec's `parallel` through `upsertTarget`. `DraftHandler` reads it through
a closure at every launch decision either way, so the change moves the next draft
rather than the next launch of the app. It is here rather than in a section of
its own because it is a fact about the SERVER, and it does not touch the
collapsed summary, which names where the three slots point and how many targets
were added. Optional, like every other control here: a host that wires no
`onProseParallelChanged` gets no segments, and since Round H the host wires none
on the GPU server placement. A derived box target is fixed at four, that number
is the box's own slot count rather than a preference this install owns, and a
control that wrote nowhere would be a lie about it.
Drafts only — a recap and a refresh both write the storyline they are about and
stay at one (`docs/pipeline/10-model-routing.md`). Measured 2026-09-17: a second
local slot on this Mac's 27B did not pay (width 2 slower end to end than width
1); the default stays 1 locally, and 4 is the measured value for a GPU-served
target.

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

**Local server card.** `SettingsLocalServerBody`
(`app/lib/widgets/settings_local_server_card.dart`). It is still injected as
`SettingsScreen.modelsHeader` rather than built by the section, so neither
`settings_models_body.dart` nor the page above it knows anything about a
supervisor: what is running is the host's answer to hand over. Round H moved
where it is DRAWN, from the top of this fold to the simple page under **This
Mac**, because that is the placement it belongs to and the fold is not where
somebody goes to start a server. It is prop-only like everything else here, and
a null callback hides its control. Everything it says is unchanged:

It shows, top to bottom:

- **`Bond runs the model server`** — the switch over `AppPrefs.managedServer`,
  subtitled "One llama-server serves all three models from this Mac. Off, the
  app expects servers you started yourself." It is the only control that stays
  live when the preference is off; everything below it is disabled, not hidden,
  so the row does not jump about while the server stops. Flipping it writes the
  preference and then starts or stops the process — `_setManagedServer` on
  `_SettingsHostState`, in that order, because `ensureRunning`/`stop` both ask
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
  again**, which runs the first-run wizard from the top.

  **Set up again** stashes a `done` that was there into
  `SetupStore.previousSetupKey`, clears `setup_state` EXCEPT
  `SetupStore.keptOnRestart` — the container-migration record, the download
  ledger and that stash — and then bumps `setupRestartProvider`, which is what
  `SetupGate` re-decides on. The kept keys are the point: starting over must
  not re-copy a mailbox that is already here or re-download twenty-three
  gigabytes that already are. So the wizard opens at **Welcome to Bond** with
  the models still on disk and the session still signed in, and those two
  steps are a **Continue** each. The order matters and is pinned by
  `setup_reentry_test.dart`: the keys go first, because the gate re-reads the
  store the moment the counter moves.

  **It is not a one-way door.** With the stash present the welcome step draws
  a secondary **Back to the inbox** under **Get started**
  (`SetupWelcomeBody.onReturnToInbox`, null on a first run — there is no inbox
  behind THAT wizard). Pressing it calls `SetupController.returnToInbox`,
  which writes `setup = 'done'` back, removes the stash and hands control to
  the gate through the same `onFinished` callback Finish uses. A download this
  run started is left running, on the controller's dispose reasoning: the run
  outlives the screen, and cancelling one an hour in would be a steeper price
  than the button implies. `finish()` removes the stash too, so a second run
  that was seen through to the end leaves nothing behind.
- The caption `Changing the port or the folder restarts the server. Work in
  flight parks and resumes when it is back.`

`app/test/settings_local_server_test.dart` pins every one of those strings —
the nine state sentences, the switch's title and subtitle, the port error, the
held-port advice, the caption — plus which buttons each state offers and that
everything but the switch and **Set up again** is dead while the preference is
off — that one stays live because it acts on the wizard rather than on a
process, and a switch that is off is one of the states the wizard exists to put
right.
`settings_models_test.dart` pins the join: the server's line closes the collapsed
summary, and the card renders on the page under **This Mac** rather than in the
fold.

**The probe's lifetime is the host's.** `_SettingsHostState` holds one
`ModelServerProbe`, built on first use and closed in `dispose`. A client per
button press would leak a connection pool per press, and this is a button a
user can hammer.

## Suggested replies

When a reply is written **without anyone asking**. Three segments and a
sentence, between Needs You and Notifications, in **both scopes** — how much of
the big model's time a backlog spends on replies nobody will read is a fact
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
message the needs-you pass judged the owner is needed on, with `urgency`
`urgent` or `high`, the same prompt goes again to whichever target the
**Improve a draft** stage points at, and that answer replaces the draft. It
needs such a target to be turned on at all — without one the switch is inert
and the caption reads *"Pick a target for Improve a draft under Models
first."*; with one it names it: *"After the local draft is written, the same
prompt goes to `<name>` and its answer replaces the draft. Counts toward the
daily cap under Processing."*

The mechanism, the two pre-gates, the Improve button and the activity notes
are in [pipeline/07-replies.md](pipeline/07-replies.md), "When a draft is
written" and "Improve a draft". The policy control is
`SettingsSegments<DraftPolicy>`, the same widget Notifications and Models ›
Drafts in flight use.

## Processing

Whether this install runs model work at all, and the two ways to throw away
what it has already produced. In both scopes, because all three are questions
about the model rather than about the app.

**AI processing** is the same switch as the one at the top of the sidebar,
drawn here as a `Switch` keyed `settings-processing-toggle` beside its name and
the word `On` or `Off`. It is REMEMBERED and it starts on: a fresh install goes
to work the moment the wizard finishes, and a machine somebody stood down comes
back down. The preference is `processing_on`, and it was session state, off at
every launch, until Round H; what made it session state was the risk of
spending the first minutes on the wrong server, and the placement rule closes
that, because the default server is now the measured one. Turning it off still
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
| **Stop sending drafts anywhere** | `settings-stop-cloud-drafts{,-confirm,-keep}` | the `draft_reply` and `draft_improve` stage entries and `cloud_drafts_consent`, so Draft reply resolves to `Local prose` again, `draft_improve` resolves to nothing at all and the Improve a draft button goes with it, and the consent is withdrawn | every row, every target, every keychain bearer and every other stage entry |
| **Clear AI results** | `settings-clear-ai-results{,-confirm,-keep}` | every triage verdict, summary, storyline, draft, digest and embedding — the sixteen `MessageStore.derivedTables`, the verdict columns on `messages` and `conversations`, and the stage markers on `attachments` and the library; the activity log is one of the sixteen, so today's **Cloud drafts** count starts again at zero, which the caption above the buttons says | mail, Teams messages, attachments, registered directories, the sign-in and every preference |
| **Forget everything and re-sync** | `settings-forget-resync{,-confirm,-keep}` | everything above **and** the mailbox itself — `MessageStore.wipeAll(keepIdentity: true)`, cursors and bootstrap floors included | the sign-in, the about-me text, the Needs You rules, the sender rules, the registered directories and every setting |

**Stop sending drafts anywhere** is the one-button revoke, in the same
two-step and above the two resets. It makes three preference writes in one
order that matters: `clearStageTarget('draft_reply')`, then
`clearStageTarget('draft_improve')`, then `setCloudDraftsConsent(false)`. The
stages go first and the flag last, which is the grant's order reversed, and
for the grant's reason: `AppPrefs.specForStage` sends a third-party draft
target back to the local one while the flag is false, so clearing the stages
first means they are already local by the moment consent goes. Consent first
would leave two stage entries pointing off this machine with nothing but the
resolver between them and a draft.

The `draft_reply` stage falls back to the local prose target and
`draft_improve` resolves to nothing at all, which is that stage's own rule, so
the Improve button goes rather than quietly running on this machine. It is
**not** refused while processing is on, unlike the two resets it sits above:
it writes preferences and touches no rows, so there is no drain it could race,
and somebody who has just realised their drafts are leaving the machine should
not have to find a switch first. Nothing else goes with it: the third-party
target stays in the list, its keychain bearer stays in the keychain, and any
other stage pointed at it keeps pointing at it. Granting
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

Neither reset queues the mailbox. The next sync's own backlog calls are what
refill the pipeline, one `backlogEnqueueCap` slice a poll, which is why the
first button's caption says the mailbox is re-queued a slice at a time — see
[pipeline/01-sync-ingest.md](pipeline/01-sync-ingest.md).

**What the owner decided by hand survives a clear.** A message they restored
keeps its `gate_override`, and one they ignored keeps `gate_reason = 'user'`
and stays out; both are the owner's own hand on the gates, and nothing
recomputes either on a later triage claim. The gate verdicts written at ingest
survive too (`outbound`, `backlog`, and Teams' `auto_generated` and
`teams_source`); every other gate reason is cleared and re-derived on the next
claim.

**Everything comes back on its own**, each by the path that would have
written it the first time. Mail, chats, storylines, drafts and embeddings ride
the sync's backlog calls; the library rides the reconcile, which is requeued
per directory on every sync. Attachments are the one case the clear has to
queue for itself, in the same transaction: `attachment_text` is enqueued at
ingest, by a detail fetch and by Restore, and a message already stored with a
body reaches none of the three, so the clear writes one `attachment_text` work
row per attachment left `pending` and the digest follows the text pass. A
refusal is not re-queued, because "too large" and "not text" are verdicts
about the file rather than about the model that read it.

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
has moved. The gate answers ONCE, on `AuthGate`'s pattern, and re-decides only
when the flow reports itself finished or when **Set up again** bumps the
counter.

`SetupFlow` (`app/lib/screens/setup/setup_flow.dart`) is the only file in the
flow that touches a provider. Every step body is prop-only, the
`SettingsLocalServerBody` discipline: the host reads `setupControllerProvider`
and hands down values and closures, and a null callback hides its control.
One `PaneSurface`, whose title is the step's and whose trailing slot reads
`Step N of 9`. The back arrow is `null` on the first step — which is why
`PaneSurface.onBack` is nullable and renders DISABLED rather than absent.

| # | Title | Primary button | What it does |
|---|---|---|---|
| 1 | Welcome to Bond | `Get started` | What Bond is; the container-migration line when there was one |
| 2 | Your Mac | `Continue` | Chip, memory, macOS, and which models this Mac takes. Intel or Rosetta renders **no** button at all. At 40 GiB and up, one line saying it runs all three; below it, an alert naming the memory, saying the writing model is not downloaded here and that the writing stages run on the inbox model until a target is added under Settings, Models. Under 16 GiB the same alert gains one sentence about slower triage. All of it is a warning that still continues |
| 3 | Where the models run | `Continue` | The one question this round is about, and the wizard's own copy of the Settings form: `SetupWhereBody` with both cards. On a build carrying `BOND_BOX_URL` the **GPU server · recommended** card opens ALREADY CHOSEN, with **Box address** prefilled from the install's saved address or the compiled one, because `defaultModelPlacement` is the box whenever an address was compiled in. **This Mac** is never preselected: the box card keeps Continue closed until the **Access key** field is answered, where a preselected This Mac would put a live Continue under a question nobody had been asked. **Check server** asks BOTH slots and reports two captioned lines, **Writing model** and **Inbox model**, the captions up from the first frame. An address that is not an origin is refused under the field in the widget's own words, and nothing is written. On a re-entry with a key already in the keychain the field opens empty with the hint `Stored. Type to replace` and Continue is live with it blank; a blank field with no stored key is refused. Continue on the box calls `useBox(baseUrl:, key:, hardwareTier:)`: the address, the key under both keychain ids, or null to keep the stored one, the box placement, and no stored target or stage entry anywhere. A check made with the field blank sends the stored key, looked up by id at the press, and an address edited while a check is out drops that check's answers when they land. Continue on This Mac calls `usePlacement(local, hardwareTier:)` with this Mac's HARDWARE tier, never the effective one, which reads `remote` while the placement is still the box. It KEEPS the address and the key: changing where the work runs is not forgetting how to reach the box |
| 4 | Models | `Continue` | The RESOLVED manifest's rows — name, role sentence, size, licence button, and any `notice` verbatim — and the total. Three rows and 23.8 GB on a full Mac — four files, because the writing model's row says `+ MTP head, 1.6 GB` under its size — two rows and 4.6 GB on an inbox one, and the first sentence says which |
| 5 | Storage | `Continue` | The effective folder, **Change folder…**, and `checkDisk`. Dead until the preflight answers and passes; free space that could not be asked counts as passing, a folder that cannot be WRITTEN does not — `Bond can't write to this folder. Choose another one.` |
| 6 | Download | `Continue` | One bar per MODEL this Mac's tier wants, smallest first — the writing model's MTP head rides on its model's bar rather than taking one of its own, so the bar counts both files and finishes once. Enabled only when EVERY file is done — see below |
| 7 | Sign in | `Continue` | `SignInBody(showTitle: false)` when signed out (signing in advances, and there is no Continue); `You're signed in.` and a Continue when already signed in |
| 8 | Notifications | `Continue` | The press IS the ask. Exactly one button, and the word `Allow` appears nowhere — macOS is about to put its own Allow up |
| 9 | All set | `Finish` | Folder, port, account, notifications, then this Mac's tier defaults on the local placement only, `managedServer = true` and `setup = 'done'`, and only then the server. It does not touch processing: that is a remembered preference and it starts on |

**`'done'` is written by Finish and by `returnToInbox`, and by nothing else.**
The second writer never INVENTS the word: it only puts back a value
`finish()` had written, stashed by **Set up again** at the moment it cleared
it. Arriving at **All set**
records `notifications` — the step BEFORE it — because `'done'` is the gate's
sentinel: a quit on the last screen would otherwise let the next launch
straight past the gate with `managedServer` still off and no wizard left to
turn it on. A relaunch lands on Notifications instead, whose Continue re-asks
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

**Continue on the download step waits for every file this Mac's tier asked
for** — four on a full Mac, since the writing model brings its MTP head — and
not for `ModelManifest.usableIds` (embed + bulk, informational and gating
nothing).
`ModelServerSupervisor._launch`
refuses to start while any file the preset names is missing, so a partial set
could not serve the inbox anyway — and finishing early would leave a
non-engineer looking at an idle inbox with no progress bar left to explain it.

**`--dart-define=BOND_DEV_SKIP_SETUP=1`** skips the wizard entirely
(`SetupGate.skipDefine`). It is for the engineers who run `make model fast
embed` by hand: their models are in the Homebrew cache rather than this app's
folder, and a wizard offering to download twenty-three gigabytes they already
have would be in the way of every `make app-run`. A define rather than a
preference because it describes the BUILD, not the person — `local.mk` passes
it through (see QUICKSTART step 2).

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
preselected box card, the two-slot check, the address refusal and what each
answer writes; `setup_gate_test.dart` pins which screen a
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
