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
| Models | `onUseBox` wired | `Managed · <the app's own server's state sentence>`, or `User defined · <big host>[ · <small host>]` with the two collapsed to one when they are the same host, or `User defined · no address yet` when neither address resolves |
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
`settings_connection_test.dart`, `settings_models_page_test.dart`,
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

**The Models form commits on Connect only.** Two addresses, two discovered
model names and a key per server travel together in one write, because an
address sent with the previous server's model name against it is an HTTP 400
on an MLX runtime, which is fatal and never retried. That is also why the name
is discovered rather than typed: Connect asks each server what it serves and
writes what it answered.

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
`_clearAiResults`, `_forgetAndResync`, `_resetPipeline`,
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

- `modelPlacement: prefs.modelPlacement`, and the four values the form opens
  on: `boxBigUrl: prefs.effectiveBoxBigUrl` and its three siblings
  (`effectiveBoxSmallUrl`, `effectiveBoxBigModel`, `effectiveBoxSmallModel`),
  each already resolved to the stored value where there is one and the build's
  otherwise. Never a key.
- `boxKeyStored`, `boxBigKeyStored` and `boxSmallKeyStored` are presence flags
  and never the token: the first offers **Remove key**, the two below hint that
  typing replaces something.
- `onUseBox` reads this Mac's hardware tier AT THE PRESS and calls
  `notifier.useBox(bigUrl:, smallUrl:, bigModel:, smallModel:, bigKey:,
  smallKey:, hardwareTier:)`; `onUseManaged` does the same and calls
  `notifier.usePlacement(ModelPlacement.local, hardwareTier:)`. The tier is
  read at the press rather than closed over, so a press cannot write last
  frame's answer. `onRemoveKey` is `notifier.clearBoxKey`.
- `serverState` is `ref.watch(serverStateProvider)` with the supervisor's own
  field as the fallback for the frame before the stream's first value lands,
  and `managedModelsStatusProvider` is watched ONCE into a local beside it.
  Both watched, so a load that finishes behind an open pane moves the bar and
  the three rows without the reader touching anything. The statuses do not
  reach the page as a prop: the host joins them onto `roleLines` below, so the
  page draws rows rather than resolving them.
- `roleLines` is `RoleLine.withStatus(RoleLine.fromPrefs(prefs), statuses:,
  serverState:, placement:)`, two pure functions beside the widget that the
  host calls and `settings_models_page_test.dart` pins under both modes. A
  role's steps are every stage the placement's rule sends to the same default
  target as its lead stage, `draft_reply` for the big model and `triage` for
  the small. Membership is read off `prefs.defaultTargetIdForStage` rather than
  off `roleOfStage`, because the two disagree on purpose: storyline membership
  is the big model's work on a user-defined server and the small model's on
  this Mac, so grouping by the enum would read every Managed install as Custom.
  `draft_improve` is one of the big model's steps since Round H, when it
  stopped being optional, so a target on it reads as Custom like a target on
  any other. The row describes the target most of the role's steps resolve to,
  compared by the spec `specForStage` answers rather than by the stored id, so
  a third-party pick with consent withheld reads as the fallback it actually
  reaches.
- `processingOn: ref.watch(processingProvider)`, the same value the Processing
  section's switch shows, so the status line can say the switch is off instead
  of repeating a park.
- `parked: ref.watch(parkedProvider).valueOrNull`, the whole fact rather than
  the two words the old placement block could answer for. The page decides
  which reasons it can speak to.
- `onSetUpAgain` is `restartSetup(ref)` and `onShowLog` hands
  `supervisor.logFile` to `launchUrl`. `onCloudDraftsConsent` is
  `notifier.setCloudDraftsConsent(true)`, called by the consent pane before
  the connect it is standing in front of.

`managedModelsStatusProvider` reads `modelManifestProvider`, which THROWS
unless a host overrides it. Nothing breaks in a widget test that does not —
the future simply carries the error and `valueOrNull` is null, so the rows keep
what the preferences said — but a test that wants the sizes and the disk
states overrides it with `testManifest()`.

## Models

