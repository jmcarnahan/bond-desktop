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
| Models | always | `Configured at build time` |
| Needs You | always | the threshold wording, plus ` · custom rules` or ` · default rules` when `onNeedsYouRulesSaved` is wired |
| Notifications | `onNotifyStyleChanged` wired | `Off` / `In-app ribbon` / `System notifications when in background` |
| Activity log | `onShowActivityLogChanged` wired | `Shown in the sidebar` / `Hidden` |
| Home & feed | `onHomeShowDroppedChanged` wired | `Dropped messages shown` / `Dropped messages hidden` |
| Storylines | `onStorylineNewestFirstChanged` wired | `Newest first` / `Oldest first` |

**A section whose wiring is absent is absent** — the same discipline every
optional row in the old dialog followed, and what lets the permissions tests
wire `hasScope` alone.

**These strings are pinned by tests** (`settings_screen_test.dart`,
`settings_connection_test.dart`). This table and those tests must agree; when
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

## Deliberate deferrals

- **Models is a placeholder.** The section renders one sentence saying the bulk
  and prose servers are set at build time, in the Makefile. Repointing a slot at
  another server, and picking a model from what that server lists, is a later
  round.
- **The storyline pickers keep their private `_PaneSurface`.**
  `app/lib/widgets/storyline_pickers.dart` still has its own copy of the header
  `PaneSurface` was generalised from. Retrofitting its two call sites is a
  follow-up; keeping them separate here means the picker tests cannot break on a
  settings change.
- **`SegmentedButton` stays.** Both segmented controls could be
  `BondFilterPillRow`, but the existing tests read `.selected` off the
  `SegmentedButton` directly, and this round is about the container rather than
  the controls.
