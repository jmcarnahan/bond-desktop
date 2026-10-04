# 14 · Calendar

**What happens.** The owner's **primary** Outlook calendar is mirrored into
one local table, `calendar_events`, over a rolling window, by a sync that runs
fire-and-forget after every mail load. Everything the calendar features read —
a day, the invites still owed an answer, the meeting before and after a
person, the messages that carried an invite — reads that mirror, never the
server, so a slow or failing calendar costs the screen nothing.

Built in the calendar round (2026-09, schema v25 once merged over the needs-you rounds' v21–v24). The open owner checks and
the follow-ups are listed [at the end](#owner-checks-and-follow-ups).

## How it fits together

One mirror that every surface reads, one write path, and three kinds of model
use. None of them goes to the cloud.

1. **The mirror.** `CalendarSync` writes `sync_calendar` pages into
   `calendar_events` after each mail load. It runs in MCP mode only and reads
   the primary calendar only. It also caches the mailbox settings that give
   the display zone ([The sync](#the-sync)). A message that carried an invite
   stores its event's id ([Meeting fields on messages](#meeting-fields-on-messages)).
2. **The Day stop** is one of eight rail stops, right after Needs You. It draws
   one day out of the mirror, either as an agenda (meetings, deadlines,
   threads coming back from Later, the Now marker) or as a day or week grid.
   It also holds the invites owed. The Inbox's Today section is a slice of it
   ([The Day stop](#the-day-stop), [The grid](#the-grid)).
3. **The event panel and cards.** A meeting opens as `EventPanel`, the ninth
   side panel. An invite's thread carries a `MeetingCard`, and a person's
   room opens with the next and last meeting
   ([Events, invite cards and people](#events-invite-cards-and-people)).
4. **Writes.** Every answer, move, cancel, delete and create goes through
   `CalendarWriter` (a dry run, then the commit) and one UI state machine,
   `CalendarWriteFlow`. A write that emails anyone waits on an inline confirm
   that says who gets email. A write that emails nobody happens at once and
   offers Undo. The grid's drag, the command bar's card and Find a time's
   invite all go through this same path ([Writes](#writes)).
5. **Briefs.** After each synced tick, `BriefPlanner` queues `meeting_brief`
   work for the meetings of today and tomorrow in the display zone
   (`briefHorizonEnd`: the local midnight that ends tomorrow) with people the
   owner has exchanged mail with; a person can ask for a brief of any future
   meeting (**Write a brief**). The handler writes `event_briefs`, which the panel
   draws and the agenda teases ([Briefs](#briefs)).
6. **The command bar.** `DayCommandBar` reads a typed request mostly by
   lookup. Dart resolvers find the time, the people and the meeting; the
   command head, or else the lexicon, names the action. The result is a
   proposal, a choice of slots, an answer, or a question back. ⌘K hands a
   needle that looks like a calendar request to the bar
   ([Commands](#commands)).
7. **Find a time.** When the decision model reads a thread as asking for a
   time (or the owner says so from the thread bar), the thread is listed in
   the Day column's Scheduling asks, where its row opens on real free slots.
   They can go into the reply or out as an invite, and a slot picked in the
   column is shown on its day before anything is sent
   ([Find a time](#find-a-time)).

**The models.**

- The **generative** model (`generativeSpec`) runs two stages:
  - `meeting_brief`;
  - `calendar_intent`, on Enter only, only when the rules could not finish,
    and only to copy phrases out of the request.
- The **decision** model gets no new triage call. The calendar reads the
  answers triage already stored:
  - urgent invites are pinned first;
  - a brief's threads are ranked and its open asks chosen;
  - scheduling asks are marked.
- The decision model's one new request is the command head's `embedRaw`,
  and it is made only when a fitted head has been adopted.
- Neither generative stage is in `draftStageIds`, so Cloud drafts never sees
  a calendar call (D9).
- The mirror, the agenda, the grid, the writes and Find a time's search call
  no model at all.

## MCP mode only

The calendar is a bond-mcps feature. `McpCalendarBackend` calls six tools:
`sync_calendar`, `get_calendar_event`, `get_mailbox_settings`, `manage_event`,
`create_calendar_event` and `find_meeting_times`. That brings the app to 22
called tools, pinned by `mcp_tool_names_test`. SDK mode's
direct Graph sign-in asks for no calendar scope and the app carries no
Graph-SDK calendar code, so `calendarBackendProvider` hands SDK mode
`UnavailableCalendarBackend`, whose every call throws `CalendarUnavailable`
with a sentence naming the connection that would give one. The sync's precheck
answers `sdkMode` before any call, and `calendarAvailabilityProvider` starts at
`sdkMode` in that mode rather than `unknown`. An empty calendar would read as
"you have no meetings"; a sentence reads as what it is.

## The data model

Two tables (`app/lib/data/schema.drift`, schema v25, `from24To25`).

| Table | Holds | Class | Written by |
|---|---|---|---|
| `calendar_events` | one row per event id, as `sync_calendar` last reported it | **synced** | `CalendarSync` via `CalendarStore.upsertEvents` / `retagRun` / `deleteEvents` / `sweepRun`; `CalendarWrites` via `CalendarSync.storeWritten` (an `upsertEvents`), `setResponseStatus` and `deleteWithOccurrences` |
| `event_briefs` | one pre-meeting brief per event occurrence ([Briefs](#briefs)) | **derived** | `MeetingBriefHandler` via `CalendarStore.putBrief`; `BriefPlanner` puts skipped rows (`putBrief`) and deletes out-of-window rows |

`calendar_events` is in `MessageStore.syncedTables`: it is mailbox data, so
**Clear AI results** leaves it and a mailbox wipe (`wipeAll`, sign-out,
**Forget everything and re-sync**) empties it. `event_briefs` is in
`derivedTables`: Clear AI results empties it, and the next calendar sync plans
the briefs again.

The time rules (D13) hold in the columns:

- A **timed** event fills `start_utc` / `end_utc` with stamps at
  `calendarStamp`'s fixed width (identical to `MessageStore.isoStamp`), so
  string comparison in SQL is chronological, and leaves the dates NULL. A
  tool row's `start_utc` / `end_utc` is read only when it ends in `Z` or a
  `±hh:mm` offset (`CalendarEvent.fromToolRow`); an empty or zoneless string
  would be read as this machine's local time, a guess, so the row is stored
  with NULL instants — unplaced — until a sync brings a usable one.
- An **all-day** event fills `start_date` / `end_date` (`yyyy-mm-dd`, end
  EXCLUSIVE) and leaves the instants NULL. It is never converted through a
  zone, which is what moves an all-day event a day for everyone west of UTC.
- Recurring series arrive **expanded** into occurrences. A `seriesMaster` row,
  if one is sent, is stored but never placed on a day.
- `response_requested`, `allow_new_time_proposals` and `is_reminder_on` are
  nullable: Graph saying nothing is not an explicit false.
- `sync_run` is the mark in mark-and-sweep (below).

The generated drift row classes are renamed (`AS CalendarEventRow`,
`AS EventBriefRow`) so they do not collide with the model's `CalendarEvent`.
Nothing reads through them; `CalendarStore` is raw SQL.

## The store

`CalendarStore` (`app/lib/data/calendar_store.dart`) is a second store over
the same database, for `ContextStore`'s reason (MessageStore is 11,000 lines)
and unlike it in one respect: this IS mailbox data.

| Method | Reads or writes |
|---|---|
| `upsertEvents(events, syncRun:, skipIds:, keepAnswerFor:)` | one transaction (a savepoint when the sync's page transaction is open); `INSERT … ON CONFLICT(id) DO UPDATE` over every column of `CalendarEvent.toDbRow`, so the column list cannot drift from the model; ids in `skipIds` are not written; an id in `keepAnswerFor` whose page status is empty, `none` or `notResponded` keeps a stored `accepted`/`tentativelyAccepted`/`declined` (the rest of the row is the page's) |
| `retagRun(ids, runId)` | sets `sync_run` on the stored rows of `ids` and nothing else; the write guard's re-tag |
| `deleteEvents(ids)` | by id; ids never stored are ignored |
| `sweepRun(runId, keepIds:)` | deletes every row whose `sync_run` is not `runId`, except `keepIds` |
| `setResponseStatus(id, status)` | the owner's answer on `id` and, for a series master, on every mirrored occurrence; returns the ids touched (the write guard notes them) |
| `deleteWithOccurrences(id)` | `id` and, for a master, its mirrored occurrences; returns the ids deleted. Both write helpers take an empty id to name nothing, because an unset `series_master_id` is `''` |
| `event(id)` | one row |
| `occurrencesOf(seriesMasterId)` | the mirrored occurrences of a series, by start; the event panel picks the one to show from these |
| `eventsBetween(startUtc:, endUtc:, fromDate:, toDateExclusive:)` | timed events overlapping `[startUtc, endUtc)` plus all-day events overlapping `[fromDate, toDateExclusive)`; a zero-length timed event counts when its start is in the span; cancelled included (the caller decides), series masters excluded; all-day first, then by start |
| `invitesOwed(nowUtc:, today:)` | `CalendarEvent.needsResponse` in SQL (a null `response_requested` counts as asked), future only — timed after now, all-day from today — soonest first |
| `nextMeetingWith(addresses, nowUtc:)` / `lastMetWith(…)` | the next timed meeting starting after now, or the latest that ended by now, with any address as attendee (`json_each` over `attendees_json`) or organiser; case-insensitive; not cancelled, not declined |
| `messagesForEvent(eventId)` | stored messages whose `source_meta_json.event_id` is the event, newest first; a `LIKE '%"event_id"%'` prefilter first, then `json_extract` guarded by `json_valid` so one malformed blob cannot fail the statement |
| `brief(eventId)` / `briefsFor(ids)` / `putBrief(…)` | the `event_briefs` reads and the handler's upsert ([Briefs](#briefs)) |
| `touchBrief(eventId, generatedAt:, inputsHash:)` | moves only `generated_at` (and the hash, if one is given); the one write a failed or skipped run makes over a ready brief |
| `deleteBriefsOfEndedEvents(nowUtc:, today:)` | the planner's cleanup: deletes the briefs of meetings gone from the mirror, timed ones whose `end_utc` is at or before now, and all-day ones whose exclusive `end_date` is at or before today — a brief for a meeting still ahead is kept however far off |

## The sync

`CalendarSync` (`app/lib/services/calendar/calendar_sync.dart`).

### The window, the run state and the cursor

A **run** is one full read of a fixed window, then delta pages for as long as
its cursor lives. A new run's window is **30 days back to 120 days ahead**
(`pastDays`, `futureDays`), at UTC midnights built from the date's components:
`[today − 30, today + 121)`. The server fixes the window on the first call and
echoes it only then, so the app persists it itself — together with the run id
(`calendarStamp` of the tick that started it) and whether the completed run
has been swept — as JSON in the `calendar_run` pref (`calendarRunKey`):

```json
{"start": "2026-09-05T00:00:00Z", "end": "2027-02-03T00:00:00Z",
 "run": "2026-10-05T15:00:00.000000Z", "swept": true}
```

If the first page echoes a window, that is what is stored. The cursor lives in
`sync_state` under source `calendar`, folder `primary`, beside the mail
cursors.

A tick starts a **new run** when there is no cursor, when the run state is
missing or unreadable, or when the window's start is more than
`pastDays + rollDays` (37) days back — the **weekly roll** that keeps the
window's past edge from drifting. The tick reads the state and the cursor,
decides, and — for a new run — clears the cursor and writes the new state
(swept false) in ONE transaction, so the two land together or not at all. An
old cursor under a new, unswept run id is never reachable: the next completed
delta page would sweep nearly the whole mirror.

### The page loop

At most `maxPagesPerTick` (10) calls per tick. Each page is applied in ONE
transaction, behind the generation check (below):

1. a window the first page echoes is written into the run state;
2. upserts `events` tagged with the run id, skipping the ids the write guard
   names and re-tagging their stored rows with the run instead (below);
3. deletes `removed` — ids never stored are ignored;
4. persists a non-empty returned cursor, **after every page**, so a failure
   keeps what was read;
5. on the run's first page that says `complete: true` explicitly, the sweep
   and `swept: true`.

The loop stops on `complete` (a page with no `complete` flag counts as done,
so a malformed page cannot spin the loop, but only an explicit `true` sweeps —
`CalendarSyncPage.explicitlyComplete`); on a page that is not complete and hands back
the cursor it was sent (the server's signal that a later Graph page failed —
tried again next tick, no error); and at the cap, leaving the cursor for the
next tick. A first read bigger than ten pages therefore spreads across ticks,
and its sweep waits until the run completes.

### Mark-and-sweep

When a run first reaches an explicit `complete: true`, every row whose `sync_run` is not the
run's id is something the calendar no longer holds inside the window, and
`sweepRun` deletes it, except ids written by this app within the write guard's
span. The state is then marked `swept: true`, and later delta pages of the
same run never sweep again. An empty cursor together with `complete` is the
server's "start a new run next time": the stored cursor is cleared.

### The generation check

A page's transaction and the cursor-expired restart's open by re-reading
`calendar_run` and abandon the tick, writing nothing, unless it still names
the tick's run. `wipeAll` deletes that pref inside its own transaction, so the
two serialize: a tick whose `sync_calendar` call was in the air across a
sign-out or **Forget everything and re-sync** cannot write the old account's
rows or cursor back. An abandoned tick ends `skipped`, leaves availability
alone and does not stamp the throttle, so the next tick begins the new run at
once. The new-run transaction at the top of a tick needs no check: it is the
one that writes the run.

The mailbox-settings write sits behind the same check but only skips itself
when superseded: the tick has already ended `synced`, so it still sets
`available` and stamps the throttle.

The check fences a wipe, not a rebuild. A rebuild of `calendarSyncProvider`
(a backend or server URL change) starts a fresh `CalendarSync`, which reuses
the stored run whenever a cursor exists and the window has not rolled, so the
old instance's in-flight tick and the new one's first tick can overlap for one
tick. Deltas are idempotent, so the cost is pages read twice, not bad rows.

### An expired cursor

`CalendarCursorExpired` on a continuation drops the cursor and writes the
state with the **same window**, a fresh run id and `swept: false` — one
transaction, for the new-run reason above — and restarts the loop once in the
same tick with an empty cursor. Rows the dead cursor brought
in keep the old id until the new run returns them; once the new run completes,
the sweep deletes whatever it did not return. An expiry on a call that already
had no cursor, or a second expiry in the same tick, is a failure, not a loop.

### When it runs: throttle, single flight, failure isolation

The inbox calls `_syncCalendar` from `_refresh`, **after** the mail load has
returned — in the same `finally` that clears the pulling flag, so a mail load
that threw still gets its calendar tick — and **without awaiting it**, so the calendar can neither fail nor
delay mail. It is never called from `ConversationsNotifier.load`. The
sixty-second poll timer does reach it — this is Graph calendar, not the Teams
messaging endpoints the terms forbid polling — but unforced, and an unforced
call inside `throttle` (120 s) of the last tick that reached ANY answer —
`synced`, `failed`, `unavailable`, `scopeMissing` or `sdkMode` — returns
`skipped` without a request, so a broken or permissionless calendar is asked
no more often than a working one. Startup and the refresh button go through `_refreshAll`,
which forces it, and arriving on the Day stop forces a tick too.

**Single flight:** an unforced call while a tick runs returns that tick's
future. A forced one returns ONE forced tick queued behind the running one
(`_forcedNext`), shared by every forced call that lands before it starts: the
running tick's pages may predate the write that asked, and it stamps the
throttle, so joining it would leave the write out of the mirror for a couple
of minutes.

`syncNow` **never throws**. Outcomes: `synced`; `skipped`; `scopeMissing`
(`CalendarScopeMissing`, or the precheck finding no `calendars.read` in a grant
that still answers `mail.read`); `sdkMode`; `unavailable` (`CalendarUnavailable`,
`ReconsentRequired`, `NotSignedIn`, or a session that cannot answer even
`mail.read` — an MCP server offline or mid-restart, which the precheck
`calendarPrecheck` tells apart from a missing scope with `read_ack_queue`'s
idiom); `failed` (anything else — a transport drop, a Graph 5xx — traced with
`debugPrint` by exception type only, and asked again once the throttle
lapses — there is no separate backoff). Progress persisted before a failure stays.

After each tick that reached an answer (never a `skipped` one) the sync's own
`onOutcome` — wired in `calendarSyncProvider` as `calendarOutcomePublisher` —
copies `CalendarSync.availability` into `calendarAvailabilityProvider` (synced
→ available; scope missing, SDK mode and unavailable → themselves; a failure
keeps the last answer, so one dropped request does not flicker the Day stop)
and bumps `calendarRevisionProvider` when rows changed or the tick wrote the
mailbox-settings cache (`settingsRefreshed`). The publisher, not the inbox, so
a tick nobody on screen awaited — the forced sync after a write — reaches the
readers too: a create or a move whose ack could not be placed shows up the
moment that sync brings it. Readers of the mirror, and the zone, watch the
revision. The inbox only plans briefs off the outcome it awaited.

### The write guard

A write this app makes calls `noteWrite(eventId)` and stores the server's
answer itself (`storeWritten`, see Writes). A page requested before the write landed would put the
old version back, so the sync stamps the instant **immediately before each
`syncPage` request**, and ids noted at or after that stamp are not upserted
from that page; a write noted before the request is already in the answer and
is not skipped. The skipped ids' stored rows are re-tagged with the run
(`retagRun`, in the page's transaction), so the sweep — however long after —
never deletes the app's own write. Ids noted within `writeGuardSpan`
(10 minutes) are also kept by a sweep, as a belt. Older notes are pruned on
every call.

The guard covers only pages requested while the write was in the air; the
forced sync after a write starts after the note, so a lagging Graph delta in it
could put `notResponded` back over the app's own answer. The belt: ids noted
within `answerHold` (2 minutes) before the page's request stamp go to
`upsertEvents(keepAnswerFor:)`, where the mirror's own ANSWER is kept against
any differing value the page carries (a page that still says `accepted` after
the owner pressed Maybe must not put it back — changing an answer is a main
flow since the clash buttons), a page that agrees is applied, and the rest of
the row is always the page's.

## Mailbox settings

After a `synced` tick, when the `calendar_mailbox` pref (`calendarMailboxKey`)
is absent, unreadable, or its `fetched_at` is older than 24 hours, the sync
asks `get_mailbox_settings` and stores `{"settings": …, "fetched_at": …}`,
behind the generation check.
A missing MailboxSettings scope is stored as `settings: null`, so it is asked
again in a day rather than every tick; any other failure stores nothing and is
asked again next tick. The fetch never changes the tick's status; a tick that wrote the cache says so
with `settingsRefreshed`, so a first fetch reaches the zone's readers even when
no rows moved.
`mailboxSettingsProvider` reads the cache (`CalendarSync.readMailboxSettings`);
`calendarZoneProvider` resolves the display zone from it — the OS zone, then
the mailbox's, then UTC.

## Activity

Kind `sync_calendar`, labelled **Calendar sync**. A row is recorded when a
synced tick changed rows, or started a new run and completed it in that same
tick (a first read spread over several ticks that ends with no changes logs
nothing): `count` = rows upserted,
detail `{removed, swept, pages, run: new|delta}`. The one error row is
`status: error`, `detail: {outcome: scope_missing}`, recorded on the
TRANSITION into that state, not every tick. `failed`, `unavailable` and SDK
mode write no row. Counts and enum words only — never a subject, a name or an
address.

Kind `calendar_write`, labelled **Calendar**: one row per write the owner
made, `detail: {action, outcome, notified}` plus `undo: true` on an Undo's own
write — `Calendar — Accepted a meeting · emailed 1`, `Calendar — couldn't move
an event (changed)`; a failed accept, maybe or decline all read `couldn't
answer a meeting`, since it gave none of them. The same rule: no subject, no
address, no event id.

Kind `find_time`, labelled **Find a time**: a search's slot count and whose
calendars answered, and what was done with the slots — see
[Find a time](#find-a-time).

## The two prefs and a wipe

`calendar_run` and `calendar_mailbox` are declared beside the bootstrap floors
in `message_store.dart` and deleted by `wipeAll` with `mail_last_reconcile`:
the first describes a run over rows the wipe deletes, the second one mailbox's
zone and hours, which the next account may not share. The cursor goes with
`sync_state`. Clear AI results touches none of them — it does not undo a sync.

## Meeting fields on messages

`read_email` answers `meeting_message_type` (`none` for ordinary mail, else
Graph's value as spelt, `meetingTenativelyAccepted` typo included) and
`event_id` (the linked event, or null when there is none or it is gone).
`McpMailBackend.getMessageDetail` renames them to `meetingMessageType` (Graph's
own key, dropped for `none`) and `calendarEventId`, so
`SyncService._fetchDetailInto` reads one shape from both backends and stores
them in `source_meta_json` as `meeting` and `event_id`, each omitted when
empty. `Message.meetingMessageType` and `Message.meetingEventId` read them;
null means "nobody said", never "not a meeting". `event_id` is how the
event panel and the invite cards link a message to its event
(`CalendarStore.messagesForEvent`). The
SDK backend never sets `calendarEventId`. `read_email`'s `is_auto_reply` is
mapped the same way, to `isAutoReply`, and stored as `auto_reply: true` only
when true; `Message.isAutoReply` reads it, and nothing gates on it yet (D15,
[the follow-ups](#owner-checks-and-follow-ups)). `read_email`'s `not_found`
error is mapped to a 404, which the sync skips like any vanished message.

**The backfill.** Rows fetched before the server sent these fields carry
neither key. The one-shot `meeting_detail_backfill` in `SyncService._pass`
re-fetches them once: `MessageStore.meetingBackfillCandidates` picks inbound
email from the last 30 days with no `meeting` key whose subject opens with a
calendar response's prefix (`Accepted:`, `Declined:`, `Tentative:`,
`Tentatively accepted:`, `Canceled:`, `Cancelled:`, `New time proposed:`) or
equals, case-insensitively and trimmed, the subject of an event in the mirror
(an invitation carries the meeting's own subject, unprefixed) — newest first,
at most 200. It runs only once `MessageStore.calendarMirrored()` is true —
the `calendar_run` pref parses with `swept: true`, meaning the first full read
completed and was swept (a cursor alone is not enough: a first read spread
across ticks holds one after its first page) — which makes it MCP-only and
keeps it from spending its shot on a partial calendar. It runs once inside a
mail pass, so that one pass can be held up by up to 200 sequential detail
fetches, by design. After a clean loop it re-gates meeting responses the way
`meeting_regate_crlf` does and sets the pref to `1`; any throw stops the loop
and writes `attempt:<n>`, owed next sync, without failing the sync. The gate
runs while the pref is absent or `attempt:…`; the third failed pass writes
`1` and closes it, so a message that always fails cannot cost every sync. It reports `backfilled_meetings` (and any
`regated_meeting_responses`) on the `sync_mail` row. `wipeAll` deletes the
pref; Clear AI results keeps it, because it keeps `source_meta_json`.

## The Day stop

**What happens.** The icon rail's Day stop (one of eight rail stops, right after Needs You)
shows one day at a time as a MERGE of three things the app already holds: the mirror's events,
the deadlines triage read out of the mail, and the threads coming back from
Later. The merge is pure (`app/lib/services/calendar/day_items.dart`,
`buildDayItems`); `DayPane` only draws it. The reads are
`app/lib/providers/day_providers.dart` — `dayEventsProvider(day)`,
`upcomingEventsProvider(today)` and `invitesOwedProvider(asOf)` — and every
one reads the store, never the backend, and watches `calendarRevisionProvider`.
Every family argument is computed by the inbox from the clock on each build —
a date for the two event reads, and for the invites an "as of" UTC instant
floored to the quarter hour (`invitesAsOf`) — so a stop left open across
midnight moves on with the next rebuild and a started invite drops off within
fifteen minutes. Picking today stores no date: an explicit Today follows the
clock just as arriving on the stop does. Arriving on the stop from another
one clears the side panel, as any stop does; stepping the date once there
(the arrows, the column's day rows, the grid's paging) keeps it open.

### What a day holds, in order

1. **All-day events**, in the store's order. They are dates, not instants, and
   head the day rather than sitting at a midnight they do not have.
2. **Deadlines**: every thread that is not done whose `latestDeadline` passes
   `showableDeadline` and whose `parseDeadline` day is this day. Relative
   deadlines resolve against the inbound message that named them
   (`lastInboundAt`, falling back to now), so "EOD" said three weeks ago is not
   due today; a deadline whose day has passed does not appear on today's
   agenda — overdue work lives in Needs You. A meeting message — anything
   whose `source_meta_json.meeting` names a type other than Graph's `none` —
   never names a deadline: the query reads its `latest_deadline` as NULL (and
   `latestInboundMeta` its `deadline`, so attention is not raised either),
   `Message.fromRow`/`fromJson` read its `deadline` as null (the message row's
   chip, the re-fold, notifications), and the extraction stores none and puts
   no "by …" on the thread's ask, so an invitation is never a Due row; its
   time is the event's to show. A
   deadline's day is read in the device zone (`DateTime.toLocal()`), meetings and returns in the display
   zone; the two differ only when the OS zone lookup fails and the display
   zone falls back to the mailbox's — a known edge.
3. **Everything with an instant**, by that instant: meetings, **returns**
   (threads in Later — `bucket = 'later'`, not done — whose `snoozed_until`
   falls on this day in the display zone) and the **Now marker**. The marker
   sits after every row that started strictly before now and before every row
   starting at or after it, so a meeting starting this minute reads as next.
   A meeting and a return at the same instant put the meeting first.

A thread gives ONE row per day: a deadline beats a return. A declined meeting
is not on the day at all — the owner said no, and Outlook removes it from the
calendar anyway; the local apply marks it declined at once, so the row leaves
before the write returns. A cancelled meeting stays, struck through with a
`Cancelled` caption, because a meeting that silently vanished is one somebody
turns up to. Every meeting row wears its standing (`standingOf`): a 3-px bar
down the left of its body (`DayPane.standingBarKeyFor(id)`) in
`standingBarColor` — the grid tiles' palette, so a Maybe is the same colour
in both faces; an unanswered or cancelled bar is muted, the buttons or the
caption doing the talking — and a `Maybe` caption for a tentative meeting
(accepted, yours and no-answer-needed stay quiet). Each meeting's
overlaps come from `overlapsForEvent` against that same day's events,
which skips cancelled, declined, free and workingElsewhere; a cancelled
meeting has no overlaps of its own either. A tentative hold — a Maybe answer,
or anything Outlook shows as tentative, which is how an unanswered invite
sits (`isTentativeHold`) — is a soft overlap; the rest are hard. A timed event sits
on every local date it touches, from the date of its start through the date of
the instant just before its end; an all-day event on every date in
`[startDate, endDate)`.

A meeting that overlaps another carries a **clash strip**
(`DayPane.clashKeyFor(id)`) in place of the old one-line summary: `⚠ overlaps`
(in the error colour when any clash is hard, muted when every clash is soft —
the grid's rule) and one chip per clashing meeting — hard first, then soft (muted, ending
` · maybe` for a Maybe, ` · not answered` for an invite still owed an answer,
` · tentative` otherwise) — labelled `subject · time` (`clashLabel`), keyed
`clashChipKeyFor(id, otherId)`; a chip opens THAT meeting beside, and its
press is the chip's, never the row's open. The word is overlap or clash,
never "conflict" (that is an etag rejection here). For a meeting the owner
attends (`canRespond`) the compact answer buttons stay on a clashing row even
after answering — the current answer drawn as chosen — so one side can be
stepped down to Maybe or declined from the row; an organiser's clashing row
shows the strip and no buttons (the panel has Move and Cancel), and an ended
one shows none. The invite rows and the meeting card keep the one-line
`overlapLine`.

Times print on the display zone's wall clock (`zone.toLocal`, never
`DateTime.toLocal()`), in the house 12-hour style: `10:00–10:30 AM`,
`11:30 AM–12:30 PM`, `11:00 PM–Wed 1:00 AM`. A meeting counts down (`in 18m`,
`now`) inside the hour before it and while it runs, and carries **Join** from
fifteen minutes before its start until its end. The agenda sits under one
30-second clock tick, so the Now marker, the countdowns and Join follow the
clock on a pane nobody touches. A meeting, all-day or invite row opens the
event beside ([Events, invite cards and people](#events-invite-cards-and-people)).
An unanswered meeting's row (`MeetingItem.needsResponse`) carries the compact
Yes / Maybe / No / Dismiss under its text, through the host's `meetingActions`
builder (one `CalendarWriteFlow` per event, `agenda-write-<id>`, no series
folding — the row IS the occurrence), as does an attended meeting with a
HARD clash, or a soft one whose other side answered Maybe (above) — never
for an unanswered pencilled invite beside it, which is the side to settle and
has its own buttons; the 'RSVP owed' chip gives way to the
buttons and is drawn only when no builder is given or once the meeting has
ended (an ended invite gets no live buttons). A press inside is the
button's, never the row's open. Rows are keyed `DayPane.meetingRowKeyFor(id)`.

### What shows, per availability

| `CalendarAvailability` | Day pane | Today section |
|---|---|---|
| `available` | rows; an empty day says `Nothing on your calendar.` | shown |
| `unavailable` (offline) | rows as saved, under `Can't reach the calendar right now — showing what was saved.`; an empty day says `Nothing saved for this day.` | shown |
| `unknown` (no tick yet) | rows; an empty day says `Reading your calendar…` | hidden |
| `scopeMissing` | no rows; `Calendar permission needed — Settings › Connection` and **Open Settings** | hidden |
| `sdkMode` | no rows; the SDK-mode backend's own sentence | hidden |

The Invites view follows the same table: the same sentences for `scopeMissing`
and `sdkMode` (never `No invites to answer.`), the offline caption for
`unavailable`, and nothing at all while the read is still in flight.

`calendarShowsMirror` (the first three) is the providers' gate too, so a switch
to SDK mode stops the stale rows showing without deleting them.

Offline, the other surfaces drawn from the mirror say where their answer came
from in one muted line, `From the saved calendar — can't reach Outlook right
now.` (`offlineCaption` in `day_items.dart`): the command bar's plan card (an
answer, slots or a proposal — a refusal read nothing and says nothing), the
event panel over a found event, and Find a time. Each takes the availability
as a prop; the inbox reads the provider.

### Invites owed

`invitesOwed` answers every expanded occurrence of an unanswered series, so
`collapseInvites` folds them by `seriesMasterId`: one entry, the SOONEST
occurrence shown, the rest counted (`· series` on the row). An invite is
**pinned** when any linked invite message — linked to the occurrence, or to
its series master, through `messagesForEvent` — has a stored decision with
urgency `high` or `urgent`, or importance `high`. Pinned entries come first,
then soonest first. A decision read that throws costs that invite its pin,
never the list. Overlaps for all invites come from ONE `eventsBetween` over
the span they cover, capped at 121 days. Each row carries Yes / Maybe / No /
Dismiss (see Writes), and an unanswered meeting's agenda row carries the same
Yes / Maybe / No / Dismiss, so an invitation is answered where it is seen. A row answers the whole series, through its master's id, only
when more than one occurrence is owed AND the one shown is a plain occurrence
(`InviteEntry.answersSeries`); a single owed invite, and a lone owed exception
— a moved meeting of a series answered already — answers itself, since an
answer to the master would re-answer every meeting in it. `· series` on the
row (`isSeries`) still says the meeting belongs to one.

### The list column and the Today section

The Day stop's column is `Invites · N` (when any are owed), then today and
tomorrow ALWAYS, then each later day up to fourteen out that has anything on
it (`upcomingDays`), labelled by `dayRowLabel`: `Today · 2 meetings · 1 due`,
`Tomorrow · clear`, `Fri Oct 2 · 1 back · 1 invite`. The threads are narrowed
once to those whose deadline or return lands inside the window, by the same
rules the merge uses, and the column is only worked out while the Day stop is
showing. Meetings counted are the
commitments — timed and all-day, not cancelled, not declined. The arrows on
the pane stop at the mirror's window, thirty days back and 120 ahead.

The Inbox stack's **Today** section sits under Needs You: up to three timed
meetings still ahead today — not cancelled, not declined, not ended
(`remainingToday`) — each with its countdown, its label ending ` · Maybe`
for a tentative meeting or ` · RSVP owed` for one still owed an answer — then
`Invites · N`. It shows
only while the calendar is `available` or `unavailable`, so a launch does not
grow the section and then lose it.

### The grid

The pane's **Agenda | Grid** control switches the day between the list above
and a time grid (`app/lib/widgets/day_grid.dart`, `DayGrid`); beside Grid,
**Day | Week** picks one column or seven. Both choices are remembered in
`app_prefs` as `day_view` (`agenda` | `grid`) and `day_grid_span` (`day` |
`week`), read once when the inbox starts and written on each press; a press
on one control before that read lands keeps the press and still restores the
other's stored value. The week starts on **Monday** (`mondayOf`), and its
events come from `weekEventsProvider(monday)` — the seven local days
`[monday, monday+7)`, so a Sunday-night meeting that is already Monday in UTC
stays in its own week. The arrows step a week on the week grid and a day
everywhere else; paging the grid itself moves the pane's day the same way, and
both stop at the mirror's window (`DayPane.daysBack` / `daysForward`, the
grid's `displayRange`). The availability table above holds for the grid
exactly as for the agenda.

While the next day's or week's read is in flight the grid keeps drawing the
last list it had (`_lastGridEvents` on the inbox, dropped on a zone change)
rather than unmounting for "Reading…", which would rebuild the view and
scroll it back to the morning on every arrow. Tiles are placed by their own
instants, so the old list draws nothing on a page it does not touch. "Reading
your calendar…" shows only before the first list.

The grid is drawn by **`kalender` 0.32.0, pinned exactly**: the package is
pre-1.0 and its minor releases rename controllers and callbacks, so a caret
range would break the build on a routine `pub upgrade`. The app calls
`initializeDateFormatting()` before `runApp`. Today it cannot be needed — the
app formats in en_US (no `flutter_localizations`, no `Intl.defaultLocale`),
which intl compiles in — so it is forward-proofing for the day the app takes
a locale, when the grid's day names would throw in any other; it is cheap and
in-memory.

- **Tiles.** A timed event is a tile at its instants on the display zone's
  clock, titled by its subject (plain text) with its range when there is
  room. A tile wears the owner's standing — `standingOf`
  (`app/lib/services/calendar/event_standing.dart`, re-exported by
  `event_view.dart`), the ONE reader of `responseStatus`, and of `showAs` for
  the tentative hold (`overlaps.dart` reads `showAs` once more, only to drop
  `free`/`workingElsewhere` time — blocking, not standing). The owner's ANSWER
  wins over `showAs`: Outlook pencils every new invite in as `showAs:
  tentative` and a fresh Yes moves `show_as` only on a later delta, so an
  accepted meeting shown tentative is Accepted on every face (the second live
  pass found a just-accepted meeting called a Maybe for minutes); the mirror's
  `setResponseStatus` also moves `show_as` as Outlook records an answer
  (tentative → busy on Yes, → tentative on Maybe) — in
  the one palette every calendar face shares (`toneOfStanding`,
  `standingBarColor`, `standingFillColor` in
  `app/lib/widgets/event_standing_style.dart`):

  | Standing | Tile |
  | --- | --- |
  | accepted, yours, no answer needed | primary fill, primary bar |
  | maybe — a tentative answer, or an accepted meeting shown `tentative` | attention tint, attention bar |
  | maybe — asks no answer and is shown `tentative` | attention tint, attention bar |
  | not answered (Outlook pencils such an invite in as `tentative`; it is still not answered) | faint fill, thin primary border, muted bar — the agenda row carries the buttons |
  | cancelled | grey, struck through |
  | declined | no tile |

  A hard overlap turns the bar the ERROR colour (never attention, which is a
  Maybe's) and puts '⚠ ' before the title; a soft one (the other side is a
  tentative hold) only the '⚠ '. So the marks are asymmetric: next to an
  accepted meeting, the Maybe tile's bar turns the error colour (the accepted
  one is a hard overlap for it) while the accepted tile only gets the '⚠ ' —
  a soft clash marks the side that is not firm. Overlapping tiles are laid **side by side**
  (`MultiDayBodyConfiguration(eventLayoutStrategy:
  EventLayoutStrategy.sideBySide())`), dividing the column instead of
  covering each other, so a clash shows as two tiles.
- **The all-day header** holds all-day events, the day's **deadlines** (`Due ·
  subject · the sender's words`) and **returns** (`Back: subject`), taken by
  `rangeMarkers(from, toExclusive)`, which shares its one private rule with
  `buildDayItems` (a deadline claims its day from a return on the same day),
  so the two views cannot disagree about what falls when — without running
  the day's overlap maths seven times for a week. A deadline or return opens
  its thread; an event tile opens the event beside. Marker tiles are keyed
  `DayGrid.markerKeyFor(source, id, kind: 'due' | 'back')`.
- **The Now line** follows the clock through the package's own indicator, fed
  the display zone's wall time, so "today" is the display zone's today.
- **Drag and resize** are offered only on a timed event that `canMove` allows
  (the organiser's own, not cancelled, not a series master), snapping to
  fifteen minutes and never to the Now line. A drop is a PROPOSAL, not a
  change. A drop where the tile already was (a click that wobbled, which the
  package snaps back and still reports) stops in the grid and costs nothing.
  Any other drop goes to the host, which runs `checkDrop` — the typed move's
  own refusals in its words: "That's when it already is.", "That time has
  passed.", "A meeting needs to end after it starts." — and a refusal is a
  toast with nothing written. A drop that passes runs `MoveEvent.timed`
  through the same `CalendarWriteFlow` as every other write — an own event
  moves at once and offers Undo, a meeting with guests waits on the confirm
  strip, drawn over the grid, naming who is emailed. While that write is in
  flight the grid is `locked` (every tile undraggable) and shows where the
  move would land as a ghost tile titled "Move here?" with the caption "Send
  or Cancel above" (it is the move the strip asks about, not a new event; on
  a half-hour tile the caption rides the title's line), which the flow's `onIdle`
  takes down when the write goes through, fails or is dismissed. The grid
  never moves the tile itself: it renders from the store, so a refused,
  failed or dismissed move leaves the tile where it was, and a move that went
  through moves it when the mirror does.
- **What a drag shows.** kalender draws NOTHING while a tile moves unless it
  is given the drag builders, so the grid gives all three: the tile itself
  follows the pointer at the landing size, 85 % opaque with a primary
  outline (`feedbackTileBuilder`, `DayGrid.feedbackKey`); the tile left
  behind fades to 35 % (`tileWhenDraggingBuilder`, `DayGrid.draggedKey`);
  and the landing span is outlined as the pointer moves, the ghost's own
  look (`dropTargetTile`, `DayGrid.dropTargetKey`). The anchor is
  `childDragAnchorStrategy`: the copy stays under the grab point, and its
  top and LEFT edges are what kalender reads for the landing time and day
  (so a sideways drag of exactly one column can land a fraction short;
  the outline shows where it will land).
- **Resize zones.** A tile's resize bands are 10 px at its ends
  (`KalenderTheme` → `ResizeHandleStyle(length: 10)`, kalender's default
  is 16), shown to a hovering mouse or a selected tile, each marked by a
  small primary pill (`TileComponents.verticalResizeHandle`) drawn on a
  transparent fill of the whole band — kalender's resize `Draggable`
  hit-tests only its child, and a bare pill made the band a 3-px line: the
  middle of a 30-minute tile drags and only its last 10 px resize; the
  start band hides where kalender hides it (on a short tile). kalender
  reads a resize's end from the pointer's COLUMN as well as its height, so
  an end handle drifting into the next day would make a two-day span: the
  grid refuses a resize whose new span leaves the day or days the meeting
  already covered (`DayGrid.resizeKeepsDays`; an own overnight meeting may
  be moved or resized within the days it already covered), the tile snaps
  back and
  the host toasts "A meeting stays on one day — move it instead."
  (`onRefused`); a move, the same length, still crosses columns.
  `DayGrid.staysOnOneDay` (the host's belt) compares the dates of a span's
  first and last minute only, so a 25-hour fall-back day is one day.
  The host's belt (`_reproposeFromGrid`) keeps the grid's rule: a span on
  one day, or one inside the days the standing proposal already covered
  (`resizeKeepsDays`, so a shortened overnight proposal re-proposes), and
  refuses anything else — a resize in the grid's words, a same-length move
  in its own (below) — whatever handed it in.
- **The ghost tile.** `DayGrid.proposal` draws a tile — a solid 1.5 px
  primary outline on an 8 % fill; solid because Flutter's `Border` has no
  dashed style — for a time that is not on the calendar: the pending drop's
  "Move here?" over "Send or Cancel above" (`GridProposal.caption`, an
  unnamed ghost's caption), which is undraggable (`adjustable: false`), and a
  standing proposal, "Proposed" ([The bar](#the-bar)), which moves and
  resizes (the proposal tile, below).
- **The proposal tile** (a standing proposal's ghost) is a kalender event of
  its own kind. It is NAMED: the invite's subject ("Re: dinner on friday"),
  the blank event's name as its card's field reads it (the card's
  `onSubjectChanged` → `_proposalName`), or the moved meeting's subject,
  with "Proposed" as its caption (`GridProposal.subject`; on the same line,
  "Re: dinner on friday · Proposed", when the tile is one line tall). It is ADJUSTABLE
  (`GridProposal.adjustable`, when the grid is not `locked`): it moves and
  resizes like an own event, to another time or to another day's column in
  Week view, and the grid asks `onProposalChanged(startUtc, endUtc)` without
  moving it. The inbox (`_reproposeFromGrid`) makes the same proposal again
  on the new span — an ask's slot again (`_pickAskSlot`, the same ask and
  people), a blank event under its typed name, a typed command's write
  rebuilt on the span and dry-run against its own meeting
  (`_reproposeCommand`, keeping the outcome's reading) — and the ghost is
  redrawn where that answer puts it; nothing is stored, and a proposal that
  does not change leaves the ghost where it was. A move of a meeting the
  owner may not move is never adjustable (the drop's `canMove`); a moved
  ghost goes through the one past rule (below) and the drop's own refusals
  (`checkDrop`: "That's when it already is."). A same-length MOVE across
  midnight is refused in its own sentence, "A meeting stays on one day —
  pick a time inside it." (`moveLeavesDay`), since "move it instead" is what
  the owner just did; a resize across it keeps the grid's. EVERY
  re-proposal keeps its card and ghost on screen through the dry run — a
  typed command's and a blank event's through `_reproposeCommand`, an ask's
  invite through `_pickAskSlot(keep: true)` → `_showProposal(keep: true)`,
  so the row's "Proposed:" line stays too. A blank event's carries its
  typed name (`CommandPlanCard.initialSubject` ← `_Proposal.name`, so the
  new card — keyed by the moved serial, built while the dry run is out —
  shows the name as typed, not the old write's "New event",
  `blankEventSubject`) and its guests (`_Proposal.attendees`); text
  half-typed in the With line is not carried. A dragged ask's invite keeps
  the message its slot was first picked for
  (`_pickAskSlot(messageId: _Proposal.messageId)`). While the card's write is out
  (`CommandPlanCard.onWritingChanged` → `_writingSerial`, the serial of the
  card that reported it; `_cardWriting` holds only while THAT card stands,
  so a typed Enter, a slot pick or a re-proposal during the write leaves
  the new card's grid live) the ghost holds still, a tap on it is ignored
  (`onProposalTapped: null`) and an empty-time press proposes nothing, so
  the write in the air is the one the card shows. A new card never flashes
  as it appears. In Day view
  a tile cannot leave its one column: to another day, Week view, or the Day
  bar's "move … to …". A TAP on it flashes its card once
  (`CommandPlanCard.flash`, a 600 ms fade, never looping); the card sits
  above the grid and never scrolls out of view, so no scrolling is needed.
  Only the card's frame flashes: its body is never rebuilt by a tap, so a
  typed name, a standing confirm strip and a write in the air all survive
  one, and the write still says when it is done.
- **The one past rule.** Every entry that proposes a time — a press on
  empty time (`_createFromGrid`), an ask's slot (`_pickAskSlot`) and a
  dragged ghost (`_reproposeFromGrid`) — first asks `_refusePast`: a start
  before now is a toast, "That time has passed." (`pastRefusal`), with
  nothing dry-run and no card; with an ask open a past press is refused,
  never turned into a blank event. Every `propose` the inbox calls passes
  `now:`, so the planner refuses the same start again as the belt (a card
  held on screen past its start). A refusal's toast carries no Undo and is
  the one kind of bar that leaves the `z` slot as it was (`_toast(keepUndo:
  true)`): nothing was done, so the write just done can still be undone.
  The four calendar refusals keep it — the past rule, the cross-midnight
  belt, the grid's `onRefused` and a moved ghost's `checkDrop` refusal.
  Every other bar without an Undo still empties the slot, as before.
- **A press on empty time is a PROPOSAL too.** The body allows creation
  (`allowEventCreation` while not `locked` and the host passes
  `onCreateRequested`; the all-day header never). kalender 0.32 has two
  create gestures, both Draggables: `tap` (a plain Draggable that starts on
  the first movement — a desktop press-and-drag sizes the span as the
  pointer moves) and `longPress` (held first, what a phone needs). The grid
  picks `tap` on the desktop and `longPress` on Android and iOS. Neither makes
  an event from a bare tap, so a bare tap on empty time comes through
  `onTappedWithDetail` (a `DayDetail`; the header's `MultiDayDetail` is
  ignored) and takes `defaultCreateMinutes` from the quarter hour tapped; a
  drag of a quarter hour or less does too. The span reaches the host
  through `onEventCreated` → `onCreateRequested(startUtc, endUtc)`, and the
  grid adds NOTHING — kalender leaves adding a created event to the host,
  and this host never does, so the grid stays a mirror of the store, as for
  a drop. The inbox (`_createFromGrid`): with an ask open in the Day column,
  the span is that ask's slot (`_pickAskSlot`: its day, the card, the
  `Proposed` ghost, Send) and `defaultCreateMinutes` is the ask's length;
  with none, it is a **blank event**: `CreateEvent.propose(subject: 'New
  event', …)` through `_showProposal`, whose card (`subjectEditable`) draws
  a name field (`CommandPlanCard.subjectKey`, focused) above the summary.
  The field starts EMPTY under its hint, "Name this event" — prefilled, the
  first keystroke wrote "New eventL" — and the summary says "New event"
  while it is blank; it re-words the summary with `writeSummary` as the name
  changes, and at the press writes `CreateEvent.withSubject(name)` (empty →
  "New event") under the proposal's own `transactionId`. Under the name, a
  **With** line (`CommandPlanCard.withKey`, "With — a name or address")
  takes people on Enter or a comma: each name goes through `matchPeople`
  against the card's `people`; one person is a chip (× takes it off), a name
  several people share is a row of buttons to pick from, an address is that
  address, and a name the directory lacks — or knows only in part — is
  looked up through the card's `searchPeople` (`search_people`), else
  refused in the planner's own sentence ("I don't know who … is — name
  someone from your mail."). The chips ride the write as
  `withAttendees(…)` (an online meeting, the same `transactionId`) and go
  up through `onAttendeesChanged`. With anyone on it the create confirms
  (`needsConfirm`): the card says "This may email: …" from the chips and
  Send, and the press shows the strip. With nobody on it the write goes
  straight on with its Undo, the Writes policy as it stands. Both fields are
  off while the card's write is out. A name left in the With line without
  an Enter is taken at the press (`ready`): it goes on the write when it
  resolves, and otherwise the press stops with the caption or the choices
  under the field, never a private event in place of an invite. Do it is
  off while a directory lookup is out, and a lookup answering after the
  write went adds nobody. The inbox hands the card the bar's own
  people (`_commandPeople`) and the bar's directory lookup
  (`_searchCommandPeople`: `PeopleBackend.searchPeople`, five hits, each by
  `directoryAddress`, as the router's Enter does; a failed search throws on
  and the card says "Couldn't search the directory.",
  `CommandPlanCard.directoryFailedText`, never that nobody has the name),
  and keeps the chips (`onAttendeesChanged` → `_Proposal.attendees`, one
  record with the typed name, the ask and its message, dropped whole with
  the command), so a drag of the ghost re-proposes with them and the new
  card starts from them (`initialAttendees`).

## Events, invite cards and people

A meeting opens as the ninth side panel, `EventPanel(eventId)`
(`app/lib/widgets/event_panel.dart`, hosted by `InboxScreen._eventPanel`).
The id resolves through `eventByIdProvider`
(`app/lib/providers/event_providers.dart`):

1. Calendar not shown (no permission, SDK mode) → `blocked`, and the panel
   says the Day stop's sentence. Neither the store nor the server is asked.
2. The mirror row, when there is one. A series master brings its mirrored
   occurrences (`CalendarStore.occurrencesOf`), and every view shows the
   first non-cancelled one that has not ended, else the last
   (`displayOccurrence`), marked `· series`.
   A date outside the current year carries its year.
3. Otherwise a live `get_calendar_event` — an invite for a meeting outside the
   121-day window, say, or a recurring invite: the mail names the series
   MASTER, and calendarView mirrors the occurrences without it, so a live
   master still takes its occurrences from the mirror. The answer is held in memory ONLY: a row written
   outside `CalendarSync` would be swept by the next run (gotcha 36).
   `CalendarEventGone` → "This event no longer exists."; a live
   `CalendarScopeMissing` → `blocked`, with the permission sentence and
   **Open Settings**; a `CalendarUnavailable` in SDK mode → `blocked` with
   SDK mode's sentence; any other failure → "Couldn't reach the calendar. Try
   again in a moment." — except a live RE-read after an earlier one found the
   event (a revision bump re-runs the read, and a master the mirror does not
   hold is read live each time), which keeps the event it had rather than
   turning an open panel into that sentence.

The panel holds: when (`Tomorrow · Wednesday, Sep 30 · 10:00–10:30 AM`, or
`All day · …`) with a live countdown; Join (emphasised from fifteen minutes
before the start, absent once it has ended, when cancelled, or with no link);
**Open in Outlook** (`web_link`); where; who organised it; your own answer
(`You accepted`, `You haven't answered`, …; `responseLine` reads the standing,
and says "You said maybe" only for a tentative ANSWER; the line wears the
standing's tone colour, `toneOfStanding`); the clash list — `⚠ overlaps`
(`overlapKey`; the error colour when any clash is hard, muted when all are
soft) then one row per clashing meeting, hard first, `subject · time`
(a soft one ending ` · maybe`, ` · not answered` or ` · tentative`), keyed `EventPanelBody.overlapRowKeyFor(i)`, each
opening that meeting in the same side panel on top of this one through
`onOpenEvent` (the host's `_openEvent(id, push: true)`, so Back returns;
null leaves the rows inert); the attendees
with their answers under a tally; the conversations linked to the
event; and the invite's own text (untrusted — never HTML; drawn through
`LinkedText`, so a web address in it, a Teams invite's "Join:" line, is a
link, http(s) and mailto only). Every link it offers goes through
`_launchExternal`'s scheme guard.

**The tally** counts people, never rooms, the organiser, or an entry whose
answer is `organizer`. On a meeting you organised — `isOwnersEvent`
(`isOrganizer`, or the response `organizer`), the rule `eventRoleOf` and the
response line read too — it is the whole picture —
`4 of 6 accepted · Sam declined · 1 no reply`. On an attendee's copy Exchange
does not reliably track the other attendees' answers (they commonly read
`none`), so the tally names only definite answers — `2 accepted · Sam
declined` — and is absent when there are none. Whether an attendee's copy
carries answers at all is an owner live check.

A live read that fails leaves the panel saying so with a **Retry**, which
drops the cached answer (`ref.invalidate`) and asks again; a failed mirror
read reads as the same "Couldn't reach the calendar. Try again in a moment.",
never as a panel stuck on "Reading…".

**Linked conversations** (`eventLinksProvider`): every stored message whose
`source_meta_json.event_id` is the event — or, for an occurrence, its series
master — folded to one row per conversation, each with its storyline chip
when the thread is in one: the occurrence's own links newest first, then the
master's, then the meeting chat. The Teams meeting chat is added when
`teamsThreadId` parses out of the join link AND a `teams` conversation with
exactly that chat id is stored; a short join link carries no id, and nothing
is guessed from one. A conversation row opens the thread pushed on the event,
so ✕ comes back to it.

**Invite cards.** A message whose `meetingMessageType` is `meetingRequest` or
`meetingCancelled` (compared lowercased) AND whose `meetingEventId` is set
carries a card under its body (`MeetingCardHost` → `MeetingCard`). No id, no
card — nothing is matched by subject. Responses never get one; the gates have
already kept them out of the list. A request card shows the when line, the
overlap line, the tally, Yes / Maybe / No / Dismiss while unanswered (see Writes), Join and **Open
event**; a cancellation, or a request
whose event has since been cancelled, is one line — `Cancelled: Design review
· Friday, Oct 2 · 10:00–10:30 AM`. An event the calendar no longer has says
so in one line. A message with a request card never starts folded in the transcript; a
cancellation folds like any other history.

**People.** A person's room leads with `Next meeting: … · Last met 12 days
ago`, from `nextMeetingWith` / `lastMetWith` over every address in the room
(`personMeetingsProvider`, keyed by the addresses and the host's quarter-hour
"as of" instant). Because that instant is floored to the quarter hour, a
meeting already under way can still be named "Next meeting" for up to fifteen
minutes. "Days ago" counts display-zone dates, not 24-hour spans.

## Writes

Answering, proposing, moving, cancelling, deleting and creating, through
`CalendarWrites` (`app/lib/services/calendar/calendar_writes.dart`, behind the
`CalendarWriter` seam, `calendarWritesProvider`). The rules a UI needs — which
writes an event offers, how a typed time becomes one, every sentence — are
pure, in `write_rules.dart`.

**Autonomy by risk (D5).** Every write runs as a dry run first, and the dry
run's `notifies` — the addresses the real write would email — decides what
happens next: a write that emails anybody, and every answer, cancel or delete,
waits on an inline confirm (`WriteConfirmStrip`: the summary, "This emails:
…", the confirm and dismiss buttons — **Send** / **Cancel**, **Delete** /
**Keep it**, **Cancel meeting** / **Keep it** (`confirmLabelFor`,
`dismissLabelFor`; the plan said Send / Cancel throughout, but a second
"Cancel" beside "Cancel meeting" reads as the same press) — Enter and Esc —
and, when a write that confirms by its kind
came back from the dry run naming nobody, "This may email: …" from the event
as the app reads it (`mayEmailFor`: the organiser for an answer, the people on
a create, the guests of a cancel or a delete), so a strip never confirms while
saying nothing about mail); anything else goes at once and offers an
**Undo** through the app's one toast (five seconds, `DraftNotifier.undoWindow`,
and `z`). The host honours an Undo — the toast's button or `z` — for twice
that window (`calendarUndoWindow`, 10 s, `calendarUndoStillOpen`); after it,
"Too late to undo that — open the event instead." and nothing is sent. Every
answer confirms by its
kind, not by the dry run's list: each one is sent and emails the organiser,
whatever the server happened to name. An Undo exists only for a write whose
DRY RUN emailed nobody — a commit made without a preview never offers one —
because an answer, once sent, can be followed by another but not taken back.

**Dismiss.** `RespondToEvent(sendResponse: false)` — Outlook's "Decline › Do
not send a response": a decline that tells the organiser nothing, so the
meeting leaves every device and nobody is emailed. `EventActions` offers it
(`event-actions-dismiss`, after No) only while the invite is unanswered
(`CalendarEvent.needsResponse`), in compact and full mode alike, and never
with the typed note or a proposal (Graph refuses both without a response;
`_send` asserts it and sends neither). It still waits on the strip because
the owner asked for the confirm: the summary reads `Dismiss "subject" · when —
declines without telling the organiser` (a series: `Dismiss every meeting in
…`), the buttons **Dismiss** / **Cancel**, no "This may email" line
(`mayEmailFor` is empty for it), and the toast `Dismissed "subject" — nobody
was told.` The mirror marks it declined at once, so the row leaves the agenda,
the grid and the Today list (a declined meeting is not drawn); its activity
row is a `decline` with `quiet: true`, read as "Dismissed an invitation". It
has no Undo and no Try again, as every answer.

The Undo is itself a write sent with no confirm, so it runs its own dry run
first (`_refuseUndo`) and is refused, with nothing sent, when:

- the dry run now lists anyone (a guest added since) — "Undo would email
  people now — open the event instead." (`undoRefusedSentence`);
- the event's change key moved since the write it undoes — "This event
  changed in Outlook — check it and try again." A create's undo, a delete,
  carries the ack's key as `DeleteEvent.expectChangeKey` and checks it against
  the mirror's (else the live) key before sending; a move's undo carries the
  post-move key as `MoveEvent.ifMatch`, so the server refuses it with
  `event_changed`.

A refused undo's activity row reads `status: refused`, `outcome: undo_emails
| changed`, `undo: true`.

One send per confirm: the flow moves to committing before its first await, so
a click and an Enter in the same frame send once.

| Write | Who is emailed | Confirm | Undo |
|---|---|---|---|
| Accept / Maybe / Decline (+ a note, + a proposed time) | the organiser | always | none |
| Move — organiser with guests | the attendees | yes | none |
| Move — your own event | nobody | no, acts at once | the move back, pinned to the post-move change key (`if_match`) |
| Cancel meeting (+ a note to everyone) | the attendees | always | none |
| Delete | an organiser's delete sends cancellations | always | none |
| Create | whoever it invites | always when it invites anyone — named outright in `needsConfirm`, not left to the dry run's notifies list, because the Day command bar builds invites from typed words | delete it, when it invited nobody, refused if its change key has moved |

A create carries a transaction id (32 hex characters from `Random.secure`) made
once per proposal; a retry reuses the same `CreateEvent`, so a create whose
answer was lost cannot land twice within a session (the transaction id is held
in memory; a retry after a restart is a new create).

**The local effect.** A real write makes the mirror agree at once, then forces
a sync (`syncNow(force: true)`, unawaited) for what the server did beyond the
one row it answered:

- a move or a create that answered a row → `CalendarSync.storeWritten`: the
  write guard noted and the row tagged with the CURRENT run, so neither a page
  read before the write nor the next sweep undoes it (gotcha 36); a create or
  a move whose ack has no placeable row (its `start_utc`/`end_utc` empty — the
  legacy naive `start`/`end` are never read) only notes its id and waits for
  the forced sync, whose publisher bumps the revision when it brings the row;
- an answer → `CalendarStore.setResponseStatus` on the id and, for a master,
  every mirrored occurrence, each id noted — so for `answerHold` (2 minutes)
  a sync page that disagrees with the answer keeps the answer (see The write
  guard);
- a cancel or a delete → `CalendarStore.deleteWithOccurrences`, each id noted.

Then `calendarRevisionProvider` is bumped, so the Day stop, the panel and the
cards follow without waiting.

**After it goes through**, the side effects — the local apply, the revision
bump, the forced sync, the activity row, the Undo — each run on their own
guard OUTSIDE the failure mapping: a throw there is logged by type and the
write is still a success, because the server has it and a Try again would
send it twice. The toast says a series-wide answer, cancel or delete as
"Accepted every meeting in …", as the confirm did, and ends with where the
mail goes — "Emails go to a@x." or "Emails go to 3 people." — worded as a
preview, because the list is the dry run's (or the `mayEmailFor` reading),
not a receipt. The buttons are rebuilt
fresh, so a "Move to…" field typed for the old time is gone, and the keyboard
stays in the panel, so `z` reaches the Undo without a click.

**When it fails**, the sentence stands under the buttons that caused it —
unless the flow that started it has gone (the panel closed, a new command
replaced its card), when the host toasts it (`_calendarWriteFailed`), because
the inline line has nowhere left to stand.

Everything a commit does before the real request only reads: the event (for
a move, and for an undo's delete) and, for an all-day move, the mailbox zone.
A failure there is mapped as a dry run's — nothing was sent, nothing changed,
no sync forced. "Couldn't confirm the calendar got this" is only for a
failure on the real request.

| Failure | Sentence | Also |
|---|---|---|
| `event_changed` | "This event changed in Outlook — check it and try again." | re-read and stored |
| `not_organizer` | "Only the organiser can change this meeting." | |
| scope missing | "Calendar write permission missing — reconnect in Settings." | |
| `not_found` | "This event no longer exists." | dropped from the mirror |
| any other refusal | the first sentence of the server's reason | |
| `CalendarUnavailable` | its own sentence (SDK mode's, naming the connection that would give one) | |
| reconsent / signed out | "Reconnect Microsoft in Settings, then try again. Nothing was changed." | |
| `ArgumentError` (a write the backend will not build) | "This can't be sent as it stands. Nothing was changed." | |
| no mailbox zone for an all-day move | "Couldn't read your mailbox's time zone. Nothing was changed." | |
| transient, dry run or a read before the write | "Couldn't reach the calendar. Nothing was changed." | **Try again** re-runs the same write; no sync is forced |
| transient, real write | "Couldn't confirm the calendar got this — check it before trying again." | it may have landed: a forced sync; **Try again** only for a create (its transaction id) and a move (its retry pins the `if_match` it was first sent with, so a landed first try becomes `event_changed` even after the forced sync stored the new key), never for an answer, a cancel or a delete, which would email everyone twice |
| an undo that would email anyone | "Undo would email people now — open the event instead." | `status: refused`, `outcome: undo_emails` |
| an undo whose event's key moved | "This event changed in Outlook — check it and try again." | `status: refused`, `outcome: changed` |

**Where they appear, by role** (`eventRoleOf`). An attendee gets Yes / Maybe /
No (the current answer shown chosen), **Add note** and **Propose new time**; an
organiser with guests gets **Move to…** and **Cancel meeting** with an
optional note; an event of the owner's own — organised by them with no
guests, where a room or the organiser listed on their own invite is not a
guest — gets **Move to…** and **Delete**. Whose event it is comes first
(`isOrganizer`, or the response `organizer`): an attendee's copy of an invite
whose organiser hid the list names nobody and is still answered, never moved
or deleted. An attendee's cancelled meeting gets **Remove from
calendar**. Attendees never see Move (only the organiser may move a meeting,
gotcha 6); Propose is hidden when the organiser set
`allowNewTimeProposals: false`, and on all-day events. For a series, an
answer or a cancel goes to the MASTER and so to every meeting in it — the
summary says "every meeting in …" — while a move or a proposal acts on the
occurrence on display: moving a whole series is recurrence editing, which is
not done here. The event panel shows the full set; the meeting card, each
Invites row and an unanswered meeting's agenda row show Yes / Maybe / No only,
plus **Dismiss** while the invite is unanswered.

**No pickers.** The new time is typed — "Thu 3pm", "tomorrow 10–10:30" — and
read by the date resolver (booking mode), with the absolute result shown under
the field before anything is sent, against the clock at that moment (read
again at the send, so a panel left open cannot send a time that has since
passed); Escape in the field closes it, not the panel. What the text leaves
out is kept from the meeting, never invented: a day alone keeps the wall time, a time alone keeps
the day, no length keeps the length. A part of the day with no time ("tomorrow
morning"), a week, a past time and the time it already has are refused in a
sentence. An all-day event moves by whole days, keeps its span, and sends the
mailbox's zone (`allDayZone`, from the cached settings, else a live read).

## Briefs

A dense briefing before a meeting with people the owner has been writing to:
the story so far, who each person is and what they last wrote, what the files
sent ahead say, what is open with them, what they asked, what the owner is
waiting on, and questions worth asking. Stage
`meeting_brief` (generative, [10-model-routing.md](10-model-routing.md)),
stored per event in `event_briefs` (`event_id` PK, `inputs_hash`, `status`
`ready|failed|skipped`, `brief_json`, `model`, `generated_at`), drawn in the
event panel's **Brief** section and teased on the Day agenda.

**Eligibility (D6)** — `briefQuickCheck` for the rules that need no read, then
the mail rule in `BriefGatherer.gather`; each failure is an enum word
(`BriefIneligibility.wire`) that a skipped row carries as
`inputs_hash = ineligible:<word>`:

| Rule | Word |
|---|---|
| not cancelled | `cancelled` |
| the owner's own response is not `declined` | `declined` |
| starts after now (an all-day event at its local midnight) | `past` |
| starts today or tomorrow in the display zone (`briefHorizonEnd(nowUtc, zone)`: the local midnight that ends tomorrow; 23:59 tomorrow is in, 00:00 the day after is not) — lifted when a person asked (`asked`) | `too_far` |
| at least one other person: an attendee whose address is not the owner's (case-insensitive) and whose type is not `resource`, or an organiser who is not the owner — an attendee's copy with a hidden guest list names only the organiser, and is still a meeting with someone | `no_others` |
| at most 15 other people (`briefMaxOthers`): past that the meeting is a broadcast — a narrowing of D6, which set no ceiling | `too_many` |
| at least one thread (lifted when a person asked: the brief is written from the invite and its people alone): the meeting's own invite mail (`CalendarStore.messagesForEvent` of the occurrence, then of its series master — any sender, any age), or a conversation with any of those addresses in the last 30 days (`MessageStore.conversationsWithAddresses`, matched on `participants_json.email`) | `no_mail` |
| (handler only) the event is no longer in the mirror | `gone` |
| (handler only) a file sent ahead is still being read, no ready brief is stored, and the meeting starts more than 20 minutes from now (`MeetingBriefHandler.pendingGrace`) — not a rule about the meeting but a wait, below | `materials_pending` |

**Mail only for now.** Teams participants are stored as `teams:<id>`, not
addresses, so the address match never finds a chat; mapping them through the
people directory is a follow-up. And `participants_json` holds at most 8
people per conversation, so an attendee beyond the 8th in a busy thread is
not matched by that thread. The prompt says so too: it speaks of the owner's
"mail" only, never chats.

The owner's address unknown (the keychain has not answered), the gatherer
throws `BriefOwnerUnknown` rather than answer — the owner's own attendee row
would count as somebody else — and the worker retries the row; nothing is
written.

The owner's address is the sync's own lookup (`storedAccount`, `mail` then
`userPrincipalName`); unknown, the planner does not run at all (below) and the
handler's gather throws, as above. Briefs are keyed
by the OCCURRENCE: the planner reads the mirror's rows, never a series
master, and a master that reaches the handler anyway is briefed as its
`displayOccurrence` and stored under THAT occurrence's id, which is the id
the panel reads.

**What is gathered** (`lib/services/calendar/brief_gatherer.dart`, no model).
The planner gathers with `passages: false` — the light gather: the store reads
the hash needs and nothing else (no file text, no people block, no embedding),
so it can gather every meeting in the window; the handler's gather (the
default) also reads each read file's text, builds the people block and embeds
the meeting once to find the materials' passages. None of those is hashed, so
the two gathers hash alike:

- **Threads** — first the meeting's own mail: the distinct conversations of
  `messagesForEvent(event.id)` (newest first), then of
  `messagesForEvent(event.seriesMasterId)` for an occurrence — whoever sent
  them (an organiser's assistant matches no attendee) and however old. At
  most 3 of them (`maxInviteThreads`, so a long weekly series cannot push out
  the mail with the people) lead the list and count toward the 6. Then up to
  20 address-matched
  candidate conversations (one already found as an invite thread is not
  listed twice), ranked first by the
  decision on each one's newest inbound message (`urgency ∈ {high, urgent}` or
  `importance = high`, the invite-pinning rule), then by `last_message_at`,
  then key, fill the rest. Each kept thread carries its subject, state, last
  stamp and
  its last two messages' text (attachment markers and link targets stripped,
  whitespace collapsed, capped at 600, fenced).
- **Open asks** (§1.1 point 1) — in a kept thread whose state is
  `needs_reply`, an inbound message from an attendee that came AFTER the
  owner's last message there (an ask before a reply is taken as answered),
  whose stored decision has `needs_you_p` at or above the owner's Needs You
  slider (`needsYouAt`, the one rule the Needs You stop reads; default 0.35)
  or `reply_expected_p ≥ DecisionPolicy.replyYes` (0.50), and whose `intent`
  is `question`, `request` or `approval` (`scheduling` is left out: the
  meeting is usually its answer). The newest such message per thread, at most
  4, capped at 300 and fenced.
- **Waiting on them** — kept threads in state `waiting` whose newest message
  is the owner's, at most 3.
- **Storylines** — the live storylines of the kept threads, at most 2: the
  title, and the recap (else the summary) capped at 400 and fenced.
- **Materials** (`BriefMaterial`) — the files on any message in this
  meeting's OWN invite threads among the kept ones (the occurrence's, then
  its series master's; never an address-matched thread), inbound or
  outbound (no sender check, unlike the asks: the deck
  the owner attached to the invite they sent is as much the meeting's as
  the one the other side sent), newest mail first: kind
  `file` or `reference`, not inline, not `image/*`, named; one per file name
  (case-insensitive), the newest copy — the same deck re-attached on every
  reply is one material; at most 6. Each carries its identity (source,
  message id, attachment id — what the handler stores so the agenda can open
  it), its name, content type, sender (the invite's name, else the sender's,
  else the address; the word `you` for the owner's own), the day its mail arrived (`yyyy-MM-dd` in the display
  zone), its `text_status`, and its digest (`attachments.digest_json`) when
  there is one. A file whose text is not read yet is still listed — the brief
  names it as arrived. **Other files** (`BriefInput.otherFiles`): the files
  on the kept address-matched threads — mail with these people that is not
  this meeting's — by the same filter (both directions, newest first, one
  per name), NAMES only, at most 4 (`BriefGatherer.maxOtherFiles`), never
  read. The task lists them as other files with these people, not sent for
  this meeting, and the prompt forbids reading the meeting's purpose from
  them: a resume the owner sent the same person for another interview is
  not what this meeting is about. Both gathers carry them alike. **Text**
  (handler's gather only): a file whose
  `text_status` is `done` carries its `attachment_text` (`attachmentTextOf`),
  runs of spaces and blank lines closed up, cut at a word to 6000 characters
  (`BriefGatherer.materialTextCap`, `capAtWord`) — the head of the document,
  raw, fenced by the task as `material_text`; a store error costs that file
  its text, never the brief. **Pending**: `BriefInput.materialsPending` is
  true when a material's `text_status` is `pending` AND its `attachment_text`
  work row (`workRowOf('attachment_text', source,
  attachmentEntityId(messageId, attachmentId))`) is `pending` or
  `processing` AND the file has been being read for less than 2 hours
  (`BriefGatherer.pendingMaxAge`, from the LATER of the mail's `received_at`
  and the work row's `created_at`, against the gather's `now` — so the
  owner's invite sent days ago, whose file the handler's fetch only now
  listed and queued, is still waited for; `created_at` is fixed at the first
  ask). There is no `error` `text_status`: a text work row that gave up
  (`error` after its attempts) leaves the attachment row `pending` for good,
  so the work row is what says a file is still being read, and the age is
  the backstop. A `pending` file with NO work row at all — listed by
  `ensureBodiesFor`, which queues no text — is reported in
  `BriefEligible.unqueued` (always young: the handler queues it this run,
  so its reading starts now) rather than counted. Both gathers compute both from the stored states
  and the work rows. **Passages**: with an embeddings client
  (`briefGathererProvider` passes the retriever's), and when
  `hasAttachmentChunks` says a file's attachment id has chunks, the meeting's
  subject and preview are embedded under the document prefix (the
  retriever's rule) — once per gather, on the first such file — and
  `chunkKnn` is asked, ONE CALL PER FILE, for the 4 nearest chunks scoped to
  that attachment id (never the mailbox), so a long deck cannot starve the
  other files; the `digest` chunk is dropped, a hit must match the file's
  message AND attachment id, and each file keeps at most 2, each `[locator]
  text` capped at 350 and fenced as `passage`. Any failure there (no server, no index, a store error) costs the
  passages, never the brief.
- **Unlisted files** (`BriefEligible.unlisted`) — a kept thread's mail
  message whose row says it carries files (`has_attachments = 1`) but which
  has no `attachments` row yet, newest first, at most 4
  (`BriefGatherer.maxUnlisted`). The sync lists a message's files only from
  its detail, which runs for triage (inbound only) or when the thread is
  opened, so an invite the owner sent with a PDF on it has the flag and no
  rows. The handler fetches those details once before the first brief
  (below), so the brief names the file; its text and digest arrive through
  the attachment lane and move the hash, which re-briefs the meeting.
- **Last met** — `lastMetWith` → `lastMetLabel`.
- **People** (`BriefPerson`, handler's gather only) — the other people,
  the organiser first and then the attendees in the invite's order, at most
  8 (`BriefGatherer.maxPeople`, applied after the ordering; the rest are
  counted in `peopleMore`). The organiser first is a deliberate departure
  from D14's literal "attendee order": `briefOthers` appends the organiser
  last (a Graph attendee copy does not list them among the attendees), and
  who called the meeting is the one person the block must not count among
  "+N more". Each: the invite's name (else the address), the
  organisation (`briefOrgOf`: the label before the domain's public suffix —
  `fabrikam` for `mail.fabrikam.com`, `contoso` for `contoso.co.uk`, the
  tenant `contoso` for `contoso.onmicrosoft.com` and for its
  `contoso.mail.onmicrosoft.com` routing domain — and ''
  for a consumer mailbox (gmail, googlemail, outlook, hotmail, live, msn,
  yahoo, icloud, me, mac, proton, protonmail, aol), a
  `*.calendar.google.com` resource, an address written as an IP, or a label
  that is not letters, digits and hyphens), whether they organised it, their answer (below), their own
  "Last met …" (`lastMetWith([address])`), how many kept threads they are in
  (by `participants_json` or a message from them), and their newest inbound
  message in those threads: how long ago (`briefAgo`), its thread's subject,
  and its own words — cut at the first quoted-reply header (`askOwnWords`),
  whitespace collapsed, at most 240 at a word (`lastWordsCap`), fenced as
  `last_words` — and their open ask (the `BriefAsk` from their address), as
  fenced there. Not hashed: every field follows from hashed inputs but last
  met, and a past meeting ageing by a day is no reason to rewrite a brief.
- **The invite's `body_preview`**, capped at 600 and fenced.

Every cap here, and the task's ceilings below (but the glance's, which cuts
at a word — see the task), cuts with `capRunes`, which
never ends on the first half of a surrogate pair (a lone surrogate is not
text, and a JSON encoder or model server may refuse it).

The fencing rule: every free-text body arrives from the gatherer inside
`wrapUntrusted`; the short labels (subjects, names, titles, file names) stay
raw because the panel's links and the hash read them, and the task fences
each as it lays the message out.

**Tally honesty.** Only the organiser's copy tracks answers; on an
attendee's copy `none` means "not known", never "hasn't answered". So a
person's answer is read only off the owner's OWN organiser copy (`accepted`,
`tentative`, `declined`, `no answer yet`) and is "response not known" on any
other copy, rather than risk saying something false.

**The inputs hash** is sha256 over the event's id, `change_key` and times,
the owner's address, each kept thread's `source|key|last_message_at|
message_count`, each ask's message id, each storyline's id with the sha256
of its shown text (the recap, else the summary), and each material's
`message id|attachment id|text_status|digest_status`, and each other
file's `otherfile|<lower-cased name>` (a new file with these people changes
what the brief is told). A new
message moves its thread's stamp and count, so it moves the hash; an edit to
an existing message's text alone does not. A storyline's text is hashed
because a recap is rewritten in place, moving no id or stamp. A material's
text and digest states are hashed so a deck whose words or digest land after
the first brief re-briefs the meeting; its name is not (a rename says nothing
new), and neither are its text or passages (they follow from the text
status), nor the people block. The hash never reads the clock.

**The task** (`MeetingBriefTask`, `lib/services/llm/meeting_brief_task.dart`):
a const system prompt ending in `untrustedDataClause`. v3 is written for an
owner who wants to walk in completely on top of the meeting: it speaks to them
as "you" and never "the owner", asks for DENSITY — every sentence carries a
name, a number, a date, a decision or a claim from a file; thin inputs mean
fewer sentences, never vaguer ones — has the model write the evidence line
first, and keeps "Name a day by its date, never by a relative word." (a brief
is read for up to a day and a half after it is written) and "Never invent: a
number, a name, a date or a claim that is not in the inputs does not go in."
The user message opens with `Now: <absolute local time>` and the meeting line,
both absolute (`briefWhenLine`: "Wed 7 Oct 2026 · 10:00–11:00 AM PDT", "All
day · Wed 7 Oct 2026"), the fenced attendees and the last-met line, then
**People, numbered, the organiser first:** — per person `[n]` and the fenced
`name · organisation` (the organisation is a DNS label whoever owns the
domain chose, so it is untrusted text like the name), then the app's words
outside the fence: "no organisation known" when there is none,
`organiser|attendee` and the answer; then, only when present, their "Last
met …" line, "in N of the threads", "last wrote <ago>:" with the fenced
subject and the fenced last words, and "open ask: yes (see Open asks)" — the ask itself is said once, in
"Open asks", not repeated here; "+N more" past eight. Then the numbered threads, each with its
last message as an age from `now` (`briefAgo`: "3 hours ago", "2 days ago"),
and each section. Every label is capped at 120 characters (`labelCap`)
before it is fenced: file names, thread and last subjects, the meeting's
subject, storyline titles, attendee and people names. After the storylines and before the invite, **Materials
sent ahead, numbered ("you" is the owner):** — per material `[n] (<state>)`
and a fenced `name · sender · day`, then
its fenced digest (summary, then its facts one per line), its text fenced as
`material_text`, and its pre-fenced passages. Digests, text and passages
share a budget of 10000 (`materialsBudget`), fences included, where a block
COSTS its length plus its digit count: Qwen tokenises digits one per token,
so a sheet or a financial deck runs near two characters a token, and at the
old 14000 raw characters such a block overflowed the 16k context. The budget
is spent in two rounds (one private spend, `_spend`). Round 1, newest
material first: its digest, then its text whole when it fits, else — while
more than 1000 is left (`minTextHead`) — its head cut at a word to what is
left (a partial head beats "not shown"). Round 2: the passages, with what is
left, for every material whose text was not written whole and uncut (a text
written whole that the gatherer did not cut — `BriefMaterial.textCut`, set
when the squeezed words ran past `materialTextCap` — is the whole document,
and its passages would be duplicates). After the materials and before the
invite, when there are any, **Files on other threads with these people (NOT
sent for this meeting):** — one `- ` line per name, capped at 80 characters as fenced
(`otherFileNameCap`, not `labelCap`'s 120) and fenced as `file`, outside the budget. The rule after `materials` says the
meeting's PURPOSE comes from its own invite — the subject, the invite text
and the threads about this meeting — never from a file or thread that merely
involves the same people; such a file is named only when the invite or a
thread about this meeting refers to it, and an invite that says little gets
a brief that says so ("The invite gives no agenda.") and then what is open
with these people. Each block is tried on its own, so a later,
smaller one may still fit. A digest at its caps is about 1.7k, so one file's
digest and whole 6000-character text fit, plus a second's digest, and the
head of its text when the digests are short of their caps; a third is named
only. The state word is the app's and
sits OUTSIDE the fence, so a file name cannot pose as one: `read` only when a
digest, text or passage was actually written for that file, `unread` when its
text was never read, `not shown` when it was read but nothing of it is in the
message. The prompt treats `not shown` like `unread`: the file is named as
arrived in one point, not summarised. The prompt carries length hints
inside its rules — a person's line "at most about 25 words", each briefing
sentence "at most about 40 words", each material point "a short line" — so
the model aims below the hard caps. Temperature 0.2, **2700 tokens**: every
string at its cap is about 12.9k characters (13.7k with keys and quotes,
about 3.4k tokens), a realistic dense answer about 8k characters (2.0–2.1k
tokens), and a truncated answer is invalid JSON — a failed brief retried on
the same inputs — so the budget sits over the realistic answer, and a test
holds the caps' sum / 4 within 1.2 × `maxTokens`. Worst case in, measured by
the size guard in `meeting_brief_task_test` (every cap full, every label 300
characters of `&<>`, so each costs its full escaped 120): about 38.1k
characters (38133) with the 4.5k system prompt — six threads with their two
600-character snippets, four asks, two storylines, the materials' 10k plus
six name lines, four other files (each name fenced at 80,
`otherFileNameCap`), eight people, fifteen attendee names, the invite 0.7k
and the headers — about 12.7k tokens at three characters a token, plus the
2.7k answer: about 15.4k, inside the 16384 context. The ceiling is (16384 −
2700) × 3 = 41052 characters of prompt; the guard holds it at 38500 (the
measurement plus about 1%; 37800 before the other files and their rule).

The schema (v3) is flat and in THIS order, which is the order the grammar
makes the model write: `evidence` (one sentence — what the meeting is for and
where things stand), `headline` (the glance: one or two dense sentences for
the agenda), `briefing` (strings, `maxItems` 6 — the story so far, one
fact-bearing sentence each), `people` (`{name, line}` — who they are, what
they last wrote or asked and when, what is open with them), `materials`
(`{file, points}` — per numbered file that matters, up to five points of what
it SAYS: figures, names, dates, claims, decisions asked for, gaps),
`questions` (strings, `maxItems` 5, each grounded in one specific fact),
`open_asks` (`{person, ask, thread}`), `points` (`{text, thread}` — the
references), `prep` (strings, `maxItems` 3) — all required,
`additionalProperties: false`, `maxItems` only on the three arrays of strings
at the top (none on an object array or on `materials[].points`) and no
`maxLength` anywhere, because the grammar converter refuses them. `validate`
holds every ceiling instead: evidence 300, headline 320 and each briefing
sentence 320, all cut back to the last whole word (`capAtWord`); at most 6
briefing sentences, 8 people (name 80, line 220), 4 materials of at most 5
points of 220, 5 questions of 220, 4 asks of 200 (person 80), 5 points of
200, 3 prep lines of 120, empty strings dropped; thread numbers are 1-based
in the message and the answer, and are turned 0-based, with anything outside
the numbered list (or ≤ 0) becoming -1, so a line can never link to a thread
that is not there. A material number outside the materials list DROPS its
entry (never -1): points about a file that is not there are about nothing.
`MeetingBrief` writes v3 (`materials[].points`); a stored v1 row (no
`evidence`, `materials`, `questions`, `material_refs`) and a v2 row (a
material's one `takeaway`, read as its one point; no `briefing` or `people`)
still decode. `BriefMaterialOut.takeaway` joins the points back into a line
for the faces that still draw one.

**The handler** (`MeetingBriefHandler`, kind `meeting_brief`, source
`calendar`, entity = event id) re-reads the event (missing → skipped
`gone`), gathers (ineligible → skipped with its word, no call) — and when
the gather reports unlisted files and a `fetchDetails` closure is wired
(the provider's: the mail sync's `ensureMessageBody` per id through
`MeetingBriefHandler.fetchEach`, which lists the files AND queues their
`attachment_text`), fetches them ONCE and gathers again, never looping; a
failed id is traced by its type and costs only itself, so the meeting is
gathered again whenever any fetch completed, and the first gather stands
only when none did — and returns
without a call when the stored brief is `ready` with the same hash — unless
the row's payload is `{"asked":true}` (`BriefRequest`, Regenerate's and Write a brief's), which
always writes. Every one of those decisions is made on the LIGHT gather
(`passages: false`: no file text, no people, no embedding), which hashes and
reads the wait exactly as the full one does; the full gather (text, people,
passages) runs only once a call will be made, so a waiting or unchanged
brief costs store reads and nothing more. **Queueing the unqueued**: when
the gather reports `unqueued` files (listed, `pending`, no `attachment_text`
row), the handler `enqueueWork`s their text once (INSERT OR IGNORE, so a
second ask changes nothing; activity `queued_text: n`), and they count as
pending for this run, whatever the mail's age: their reading starts now. **Waiting for the files**:
after the (possibly second) gather,
when a material is still pending AND no ready brief is stored AND the meeting
starts more than 20 minutes from now (`pendingGrace`), it writes `skipped`
with `ineligible:materials_pending` (the skip path, so the activity note is
`{reason: materials_pending}`) and makes no call — a brief written before the
file is read says "unread" about the thing the meeting is likeliest to be
about, and would be rewritten minutes later; the panel says "Reading the
files sent ahead — brief coming." A ready brief is rewritten anyway (it is
there to read meanwhile), a meeting inside the grace is briefed with what
is read, and an asked-for row (Regenerate, Write a brief) never waits. Otherwise
it runs the task and stores `ready` with the brief JSON — plus a `threads`
list of `{source, conversation_key, subject}` in the order the model was
shown them, so the panel links a point to its thread without gathering again,
and a `material_refs` list of `{source, message_id, attachment_id, name}` in
the materials' order, so a material line opens its file the same way
(`MeetingBrief.materialAt`) — and the resolved model name. Stored v1 and v2
rows decode (above). The activity detail carries `threads`, `asks`,
`materials`, `other_files`, `questions` and `people` counts and `text_chars` (the
characters of the materials' text the message actually carried —
`MeetingBriefTask.materialTextCharsWritten`, the same spend as the message —
not what was gathered), `queued_text` when it queued any, and `fetched`
(how many unlisted messages the fetch completed, failures not counted) when
it asked for any. An empty headline is an `LlmFormatException`.
A dead server (`LlmUnavailableException` and its subclasses) propagates and
PARKS the kind like a draft, writing nothing; any other failure writes
`failed` and rethrows, so the worker's retry-once-then-error policy applies.
**A ready brief outlives most later runs**: over one, a failure, or a skip
for `past` (the meeting has started) or aged-out mail, keeps `brief_json` and
`status = ready` and moves only `generated_at` (`CalendarStore.touchBrief`),
and the planner tries one set of moved inputs only once while the brief is
fresh (below); the activity note says `kept: ready`. A skip for `gone`, `declined` or `cancelled` REPLACES it with a
skipped row: the owner is not going to that meeting, so neither the panel nor
the agenda should go on offering its brief.

`AiWorker.sources` carries `calendar` for these rows: a work row's source is
the row's origin, and a brief's is the calendar.

**The lane.** The draft lane, after `draft` — see
[10-model-routing.md](10-model-routing.md#three-drains) for why. Drain order
alone would still leave a person's **Draft reply** behind a backlog of briefs
the walk is already inside, so `DraftNotifier.generate` names the draft's
message as a priority ref (`pump(first: …)`): it is served at the next claim
boundary, after at most the one brief already at the model.

**Planning** (`BriefPlanner.plan`). After each calendar sync that
`InboxScreen._syncCalendar` ran — the poll's, startup's, the refresh button's,
arriving on the Day stop — whose outcome is `synced`, and only while
processing is on, it fires the planner. The forced syncs `CalendarWrites`
starts after a write call `syncNow` directly and plan no briefs. The planner
runs (never awaited by the mail load; every failure a trace) and pumps
the draft lane when it queued anything. It returns 0 at once while the
owner's address is unknown (the keychain has not answered): without it the
owner counts among every meeting's people. The host skips the pass while the
display zone has not resolved (UTC's tomorrow is not the owner's). Otherwise
it reads every event touching today and tomorrow in the display zone
(`briefHorizonEnd`: the local midnight that ends tomorrow; a meeting under
way included), deletes the briefs of meetings that have ended or are gone
(`deleteBriefsOfEndedEvents`); a brief for a meeting still ahead is kept
however far off — the window is where briefs are written, not where they
may live, so a brief asked for by hand for next week survives the pass —
and walks the meetings soonest first, timed before all-day:

- on `briefQuickCheck`, skips it — writing a `skipped` row for `no_others`
  or `too_many` (below; `no_mail`, the gather's word, is recorded from the
  gather path);
- does not gather again an event it gathered less than **15 minutes** ago
  (`BriefPlanner.recheck`, in memory) whose stored row is `failed` and has
  not moved since — a back-off for a brief that could not be written, and
  the only row it holds. A `ready` row is gathered on EVERY pass: a deck
  sent the morning of the meeting, or its text landing, reaches the brief on
  the next sync, and `_queuedFor` with the "fresh AND unchanged" rule below
  keep an unchanged one from queueing — that is what keeps a busy thread
  the morning of a meeting from buying a model call per sync. An event with
  NO stored row is never throttled, so after Clear AI results the next
  synced tick plans it at once, and neither is a `skipped` row (any
  `ineligible:*` reason), which is gathered again on EVERY pass — a Gmail
  invite's event syncs seconds before its mail, a file being read lands in a
  minute, and a quarter of an hour of "No brief — no recent mail" over a
  thread that is there would be wrong. The gathers are store reads; an
  unchanged reason writes and queues nothing (the row already says so, and
  `_queuedFor`);
- past that, gathers the fresh hash and marks the meeting due when there is
  no brief or the hash moved — at ANY age, so a deck or its digest landing
  an hour after the first brief re-briefs the meeting on the next pass. The
  one skip is "younger than **2 hours** (`freshFor`) AND unchanged": a
  `failed` brief on unchanged inputs waits out the 2 hours before it is
  tried again, and a moved hash that was already queued once while the brief
  is fresh (`_queuedFor`, in memory — a failed rewrite over a ready brief
  keeps the old hash) is not queued again until the brief ages or the inputs
  move again. A `materials_pending` row is queued when the text lands (the
  hash moves); when the light gather says nothing is being read any more
  though the hash did not move (the text work gave up, or the file has been
  read for longer than 2 hours), once per stored row (`_endedFor`, in memory, keyed by its
  `generated_at`, so a handler that throws before writing does not buy a
  queue every pass); and once more on the same hash when the meeting comes
  inside the 20-minute grace, so it is briefed with what is read rather than
  waiting on a file that may never finish;
- when the gather says `no_mail`, `no_others` or `too_many`, writes
  `skipped` with `inputs_hash = ineligible:<word>` (no model call) unless the
  row already says so or holds a ready brief, which stands; once the reason
  goes away the hash differs and the meeting is queued like any other on the
  next gather;
- skips a row already `pending` or `processing` without counting it;
- stops at **6** due, then queues them in REVERSE with
  `requeueWork(refreshCreatedAt: true)`, so the soonest meeting carries the
  newest `created_at` and drains first (the lane claims one kind at a time,
  so the stamps order briefs only among themselves). Planner rows carry no
  payload.

**Regenerate** in the panel is `requeueWork('meeting_brief', 'calendar', id,
payloadJson: '{"asked":true}', refreshCreatedAt: true)` — a person asked, so
it goes to the front and is rewritten even when nothing changed — then a
draft-lane pump. Over a ready brief it is offered with processing off too
("Briefs are paused while processing is off." stands in for "Rewriting…"); the
request waits and runs when the switch comes back. A failed row with
processing off shows only the paused sentence, with no Regenerate.

**Write a brief** (`brief-write`) is the same request, offered when the panel
would otherwise only explain — too far off, no mail, or nothing stored yet —
only with processing on, and never once the quick check refuses for a reason
a request does not lift (a stored `no_mail` row over a meeting that has since
started draws its sentence alone). An asked request also bypasses `too_far` and
`no_mail` in the quick check and the gather (`briefQuickCheck(asked:)`,
`gather(asked:)`, which the handler passes from the row's payload), never
`past`, `cancelled`, `declined`, `no_others` or `too_many`; with no thread
the brief is written from the invite and its people ("Threads: none."). The
handler notes `asked` on every activity row.

**Clear AI results** empties `event_briefs` (a derived table) and the next
sync plans the briefs again. Briefs are per meeting, not per message, so
nothing is added to `clearDerived`'s per-message loop.

**The panel.** `BriefSection` (prop-only, `lib/widgets/brief_section.dart`)
over `eventBriefProvider(<shown occurrence id>)`, drawn while the meeting has
not ended. In order of precedence: a meeting the owner declined or that was
cancelled — its sentence, even over a ready brief, since the owner is not
going; a ready brief — the headline in bold, then the body both faces draw,
in the order a catch-up is read, each block only when it has something:
**Briefing** (the sentences as one selectable paragraph, key
`brief-briefing`), **From the materials** (per material a chip with the
file's name — tooltip "Open the file" — when the brief still holds its
`materialRefs` entry, then its points as bullets, keys
`brief-material-point-<i>-<j>`; points whose ref is missing are drawn
alone), **People** (per person the name in bold, " — ", the line; key
`brief-person-<i>`), **Questions** numbered "1.", "2.", **Prep**, **Open
asks**, then the points with a chip naming the thread under **References**
— what it rests on last —, then "Generated 2h ago · Regenerate" — or
"Rewriting…" while a new one is queued; the old brief stands until the new
one lands; "Writing the brief…"; "Briefs are paused while processing is off.";
a skipped row's reason ("No brief — no recent mail with these people.",
"No brief — nobody else is invited.", "No brief — too many people for a
brief.", "No brief — this meeting has started.", "Reading the files sent
ahead — brief coming." for `materials_pending`, else "No brief for this
meeting." — a `materials_pending` row gives way to the quick check's
sentence when it says no, so a meeting that has started says "No brief —
this meeting has started.", not "brief coming"); "The brief couldn't be
written." with Regenerate; when the
no-read rules already say no, the same sentence for their word ("Briefs are
written for today and tomorrow." for `too_far`, with **Write a brief**); else
"Brief coming after the next calendar sync." with **Write a brief**. A
skipped `no_mail` or `too_far` row draws **Write a brief** beside its
sentence too. The view
re-reads on the calendar revision, `briefRevisionProvider` (bumped by the
handler's `onStored` and by Regenerate) and `briefWorkTickProvider` (the draft
lane's progress for this kind, which lands after the work row is written).
A material chip calls `onOpenMaterial(ref)`; the host's `_openMaterial` reads
the file's row now (`MessageStore.attachmentRow(source, messageId,
attachmentId)`) and opens `FilePanel(attachment: AttachmentRef.fromRow(row))`
beside, pushed; a row the store no longer holds toasts "That file is no
longer here." No conversation key rides along: briefs read mail, where the
message id is enough. Every string is model output and plain text (`Text`,
the briefing's `SelectableText`, a person's unstyled spans — no markup, no
links); the chips are the only tappables. A briefing sentence cut at its cap
(no closing punctuation) ends in "…" so it does not run into the next, and a
person with no name is the line alone.

**The agenda.** The owner reads the day's agenda in the morning to get up to
speed with every meeting at once, so the brief lives there, not only in the
panel. `dayBriefsProvider(day)` (`Map<String, MeetingBrief>` of the day's
ready briefs with a non-empty headline, watching the day's events — so the
calendar revision — and `briefRevisionProvider`, not the work tick the panel
view watches for its "Writing…" state) →
`DayPane.briefs`. Under a meeting's subject, the **glance** — the headline,
muted, up to three lines (key `day-brief-teaser-<id>`) — with a chevron beside
it (`day-brief-toggle-<id>`, "Show the brief" / "Hide the brief"); a tap on
either toggles the brief, a tap anywhere else on the row still opens the
event. The host holds the open set (`InboxScreen._expandedBriefs`, emptied
whenever the shown day changes, through `_setSelectedDay`), and an open row
draws `BriefSection(compact: true)` under itself from the subject column
(`DayPane.subjectIndent`): the panel's body in the panel's order — Briefing,
From the materials, People, Questions, Prep, Open asks, at most three points
with their thread chips under References (`BriefSection.compactPointsCap`;
the panel shows them all) — and one Regenerate: no headline (the glance is
it) and no footer. A brief waiting on the files sent ahead
(`materials_pending`) has no glance to open, so the agenda says so in the
glance slot instead: `dayBriefsWaitingProvider(day)` (the event ids, from
the same stored rows as `dayBriefsProvider`; none while processing is off)
→ `DayPane.briefsWaiting`, drawn as "Reading the files sent ahead — brief
coming." in one muted caption line (key `day-brief-note-<id>`) with no
chevron — not once the meeting has started, when the planner no longer
tends the wait; a ready brief wins. A body is only opened under a ready
brief, so the note is what the agenda shows: the compact face's own copy of
the sentence serves only a host that draws a compact face for a skipped row
(a row that turned pending under an open brief). None of it on a cancelled meeting (a declined one is not on the agenda). The **Today
section** of the rail draws the same glance under each of its up to three
meeting rows (`AppRail.todayGlances`, key `today-glance-<id>`), from
`dayBriefsProvider(today)`, only while that section is shown.

**Activity.** Kind `meeting_brief`, labelled **Meeting brief**, written by the
worker with the handler's notes: `ok` with `{threads, asks, materials,
other_files, questions, people, text_chars}` → "Meeting brief — written from 3 threads"; `skipped` with `{reason: <word>}` (a D6 word,
`materials_pending` — "reading the files sent ahead" — or `unchanged`) →
"Meeting brief — skipped (no recent mail with these people)";
`error` → "Meeting brief — failed"; either over a ready brief (`kept: ready`)
adds "; the last brief stands"; a park keeps the general sentence. Counts
and enum words only: an answer that was not the JSON asked for is recorded as
its category (`format: not JSON`, `rowErrorFor`) in the row's `error` and
`llm_error` and the work row's error, never a word of the answer. The row's
`entity_id` is the work row's (the worker's convention: an activity row
names the entity its work row does) — the OCCURRENCE id the brief is keyed
by, except when a series master reached the handler: then the work row and
the activity row carry the master's id while the brief is stored under the
occurrence's.

## Commands

The Day stop's command bar ([The bar](#the-bar)) reads short
requests — "move my 3pm with Dana to tomorrow morning", "what's on Friday",
"find 30 min with Lee next week" — through an engine in
`lib/services/calendar/command/`. A calendar command is short text over
FINITE, KNOWN sets, so reading one is mostly lookup, not generation:

| Slot | Known set, determined ahead of time | Resolver | Model? |
|---|---|---|---|
| **action**: `create`, `move`, `cancel`, `rsvp_yes`, `rsvp_no`, `rsvp_maybe`, `find_time`, `ask_free`, `ask_agenda`, `ask_person` | closed enum | the decision model's command head (`command_heads.dart`) when one ships and is sure, else the lexicon (`command_lexicon.dart`) | only on Enter, below the bar |
| **when** | the time grammar | `resolveWhen` (`when_resolver.dart`), pure Dart | never |
| **duration** | "30 min", "an hour", "90m" | the resolver's duration grammar | never |
| **people** | the People directory: names and addresses from mail | `matchPeople` (`people_matcher.dart`), exact hits; ambiguous → a choice; unknown → `search_people` on Enter | never |
| **event** | the mirror's meetings in the named day, or the next 14 days | `matchEvents` (`event_matcher.dart`), scored | never |
| **subject** | the leftover words | the parser (`command_parser.dart`) | never |

**The lexicon.** Verb and phrase rules, case-insensitive on word boundaries:
schedule / book / set up / block / put in / new meeting → create (add, invite
are weak cues); move / push / reschedule / shift / bump / postpone → move;
cancel / drop / delete / call off / remove → cancel; accept / yes to / I'll be
there → `rsvp_yes`; decline / can't make / turn down → `rsvp_no`; tentative /
say maybe → `rsvp_maybe` (a bare "maybe" is weak); find (a) time / find 30 min
/ when can / good time → `find_time` (slot with, free with are weak); am I free
/ what's free / do I have time → `ask_free`; what's on / what do I have →
`ask_agenda` (agenda, my day, anything on are weak); when did I last / next
meeting with / when am I seeing → `ask_person`. A STRONG phrase beats every
weak cue wherever it sits; among one strength the earliest wins, and at one
position the longest ("tentatively accept" is a maybe). Confidence is 0.9 for
a strong phrase that leads (after "please", "can you" and the like), 0.75 for
one further in, 0.6 for a weak cue, 0.0 for `unknown`.
`looksLikeCalendarCommand` (for the ⌘K hand-off) is narrow, because the row
that answers true takes Enter away from the search. A calendar verb or ask
phrase must LEAD the text — after one optional please / hey / ok / okay / can
you / could you / would you — and then:

- a person ask stands alone ("when did I last meet Sam");
- a find-a-time stands alone only with a "with" after it ("find time with
  Dana");
- every other phrase needs a day or clock time, or a calendar noun (meeting,
  call, invite, calendar, sync, standup, 1:1, lunch, event, appointment),
  after it ("move my 3pm to Thursday", "cancel the standup", "what's on
  tomorrow").

A phrase further in is a search ("had a good time at the offsite", "notes
from Monday's meeting"), and so is a day beside a noun with no verb ("Friday
call recap"). A verb alone is never enough — "push notifications", "cancel
subscription", "book club", "delete account" are searches for mail — and a
needle carrying a Find facet (`label:`, `-label:`, `from:`, `to:`, `is:`,
`has:`, `in:`, `before:`, `after:`) is a search being built, so it is never
handed over. A false negative costs one click on the Day stop; a false
positive loses what was typed.

**The parser** (`parseCommand`, SYNCHRONOUS — the live preview runs it per
keystroke) composes the lexicon, the resolver (in question mode for the three
asks, booking otherwise), the people match and the event match. **The
leftover rule:** take away the verb phrase, every when-phrase, every person and
the filler ("my", "the", "with", "meeting", "please", "in my calendar"…), and
the words that remain are the subject; quoted text is the subject verbatim
and is never read as a when or a person. **The move split:** the words before
the last "to" / "until" / "till" / "til" / "into" followed by a when-phrase say WHICH meeting
(`eventWhen`); the rest is the target. With no such "to", a when-phrase
marked as a reference ("my 3pm", "Monday's") is the meeting. A slot is
**unresolved** when: no action; no day or time for a create, a move's target
(a shift — "by an hour" — places a move as surely as a time does) or an
ask-free (an agenda defaults to today and never is); nobody named for a
find-a-time or an ask-person; no candidate meeting for a move, cancel or
answer; no subject for a create. `leftoverAfterResolvers` is a slot unresolved
AND non-filler words nothing consumed — for a create or a find-a-time the
leftover words ARE the subject, so they count as explained.

**People** match exactly: an address; a full name; a first name one person
has (several → ambiguous, the planner asks). A capitalised word that matches
nobody is looked up only where a name is expected — after "with", "invite",
"meet", "see", "cc", "to", or continuing a list — so "book Design review" does
not search the directory for "Design". People without a mailbox (Teams-only
`teams:<id>` rosters) are left out of the directory the bar matches against.

**Events** score 3 for the named clock time as the local start, 2 for the
named day (1 for today when a time was named with no day), 2 per named person
attending or organising, 1 per shared subject word. A named clock time is
also a FILTER: a timed meeting that starts at any other time, and every
all-day event, is no candidate at all — "cancel my 3pm" with only a 4 PM call
today finds nothing and says so, rather than cancelling the 4 PM on the
strength of being today's. Series masters and cancelled meetings are never
candidates; a tie at the top is a choice, never broken by anything the
person did not say. Subject words bind nothing on their own day alone: when
the typed subject words match none of a meeting's, and no clock time was
named and no named person is on it, that meeting is no candidate, so "cancel
tomorrow's standup" never binds tomorrow's only other meeting on its day.
With a clock time or a person match, the day rule stands.

**The planner never invents a time.** A create with no clock time, and a
move to a PART of a day ("to tomorrow morning"), is a `SlotChoice` of up to
three real openings. A move's openings are always the owner's own free slots
(`_localSlots`: `freeSlotsOnDay` / `freeSlotsInRange`, working hours from the
cached mailbox settings), whoever attends. A create's and a find-a-time's are
the owner's own when nobody else is invited, `find_meeting_times` with the
bare addresses when somebody is (a personal account's `unsupported_account`
falls back to the owner's own, and the title says so). With no when at all it looks
across the next five working days. A time with no day is today's. A moved
meeting keeps whatever the text leaves out (`resolveNewTime`): a move to a
DAY keeps its wall time and its length ("move my 3pm to Thursday" is Thursday
at 3), a time alone keeps its day; only a part of a day gives openings, in
that window for the meeting's own length. **A move by a duration shifts,
never stretches** (`moveShiftOf`, `shiftedTime` in `write_rules.dart`): a
target that names no day, time or part and ends in a length with a direction
— "by an hour", "forward 15 min", "back 30 min", "earlier by 30 min", "an
hour later" — moves start AND end by it (back and earlier are negative; "by"
with no direction is later), keeping the length. A target with no day, time,
part or shift at all — "move my 3pm", "move my 3pm an hour" — is "Say when it
moves to — e.g. 'to 4pm' or 'by an hour'.", so `resolveNewTime` is never
handed a lone length to read as a new length. A bare hour after "to" with no
am, pm or minutes ("move my 3pm to 4") is "Add am or pm — e.g. 'to 4pm'.":
daytime-first would read it as 4 PM, and a write that may email people is
not the place for that guess. Every
write is dry-run through `CalendarWriter.preview` before it is offered, so a
`CalendarProposal` already carries who it emails and whether it needs a
confirm (the Writes policy above). A cancel follows the role: an organiser
with guests cancels, the owner's own event is deleted, an attendee is offered
a decline and told why. The bar acts on the matched OCCURRENCE: its
candidates are the mirror's rows, and calendarView mirrors a series'
occurrences, never its master, so a command never answers, cancels or deletes
a whole series. When the meeting belongs to one, the confirm line ends
"· one meeting of a series" (`oneOfSeriesSuffix`) — honestly unlike the card
and the panel, whose answer to a master says "every meeting in".
Questions are `Answer`s: a yes or no for a named time ("No — on Fri Oct 16 at
2:00 PM you have Budget review."), the openings in a window, the day's
meetings, next and last met.

**The router** (`CommandRouter.submit`, Enter) asks the classifiers in order
— the command head, then the lexicon; the first answer that names an action
wins, so a head that is absent, refused, down or under its bar (`unknown`)
falls through to the lexicon — parses, and calls the generative model (`calendar_intent`,
`CalendarIntentTask`) ONCE, and only when the best classifier is under the
bar (0.8) or a required slot is unresolved with leftover words. The model
names the action when the rules could not and COPIES phrases — when, people,
event reference, subject, duration — out of the request; it never computes a
date. Each phrase is checked against the request and dropped when it is not
in it — as whole words over the whitespace-collapsed text, so "Dan" is not in
"Danielle" — then goes through the same resolvers as typed text. A slot the
rules filled keeps its value, with two exceptions: when the ACTION was the
model's, its subject replaces the rules' (the rules never read the leftover
words as a subject then, they only failed to read them); and when an action
that needs a meeting found no candidate, the copied event reference is
appended to the subject and, resolved, replaces `eventWhen`. The length is a
copied phrase too: `duration` is the exact words ("30 min", "an hour"), `""`
when none, never a number of minutes; it is used only when it appears in the
typed text, the duration rules read it as 5 to 480 minutes, and the rules
found no length of their own. A move's `when` is
never merged: the planner reads a move's target from the typed words after
the split, so a merged `when` would be drawn and never used. The outcome's
`path` is `generative` only when the model's answer changed the action or
filled a slot; an answer that added nothing leaves the classifier's path,
`head` or `lexicon`. When the model
is not running the local parse stands, and a request the rules cannot finish
says "The model isn't running; try a plainer phrasing…".

Names nobody in the mail has are searched in the directory (`search_people`,
top 5, at most three names). A hit binds by its `mail`, else by a user
principal name that is an address and not a guest's `#EXT#` placeholder; a
hit with neither is not bindable. One bindable person binds; several are a
choice whose every option names the NAME it answers (`CommandBind.answers`),
so picking "Robert Smith" settles "Bob". None: for a create the words go back
into the subject ("book lunch with Design team Friday" is a meeting called
"lunch with Design team", `subjectRestoring`) unless the subject was quoted;
for a find-a-time or a person question the planner says "I don't know who
Priya is — name someone from your mail." A create never goes out a guest
short without saying the same.

**A choice pressed** re-plans the outcome it answered: `submit(binds:,
resume:)` carries EVERY choice pressed so far for the text plus the outcome
the latest press answered, and the router lays the binds over that outcome's
parse with no classifier, no model call and no second search for a name
already settled — so two ambiguous names are two presses and then a plan.

**Activity.** Kind `calendar_command`, one row per Enter, `detail: {action,
path: lexicon|head|generative, outcome: proposal|slots|answer|choice|cannot}`.
Enum words only: never the text, a name or a subject. The activity panel
reads it as "Calendar command — Move · lexicon · proposal".

### The command head

The decision model's second consumer (see `10-model-routing.md`): a
linear head on the SAME encoder triage uses, fitted on the encoder's raw
pooled vector of the typed command, naming its action. It lives in
`command_heads.dart` (`CommandHeads`), kept apart from the nine message heads
(`DecisionHeads`, pinned), and asks the server through
`DecisionClient.embedRaw` — the triage call's wire exactly: the `/tokenize`
identity probe, `embd_normalize: -1`, the width and norm≈1 refusals, the token
path for a long text, and one call record labelled `command_head`.

- **The file.** `app/assets/calendar/command_heads.json`: `{format:
  bond-command-heads/1, encoder_qhash, encoder_model, input: raw-text/1,
  fields: {action: {options, weight, bias, temperature}}, fitted: {n_train,
  n_heldout, heldout_acc, lexicon_heldout_acc, n_heldout_hard,
  heldout_hard_acc, …}}`. The options are the ten actions in `CommandAction`
  order without `unknown`. A file whose format, input or options differ,
  whose weights are ragged, whose temperature is not positive, whose
  `encoder_model` is missing or empty, or whose `encoder_qhash` is not
  `DecisionHeads.expectedQhash` (`6eba387492208260`) is REFUSED at load.
  `pubspec.yaml` registers the DIRECTORY `assets/calendar/`, so a build with
  no fitted file still builds; the loader (`loadCommandHeadsAsset`,
  `commandHeadsProvider`) reads a missing or refused file as null.
- **Tied to the model, not only the question set.** A head reads only the
  vector space of the encoder it was fitted on. `encoder_qhash` is the
  QUESTION SET's hash, which two trainings on the same questions share, so
  the fit also copies the installed `decide-heads.json`'s own `model` name
  into `encoder_model`, and `DecisionCommandClassifier` compares it with the
  installed heads (`decisionHeadsProvider`) at every call: another model
  installed since the fit is no head (one debug line), never a wrong
  answer.
- **The bar.** `apply` is `softmax((W·x + b) / T)`; the argmax is the guess
  when its probability is at least **0.80**, and below that the head answers
  `unknown`, which the router passes over. The head answers only above its
  bar.
- **Refuse → lexicon.** `DecisionCommandClassifier` returns null for no file,
  a refused file, a vector of another width, a model other than the head's
  `encoder_model`, a caller's 800 ms wait running out, and every
  decision-server exception; it never throws and never parks. It catches the
  expected kinds by name (`LlmException` and the decision subclasses,
  `CommandHeadsRefused`, `TimeoutException`); anything else is a bug, printed
  with its stack in debug, and is still null. With no head the bar reads
  the action with the lexicon alone, which is what ships until a fitted head
  is adopted.
- **Nothing asked that could not be answered.** When the decision role is
  not ready — its heads file is not on this Mac, or its target carries an
  `unavailable` sentence (the managed router not serving `bond-decide`) — or
  the installed heads name another model, the classifier returns null BEFORE
  `embedRaw`, so no `command_head` call record and no activity row speaks of
  a model nobody could have asked.
- **The live preview refine.** The lexicon's chips still show 150 ms after
  the text stops; a further 200 ms later the bar asks the head
  (`classifyPreview`, no call record), and when an answer that names an
  action comes back for the words still in the field, the preview is parsed
  again under that guess. A late answer for older words is dropped. The ONE
  gate on requests is the classifier's: the slot is held by the UNTIMED
  request, so a caller that stopped waiting at 800 ms does not free it while
  the server still works; a newer text starts no request of its own, waits
  for the one out to settle, and is then sent once if it is still the newest
  (every text overtaken meanwhile gets null). The bar keeps only the
  "words unchanged" check.
- **The three fixture files** (`app/test/fixtures/calendar_commands/`, all
  fictional, `calendar_commands_fixture_test.dart` pins them):
  `train.jsonl` (40 per action — the fit's only input), `heldout.jsonl` (10
  per action — the number the adoption bar reads) and `heldout_hard.jsonl` (5
  per action: indirect phrasings and typos — reported beside the held-out
  number and deciding nothing). No held-out or hard line may be a train line
  with its slots swapped: after masking roster names, addresses, weekdays,
  months, times, numbers and relative days, none equals a train line.
- **Fitting is owner-run.** `make calendar-heads` (needs `make decide`, or
  `DECIDE_URL`, live; never beside `make model` / `make fast` on one Mac)
  reads the installed `$(DECIDE_DIR)/$(DECIDE_HEADS)` for `qhash` and
  `model`, embeds the three fixture files, fits `tools/calendar_heads/fit.py`
  (numpy: L2 softmax regression, the L2 weight by 5-fold CV, the temperature
  on a fold the weights did not see), prints the head's held-out and hard-set
  accuracy and writes the head under the git-ignored
  `tmp/calendar_heads/command_heads.json` (`CALHEADS_OUT`) — never the asset.
  It then runs `test/calendar_command_heldout_test.dart`, handed that file
  (`--dart-define=CALHEADS_JSON=…`), which prints the LEXICON's held-out and
  hard-set accuracy, both hard-set numbers side by side, and the ADOPTION
  LINE: `adoption: go`, `adoption: no-go (head 0.xx < 0.90)` or `adoption:
  no-go (head 0.xx < lexicon 0.yy + 0.05)`. Every number and the verdict are
  printed; nothing asserts a threshold.
- **The adoption bar** (plan §1.1): the head ships only if its held-out
  accuracy is ≥ 0.90 AND ≥ the lexicon's + 0.05; the hard set's numbers are
  read beside it and decide nothing. On `adoption: go` the owner runs `make
  calendar-heads-adopt`, which copies `CALHEADS_OUT` to
  `app/assets/calendar/command_heads.json`; otherwise nothing ships and the
  lexicon reads commands alone. All four numbers go in the
  `docs/model-bakeoff.md` ledger — measured: head **pending owner run**,
  lexicon **pending owner run** (serverless, the Dart heldout test reads the
  LEXICON — not the head — at 0.710 held-out and 0.140 hard on the fixture
  set; it read 0.830
  held-out before fifteen held-out and hard lines that were train templates
  with other slots were rephrased, which is the leakage the mask check now
  refuses).

### The bar

`DayCommandBar` (`widgets/day_command_bar.dart`) sits under the Day stop's
title row in the agenda AND the grid (never in the invites view), hint "Ask
or tell: move my 3pm with Dana to tomorrow morning". It is prop-only: the
screen binds the clock, the zone, the people (`knownPeopleOfRooms` over the
People rooms) and the meetings (`upcomingEventsProvider(today)`, fifteen
days from today; the event matcher then looks 14 days ahead when no day is
named) into `CommandRouter.preview` and `submit`, through
`commandRouterProvider` / `commandPlannerProvider`.

- **The live preview.** 150 ms after the text stops moving, the synchronous
  parse is read back as chips: the action ("Move", "Create", "Yes"…; none for
  `unknown`), the when on the display zone's clock ("Thu Oct 15 · 2:00 PM",
  "Thu Oct 15 morning", a range, or the resolver's reason), the people
  (matched names, "Dana? (2)" for a shared first name, "Sam?" for a name
  nobody in the mail has — the last two tinted for attention), the meeting
  (its subject, or "2 matches"), the duration ("45 min"). No generative
  model per keystroke; when a command head ships, it refines the action
  chip 200 ms later (The command head, above). For a MOVE the when chip is where the meeting
  goes — read from the target words after the split, a shift as "1 h later"
  / "30 min earlier" (with no duration chip) — tinted for attention while it
  cannot be read yet ("to when?", a bare hour); the time the meeting is at
  now rides on the event chip ("Design sync · 3:00 PM").
- **Enter** runs the router (the model at most once, above); the field spins
  and a second Enter does nothing until the plan is back. An answer that
  lands after a newer Enter, an Escape or leaving the stop is dropped.
  **Escape** clears the text, the chips and the plan — and only when there
  is text or a plan; otherwise it is left for the screen. **Editing** the
  text away from what was submitted drops the plan, so a card never stands
  under words that did not make it. A reading that throws (the router, or a
  slot's dry run) still ends the spin, with "Something went wrong reading
  that."
- **The plan card** (`CommandPlanCard`, `widgets/command_plan_card.dart`),
  inline directly under the bar: a `CalendarProposal` is its summary, the
  overlap line and "This emails: …", and **Do it** (**Send** when it emails
  anyone) through `CalendarWriteFlow` — the dry run again, then the same
  inline confirm strip and the same Undo toast as every other calendar write
  (the Writes policy); the card goes once the write went through. A
  `SlotChoice` is up to three buttons by date and time, captioned "from your
  calendar" or "when everyone is free"; a press dry-runs that slot
  (`CommandPlanner.propose`) into a proposal. A `NeedsChoice` is a button per
  option; a press adds its bind to the choices pressed so far and re-plans
  (above). An `Answer` is selectable text with a chip per meeting it names,
  each opening the event panel. A `CannotDo` is its sentence. The card is
  capped at 320 px or 40% of the pane, whichever is less, and scrolls inside
  that, so a week's agenda cannot push the day off the pane.
- **Availability.** The bar and its card show only where the pane shows the
  mirror (`calendarShowsMirror`): in SDK mode or with the scope missing there
  is no calendar to ask, and neither is drawn.
- **The grid ghost.** While a proposal with a landing time stands, the grid
  draws it as the `GridProposal` ghost ("Proposed"), placed by its instants
  on whichever page holds it; a drop in flight wins over it.
- **Leaving the Day stop** drops the plan, wherever the section is assigned
  (the `_selectedDay` rule); the text goes with the pane.

**⌘K hand-off.** A plain Find needle of four characters or more that
`looksLikeCalendarCommand` accepts (a leading verb or ask, above, never with
a Find facet), while the calendar is shown (`calendarShowsMirror`), gets ONE
dynamic row in Find's strip, "Ask Day: <text> ↵" (`AskDayIntent`). It is not a `findCommands` entry — that
list stays fixed at eleven. Enter on it clears Find, selects the Day stop
and hands the text to the bar, which writes it in and submits it a frame
later.

## Find a time

**What happens.** A thread asking the owner for a time gets a way to answer
it with real free slots, on the thread and in the Day column. No chat model
is involved: the signal is the decision model's, already stored, and the
slots are the calendar's.

**The signal** (`app/lib/services/calendar/scheduling_ask.dart`). A thread is
a *scheduling ask* when both of these hold:

- the owner has not written since its NEWEST inbound message
  (`received_at DESC, source_message_id DESC`, the store's own "newest"):
  the thread's `last_outbound_at` is absent or not after that message (a
  string compare, which holds because both stamps carry the store's one ISO
  width);
- the owner has not closed it: no `scheduling_ask` label with `answer =
  'no'` in `decision_labels` on that same newest inbound message (matched by
  source and `source_message_id`);

and EITHER the model says so —

- its state is `needs_reply`, and that message's stored decision
  (`message_decisions.answers_json`) has `intent` = `scheduling` with the
  scheduling option's own probability (else the choice's confidence) ≥
  `DecisionPolicy.booleanYes` (0.50);

— OR the owner says so: a `scheduling_ask` label with `answer = 'yes'` on
that newest message (the thread bar's **Find a time**, below), whether or
not the model ever read it. Both labels are pinned to the message by id, so
a later inbound message outranks either: an ask the owner opened stays
listed past a newer message only if the model reads the new one as an ask
or the owner presses again.

**Closing and reopening.** An invite is not a message in the thread, so
after the owner sent one from an ask the first three clauses still held and
the ask stayed listed (found live, 2026-10-02). The owner's word about an
ask is therefore a KEPT `decision_labels` row: `question =
'scheduling_ask'`, `answer = 'no'` (to "does this thread still ask me for a
time?"), `source_message_id` = the newest inbound message the rule read,
`origin` = `invite` | `dismiss` (`MessageStore.writeSchedulingAskLabel`).
Two things write one: a slot's invite going through from the Day column
WITH people on it (a slot only added to the owner's calendar answers
nobody, and the ask stays owed), and the row's **×**. The × toasts
"Dismissed — it comes back if they write again." with Undo (the one toast
slot, so `z` works), which deletes the row by id AND stamp
(`deleteSchedulingAskLabel`, the needs-you labels' reason: ids are reused
after a delete). Either way the inbox invalidates `schedulingAsksProvider`
and the row leaves at once; the write's own toast already said the invite
went. Because the label is pinned to a message id, a LATER inbound message
— the other person saying the time does not work — is a new newest message
and the ask comes back by itself; a label on an older message does
nothing. Activity: kind `scheduling_ask`, labelled **Scheduling ask**,
`detail: {origin: invite | dismiss | undo}` (and `owner`, below) — "Closed
an ask after an invite", "Dismissed an ask", "Brought an ask back", "Marked
a thread as asking for a time".

A message the decision model never read (triaged before it, or gated first),
or whose stored answers are unreadable, is an ask only on the owner's yes.
The rule has ONE spelling, a single SQL query —
`MessageStore.schedulingAskConversations(limit: 200, threshold:)`: the
threads joined to their newest inbound message LEFT joined to its decision
(so the owner's yes lists a thread with none), read with `json_extract`
under `json_valid` inside a CASE so a bad row is no ask rather than a failed
read, newest first, capped at 200. `schedulingAskMessageIds` keys the rows by
`'$source|$id'` (`schedulingAskKey`) to their newest inbound message id — the
one path the app and the tests share — and `schedulingAsksProvider`
(`day_providers.dart`) holds that map (the keys for the thread bar and the
column, the id for a label),
re-read when the conversation list reloads (which is what follows a triage
pass writing new decisions, a reply going out, or a state change). No clock.

**The thread header.** `ThreadActionBar` draws **Find a time** (a worded
button beside Mark done, icon `schedule_outlined`, tooltip "Find a time — in
the Day column, with these people"; its word goes with Mark done's at narrow
widths) when the host passes `onFindTime`, which the inbox does — while the
calendar can be searched (`calendarShowsMirror` and the zone resolved, the
condition the Day column draws its asks under, so a press never lands on a
Day stop with no asks column) — on ANY thread with somebody to answer
(`_canFindTime`): its newest message is
inbound (`last_outbound_at` absent or not after `last_inbound_at`) and it
has other people with an address (`_otherPeople`) — asking for a time or
not, on the main thread AND on a thread open beside (a Needs You row opens
beside). A press (`_openFindTime`) is the owner's word that the thread IS a
scheduling ask: unless the thread is already listed, it writes a
`scheduling_ask` label `answer = 'yes'`, `origin = 'owner'`, on the thread's
newest inbound message (`MessageStore.reopenSchedulingAsk`, which reads that
message in the rule's own order and, in the same transaction, deletes any
`no` on it — an earlier dismiss or invite — so the owner's newer word wins),
invalidates `schedulingAsksProvider` and awaits its read. Then it goes to
the Day stop with that ask OPEN in the column — the path a press on its row
takes (`_toggleAsk`: the words read, the default search, the pane following
to the ask's day). Activity: kind `scheduling_ask`, `{origin: owner}`. One
press at a time (`_findingTime`: a double press writes one yes); a thread
with no inbound message to pin the word to says "Nothing to find a time for
— nobody wrote in this thread." rather than nothing.

The main-pane Find a time pane (`FindTimePane`) is retired: everything it
did — the search, Put in reply, an invite through the write flow — the
column's row does. A slot's invite labels the message its slot was picked
for (read at the pick, `_proposalMessageId` beside `_proposalAsk`), not the
newest one when Send lands, so a request that arrives while the card stands
keeps its own ask.

**The search** (`searchFindTime`, `app/lib/services/calendar/find_time.dart`),
as the Day column's row runs it (below) — no search runs without the display
zone's clock:

- **With** — the thread's other participants with an address, lowercased
  (the owner and repeats left out). With nobody, a search of the owner's own
  calendar.
- **How long** — 30 / 45 / 60 min pills, plus the ask's own length; the row
  opens on the ask's own length, else 30 ("The ask's own words", below).
- **When** — the their-day pill first when a day was read, then This week /
  Next week (named by the weekday when one was read; below). The row opens
  on their day, else this week. **This week** is now until Friday
  18:00 local; on a weekend, or once less than the chosen length is left
  before Friday 18:00, the week is over and it means the coming Monday 08:00
  to Friday 18:00. **Next week** is the Monday
  after that one, 08:00 to Friday 18:00. Built from dates with
  `CalendarZone.localDateTime`, never a Duration across midnight
  (`findTimeWindowUtc`).
- **Up to three slots**, each "Tue Oct 20 · 10:00–10:30 AM", with the overlap
  line when the owner's own mirror has a hard overlap there, and a caption
  saying whose calendars answered ("when everyone is free" / "from your
  calendar").

**The ask's own words** (`readAskHints`,
`app/lib/services/calendar/ask_hints.dart`, pure). For "could we grab
dinner on Friday?" the search used to offer Friday at noon — the owner's
working hours. The ask's NEWEST inbound message (subject, then `body_text`
else `body_preview` cut at its first quoted-reply header — "On … wrote:"
over one or two lines that carry a year as a header writes one ("Sep 29,
2026", "29/09/2026", "2026-09-29"; never a clock time such as "at 1930"), a
"<" or an "@" (so
"On second thought, Friday dinner works." stays the ask), "-----Original
Message-----", or a "From:" line with a "Sent:", "Date:" or "To:" line
within the two under it, either possibly quoted with ">" (a lone "From:
tomorrow on…" is a sentence) — so the history's dates never win; the first 600 characters, cut back to a word boundary) is read ONCE
per newest message by the inbox (`_readAskHints`: on the ask's first search,
or a pill pressed while it is out; a newer inbound message is read again on
the row's next open; one read in flight, which every caller awaits) into `AskHints {day, hours, minutes, said}`:

- **The day** is `resolveWhen(…, mode: question)`'s, its relative words
  read against the message's own time when the host passes it
  (`readAskHints(sentAt:)`), else now; whether it has gone is judged at now.
  A week ("next week") is not a day. Only a weekday recurs: one that has
  gone (an old message's "Thursday", however old the message — the ask is
  still open) rolls to its NEXT occurrence — today when it is today's
  weekday — because the weekday is what they meant and the nearest one is
  the answer (a month-old "dinner on friday" opened on a Saturday is the
  coming Friday). A relative day ("tomorrow" in Monday's
  message read on Wednesday) or a date ("Oct 2" read on Oct 5) that has
  gone is dropped: each named one day (`WhenResolution.dayMention`; the
  hours stay). "yesterday" is no day. The same rule for a day that is today
  whose hours have already ended: it rolls a week on when it was a weekday
  ("dinner on Friday" read on Friday at nine is next Friday) and is dropped
  when it was "today"/"tonight"/"tomorrow" or a date ("dinner Oct 9?" names
  that one day); with no hours today stands.
- **The hours**, most specific first: an explicit clock time (a two-hour
  window from it, cut at 23:59; a range such as "2-3:30pm" ends where it
  says, and one past midnight ends at 23:59 with the length cut to the
  quarter hours that fit: "drinks 10pm-1am" is 22:00–23:59 for 105
  minutes), with a meal word
  setting a BARE hour's half of the day ("dinner at 7" is 19:00, and a
  range's bare end moves with it: "dinner from 7 to 9" is 19:00–21:00;
  breakfast keeps its morning, and an hour with am/pm or on a 24-hour clock
  is taken as written: "coffee at 4am" is 04:00); a bare or named time
  more than two hours outside the meal's hours gives way to the meal's
  ("drinks 10pm to midnight", which reads midnight last, is drinks
  17:00–19:30); else a meal or social word, the earliest in the text —
  breakfast 07:30–09:30, coffee 09:00–16:00, lunch 11:30–13:30 (wider than
  the command bar's `DayPart.lunch`, whose bounds are not touched), dinner
  17:30–20:30, a drink, drinks or happy hour 17:00–19:30 ("lunchtime" is
  lunch; "coffeehouse" is not coffee); else a part of the day at
  its `DayPart` bounds. A meal beats a part: "coffee tuesday morning" is
  coffee's hours.
- **The length**: a length the ask named, else a range's own, else the
  meal's — breakfast 45, coffee 30, lunch 60, dinner 90, drinks 60 — else
  none; never more than a window cut at 23:59 holds.
- **`said`**: "Asked for: Fri Oct 9 · dinner" (the day, then the meal, part
  or clock time that set the hours; "Fri Oct 9 · dinner · 7:00 PM" when a
  meal and a time were both named).

Hours that end where they start (a clock time at 23:59) hold no meeting:
nothing is offered and Graph is not asked. The generative model reads the
same words a second time, for several days and a day ruled out, and its
phrases go through these same rules ([Reading the ask](#reading-the-ask)).

The first search of an ask starts from them: `minutes = hints.minutes ??
30`, the window **Their day** when a day was read. `FindTimeWindow.theirs`
is that day alone, from the hours' start (else 08:00) to their end (else
18:00), and from now when it is today; with no day it is this week. Its pill
is the day itself (`findTimeWindowLabel`: "Fri Oct 9") and comes first, and
the ask's own length joins the 30 · 45 · 60 pills when it is none of them.
With hours, a week's window opens Monday at their start and closes Friday at
their end.

**A week with a weekday read means that weekday.** With "dinner on Friday",
**This week** is this week's Friday evening and **Next week** next week's
(`weekdayWithin(monday, weekday)`, built from components), from now when it
is today; this week's once gone (past, or today with no room left — now plus
the meeting's length past the hours' close) is the
next one, as their day rolls, and next week the one after. The pills say so:
"This Fri" and "Next Fri" (the weekday's three letters; plain "This week" /
"Next week" with no weekday read) — and once this week's Friday has gone,
each says the DATE it now means ("Fri Oct 9", "Fri Oct 16"), so a pill never
reads as a day that has passed: the host (the inbox, for the column) builds each pill's words from the day its search would cover
(`findTimeWindowLabels` → `findTimeWindowLabel(covers:, today:)`; a week
pill keeps "This Fri" / "Next Fri" only while that day is inside its nominal
week) and hands them to the row (`SchedulingAskRow.windowLabels`). When that day offers nothing — no slot of
the owner's own, or nothing from Graph inside the hours — the rest of its
Monday–Friday at the same hours is searched and offered under "Nothing free
on Friday for dinner that week — the rest of the week:" (the weekday and the
ask's `timeWords`; "Nothing free on Friday that week — the rest of the
week:" with no hours), with any note of the week's own search — Graph's, or
"Couldn't read their free time…" — following it. A search that could not
run at all (`FindTimeResult.failed`: a refusal, a missing permission,
unreachable) is never retried that way, and neither is a weekend day: a
Sunday has no Monday–Friday of its own after it, nor a weekday whose rest
of the week is the day just searched (Friday searched on a Friday). A window that ends where it
starts searches nothing and asks nobody.

**The pane follows the search.** Before each search of an ask — its first
open (once its words are read, so on their day), a pill pressed, and a
re-open on its standing answer — the inbox moves the Day pane to the first
day of the window about to be searched (`_followAsk`: `findTimeWindowUtc`'s
`firstDay` → `_selectedDay` alone, which keeps the Agenda or Grid face as it
is). So Next week on "dinner on Friday" shows next Friday (the week grid its
week), and a press on its empty time proposes that Friday. It never takes
the owner anywhere: off the Day stop (left during the hint read) it does
nothing, and it sets the day and nothing else — never `_selectDay`, so a
thread, storyline, room or Later day, a New message, Settings, the log or
Invites open on the Day stop stays open and only the day underneath moves.
Only an ask still OPEN moves the pane: one folded during its hint read
(another opened meanwhile) does not pull the pane to its day.

**The search** (`searchFindTime`, `app/lib/services/calendar/find_time.dart`;
never throws):

- People on it → `find_meeting_times` with those addresses, the window as
  two `Z` instants (the server reads offset-bearing bounds as they are; its
  zone is an `options` key for offset-less bounds, not a parameter — the
  handoff's §3.5 signature is wrong there, and the deployed tool refused a
  top-level `timezone` on the first live press), the length and five
  candidates, of which the best three are kept (source `graph`). They rank
  by how many people are free — each attendee whose
  `attendeeAvailability` word is `free`, plus the owner when
  `organizerAvailability` is — then Graph's `confidence`, then the sooner
  start, because Graph's own order put a slot one person could not make
  above one everyone could. Each kept slot carries that count
  (`FindTimeResult.availability`, a `SlotAvailability` of `free` out of the
  people ASKED plus the owner), so an attendee Graph does not answer for
  counts as not free, and an entry for someone not asked (the owner's own
  address) counts for nothing; a `local` slot has none.
- **An empty answer** carries Graph's `emptySuggestionsReason` as
  `empty_reason` (`MeetingTimes.emptyReason`, lowercased), and ONE rule reads
  it (`findTimeEmptyFallback`, shared with the command planner). Only
  `attendeesunavailable` (everyone was read and nobody is free) is a no:
  "Nobody is free this week — try next week." with no slots (the planner's
  `noCommonTimeSentence`). Every other word —
  `attendeesunavailableorunknown`, `organizerunavailable`,
  `locationsunavailable`, `unknown` — and none at all mean somebody's free
  time could not be read (an attendee in another tenant answers nothing;
  measured live 2026-10-02), so the owner's own openings stand in: source
  `local`, captioned "your free time", under the note "Couldn't read their
  free time — showing your own free times." (`findTimeUnreadableNote`; the
  planner's slot choice adds `unreadableSuffix` to its title).
- **With hints**: the owner's own walk takes `dailyHours` (the hours replace
  the working window on EVERY day, still clamped by the window bounds) and
  skips no weekend only when the window is the ask's own day (a week
  searched under hints still skips its weekend). Graph is asked with
  `options.activity_domain`: Graph's `personal` is the working hours PLUS
  the weekend, and only `unrestricted` opens every hour, so `unrestricted`
  when the hours leave the mailbox's working window (`workingWindowOf`:
  dinner), `personal` when the search is the ONE day the ask named and
  that day is not a working day (`isWorkingDay`; read from the window's
  day, never the pill, so a Saturday morning is `personal` under This week
  and Next week too), and `work` (the server's default, so not sent)
  otherwise — a window of several days (no day named, or the rest of a
  week) stays `work`, since the owner's own walk skips its non-working
  days.
  `findMeetingTimes(activityDomain:)` puts the key in `options` only when
  it is not `work`; the domain is decided once per search and shared by
  every call. With hours Graph is asked ONE CALL PER DAY of the window
  (`_hintedDays`; a single day — their day, a weekday on a week pill — is
  one such call): each from the later of the window's start and that day's
  opening to the earlier of its end and that day's close, five candidates;
  at most seven days, a day with no room left skipped; asked together
  (`Future.wait`). So "dinner this week" on a Friday morning asks Friday
  17:30–20:30, never from ten o'clock, and one call over a week of evenings
  starting now — which came back with daytime candidates only — is never
  made. Without hours it is one call over the window for five. The answers
  merge in day order (each suggestion once; "nobody is free" only when
  every day said so); a day whose call fails costs that day, and with
  nothing found the answer is the unreadable fallback, never "nobody is
  free"; every day failing, or a missing permission or `unsupported_account`
  on any day, is the search's failure as one call's would be.
  `FindTimeResult.graphCalls` counts the calls for the `find_time` row's
  `graph_calls`. As a belt, a suggestion whose local start or end leaves the
  hours on its own day is dropped before the ranking keeps three (Graph was
  asked over the hours, so it answers another question); none left is an
  empty answer, read by Graph's reason as above.
- Nobody → the mirror's own openings, `freeSlotsInRange` over the window with
  the mailbox's working hours (source `local`; `find_meeting_times` refuses an
  empty list — gotcha 28).
- `unsupported_account` (a personal account has no free/busy for others) →
  the same local search, with the note "Showing your own free times — your
  account can't look up others' calendars."
- Any other failure → no slots and its sentence as the note (a refusal's first
  sentence, the scope sentence, "Couldn't reach the calendar to find a time.").
- Overlaps for every slot from the mirror (`findOverlaps`).

Nothing found says the search's own note — "Nobody is free this week — try
next week." when Graph read everyone — else the row's "No free time found
this week — try next week." (`findTimeWindowWords`, "then" for their day);
a failed search shows only its sentence, never a false all-clear.

**The two actions** (from the column's row, below).

- **Put in reply** writes ONE line naming every slot shown, with the zone's
  abbreviation — "Would any of these work? · Tue 20 Oct 10:00–10:30 AM PDT ·
  Tue 20 Oct 2:00–2:30 PM PDT" (`findTimeReplyLine`) — so the other person
  picks. It goes AFTER whatever the box already holds (a blank line
  between), through the box's explicit stage (`_stage`, the path a tapped
  suggestion takes, which rebuilds the field with those words) and
  `DraftNotifier.markEdited` (recorded as the owner's words when a draft row
  exists); the thread opens with the cursor in its reply box.
- **An invite** is a slot picked: a `CreateEvent` — subject "Re: <thread
  subject>" (or "Meeting"), the other people as attendees, online when
  anyone is invited — standing as the command card's proposal, so an invite
  that emails people waits on the inline confirm strip naming them ("This
  emails: …"), and one with nobody on it goes straight on with its Undo (the
  Writes policy).

**The Day column.** The Day stop's list column (`AppRail`, 260 px) draws
**SCHEDULING ASKS · N** above the Day section (Invites, the day rows), one
`SchedulingAskTile` per ask (`app/lib/widgets/scheduling_ask_rows.dart`),
hidden at zero asks and while the calendar is not shown. The agenda carries
no asks group: the day view is about the day. The section is dismissable and
comes back: its chevron AND its header label fold the rows to the header,
which keeps its count (`_asksCollapsed` in the rail's state, session-only),
and the same press brings them back; neither selects a section. The rows are
prop-driven — the inbox owns every search in `_askSearches`, by
`'$source|$key'`, and hands the rail a `SchedulingAskRow` per ask with six
callbacks.

- **Folded**, a row is two lines: the subject and who asked (the newest
  inbound sender's name from the participants, else the address).
- **Tapping it** opens it and folds any other (one open at a time), and runs
  the first search at once when it has no answer yet — the ask's own length
  and its day when one was read, else 30 minutes this week; tapping again
  folds it and keeps the answer. A pill pressed while the ask's words are
  still being read stays: the first search is seeded only if no pill has
  been pressed. ONE staleness on the next open (`_AskSearch.forgetReading`):
  a new day (`hintsDay`, `askHintsStale`: "tomorrow" read yesterday is
  another date now) or a kept answer older than 30 minutes
  (`askResultLifetime`, `_AskSearch.searchedAt`, `askResultStale`:
  calendars move, and "dinner tonight" read at five names no day at nine)
  reads the words again AND searches again, the owner's own pills standing;
  their day read again without a day is this week (`askWindowFor`, the pill
  the row then offers). A newer message is a new ask (below).
- **Stale rows.** A row never offers a slot that has ENDED (`_liveResult`,
  for the row and for Put in reply); a slot under way still shows, and
  picking it is the past rule's refusal. Only `_closeAsk` removes a search
  on purpose, so an ask that leaves the list another way (the owner
  replied) has its search pruned when the column is next built; and a
  search read for an older message than the one now listed (a newer
  message on an open row, or an ask that left and came back) is a new
  ask's: a FRESH entry — folded, the pills at their defaults, no slots or
  words — with any answer in flight ignored, so a grid press is then a
  blank event, not an invite on the old search (`_openAsk` checks the
  same). A slot's dry run that lands after its ask was dismissed (or closed
  elsewhere) puts up no card (`_showProposal` re-reads the asks).
- **Open**, it says what the ask asked for ("Asked for: Fri Oct 9 · dinner",
  when its words named anything), then two pill rows, `min 30 · 45 · 60`
  (plus the ask's own length) and `<their day> · This Fri · Next Fri` (their
  day first, and the weeks named by its weekday, when one was read; else
  `This week · Next week`); a press searches again, and the pane moves to the
  day it searches, and an answer a newer press overtook is
  dropped (a serial per ask). "Finding…" while a search runs. Then up to
  three slots, each a full-width tap target: "Tue Oct 20 · 10:00–10:30 AM",
  over the owner's own hard overlap in the rail's accent when the mirror has
  one, else who can make it — `Everyone free` / `1 of 2 free` (graph) or
  `your free time` (local); a note that comes with slots (the
  unsupported-account sentence) sits above them. No slots says the note, else "No free time found
  this week — try next week." Under them **Put in reply** (only with slots)
  and **Open thread**, then the caption "when everyone is free" / "from your
  calendar".
- **A slot picked** shows it in context: `_selectDay` moves the pane to the
  slot's day (today's agenda or grid), and `_showProposal` dry-runs a
  `CreateEvent.propose` (subject "Re: <thread subject>", the thread's other
  addresses as attendees — `_otherPeople`, the same list the search's With
  reads — online when anyone is invited) through
  `commandPlannerProvider.propose` and stands it as `_commandOutcome`. So the
  command bar's `CommandPlanCard` draws it at the top of that day — the
  summary, "This emails: …", **Send** and Cancel — and the grid draws the
  `Proposed` ghost tile. The press goes through the card's
  `CalendarWriteFlow`, whose strip names who is emailed; nothing new
  confirms. Its outcome has no parse (`CommandOutcome.parsed` is null for a
  proposal that came from no typed text). When the card's write goes
  through with anyone on it, the ask closes (above) and leaves the column.
- **×** beside the head, folded or open, dismisses the ask (above).
- While the ask's proposal stands on the card, its head says so in the
  rail's accent: "Proposed: Fri Oct 2 · 7:15–8:45 PM"
  (`SchedulingAskTile.proposedKeyFor`), from `_proposalAsk` and the
  standing proposal's instants; it goes when the card goes.
- **Put in reply** opens the thread and stages every slot shown as one line
  through `_putInReply` (above). **Open thread** opens the
  thread (`_select`).

**Activity.** Kind `find_time`, labelled **Find a time**: one row per search,
`detail: {source: graph|local, slots, people, window:
theirs|this_week|next_week, graph_calls}` (`graph_calls` is
`FindTimeResult.graphCalls`, zero for a search of the owner alone, one per
day searched with hours; the `surface` word went with the main-pane Find a
time it told apart) —
"Find a time — 3 slots (graph)" — and one per action, `{action: put_in_reply |
send_invite}` — "Find a time — put in reply", "Find a time — invite sent" (a
slot's invite gone through with people on it, from the card's `onDone`; a
slot with nobody on it writes no action row, and the invite's own
`calendar_write` row is the writer's, as for every write).
Counts and enum words only.

**Drafts share the search** (`draft_slots.dart`; [07-replies.md](07-replies.md#times-in-a-draft-2026-10)).
A reply draft to a scheduling ask — the one rule, `schedulingAskMessageIds` —
ends with the owner's real free times: the draft handler, after its model
call, reads the ask's hints (the model's reading, else the rules'), seeds the
window as the column does on a first read (`askWindowFor`), searches the
thread's other addresses (`otherAddresses`, shared with the column) through
`searchFindTime`, and appends the `findTimeReplyLine` Put in reply writes. The
draft model never sees the slots. Its `find_time` row is `{action: draft, …,
read}`, and a draft whose times have started or that the mirror now shows
blocked (`slotGone`) is redrafted after the next synced tick, beside the
brief planner — `suggested` drafts only. Because the draft lane reads the ask
first, it is also what pre-warms `ask_readings` for the column.

### Reading the ask

The rules above read an ask at once and never need a model; the generative
model reads it second, for what regular expressions cannot: two days offered
("Tuesday or Thursday afternoon"), a day ruled out ("Friday doesn't work —
how about Monday?", which the rules read as the day ruled out), and an ask
told apart from the chatter around it. The model READS and COPIES; Dart
still works out every date (the `calendar_intent` contract,
[Commands](#commands)).

- **The task** (`AskReadTask`, `app/lib/services/llm/ask_read_task.dart`,
  stage `ask_read`, generative, never Cloud drafts —
  [10-model-routing.md](10-model-routing.md)). The user message is the
  owner's clock ("Now: Sat 3 Oct 2026, 9:40 AM PDT (America/Los_Angeles)"),
  the message's own ("Sent: Tue 1 Sep 2026, 7:34 PM PDT", none without a
  sent time), the subject, and the body's own words (`askOwnWords`, the
  same quote cut as the rules) up to 1,500 characters cut at a word
  (`askReadCap`; the rules keep their 600), fenced as untrusted. The schema,
  flat and in this order: `evidence` (one sentence, first), `asks_for_time`,
  `when` (the words naming WHICH day, one entry per alternative), `time` (the
  clock or part-of-day words), `duration` (the words saying how long), `meal`
  (breakfast, coffee, lunch, dinner, drinks or none). Temperature 0.1, 160
  tokens; `validate` trims and caps every string at 80, keeps the first
  three `when` entries, reads anything but `true` as not asking and an
  unknown meal as none, and never throws.
- **The guard** (`readAskHintsFromRead`, `ask_hints.dart`). Not asking is
  no hints, whatever phrases came with it. A `when`, `time` or `duration`
  phrase is kept only when it appears in the subject and own words on word
  boundaries, ignoring case and spacing (`findPhrase`,
  `app/lib/services/calendar/phrase_guard.dart`, the command bar's guard
  moved to be shared); a meal is kept only when that meal's own word list
  matches the text (so a "dinner" the message never says is no meal; drinks
  covers "a drink" and "happy hour" through its list).
- **The resolution** is the rules' own, through ONE core (`_hintsFrom`)
  that both readers call. Each kept `when` phrase is resolved ON ITS OWN as
  a question against the sent time; the `time` phrase gives the hours (or,
  when it is empty, the first `when` phrase that carries a time or a part of
  the day: "Friday at 3pm"); a `duration` phrase gives the length. Every day
  rule above applies to each day — a past weekday rolls, a past relative
  day or date is dropped, a week is no day, today too late rolls or drops —
  and so does every hour and length rule (the meal's half of the day, the
  two-hour reach, the midnight cut). Nothing kept is no hints.
- **Several days.** The days that survive, deduped and sorted, are
  `AskHints.days`; `day` is the first, for every reader. `said` names them
  all: "Asked for: Thu Oct 8 or Tue Oct 13 · afternoon". Several days only
  widen **Their day**: its window runs from the first day's opening to the
  last day's close, its pill names each day ("Thu Oct 8 or Tue Oct 13"),
  Graph is asked one call per day NAMED (at the hours, else 08:00–18:00) and
  never about the days between, and both the Graph answer and the owner-only
  walk keep one opening per named day first (in day order,
  `_onePerDayFirst`), then fill to three by rank. Each named day is asked
  under its own domain: `personal` for a day outside the mailbox's working
  days, the ask's domain otherwise. The week pills keep their single-day
  behaviour on the first day.
- **The cache** (`AskReader.readFor(source, messageId)`,
  `app/lib/services/calendar/ask_reader.dart`, `askReaderProvider`). On
  demand, never a lane: one call per message, single-flight, and the answer
  stored in `ask_readings` (v26, DERIVED — Clear AI results empties it) as
  `ready` or `none` with the copied PHRASES, never a date, so a reading is
  re-resolved against today on every use. A model that cannot be reached, or
  an answer that fails, stores nothing (a later open asks again) and the
  caller keeps the rules' reading. The activity row, kind `ask_read`
  labelled **Ask reading**, carries `{status, when: <count>, meal: <enum>}`
  ("Read an ask · 2 days", "Read an ask · no time asked"), or the error's
  type — never a phrase.
- **The Day column** (`_readAskHintsNow`, `inbox_screen.dart`). Opening an
  ask reads the RULES at once, so the row shows their words straight away,
  and then asks the reader, waiting up to `InboxScreen.askReadWait` (4 s)
  INSIDE the one read in flight (`_AskSearch.hintsReading`): every caller,
  the first search included, waits the same once. A reading back within the
  wait seeds the first search itself; past it the search runs on the rules
  and the reading goes on in the background (`_AskSearch.refining`). When
  it lands, `_refineAskHints` resolves it and holds it against the rules'
  hints on days, hours and length. One `ask_read` activity row records the
  verdict as booleans only, `{applied, agree, cached}` ("The model read
  the ask the way the rules did" / "The model's reading replaced the
  rules'"). Agreeing changes nothing.
  Differing replaces the hints (`hintsSource` `model`; nothing on screen
  says whose they are); if the first search already ran, the pills are
  seeded again by the same rule the first search uses (`_seedFromHints`)
  and the ask searches ONCE more, the older answer dropped by the serial. An
  ask folded meanwhile is not searched; its answer is dropped so the next
  open searches on the model's reading. A reading for an ask forgotten since
  (a new day, a stale answer) or overtaken by a newer message is ignored. No
  model (off, unreachable, a bad answer) leaves the rules standing: no
  toast, no verdict row.
- **The eval** (the round's D10). `app/test/fixtures/ask_reads/asks.jsonl`
  holds 40 fictional asks: the shapes the rules tests pin and the hard ones
  (a ruled-out day, two days, two times, a header-less quote above the ask,
  a newsletter). Each row's `expect` is what a PERFECT reading yields once
  Dart resolves it; a row the resolvers cannot read either ("the 14th")
  expects what Dart can give and is marked `hard`. Offline,
  `ask_read_fixture_test.dart` prints the rules' score (`rules: 33/40` when
  it landed) and each miss, asserting only the fixture's shape, and pins
  that a hand-written perfect reading of five hard rows resolves exactly to
  `expect`. Live, `make ask-read-eval` runs the real task on the prose slot
  and prints `model: m/40 · rules: k/40 · both: b/40 · disagree: d · failed:
  f` with every disagreement. It asserts shape only — every row answered
  (`failed` is 0), never a score — and is never in the gate. The line goes
  to the "Ask reading" ledger in
  [docs/model-bakeoff.md](../model-bakeoff.md).

The Day column asks, refining an open ask's search with the reading; the
draft lane pre-warms the cache, since a draft answering an ask reads it first
([07-replies.md](07-replies.md#times-in-a-draft-2026-10)).

## Owner checks and follow-ups

**The clean-up round (2026-10-04).** Owed by the owner before the PR merges;
tests cannot settle these. The app runs from the main checkout
(`make app-run BOND_SAMPLE_DIR=`, the real account).

- **Briefs are boxed to today and tomorrow.** The Day stop two days ahead
  shows no glance; a meeting's panel there says "Briefs are written for today
  and tomorrow." with **Write a brief**; pressing it queues an asked brief
  (the work row's payload is `{"asked":true}`) and the glance appears under
  that row once written; a standing meeting next week never gets a brief on
  its own; a brief read during the meeting stays until the meeting ends and
  is gone after.
- **An invitation is one row.** A fresh invite from the Gmail account appears
  ONCE on the agenda — the meeting row with Yes / Maybe / No / Dismiss and no
  "Due" row — and the Invites count agrees. **Yes** → the strip's Send → the
  buttons collapse, the row stays, the Invites count drops, and nothing comes
  back on the next sync. **Dismiss** → the strip reads Dismiss → the row
  leaves the agenda and the grid at once, Outlook shows it declined, and the
  organiser's mailbox receives nothing.
- **Standing and clashes.** Two accepted meetings at the same time:
  side-by-side tiles in the grid, both with a red bar and a ⚠ (each is a hard
  overlap for the other), each agenda row carrying the clash strip that names
  the other; a chip opens the other meeting beside. Maybe on one → that tile's
  fill turns the attention colour and its bar STAYS red (the firm meeting is
  still a hard overlap for it), while the firm tile's bar goes back to its own
  colour and keeps only the ⚠ (a Maybe is a soft overlap for it); the firm
  row's chip reads "· maybe"; the panel lists the clash; the Today section
  says "· Maybe" / "· RSVP owed".

**The calendar-automation round (2026-10-03).** Owed by the owner before the
PR merges; tests cannot settle these. Every surface below is reached from the
main checkout after `make foreground W=calendar-automation` and
`make app-run BOND_SAMPLE_DIR=` (the real account — the sandbox has no
calendar and no To Do).

- **Teams links.** A chat with a titled link, or a meeting's Join link, is
  clickable and opens in the browser (which hands off to Teams). Only chats
  synced since the round carry it: old bodies are not re-pulled.
- **Reading the ask.** A thread asking "Tuesday or Thursday afternoon" opens
  in the Day column with both days named and a slot on each; "Friday doesn't
  work — Monday?" reads Monday; the activity log's `ask_read` rows carry
  `agree` and `applied`. With the generative server up, `make ask-read-eval`
  prints `model/rules/both/disagree/failed` over the 40 fictional asks (the
  rules score 33/40 offline); record the line in the `docs/model-bakeoff.md`
  ledger, row 12.
- **Times in a draft.** A suggested reply on a scheduling-ask thread ends with
  "Would any of these work? · …" and real slots; its `find_time` row carries
  `action: draft`; the model's input (the activity detail) never named a
  slot. After an overlapping event syncs, the still-untouched draft is written
  again (`draft` requeued, `slots_stale`).
- **Briefs in the agenda.** With processing on, a meeting today or tomorrow
  with a deck sent ahead shows a two-line glance under its Day row; the
  chevron opens the brief inline, the deck named under Materials with a chip
  that opens the file beside; the Today section shows the glance. A deck that
  arrives after the first brief rewrites it within about 15 minutes of its
  digest landing.
- **Reminders, before consent.** Remind me on a thread shows the permission
  sentence and a Settings button, no pills; the reply box shows no follow-up
  line; Settings › Connection lists **To Do reminders** with a cross; the
  Needs You switch's caption ends "Needs the To Do permission".
- **Reminders, after consent.** The checklist in
  [15-reminders.md](15-reminders.md#dark-until-consent) (admin consent →
  `Tasks.ReadWrite` in `MS_SCOPES` → deploy → every user reconnects), then
  its [owner checks](15-reminders.md#owner-checks-owed-live-after-the-consent-round):
  a Remind me task in To Do's "Bond follow-ups" list with its reminder and
  link; Follow up · 2 days → a `waitingOnOthers` task and the flag on the sent
  mail; a reply completes both; a deadline reminder for a Needs You thread
  with a deadline; Undo deletes the task.

**Phase 11–13 (2026-10-02).** Owed by the owner before the PR merges; tests
cannot settle these.

- Live checks:
  - the column flow on a real ask, end to end: the row opened, its slots, a
    slot picked, the card, Send, the ask closing;
  - hints on real Graph: dinner → unrestricted evening slots; Saturday →
    personal; the per-day calls (`graph_calls` on the `find_time` row);
  - the cross-tenant `empty_reason` fallback, re-checked;
  - the grid on a real trackpad: the drag feedback, the 10-px band and its
    pill (the band was really 3 px until Phase 13), the next-day toast, the
    Monday caveat;
  - a blank event created, named, with people, and undone, live;
  - the thread bar's Find a time on a thread the model did not flag;
  - the items already owed: the handoff's §7 live items (gotcha 12, below),
    the Phase 5 writes, `make calendar-heads` and its ledger row, and the
    manual route pass.
- Open calls:
  - `decisionLabels()` is unscoped (it reads every question's labels);
  - "soft drinks" matches drinks;
  - "move it instead" (a resize across midnight) beside the new
    "pick a time inside it" (a move across it);
  - the `html_text` 10-s bound;
  - hot reload versus restart;
  - `make background` half-done check;
  - a calendar refusal's toast (past time, a span leaving its day) no longer
    clears Undo; every other no-Undo bar still does — the owner may veto;
  - the PR is not yet opened, and the worktree stays until the merge.

**Live checks still owed.** Tests cannot settle these. Each needs the real
server or the real calendar.

- **From the bond-mcps handoff, §7:**
  - If-Match on an OCCURRENCE id. If it keeps answering `event_changed`,
    re-read the occurrence and use its own key.
  - Recurring series through `sync_calendar`.
  - How Outlook desktop shows an all-day move.
  - Whether an organiser's change to `show_as` alone emails the attendees.
  - Teams short join links. They carry no chat id, so the panel links no
    meeting chat for them.
- **Tally honesty.** Does an attendee's copy of a meeting carry any answers
  at all? The attendee tally names definite answers only, on the assumption
  that it sometimes does. If it never does, that tally can go.
- **Writes, on the owner's calendar:**
  - one real accept, with the confirm strip naming the organiser;
  - one move of a private test event;
  - one Undo.
- **A manual pass over the routes:**
  - the Day stop: today, tomorrow and Invites;
  - Agenda | Grid, and a drag on a private test event;
  - `EventPanel` opened from a Day row, from the Today section and from an
    invite card;
  - a brief appearing for a meeting with mail history, with processing on;
  - the command bar: "what's on tomorrow", "move <test event> to Friday 3pm",
    "find 30 min with <colleague> next week";
  - ⌘K's **Ask Day** row;
  - Find a time on a thread that asks for a time.
- **The command head.** `make calendar-heads` needs the decision server live.
  It prints four accuracies (head and lexicon, on the held-out and hard sets)
  and the adoption line. Record them in the `docs/model-bakeoff.md` ledger,
  and run `make calendar-heads-adopt` only on `adoption: go`. Until then
  `app/assets/calendar/command_heads.json` does not exist and the lexicon
  reads every command.

**Follow-ups, not built:**

- **Teams participants in briefs.** Briefs read mail only. A Teams
  participant is `teams:<id>` and never matches an attendee's address, so the
  fix is to map participants through the people directory. The 8-person cap
  on `participants_json` also hides attendees in busy threads.
- **"move my 3pm to 4".** A bare hour after "to" is refused with "Add am or
  pm", not read daytime-first. Keeping that rule, or reading the hour in the
  meeting's own half of the day, is an owner call. Either way it changes
  only with a test.
- **Resolver gaps:**
  - "this weekend" and recurrence are not read ("the 14th" is, since the
    ask-reading round — the fixture row `the-14th-at-10`);
  - "in 30 min" is a duration, not a relative time.
- **Auto-replies (D15).** `read_email`'s `is_auto_reply` is now kept:
  `McpMailBackend` maps it to `isAutoReply`, the sync stores
  `source_meta_json.auto_reply: true` (only when true), and
  `Message.isAutoReply` reads it. Its first consumer is the reminders'
  reconcile: an auto-reply never completes a follow-up
  ([15-reminders.md](15-reminders.md#reconcile-completion-is-local)).
  Nothing else gates on it.
- **Out of scope for this round (D2, D3, D10, D11, D15):**
  - secondary and shared calendars, which need new scopes;
  - follow-ups beyond F1-lite: F1 shipped as To Do reminders
    ([15-reminders.md](15-reminders.md) — Remind me, Follow up if no reply,
    a deadline reminder), dark until the consent round grants
    `Tasks.ReadWrite`; nudges to other people (F2–F4) are not built;
  - standing rules, capacity, and a daily brief;
  - a calendar in SDK mode;
  - meeting reminders, which stay Outlook's.