**One question, two answers, and nothing else on the page.** The section asks
where the models run. *Managed* means this app runs the models on this Mac and
there is nothing to configure, so the page is a status block. *User defined*
means the person names two servers and pastes one access key, and **Connect**
asks each server what it serves. The page is
`app/lib/widgets/settings_models_page.dart`; the form both it and the first-run
wizard render is `app/lib/widgets/model_servers_form.dart`.

Round H deleted the **Advanced** fold, and the Local server card with it: the
stage table, the two slot editors, the targets list and editor, the presets,
**Drafts in flight**, the embeddings card, the port, the folder and the three
lifecycle buttons are gone from every screen. The routing DATA is untouched —
`stage_targets`, `llm_targets`, `applyPreset`, `setStageTarget`,
`upsertTarget`, the four slot preferences and `prose_parallel` are all still
there, still tested, still what the benches drive. Nothing shows them.

**Where the models run.** The heading, then `SettingsSegments<ModelPlacement>`
keyed `settings-mode` with two labels: **Managed** and **User defined**, under
the caption `Managed runs the models on this Mac. User defined sends the work
to servers you name.`

**The segments ACT.** Choosing **Managed** on a user-defined install calls
`usePlacement(ModelPlacement.local, hardwareTier:)` at once: there is nothing
else to fill in, so there is nothing to press afterwards. Choosing **User
defined** opens the form and writes NOTHING — the two addresses and the key
are the rest of that answer, and **Connect** is where it is given. The segment
still moves under the finger, and the status line directly under it says
`Running on this Mac until you connect.` until it has been.

**The form.** Two addresses, one key, one press:

| Control | Key | Label |
|---|---|---|
| Big model address | `servers-big-url` | **Big model address** |
| Small model address | `servers-small-url` | **Small model address** |
| Access key | `servers-key` | **Access key**, obscured |
| Access key for the small model | `servers-small-key` | only when the two addresses name different hosts |
| Model picker | `servers-big-model` / `servers-small-model` | only when that server lists several |
| Model name | `servers-big-model-text` / `servers-small-model-text` | only under a Converse address |
| Connect | `servers-connect` | **Connect** here, **Continue** in the wizard |
| Remove key | `servers-remove-key` | only with a key stored |

**The model name is DISCOVERED, never typed.** Connect probes each address's
`/v1/models` with the key. One id: used, with nobody picking anything. Several:
a `DropdownButton` appears under that address with the first id filled in, the
caption says `This server lists several models. Choose one and press Connect
again.`, and nothing is written until the second press. None, or a server that
did not answer: that address's own `ProbeStatus` says so and nothing is
written. The same address typed in both fields is the designed case for a
one-router server: it lists every id under both, and the two pickers are how
the two roles get their two names.

**Two refusals, each under the field it is about**, both before any request
leaves:

- `The address needs to start with http:// or https:// and name a server.`
  for anything `isBoxOrigin` refuses. The same rule `setBoxServers` throws on,
  said before the press reaches it.
- `The address needs to be the chat completions endpoint, ending in
  /v1/chat/completions.` for an origin where an endpoint belongs. `isBoxOrigin`
  reads the scheme and the host and nothing else, so this is the rule that
  catches a bare `https://box.example.com`.

Typing in either field clears both, drops every answer from the last press and
invalidates it: a press outlived by an edit writes nothing, on `_connectSeq`.

**A Bedrock address is typed into rather than asked.** `wireForHost` reads the
wire off the host, and a Converse service has no `/v1/models` to ask, so that
address gets a plain **Model** field instead of a probe and a picker, and
Connect refuses it with `Type the model name. This service does not list its
models.` while it is empty.

**A third-party big address asks first.** `isThirdPartyHost` names Bedrock,
anthropic.com, openai.com and deepseek.com. When the big address is one of
them the form raises `onThirdParty(spec, resume)` rather than connecting: the
Models page passes it up to `SettingsScreen`, which opens the **Cloud drafts**
consent pane in place of the sections. **Continue** records the consent and
THEN calls `resume()`, which is the same connect with the same values — that
order is the protection, because `setBoxServers` refuses a third-party big
address while the flag is false. **Not now** and **Back** close the pane and
write nothing.

