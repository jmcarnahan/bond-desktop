# The shell

What is on screen, where it comes from, and which of the four slots it lands
in. The pipeline docs in `docs/pipeline/` describe how a message becomes a row;
this describes the window that row appears in.

The code is `app/lib/screens/inbox_screen.dart` (the whole shell — there is no
router and no `Navigator`; every move is a `setState`), plus
`app/lib/widgets/icon_rail.dart`, `app_rail.dart`, `people_rooms.dart`,
`side_panel.dart` and `pane_surface.dart`.

---

## The four slots

| Slot | Width | Widget | What it is |
|---|---|---|---|
| Icon rail | 56 | `IconRail` | Seven stops and the account's face. Never scrolls, never changes. |
| List column | 260 | `AppRail` | What is inside the stop that is lit. Scrolls. |
| Main | the rest | `_main()`'s ladder | The one thing being read. |
| Side panel | 45 %, 360–640 for a file, 420–640 for a thread | `SidePanelHost` | A thread or a file read BESIDE the main pane. |

The icon rail answers *where am I*, the list column answers *what is here*.
They were one 260px column before this round, which is why the rail's rows read
as four unrelated piles under one another.

Below a 960px window the two rails lift off the page together as one scrimmed
overlay behind the hamburger, and the main pane has the window to itself.

### The post-rail width math

The side panel's share is measured **after** both rails:

```
available = window − IconRail.width(56) − AppRail.width(260) − 1 (divider) − 16 (seam)
```

The two-pane breakpoint is applied to that figure rather than to the window, so
the split first appears at a window of **1293 px**. Measuring the raw window
instead would open it at 960, leaving the main pane 323 — under the
transcript's own 420 minimum, with nothing to catch it.
`SidePanelHost.availableBesideRail` is the one place this is written down.

---

## The stops

| Stop | Icon | The list column shows | Main shows |
|---|---|---|---|
| Home | `bolt` | the whole stack: Needs You · Drafts & sent · Storylines · People · Later — every section collapsible but Drafts & sent, which is one row | `HomePane` — the pipeline as a table |
| Needs You | `notifications_outlined` | Needs You alone, expanded, with a `railBadge` count | the Needs You overview |
| Storylines | `tag` | the storylines, suggestions first | the storylines overview |
| People | `people_outline` | one row per person room | the flat list of live threads nobody has claimed, or the open room |
| Files | `folder_outlined` | the four kinds as rows — All · Documents · Images · Links | `FilesPane` — every document in the mailbox, by day |
| Later | `schedule` | one row per deferred day | `ArchivePane` — Later · Done · Dropped |
| AI | `auto_awesome` | one line: 'Models, rules and the log' | `SettingsScreen(scope: ai)`, titled 'AI' |

**Drafts & sent is a row in the Home stack, not a stop.** It sits between Needs
You and Storylines with a badge counting the suggestions waiting. What it holds
is the model's unsent work rather than a pile of mail, and a seventh icon for a
list that is usually empty would cost a permanent stop for an occasional one.
While its pane is up the icon rail lights **Home** — the stack the row belongs
to — and the list column keeps that whole stack with the row highlighted: the
reader has not gone anywhere, they have opened one of the things the column was
already offering. The row has nothing under it, because the pane IS the list and
a column repeating it would be a second copy always a beat behind.

`RailSection` is the vocabulary for all of this
(`{ home, needsYou, drafts, storylines, people, files, archive, ai }`).
`archive` keeps its enum name and is **labelled 'Later'**: the column the store
reads is `bucket = 'later'`, and renaming the constant would rename it
everywhere. `IconRail.stops` is an explicit ordered list: it DOES contain
`files`, between People and Later, and does NOT contain `drafts`.

**The Files column is a list of shelves, not of rows.** The four kinds are the
whole column, with the one that is up highlighted, and there are no counts on
them — a number per kind is a fourth query for something nobody acts on, and
the pane's own pills already say which shelf is showing. The kind itself lives
in `filesProvider`, so the rows and the pills cannot disagree about it. Neither
Find nor the unread toggle touches them, on the Drafts & sent row's precedent:
there is nothing here to narrow. The source chips in the column header DO scope
the shelf — they scope every pane — which is why `FilesPane` has no source bar
of its own.

