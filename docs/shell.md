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
| Icon rail | 56 | `IconRail` | Six stops and the account's face. Never scrolls, never changes. |
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
| Home | `bolt` | the whole stack: Needs You · Storylines · People · Later, each collapsible | `HomePane` — the pipeline as a table |
| Needs You | `notifications_outlined` | Needs You alone, expanded, with a `railBadge` count | the Needs You overview |
| Storylines | `tag` | the storylines, suggestions first | the storylines overview |
| People | `people_outline` | one row per person room | the flat list of live threads nobody has claimed, or the open room |
| Later | `schedule` | one row per deferred day | `ArchivePane` — Later · Done · Dropped |
| AI | `auto_awesome` | one line: 'Models, rules and the log' | `SettingsScreen(scope: ai)`, titled 'AI' |

`RailSection` is the vocabulary for all of this
(`{ home, needsYou, storylines, people, archive, ai }`). `archive` keeps its
enum name and is **labelled 'Later'**: the column the store reads is
`bucket = 'later'`, and renaming the constant would rename it everywhere.

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

`_main()`'s ladder is the priority order, top rung first: compose → Settings →
activity log → add-thread picker → pick-storyline picker → full file viewer →
thread → storyline → **room** → Home → AI → section overview. A pane outranks
what it was opened from because it is the newer thing the user asked for.

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

Tapping a room opens `_room()`: a `PaneSurface` titled by the person, an
`AvatarStack` of the other parties in its trailing slot, and a
`ConversationListPane` split into NEEDS YOU and THREADS. Back goes to the People
overview — the room IS the People stop, and dropping the user somewhere else
would make the way out depend on how they got in. Phase 6 replaces the body
with a merged timeline.

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

1. the scope's name in caps, then ✎ **New message** and ⟳ **Refresh**;
2. the three source chips (`SourceFilterBar`, already `onDark`);
3. the triage caption, when the model still has mail to look at.

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