**A third-party small address is refused outright.** The consent is about
drafts on the big model; the small model reads every message body for
triage and the rest, and no cloud service serves that role from any screen
(Round E decision 9). A vendor or Bedrock host in the small field is refused
under it with `The small model runs on a server of your own. Cloud services
can serve the big model only.` before any server is asked, whatever the
consent flag says, and `setBoxServers` refuses the same address as its last
line.

`onThirdParty` is null in two cases, and then the form refuses the address
under the field instead of asking: `Cloud services are connected under
Settings after setup.` The wizard is one. The other is a screen wired with
`onUseBox` but no `onCloudDraftsConsent` — a pane whose Continue recorded no
consent would hand the connect straight back to a refusal, and a question that
can only be answered wrong is worse than no question.

**A connect that does not land says so.** The form renders the reason under
the form, keyed `servers-error`: the `ArgumentError`'s own message for a
refusal, and `The servers could not be saved. Try again.` for anything else —
`useBox` ends in a keychain write, which answers with a `PlatformException` on
a locked keychain or a denied prompt, and unhandled that left the key field
full and the screen silent. When the connect was resumed from the consent pane
the form is unmounted and has nowhere to draw, so the throw is RETHROWN to the
screen, which keeps the pane open and puts the sentence on it instead of
returning the person to an unchanged section.

**The key.** One field by default; a second appears the moment the two
addresses name different hosts, because two hosts are two operators and a
token for one must never ride a request to the other. With one host the one
key is passed as both. The field opens EMPTY, always. When one is already in
the keychain it carries the hint `Stored. Type to replace` and Connect goes
through with the field blank. That is the rule, not a convenience: a token
that has reached the keychain is never read back onto a screen, so
"unchanged" has to be a state the empty field can be in. **A blank field keeps
the stored key, and Remove key is the only thing that forgets one.**

The key lives in the form's two `TextEditingController`s and in ONE other
place: the `resume` closure the form hands to the consent pane, which captures
the typed values so Continue can finish the same connect. `SettingsScreen`
holds that closure on `_ConsentPane` for as long as the pane is open, and
every way out — Continue, Not now, Back — drops it. Nowhere else: it reaches
the probes' `Authorization` headers and the one call, the controllers are
emptied the moment a connect lands, and it is never in a widget field after a
save, a probe result, a log line or a test name.

**The status line**, keyed `settings-models-status`, is always exactly one
line, and it is the first thing a stalled tester reads. It answers in this
order, and the order is the order the jobs come in:

1. `Processing is off. Turn it on under Processing, or in the sidebar, and the
   work starts.` while the session's switch is off. First, because a park
   sentence says work is retrying and nothing retries while the switch is off:
   the last parked fact stays in its provider after the drains stop, and the
   rail's own line guards the same way.
2. `Running on this Mac until you connect.` while the form is open over an
   install that has not moved yet.
3. A park this page can answer for, when something is waiting. Under **User
   defined** all three: `model_unavailable` reads `Your server is not
   answering. Work is waiting and will retry each minute.`, `unauthorized`
   reads `Your server refused the access key. Change it here.`, and
   `embed_unavailable` reads `The embedding model on this Mac is not
   answering. Work is waiting and will retry each minute.` Under **Managed**
   only the embedding one: the other two are about a server whose own line is
   the next thing on this page, and the rail already says `Model server
   unreachable`. A park word this page cannot answer for, such as a sign-out,
   is left alone: the inbox already routes it.
4. Under **Managed**, the server's own state: `Not running`, `Starting…`,
   `Loading models · N of M`, `Running`, `Not running: <reason>`, `Port <p> is
   in use[ by <holder>]`, or `Servers are started by hand for this build.` on a
   build that passed `BOND_DEV_HAND_SERVERS`. Under **User defined**, `Access
   key needed. Paste it and press Connect.` when EITHER address is somewhere
   other than this machine and has no key of its own — per server, because two
   hosts are two operators and a key stored for one says nothing about the
   other — and `Connected to your servers.` otherwise. A loopback address
   needs no key at all.

**A loading bar and a way to the log.** Under Managed, a
`LinearProgressIndicator` keyed `settings-models-progress` sits under the
status line: indeterminate while the process has not answered, and a real
fraction from `ServerLoading.loaded` once the router is reporting model by
model. No bar in any other state. **Show log**, keyed `settings-show-log`,
appears only under a failure and hands the log file to the operating system's
own viewer — this app has no log pane and does not want one.