On Home the column is the whole stack and every section collapses. On any other
stop it is that one section, expanded, with its header row and **no chevron** —
the user picked the stop, and a chevron that emptied the column would be an
affordance that lied.

---

## What opens where

> List column click → main pane. A thread reached from INSIDE a room (a
> storyline episode card, a person room's root message) → side panel. A file →
> side panel. ⤢ on a thread panel opens it in main; ⤢ on a file opens the full
> viewer. Opening a file from a side thread REPLACES the side panel.

That is Slack's rule, and it is what keeps the room on screen while one
conversation in it is being read.

`SidePanel` has five kinds, and the panel shows exactly one of them:

| Kind | What it holds | Opened by |
|---|---|---|
| `ThreadPanel` | a conversation | a storyline episode card, a person room's card or `Open chat ›`, a Drafts & sent row |
| `FilePanel` | one file | any card, chip, unfurl or shelf row |
| `WhyPanel` | why one message got its verdict | the hover **Why** on an inbound row, and the CTA banner |
| `PersonPanel` | one person | the room header's **Profile**, and tapping the faces on a room or a thread |
| `HistoryPanel` | what happened to one message — every stage, judgement and queue row, with the levers | the hover **What happened** on an inbound row, the Why panel's `What happened ›`, a home row's stage bar or Result cell, an Archive row |

Why, Person and History follow the file rule: opened from a thread that is
itself beside, they REPLACE it. One panel, never two stacked — the Why panel's
`What happened ›` swaps the history into the same slot, and its ✕ returns to
the transcript, not to Why. Neither Why nor History carries ⤢: each is prose
about one message, and prose does not improve by being given the whole window.
The history takes the thread's minimum width (`threadMinWidth`) rather than the
file's — it is a page of sections and levers, not a caption.

The history is NOT a rung of `_main()`: the storyline picker its
`Add to storyline…` opens draws in the main pane while the story stays beside,
which is what gives the picker's Back somewhere to go. Every selector closes it
through `_clearOverlays()`, like every other panel. The pipeline side of the
screen — what it reads, what each lever writes — is in
[pipeline/README.md](pipeline/README.md#finding-out-what-happened-to-a-message).

`_main()`'s ladder is the priority order, top rung first: compose → Settings →
activity log → add-thread picker → pick-storyline picker → full file viewer →
thread → storyline → **room** → **Drafts & sent** → Home → AI → section
overview. A pane outranks what it was opened from because it is the newer thing
the user asked for. Drafts & sent sits directly above Home because its row lives
in the Home stack.

---

## Finding things

Slack opens a palette over the app for its quick switcher. The house rule is
that nothing opens over anything, so Find is a **field in the column it
filters** — `FindField`, in the list-column header above the source chips. That
turns out to be the better shape: the rows narrow under the reader's eyes as
they type, so "the top match" is something they can see rather than a promise
about a list the app is hiding.

**What it matches**, per row kind (`app/lib/widgets/find_filter.dart`, all pure):

| Row | Matched against |
|---|---|
| thread | the ask (`needsYouTitleFor`), the person (`railTitleFor`), the subject, and every participant name and address |
| storyline | its title |
| person room | its title, which is the people in it |
| Later day | nothing — a day has no title, so the day rows come off entirely while a needle is up |

Find is **not search**. It narrows rows already on the rail, live, on every
keystroke, and never looks in a message body — the rail does not hold one and
could not honestly claim to have looked. An empty needle matches everything,
which is what makes an empty box the unfiltered rail.

**Badges never shrink under a filter.** Needs You still counts the whole pile
while the column shows one row of it. A filter changes what you can see, never
what you owe, and a badge that moved as the reader typed would let them hide
their own work by mistyping a name. The rail filters BEFORE it truncates to
`AttentionTuning.topCount`, which is also what makes the next rule true.

**Enter opens the first row still drawn.** `firstFindTarget` is the one place
that order lives — the rail draws it and the screen walks it — so the row that
opens is the row under the reader's eyes rather than a second opinion about
which came first. It walks the scope's own sections: Home and Drafts walk
threads, then storylines, then rooms; a single-section scope walks only its own;
Files, Later and AI answer null. `find_filter_test` and `app_rail_test` pin the two
halves of that agreement against each other.

**Nothing matched is not a dead end.** With a needle still in the box, Enter
falls through to Home's search: `_selectSection(home)` then
`submitSearch(text)`. That is the honest escalation — Find only ever looked at
the rail, and search looks at the whole index. On any pick the field clears and
gives up focus, the way Slack's switcher closes.

**⌘K** focuses the field from anywhere (and `Ctrl+K`, for a runner that is not a
Mac). The binding is a `CallbackShortcuts` around the whole `Scaffold` body,
wrapped in `Focus(autofocus: true)` — and that wrapper is load-bearing:
`CallbackShortcuts` only sees keys while focus is somewhere inside its subtree,
and on a freshly built screen nothing has focus at all. It takes focus once, at
the top, and hands it over the moment anything below asks, so a composer or a
search box the reader clicks into still gets its keystrokes. At narrow widths
⌘K opens the rail overlay first, then requests focus in a post-frame callback —
the field may only exist once that overlay has been laid out. Escape clears, and
is bound inside `FindField` so it only fires while the box holds focus.

**Unread only** is a toggle in the caption row (`Key('unread-toggle')`), not a
pill under the source chips: three source pills already fill 236px, and a fourth
would wrap onto a line of its own for one word. It hides read threads and read
rooms and leaves storylines alone — a storyline is not read or unread, and
hiding one under a filter about mail would make the toggle mean two things. Its
tooltip names what pressing it would do, so it flips: `Unread only` ↔ `Show
everything`.

**The search grammar** belongs to Home's own box, not to Find. See
`parseSearchQuery` (`app/lib/services/search_grammar.dart`); the hint on
`HomeSearchField` names it, because there is nowhere else to put a legend.

| Facet | Takes | Runs |
|---|---|---|
| `from:` | a name or address fragment, quotable | client-side, over the hits |
| `in:` | `mail`/`email`/`outlook`, or `teams`/`chat` | **server-side**, as `sources` down to `semanticSearch` and `searchAttachmentChunks` |
| `has:` | `file`/`files`/`attachment`/`attachments` | client-side, on `HomeFeedRow.hasAttachments` |
| `before:` / `after:` | `YYYY-MM-DD` only | client-side; `before` is strictly earlier, `after` includes the day |

Anything unrecognised **stays text** — an unknown facet, a value the facet does
not take, an empty one. There is no error channel between the box and the
reader, so the only honest thing to do with `re:` or `in:junk` is search for it.
Facets with no sentence left under them do not reach the index at all: the state
gets `'Add a word or two to search for — the filters alone are not a question.'`
rather than an embedding call on the empty string. Results are labelled with the
RAW query the reader typed, facets and all, because that is what the box still
shows. Documents are **not** facet-filtered: `in:` already narrowed them in SQL,
`has:file` is trivially true of every one of them, and sender and date live on
the message a chunk came from.

---

## Room anatomy

A thread and a storyline are both **rooms**, and they wear the same parts in
the same places. `app/lib/widgets/room_header.dart` is the shared header;
before it the two screens each had their own and disagreed about where things
go, so a user who learned one had learned nothing about the next.

**The header** is the room's identity plus what can be done to the ROOM: an
optional Back, a leading glyph (`#` on a storyline), the title and a subtitle,
the faces of who is on it, a state chip, then the actions. Anything about ONE
message lives on that message, never up here.

- An action with an icon is an `IconButton` whose **tooltip is its label**; one
  without is a quiet text button. Which of the two a call site picks is a width
  decision: this header shares its width with the attachment preview in the
  split, and every label comes out of the title.
- **The ⋯ menu** (`RoomHeader.moreKey`, tooltip `More`) holds the corrections —
  filing a thread, re-sorting a spine, syncing, retiring a storyline. A
  `PopupMenuButton` is not a dialog. A menu item with a null `onTap` renders
  disabled, which is what a label like `Syncing…` needs. An item **says what it
  does**: the storyline's sort item names the order it switches TO.
- **The faces are the first thing to give.** Below `540` of header width the
  `AvatarStack` comes off, because the subtitle already names those people and
  the alternative is a clipped control.

**The tab row** is a second line of `BondFilterPill`s, drawn only when there is
more than one tab — one pill is a label pretending to be a choice. Each pill
carries `RoomHeader.tabKey(value)`. A storyline's tabs are **Messages | Files
(n) | About**: the catch-up, the pinned bar and the spine; then the whole
document shelf; then the charter and the member list.

A **thread's** tabs are **Messages | Files (n)**, and only when it carries
files — with one tab the header draws no tab row, so a fileless thread looks
exactly as it always did. The Files list is DERIVED from the transcript
(`threadFiles(messages)`), not queried: `loadThread` already loads the whole
thread and hydrates every message's attachments, so a second query would be a
second answer to one question, with a loading state the transcript beside it
never has. The CTA banner stays above both tabs — what a thread wants does not
stop being true because somebody went looking for an attachment.

**The hover strip** (`app/lib/widgets/hover_actions.dart`) puts **Reply**,
**Suggest a reply**, **Why** and **What happened** at an inbound row's
top-right while the mouse is over it. It is a WRAPPER around `MessageRow`, not
a change to it: the row seeds its collapsed state once, and hover is a
per-frame fact about the pointer. Touch never enters a `MouseRegion`, so
nothing may live only here — all four buttons have a home the pointer is not
needed for (the history is also reachable from the Why panel, from every home
row and from the archive). The two that explain come after the two that write
a reply, and What happened comes after Why because it is the longer answer to
the same question: Why is the verdict, What happened is everything the
pipeline did to reach it. The strip is drawn on INBOUND rows only, so from a
thread the history of the owner's own message is reachable through the home
feed, not the transcript.

**The CTA banner explains, it no longer opens the box.** Tapping it opens
**Why** on the newest inbound message. The composer is docked and always
visible, so "put the cursor in it" was a click nobody needed help with, while
"where did this ask come from" had no answer anywhere. With no Why wired, or on
a thread with nothing inbound in it, it falls back to focusing the composer as
it always did — and every per-message ask line still focuses the box.

**The composer is docked.** Whenever a reply is possible the box is under the
transcript from the moment the thread opens, placeholder `Reply to <who>…`.
There is no reply window, no `Reply…` row and no ✕ to close: a thread that can
be answered says where the answer goes, and the transcript keeps the reader's
attention anyway because the box is quiet until typed in. Where a reply is NOT
possible — a chat without `Chat.ReadWrite` — the same slot says `Reply in
Microsoft Teams`. The focus node lives on the screen, one per pane, because the
composer is rebuilt with a new key on every send epoch.

**Reply-to** is the override the hover Reply writes: a `Replying to <who>`
caption with a ✕ above the box, and the send carries that message id. It is
cleared on a send that did not fail, on a change of selection, and when a side
thread goes away. Unnamed is the ordinary case and resolves the way it always
did — see [pipeline/07-replies.md](pipeline/07-replies.md).

**The pinned-documents bar** (`app/lib/widgets/pinned_documents_bar.dart`) is
Slack's bookmark bar: the files pinned to THIS room, at the top of its
Messages tab, one tap from being opened. It carries no × — unpinning is a
correction and stays a two-step on the Files tab.

---

## The bold grammar

**Bold means unread. Everywhere.** It used to mean "you owe this" in Needs You
and "unread" in the section under it, which is two grammars in one column — and
a reader who has to know which section they are looking at to read a font
weight is reading nothing.

What Needs You owes is said three other ways: the red `railBadge` count over the
section, the `railAccent` dot on the row, and the ask the row is titled with.

A Needs You row is titled by `needsYouTitleFor`: the `cta_text` triage wrote,
else the subject with its reply prefixes stripped, else the person —
`railTitleFor`'s answer, glyph and all. When the title is not already the
person, `needsYouWhoFor` adds a dimmed `' · <who>'` after it, as a second
`TextSpan` in `onDarkMuted`. Seven rows that all read the same colleague's name
is a list you have to open one at a time to use; a column of asks can be read.

A row the model has not finished with overrides both: muted ink and a hollow
dot until the answer is whole (`showsProcessing`).

---

## People rooms

`app/lib/widgets/people_rooms.dart` is pure and has no store behind it: rooms
are derived from the conversation list on every build.

- **The key** is the other parties' display names, lowercased, joined by `'\n'`
  — an address where a name is missing. The owner is dropped **by address**
  (exact, case-insensitive) **or by name**: a Teams roster names the account
  with a `teams:<id>` no mailbox address will ever equal, so without the name
  arm the user stands in every one of their own chats.
- Nobody left files under **`'(no sender)'`**. A no-reply address and a chat
  whose roster failed to load are still mail; a pile that loses them silently is
  worse than one odd row.
- **The title** is that one person, or 2–3 names joined `', '`, or the first
  three and `'…'` — the `TeamsSync._subjectFor` rule, so a group chat's own
  subject and its room title agree.
- **The rows** are `needsYouRows` + `conversationRows`: the live inbox, which
  between them claim each thread exactly once. Later and done threads are in
  neither and so are in no room.
- Rooms sort newest-first by `latestAt`; threads inside a room sort the same
  way.

A room row leads with a 20px face when there is one person to show, and with
the usual dot for a group. It carries a source glyph only when every thread in
it came from one connector — a colleague on both would otherwise be marked as
whichever arrived last. Its badge is the room's needs-you count in
`railBadge`, or the thread count in grey when nothing is owed, never both.

Tapping a room opens `_room()`, and what it opens is **one timeline** — goal
one of this round, literally. A `RoomHeader` titled by the person, subtitled
`N threads · mail and Teams`, and under it a `PersonRoomPane`
(`app/lib/widgets/person_room_pane.dart`) holding everything live with them in
the order it happened.

- **Chats read as messages, mail reads as cards.** The newest `roomChatCap`
  (five) Teams threads have their transcripts drawn inline as `MessageRow`s;
  every mail thread is a `RootMessageCard` — who, subject, last line, the CTA,
  `N messages · last <relative>`, `open ›`. A chat has no subject and no shape
  to summarise, so a card standing for one would say nothing; a mail thread has
  both.
- **A chat whose transcript has not arrived is a card until it does**, and so
  is every chat past the cap. The room never has a hole where a conversation
  should be.
- **Interleaved by time, oldest at the top, newest at the bottom.** The list is
  `reverse: true` over the reversed items, so the newest row is on screen the
  moment the room opens, with `DayDivider`s where the calendar turns over. A
  chat heading (`💬 <name>` plus `Open chat ›`) is drawn before every RUN of
  chat messages, not once per chat: a mail card dated between two chat messages
  lands between them, and a run resuming under somebody else's heading would be
  misread.
- **Opening the room marks its inline chats read** — `noteThreadOpened` +
  `markRead` + a transcript load, the `_openThreadBeside` pair — because they
  ARE on screen, the way a Slack DM is read when it is opened. Mail cards stay
  unread until somebody opens one: a card is a summary, not the mail.
- **One way to write, never two.** A room with exactly one person and a Teams
  thread gets the docked composer on that chat, placeholder
  `Message <name>…`, and only on the `Chat.ReadWrite` rung. Otherwise, if there
  is mail, a `Message <name>` button
  (`PersonRoomPane.messageButtonKey`) opens a new message to them. A group room
  with no mail gets neither: a group chat is not a place a sentence typed under
  a room heading obviously belongs.
- **Profile, and the faces**, both open `PersonPanel` beside — name and
  writable addresses (a `teams:` id is a Graph id and is hidden), the counts
  `N threads · M mail · K chats · J need you`, `Last seen`, the storylines
  their threads are in, every live thread as a line, and the files they sent.
  Its lists say which state they are in: `Loading…` while the read is out, and
  a sentence when the answer is genuinely nothing.

Back goes to the People overview — the room IS the People stop, and dropping
the user somewhere else would make the way out depend on how they got in.

---

## The account menu, and the list-column header

The footer is gone. It carried three source pills, a name, five icons and a
freshness caption at the bottom of the one column, and it was the busiest thing
on screen.

**What is about the app** moved to a `PopupMenuButton` on the account avatar at
the foot of the icon rail (`IconRail.accountMenuKey`): a disabled header with
the account name and address, then Settings, then Activity log (only when the
preference has it on), then Sign out. `PopupMenuButton` is not a dialog — the
no-popups rule bans `showDialog(`, `AlertDialog(` and `showDatePicker(`, and a
menu hanging off the control that opened it takes nothing over.

**What is about the mail** moved to the top of the list column, above the list,
inside the same `Material` — the screen builds it and hands it down as
`AppRail.header`:

1. the scope's name in caps, then the **Unread only** toggle, ✎ **New
   message** and ⟳ **Refresh**;
2. the **Find** field (`FindField`, hint `Find… ⌘K`);
3. the three source chips (`SourceFilterBar`, already `onDark`);
4. the triage caption, when the model still has mail to look at.

Teams freshness is now the refresh button's **tooltip** — `Refresh` before the
first pull, `Refresh · Teams updated 4m ago` after. It is a fact about that
button: chats do not arrive on their own, so the one control that pulls them is
the one place worth saying how old they are. The stored stamp is memoised in
`_teamsSyncedAt` and dropped by `_refreshTeams`; a fresh future per build would
blank the answer for a frame every time anything on the screen changed.

---

## The burgundy tokens

Raw colour lives only in `app/lib/theme/bond_colors.dart`.

| Token | Where |
|---|---|
| `rail` | the list column's fill |
| `railDeep` | the icon rail's fill, one step darker |
| `railAccent` | the dusty-rose dot: a thread on the hook, a live storyline |
| `railBadge` | the count pill, brighter than `error` so it reads on burgundy |

The `onDarkFaint` … `onDarkPrimary` white alphas are reused unchanged — they are
white over whatever is underneath, so they did not need a burgundy twin.

---

## Profile photos

Real faces, fetched through the existing `get_profile` tool — no new MCP tool
name. `PeopleBackend.profilePhoto(user, {size})` sends
`{'user': …, 'photo': 'bytes', 'photo_size': '96x96'}` and omits `user` for the
signed-in account (`PeopleBackend.self`, the empty string). The Graph twin is
`GET /users/{user}/photos/{size}/$value`.

`ProfilePhotos` (`app/lib/services/profile_photos.dart`) is the seam.
`DirectoryProfilePhotos` memoises one future per key, caches negatives for the
session, treats `directory_scope_missing` as terminal for the session, drops
the memo on any other failure so the next ask retries, and holds at most four
calls in flight. `photoFor` never throws. `NoProfilePhotos` is what a test
gets. The cache is in memory only this round.

`photoKeyFor({address, id})` mints the key: a Graph id wins, `teams:<id>`
strips to the id, otherwise the trimmed lowercased address.

`BondAvatar` paints initials FIRST and lets the photo land on top —
`cached()` seeds the first frame, so scrolling back through a transcript does
not re-flash initials at faces already seen. Faces appear in the transcript,
the recipients typeahead, the icon rail's account button, 1:1 People rows, and
the person room's header `AvatarStack`.

---

## Testing the shell

- `setSurfaceSize(Size(1400, 900))`, both sync connectors faked,
  `notificationCoordinatorProvider` handed an unstarted coordinator, the
  container disposed in `tearDown`.
- **Never `pumpAndSettle`** on anything that pumps `InboxScreen` — it owns a
  sixty-second `Timer.periodic`. Three bare `tester.pump()` calls is the idiom;
  `pump(Duration(milliseconds: 400))` is how a menu route is run out.
- `initialSectionProvider` decides which stop the column is scoped to, and the
  column shows ONLY that stop — a test that taps a storyline row must select
  the Storylines stop first, or land on Home.
- Scope finders: the list column and the overview beside it often name the same
  thing (`find.descendant(of: find.byType(AppRail), …)`), and the icon rail's
  Home stop wears the same tooltip as `PaneSurface`'s Home button.
- Settings, Activity log and Sign out are reached through
  `IconRail.accountMenuKey` and then `settingsItemKey` / `activityItemKey` /
  `signOutItemKey`.
- **Hover** needs a real mouse: `tester.createGesture(kind:
  PointerDeviceKind.mouse)`, then `addPointer(location: Offset.zero)`, then
  `moveTo(tester.getCenter(rowFor(id)))`, then `pump()`. The buttons are
  `HoverActions.replyKeyFor(id)` / `suggestKeyFor(id)` / `whyKeyFor(id)`.
- **A ⋯ menu is a route.** Tap `RoomHeader.moreKey`, then `pump()` and
  `pump(Duration(milliseconds: 400))` to run the opening animation out; the
  same pair runs the closing one out after picking an item. A panel-only test
  with no `InboxScreen` under it can use `pumpAndSettle` instead.
- **Tabs** are selected by `find.byKey(RoomHeader.tabKey(StorylineTab.files))`,
  and a thread's by `RoomHeader.tabKey(ThreadTab.files)`. Scope a `find.text`
  for the word `Files` — the icon rail's own stop wears it too.
- **Files** in a transcript are `AttachmentCard`s inside `MessageRow.cardsKey`;
  a card is reached by `AttachmentCard.keyFor(ref)` and its rendering by
  `imageKeyFor(ref)`. Two or more pictures are `ImageGrid.gridKey` (tiles by
  `ImageGrid.tileKeyFor`, the counter by `overflowKey`); a link is
  `LinkUnfurl.keyFor(ref)` with `openLinkKeyFor(ref)` for its button. The
  digest line keeps the key it always had, `attachmentKey('digest', ref)`,
  wherever it is drawn.
- **The Files stop**: `FilesPane.kindPillsKey` scopes the pill finders (the
  source chips carry an `All` of their own), `FilesPane.rowKeyFor(row)` names
  one file, `threadLinkKeyFor(row)` its way back into the conversation, and
  `emptyKey` / `loadMoreKey` the two ends of the list. The rail's kind rows are
  `ValueKey('files-kind-<name>')`.
- **Find** is reached by `find.byKey(FindField.fieldKey)`. `enterText` then
  `pump()` narrows the column; `tester.testTextInput.receiveAction(
  TextInputAction.search)` is Enter. ⌘K is four events —
  `sendKeyDownEvent(metaLeft)`, `sendKeyDownEvent(keyK)`, `sendKeyUpEvent(keyK)`,
  `sendKeyUpEvent(metaLeft)` — then `pump()`.
- `Key('unread-toggle')` is the Unread only button; find it by that, not by
  tooltip, because the tooltip flips with the state.
- `Key('needs-you-tabs')` is the Needs You pill row. **Scope pill finders to
  it**: the source chips carry an `All` pill of their own.
- `DraftsPane.draftKeyFor(source, messageId)` / `dismissKeyFor(...)` /
  `sentKeyFor(source, messageId)` reach the Drafts & sent rows. The list column
  row is `find.text('DRAFTS & SENT')`, scoped to `AppRail`.
- A screen test about which rows reach the rail should write
  `attentionThresholdKey` to `'0'` before reading prefs. The scoring pass lands
  a few pumps in, and the default 0.5 slider will cut a quiet row out from under
  an assertion that was true on the first frame.
- **A person's room**: `PersonRoomPane` is the pane,
  `RootMessageCard.keyFor(source, id)` is a mail card,
  `PersonRoomPane.openChatKeyFor(key)` is a chat's way in,
  `messageButtonKey` the compose button and `emptyKey` the empty room. The
  header is a `RoomHeader<ThreadTab>`, so scope Back to it rather than to
  `PaneSurface` — the room stopped being one in Phase 6.
  `inbox_room_timeline_test.dart` is the harness, and it fakes the send grant
  with an `implements AuthSession` whose `hasScope` answers from a set, which
  is far less machinery than the full SDK stack `inbox_teams_test` stands up.
- **The Why panel**: `WhyPanelBody` inside a `SidePanelHost`, with
  `verdictKey` / `triageKey` / `asksKey` / `attentionKey` / `extractionKey` per
  block and `whatHappenedKey` for the history door. `inbox_why_test.dart`
  covers the seam (which gesture, which pane, and that the door swaps the
  history into the same slot); `why_panel_test.dart` owns the wording.
- **The history panel**: `MessageHistoryScreen` (`chrome: false`) inside a
  `SidePanelHost` titled `What happened`. `message_history_nav_test.dart`
  covers the shell seam from a home row (opens beside, ✕, Open thread, the
  picker in main with the story still beside, another stop closes it); the
  hover door is `HoverActions.historyKeyFor(id)`, pinned in
  `thread_detail_panel_test.dart`. The story is a lazy `ListView` and the
  panel is narrower than a pane, so `scrollUntilVisible` a lever before
  tapping it. A Needs You rail row is titled by its ASK and carries a dimmed
  `· who` suffix, which makes it a `Text.rich` — use `find.textContaining`,
  not `find.text`.
- **The Person panel**: `PersonPanelBody`, with
  `threadKeyFor(source, id)` / `storylineKeyFor(id)` / `fileKeyFor(row)`. A
  room's face comes off its NEWEST thread, so a person whose newest thread is a
  chat shows a `teams:` address the panel deliberately hides — assert on the
  counts line instead.
- **Later reminders**: `LaterDigestPanel.backKeyFor(source, id)` is the
  `Back <when>` caption, `snoozeTomorrowKeyFor` / `snoozeNextWeekKeyFor` the two
  pills. `ArchivePane` now requires `onSnooze` as well as `now`.