**Three role rows.** **Big model**, **Small model** and **Embeddings**, each a
title over one line. The line is the role's phrase, then its size and its
state where there are any, joined by ` · `.

Under Managed each row is joined with this Mac's own facts by
`RoleLine.withStatus`, from `managedModelsStatusProvider` and the supervisor:
`Qwen3.8 27B on this Mac · 20.9 GB · on disk · loaded`. The name is the
MANIFEST's `displayName`, the size is what the checkpoint cost to fetch
(weights plus any sidecar), and the state is `not downloaded` when the bytes
are not there, `on disk · loaded` when the router says it is resident, and `on
disk · not loaded` otherwise. Loaded is read by ROUTER id rather than by role, which is why
`ManagedModelStatus` carries one: on a small Mac the big row's file IS the bulk
file, and a row that looked itself up by `bond-prose` would read as never
loaded there.

Under User defined the two chat rows read `qwen3.8 at box.example.com` — the
discovered model name and the address's host — and have no size or state,
because those models are on somebody else's machine. The embedding row is
built the Managed way under either mode, because that model is here whatever
the rest of the pipeline is doing.

**The server follows the placement.** Choosing User defined restarts the app's
own server onto the embedding model alone, so the two chat models leave this
Mac's memory; choosing Managed restarts it onto this Mac's whole set and the
bar and the rows show the load. One call does it,
`ModelServerSupervisor.ensurePreset`, made by the host after either placement
write and by the wizard's Finish. It restarts only when the preset hash
changed, so a Finish that moved nothing leaves a model that took a minute to
map exactly where it is.

**Also on this Mac, not in use.** Under User defined, a block keyed
`settings-idle-models` sits after the three rows and before Set up again, with
one line per model this Mac holds that the placement does not serve:
`Qwen3.8 27B · 20.9 GB · on disk · not loaded`. The name, the size and the
state are the row's own three facts, from the statuses
`managedModelsStatusProvider` marks `inUse: false`. Only files ON DISK are
listed, one line per FILE (a small Mac's big and small rows share the bulk
file), and an idle file is `not loaded` by definition: `Ready` means every
model in the small server's own preset is resident, and these are not in it.
The lines say `not loaded` rather than disappearing because a person who has
just switched wants to see the memory come back and the download stay.
Managed never draws the block, and neither does a user-defined install with
nothing idle.

A role whose steps do not all resolve to one target reads `Custom · N steps
point elsewhere`, singular at one. N is counted against the target most of the
role's steps share, so one odd step reads as one wherever it sits, the lead
stage included, and the row's Check asks the shared target rather than the odd
one. There is no longer anywhere to go and look at which ones: the sentence
says how many and stops.

The two local chat names in `RoleLine.fromPrefs` are a const map in
`settings_models_page.dart`, keyed by built-in target, with the embedding name
one constant beside it. They are what a row says before the manifest has been
read and on a row the statuses do not cover; `withStatus` replaces them with
the manifest's own name the moment the host has it.

Each row carries a **Check**, keyed `settings-role-check-big`, `-small` and
`-embed`, which probes that role's own resolved URL with that target's stored
token and renders a `ProbeStatus` beneath the row. A row that moves to another
server drops the answer it had, so a green line from one machine is never read
as a report about another. A host that wires no probe gets no Check anywhere
on the page, and no Connect either, the same discipline every optional control
here follows.

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

**What pins all of this.** `model_servers_form_test.dart` for the form,
`settings_models_page_test.dart` for the page, `probe_status_test.dart` for the
three outcomes of a look at a server, `settings_models_host_test.dart` for the
wires, and `settings_cloud_drafts_test.dart` for the consent pane through
Connect.

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
`SettingsSegments<DraftPolicy>`, the same widget Notifications and the Models
page's two modes use.

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
| **Stop sending drafts anywhere** | `settings-stop-cloud-drafts{,-confirm,-keep}` | the `draft_reply` and `draft_improve` stage entries and `cloud_drafts_consent`, so both drafting stages resolve to `AppPrefs.draftFallbackSpec` again, and the consent is withdrawn | every row, every target, every keychain bearer and every other stage entry |
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

Both drafting stages fall back to `AppPrefs.draftFallbackSpec`: the
user-defined big model on that placement and the local prose target here, and
never a third-party address, since that is the operator the withdrawal just
refused. It is
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
flow that touches a provider. Every step body is prop-only, the settings
bodies' discipline: the host reads `setupControllerProvider`
and hands down values and closures, and a null callback hides its control.
One `PaneSurface`, whose title is the step's and whose trailing slot reads
`Step N of 9`. The back arrow is `null` on the first step — which is why
`PaneSurface.onBack` is nullable and renders DISABLED rather than absent.

| # | Title | Primary button | What it does |
|---|---|---|---|
| 1 | Welcome to Bond | `Get started` | What Bond is; the container-migration line when there was one |
| 2 | Your Mac | `Continue` | Chip, memory, macOS, and which models this Mac takes. Intel or Rosetta renders **no** button at all. At 40 GiB and up, one line saying it runs all three; below it, an alert naming the memory, saying the writing model is not downloaded here and that the writing stages run on the inbox model unless Bond is pointed at the user's own servers under Settings, Models. Under 16 GiB the same alert gains one sentence about slower triage. All of it is a warning that still continues |
| 3 | Where the models run | the form's `Continue` | The one question this round is about, answered by the same form Settings renders. `SetupWhereBody` is two cards and nothing else: **Managed · recommended** keyed `setup-where-managed` and **User defined** keyed `setup-where-custom`. User defined renders `ModelServersForm` with `connectLabel: 'Continue'` and `onThirdParty: null`, so its press IS the way forward and there is no second Continue under it. On a build carrying `BOND_BOX_URL` the User defined card opens ALREADY CHOSEN with both addresses filled in, because `defaultModelPlacement` is the box whenever an address was compiled in. **Managed** is never preselected: the form keeps the way forward behind its own press, where a preselected Managed would put a live Continue under a question nobody had been asked. The press probes BOTH addresses with the typed key, or with the stored one looked up by id when the field is blank, takes the model names the servers list, refuses an address under its own field in the form's own words, and refuses a vendor's address with `Cloud services are connected under Settings after setup.` — there is no consent pane behind a wizard, and cloud services are a Settings decision. It then calls `continueFromWhere(servers:)`, which is the four-value `useBox`: the two addresses, the two discovered names, a key per id or null to keep the stored one, the box placement, and no stored target or stage entry anywhere, and then the models step. A re-entry with a key already in the keychain continues with the field blank and keeps it. Managed's own Continue calls `continueFromWhere()` with no payload, which is `usePlacement(local, hardwareTier:)` with this Mac's HARDWARE tier, never the effective one, which reads `remote` while the placement is still the box. It KEEPS the addresses and the key: changing where the work runs is not forgetting how to reach the servers |
| 4 | Models | `Continue` | The RESOLVED manifest's rows — name, role sentence, size, licence button, and any `notice` verbatim — and the total. Three rows and 23.8 GB on a full Mac — four files, because the writing model's row says `+ MTP head, 1.6 GB` under its size — two rows and 4.6 GB on an inbox one, and the first sentence says which |
| 5 | Storage | `Continue` | The effective folder, **Change folder…**, and `checkDisk`. Dead until the preflight answers and passes; free space that could not be asked counts as passing, a folder that cannot be WRITTEN does not — `Bond can't write to this folder. Choose another one.` |
| 6 | Download | `Continue` | One bar per MODEL this Mac's tier wants, smallest first — the writing model's MTP head rides on its model's bar rather than taking one of its own, so the bar counts both files and finishes once. Enabled only when EVERY file is done — see below |
| 7 | Sign in | `Continue` | `SignInBody(showTitle: false)` when signed out (signing in advances, and there is no Continue); `You're signed in.` and a Continue when already signed in |
| 8 | Notifications | `Continue` | The press IS the ask. Exactly one button, and the word `Allow` appears nowhere — macOS is about to put its own Allow up |
| 9 | All set | `Finish` | Folder, port, account, notifications, then this Mac's tier defaults on the local placement only and `setup = 'done'`, and only then the server. Nothing writes `managedServer`: it is a build define since Round H. It does not touch processing either: that is a remembered preference and it starts on |

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
