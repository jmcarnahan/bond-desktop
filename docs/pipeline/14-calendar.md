# 14 · Calendar

**What happens.** The owner's **primary** Outlook calendar is mirrored into
one local table, `calendar_events`, over a rolling window, by a sync that runs
fire-and-forget after every mail load. Everything the calendar features read —
a day, the invites still owed an answer, the meeting before and after a
person, the messages that carried an invite — reads that mirror, never the
server, so a slow or failing calendar costs the screen nothing.

No chat model is involved in the mirror: it is `sync_calendar` pages written
into sqlite. The calendar makes two model calls: the pre-meeting
[brief](#briefs), on the generative model, off the draft lane, and — on Enter
only, when the rules could not finish — a [command](#commands)'s
`calendar_intent` read.

> **Live as of schema v21** (calendar round, Phase 2): the table, the sync,
> the store's reads, the inbox wiring and the mailbox-settings cache. Phase 3
> adds the first screen that reads it, [the Day stop](#the-day-stop); the rest
> arrive in later phases — see the end of this file.

## MCP mode only

The calendar is a bond-mcps feature (`McpCalendarBackend`, over the
`sync_calendar` / `get_mailbox_settings` / `manage_event` tools). SDK mode's
direct Graph sign-in asks for no calendar scope and the app carries no
Graph-SDK calendar code, so `calendarBackendProvider` hands SDK mode
`UnavailableCalendarBackend`, whose every call throws `CalendarUnavailable`
with a sentence naming the connection that would give one. The sync's precheck
answers `sdkMode` before any call, and `calendarAvailabilityProvider` starts at
`sdkMode` in that mode rather than `unknown`. An empty calendar would read as
"you have no meetings"; a sentence reads as what it is.

## The data model

Two tables (`app/lib/data/schema.drift`, schema v21).

| Table | Holds | Class | Written by |
|---|---|---|---|
| `calendar_events` | one row per event id, as `sync_calendar` last reported it | **synced** | `CalendarSync` via `CalendarStore.upsertEvents` / `deleteEvents` / `sweepRun` |
| `event_briefs` | one pre-meeting brief per event occurrence ([Briefs](#briefs)) | **derived** | `MeetingBriefHandler` via `CalendarStore.putBrief`; `BriefPlanner` deletes out-of-window rows |

`calendar_events` is in `MessageStore.syncedTables`: it is mailbox data, so
**Clear AI results** leaves it and a mailbox wipe (`wipeAll`, sign-out,
**Forget everything and re-sync**) empties it. `event_briefs` is in
`derivedTables`: Clear AI results empties it, and the next calendar sync plans
the briefs again.

The time rules (D13) hold in the columns:

- A **timed** event fills `start_utc` / `end_utc` with stamps at
  `calendarStamp`'s fixed width (identical to `MessageStore.isoStamp`), so
  string comparison in SQL is chronological, and leaves the dates NULL.
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
| `upsertEvents(events, syncRun:, skipIds:)` | one transaction (a savepoint when the sync's page transaction is open); `INSERT … ON CONFLICT(id) DO UPDATE` over every column of `CalendarEvent.toDbRow`, so the column list cannot drift from the model; ids in `skipIds` are not written |
| `retagRun(ids, runId)` | sets `sync_run` on the stored rows of `ids` and nothing else; the write guard's re-tag |
| `deleteEvents(ids)` | by id; ids never stored are ignored |
| `sweepRun(runId, keepIds:)` | deletes every row whose `sync_run` is not `runId`, except `keepIds` |
| `event(id)` | one row |
| `eventsBetween(startUtc:, endUtc:, fromDate:, toDateExclusive:)` | timed events overlapping `[startUtc, endUtc)` plus all-day events overlapping `[fromDate, toDateExclusive)`; a zero-length timed event counts when its start is in the span; cancelled included (the caller decides), series masters excluded; all-day first, then by start |
| `invitesOwed(nowUtc:, today:)` | `CalendarEvent.needsResponse` in SQL (a null `response_requested` counts as asked), future only — timed after now, all-day from today — soonest first |
| `nextMeetingWith(addresses, nowUtc:)` / `lastMetWith(…)` | the next timed meeting starting after now, or the latest that ended by now, with any address as attendee (`json_each` over `attendees_json`) or organiser; case-insensitive; not cancelled, not declined |
| `messagesForEvent(eventId)` | stored messages whose `source_meta_json.event_id` is the event, newest first; a `LIKE '%"event_id"%'` prefilter first, then `json_extract` guarded by `json_valid` so one malformed blob cannot fail the statement |

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
5. on the run's first `complete`, the sweep and `swept: true`.

The loop stops on `complete`; on a page that is not complete and hands back
the cursor it was sent (the server's signal that a later Graph page failed —
tried again next tick, no error); and at the cap, leaving the cursor for the
next tick. A first read bigger than ten pages therefore spreads across ticks,
and its sweep waits until the run completes.

### Mark-and-sweep

When a run first reaches `complete`, every row whose `sync_run` is not the
run's id is something the calendar no longer holds inside the window, and
`sweepRun` deletes it, except ids written by this app within the write guard's
span. The state is then marked `swept: true`, and later delta pages of the
same run never sweep again. An empty cursor together with `complete` is the
server's "start a new run next time": the stored cursor is cleared.

### The generation check

Every write transaction of a tick — a page, the cursor-expired restart, the
mailbox-settings cache — opens by re-reading `calendar_run` and abandons the
tick, writing nothing, unless it still names the tick's run. `wipeAll` deletes
that pref inside its own transaction, so the two serialize: a tick whose
`sync_calendar` call was in the air across a sign-out or **Forget everything
and re-sync** cannot write the old account's rows, cursor or zone back. An
abandoned tick ends `skipped`, leaves availability alone and starts no
backoff, so the next tick begins the new run at once.

A rebuild of `calendarSyncProvider` (a backend or server URL change) starts a
fresh `CalendarSync`; the generation check keeps a tick the old one still has
in flight from writing into a run the new one has since replaced.

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
which forces it.

**Single flight:** a call while a tick runs returns that tick's future, forced
or not.

`syncNow` **never throws**. Outcomes: `synced`; `skipped`; `scopeMissing`
(`CalendarScopeMissing`, or the precheck finding no `calendars.read` in a grant
that still answers `mail.read`); `sdkMode`; `unavailable` (`CalendarUnavailable`,
`ReconsentRequired`, `NotSignedIn`, or a session that cannot answer even
`mail.read` — an MCP server offline or mid-restart, which the precheck
`calendarPrecheck` tells apart from a missing scope with `read_ack_queue`'s
idiom); `failed` (anything else — a transport drop, a Graph 5xx — traced with
`debugPrint` by exception type only, retried after the backoff). Progress persisted before a failure stays.

After each tick the inbox copies `CalendarSync.availability` into
`calendarAvailabilityProvider` (synced → available; scope missing, SDK mode
and unavailable → themselves; a failure keeps the last answer, so one dropped
request does not flicker the Day stop) and bumps `calendarRevisionProvider`
when rows changed or the tick wrote the mailbox-settings cache
(`settingsRefreshed`). Readers of the mirror, and the zone, watch the revision.

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
synced tick changed rows or completed a new run: `count` = rows upserted,
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
null means "nobody said", never "not a meeting". `event_id` is how later
phases link a message to its event (`CalendarStore.messagesForEvent`). The
SDK backend never sets `calendarEventId`. `read_email`'s `not_found` error is
mapped to a 404, which the sync skips like any vanished message.

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

**What happens.** The icon rail's Day stop (after Needs You) shows one day at a
time as a MERGE of three things the app already holds: the mirror's events,
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
clock just as arriving on the stop does.

### What a day holds, in order

1. **All-day events**, in the store's order. They are dates, not instants, and
   head the day rather than sitting at a midnight they do not have.
2. **Deadlines**: every thread that is not done whose `latestDeadline` passes
   `showableDeadline` and whose `parseDeadline` day is this day. Relative
   deadlines resolve against the inbound message that named them
   (`lastInboundAt`, falling back to now), so "EOD" said three weeks ago is not
   due today; a deadline whose day has passed does not appear on today's
   agenda — overdue work lives in Needs You.
3. **Everything with an instant**, by that instant: meetings, **returns**
   (threads in Later — `bucket = 'later'`, not done — whose `snoozed_until`
   falls on this day in the display zone) and the **Now marker**. The marker
   sits after every row that started strictly before now and before every row
   starting at or after it, so a meeting starting this minute reads as next.
   A meeting and a return at the same instant put the meeting first.

A thread gives ONE row per day: a deadline beats a return. Declined and
cancelled meetings stay on the day, faded and struck through, because a
meeting that silently vanished is one somebody turns up to. Each meeting's
overlap line comes from `overlapsForEvent` against that same day's events,
which skips cancelled, declined, free and workingElsewhere. A timed event sits
on every local date it touches, from the date of its start through the date of
the instant just before its end; an all-day event on every date in
`[startDate, endDate)`.

Times print on the display zone's wall clock (`zone.toLocal`, never
`DateTime.toLocal()`), in the house 12-hour style: `10:00–10:30 AM`,
`11:30 AM–12:30 PM`, `11:00 PM–Wed 1:00 AM`. A meeting counts down (`in 18m`,
`now`) inside the hour before it and while it runs, and carries **Join** from
fifteen minutes before its start until its end. The agenda sits under one
30-second clock tick, so the Now marker, the countdowns and Join follow the
clock on a pane nobody touches. A meeting, all-day or invite row opens the
event beside ([Events, invite cards and people](#events-invite-cards-and-people)).

### What shows, per availability

| `CalendarAvailability` | Day pane | Today section |
|---|---|---|
| `available` | rows; an empty day says `Nothing on your calendar.` | shown |
| `unavailable` (offline) | rows as saved, under `Can't reach the calendar right now — showing what was saved.` | shown |
| `unknown` (no tick yet) | rows; an empty day says `Reading your calendar…` | hidden |
| `scopeMissing` | no rows; `Calendar permission needed — Settings › Connection` and **Open Settings** | hidden |
| `sdkMode` | no rows; the SDK-mode backend's own sentence | hidden |

The Invites view follows the same table: the same sentences for `scopeMissing`
and `sdkMode` (never `No invites to answer.`), the offline caption for
`unavailable`, and nothing at all while the read is still in flight.

`calendarShowsMirror` (the first three) is the providers' gate too, so a switch
to SDK mode stops the stale rows showing without deleting them.

### Invites owed

`invitesOwed` answers every expanded occurrence of an unanswered series, so
`collapseInvites` folds them by `seriesMasterId`: one entry, the SOONEST
occurrence shown, the rest counted (`· series` on the row). An invite is
**pinned** when any linked invite message — linked to the occurrence, or to
its series master, through `messagesForEvent` — has a stored decision with
urgency `high` or `urgent`, or importance `high`. Pinned entries come first,
then soonest first. A decision read that throws costs that invite its pin,
never the list. Overlaps for all invites come from ONE `eventsBetween` over
the span they cover, capped at 121 days. Each row carries Yes / Maybe / No
(see Writes); a row folded from a series answers the series, through its
master's id.

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
(`remainingToday`) — each with its countdown, then `Invites · N`. It shows
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
  room. Tentative is a lighter fill with a fainter bar, declined is faded and
  struck through, cancelled is grey and struck through, and a hard overlap
  turns the tile's left bar to the attention colour.
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
  move would land as a ghost tile, "Moving here…", which the flow's `onIdle`
  takes down when the write goes through, fails or is dismissed. The grid
  never moves the tile itself: it renders from the store, so a refused,
  failed or dismissed move leaves the tile where it was, and a move that went
  through moves it when the mirror does.
- **The ghost tile.** `DayGrid.proposal` draws a translucent, outlined,
  undraggable tile for a time that is not on the calendar: the pending
  drop's "Moving here…" today, and Phase 8's hook for a proposed slot.

## Events, invite cards and people

A meeting opens as the ninth side panel, `EventPanel(eventId)`
(`app/lib/widgets/event_panel.dart`, hosted by `InboxScreen._eventPanel`).
The id resolves through `eventByIdProvider`
(`app/lib/providers/event_providers.dart`):

1. Calendar not shown (no permission, SDK mode) → `blocked`, and the panel
   says the Day stop's sentence. Neither the store nor the server is asked.
2. The mirror row, when there is one. A series master brings its mirrored
   occurrences (`CalendarStore.occurrencesOf`), and every view shows the
   first one that has not ended (`displayOccurrence`), marked `· series`.
   A date outside the current year carries its year.
3. Otherwise a live `get_calendar_event` — an invite for a meeting outside the
   121-day window, say, or a recurring invite: the mail names the series
   MASTER, and calendarView mirrors the occurrences without it, so a live
   master still takes its occurrences from the mirror. The answer is held in memory ONLY: a row written
   outside `CalendarSync` would be swept by the next run (gotcha 36).
   `CalendarEventGone` → "This event no longer exists."; any other failure →
   "Couldn't reach the calendar."

The panel holds: when (`Tomorrow · Wednesday, Sep 30 · 10:00–10:30 AM`, or
`All day · …`) with a live countdown; Join (emphasised from fifteen minutes
before the start, absent once it has ended, when cancelled, or with no link);
**Open in Outlook** (`web_link`); where; who organised it; your own answer
(`You accepted`, `You haven't answered`, …); the overlap line; the attendees
with their answers under a tally; the conversations linked to the
event; and the invite's own text as plain words (untrusted — never a link,
never HTML). Every link it offers goes through `_launchExternal`'s scheme
guard.

**The tally** counts people, never rooms, the organiser, or an entry whose
answer is `organizer`. On a meeting you organised it is the whole picture —
`4 of 6 accepted · Sam declined · 1 no reply`. On an attendee's copy Exchange
does not reliably track the other attendees' answers (they commonly read
`none`), so the tally names only definite answers — `2 accepted · Sam
declined` — and is absent when there are none. Whether an attendee's copy
carries answers at all is an owner live check.

A live read that fails leaves the panel saying so with a **Retry**, which
drops the cached answer (`ref.invalidate`) and asks again; a failed mirror
read reads as the same "Couldn't reach the calendar", never as a panel stuck
on "Reading…".

**Linked conversations** (`eventLinksProvider`): every stored message whose
`source_meta_json.event_id` is the event — or, for an occurrence, its series
master — folded to one row per conversation, newest first, each with its
storyline chip when the thread is in one. The Teams meeting chat is added when
`teamsThreadId` parses out of the join link AND a `teams` conversation with
exactly that chat id is stored; a short join link carries no id, and nothing
is guessed from one. A conversation row opens the thread pushed on the event,
so ✕ comes back to it.

**Invite cards.** A message whose `meetingMessageType` is `meetingRequest` or
`meetingCancelled` (compared lowercased) AND whose `meetingEventId` is set
carries a card under its body (`MeetingCardHost` → `MeetingCard`). No id, no
card — nothing is matched by subject. Responses never get one; the gates have
already kept them out of the list. A request card shows the when line, the
overlap line, the tally, Yes / Maybe / No (see Writes), Join and **Open
event**; a cancellation, or a request
whose event has since been cancelled, is one line — `Cancelled: Design review
· Thursday, Oct 2 · 10:00–10:30 AM`. An event the calendar no longer has says
so in one line. A message with a request card never starts folded in the transcript; a
cancellation folds like any other history.

**People.** A person's room leads with `Next meeting: … · Last met 12 days
ago`, from `nextMeetingWith` / `lastMetWith` over every address in the room
(`personMeetingsProvider`, keyed by the addresses and the host's quarter-hour
"as of" instant). "Days ago" counts display-zone dates, not 24-hour spans.

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
…", Send / Cancel, Enter and Esc); anything else goes at once and offers an
**Undo** through the app's one toast (and `z`). Every answer confirms by its
kind, not by the dry run's list: each one is sent and emails the organiser,
whatever the server happened to name. An Undo exists only for a write whose
DRY RUN emailed nobody — a commit made without a preview never offers one —
because an answer, once sent, can be followed by another but not taken back.
One send per confirm: the flow moves to committing before its first await, so
a click and an Enter in the same frame send once.

| Write | Who is emailed | Confirm | Undo |
|---|---|---|---|
| Accept / Maybe / Decline (+ a note, + a proposed time) | the organiser | always | none |
| Move — organiser with guests | the attendees | yes | none |
| Move — your own event | nobody | no, acts at once | the move back, with the new change key read at undo time |
| Cancel meeting (+ a note to everyone) | the attendees | always | none |
| Delete | an organiser's delete sends cancellations | always | none |
| Create | whoever it invites | always when it invites anyone — named outright in `needsConfirm`, not left to the dry run's notifies list, because the Day command bar builds invites from typed words | delete it, when it invited nobody |

A create carries a transaction id (32 hex characters from `Random.secure`) made
once per proposal; a retry reuses the same `CreateEvent`, so a create whose
answer was lost cannot land twice.

**The local effect.** A real write makes the mirror agree at once, then forces
a sync (`syncNow(force: true)`, unawaited) for what the server did beyond the
one row it answered:

- a move or a create that answered a row → `CalendarSync.storeWritten`: the
  write guard noted and the row tagged with the CURRENT run, so neither a page
  read before the write nor the next sweep undoes it (gotcha 36); a create
  with no placeable row only notes its id and waits for the sync;
- an answer → `CalendarStore.setResponseStatus` on the id and, for a master,
  every mirrored occurrence, each id noted;
- a cancel or a delete → `CalendarStore.deleteWithOccurrences`, each id noted.

Then `calendarRevisionProvider` is bumped, so the Day stop, the panel and the
cards follow without waiting.

**After it goes through**, the side effects — the local apply, the revision
bump, the forced sync, the activity row, the Undo — each run on their own
guard OUTSIDE the failure mapping: a throw there is logged by type and the
write is still a success, because the server has it and a Try again would
send it twice. The toast says a series-wide answer, cancel or delete as
"Accepted every meeting in …", as the confirm did. The buttons are rebuilt
fresh, so a "Move to…" field typed for the old time is gone, and the keyboard
stays in the panel, so `z` reaches the Undo without a click.

**When it fails**, the sentence stands under the buttons that caused it,
never in a toast:

| Failure | Sentence | Also |
|---|---|---|
| `event_changed` | "This event changed in Outlook — check it and try again." | re-read and stored |
| `not_organizer` | "Only the organiser can change this meeting." | |
| scope missing | "Calendar write permission missing — reconnect in Settings." | |
| `not_found` | "This event no longer exists." | dropped from the mirror |
| any other refusal | the first sentence of the server's reason | |
| reconsent / signed out | "Reconnect Microsoft in Settings, then try again. Nothing was changed." | |
| transient, dry run | "Couldn't reach the calendar. Nothing was changed." | **Try again** re-runs the same write |
| transient, real write | "Couldn't confirm the calendar got this — check it before trying again." | it may have landed: a forced sync; **Try again** only for a create (its transaction id) and a move (its `if_match` turns a landed first try into `event_changed`), never for an answer, a cancel or a delete, which would email everyone twice |

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
not done here. The event panel shows the full set; the meeting card and each
Invites row show Yes / Maybe / No only.

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

A short brief before a meeting with people the owner has been writing to:
what is open with them, what they asked, what the owner is waiting on. Stage
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
| starts within the next 36 hours (`briefHorizon`; exactly 36 h is in, a minute past is not) | `too_far` |
| at least one other person: an attendee whose address is not the owner's (case-insensitive) and whose type is not `resource`, or an organiser who is not the owner — an attendee's copy with a hidden guest list names only the organiser, and is still a meeting with someone | `no_others` |
| at most 15 other people (`briefMaxOthers`): past that the meeting is a broadcast | `too_many` |
| at least one conversation with any of those addresses in the last 30 days (`MessageStore.conversationsWithAddresses`, matched on `participants_json.email`) | `no_mail` |
| (handler only) the event is no longer in the mirror | `gone` |

**Mail only for now.** Teams participants are stored as `teams:<id>`, not
addresses, so the address match never finds a chat; mapping them through the
people directory is a follow-up. And `participants_json` holds at most 8
people per conversation, so an attendee beyond the 8th in a busy thread is
not matched by that thread.

The owner's address is the sync's own lookup (`storedAccount`, `mail` then
`userPrincipalName`); unknown, an event the owner organised still leaves its
organiser out, and the planner does not run at all (below). Briefs are keyed
by the OCCURRENCE: the planner reads the mirror's rows, never a series
master, and a master that reaches the handler anyway is briefed as its
`displayOccurrence` and stored under THAT occurrence's id, which is the id
the panel reads.

**What is gathered** (`lib/services/calendar/brief_gatherer.dart`, store
reads only, no model):

- **Threads** — up to 20 candidate conversations are read; ranked first by the
  decision on each one's newest inbound message (`urgency ∈ {high, urgent}` or
  `importance = high`, the invite-pinning rule), then by `last_message_at`,
  then key; the top 6 are kept, each with its subject, state, last stamp and
  its last two messages' text (attachment markers and link targets stripped,
  whitespace collapsed, capped at 600, fenced).
- **Open asks** (§1.1 point 1) — in a kept thread whose state is
  `needs_reply`, an inbound message from an attendee that came AFTER the
  owner's last message there (an ask before a reply is taken as answered),
  whose stored decision has `needs_you_p ≥ DecisionPolicy.needsYouYes` (0.65)
  or `reply_expected_p ≥ DecisionPolicy.replyYes` (0.50), and whose `intent`
  is `question`, `request` or `approval` (`scheduling` is left out: the
  meeting is usually its answer). The newest such message per thread, at most
  4, capped at 300 and fenced.
- **Waiting on them** — kept threads in state `waiting` whose newest message
  is the owner's, at most 3.
- **Storylines** — the live storylines of the kept threads, at most 2: the
  title, and the recap (else the summary) capped at 400 and fenced.
- **Files** — attachment names from the attendees' messages in the kept
  threads (not inline, not a quoted message or a card), at most 8.
- **Last met** — `lastMetWith` → `lastMetLabel`.
- **The invite's `body_preview`**, capped at 600 and fenced.

The fencing rule: every free-text body arrives from the gatherer inside
`wrapUntrusted`; the short labels (subjects, names, titles, file names) stay
raw because the panel's links and the hash read them, and the task fences
each as it lays the message out.

**Tally honesty.** Nobody's response is read anywhere in a brief. Only the
organiser's copy tracks answers; on an attendee's copy `none` means "not
known", never "hasn't answered", so the brief says nothing about who is
coming (the prompt also forbids it) rather than risk saying something false.

**The inputs hash** is sha256 over the event's id, `change_key` and times,
the owner's address, each kept thread's `source|key|last_message_at|
message_count`, each ask's message id, each storyline id and each file name.
A new message moves its thread's stamp and count, so it moves the hash; an
edit to an existing message's text alone does not. The hash never reads the
clock.

**The task** (`MeetingBriefTask`, `lib/services/llm/meeting_brief_task.dart`):
a const system prompt ending in `untrustedDataClause`, with the rule "Never
write today, tomorrow or yesterday; name the day." (a brief is read for up to
a day and a half after it is written); the user message opens with `Now:
<absolute local time>` and the meeting line, both absolute (`briefWhenLine`:
"Wed 7 Oct 2026 · 10:00–11:00 AM PDT", "All day · Wed 7 Oct 2026"), then the
numbered threads, each with its last message as an age from `now`
(`briefAgo`: "3 hours ago", "2 days ago"), and each section; temperature 0.2,
700 tokens. The schema is flat — `headline` (string), `points` (`{text,
thread}`), `open_asks` (`{person, ask, thread}`), `prep` (strings, `maxItems`
3) — all required, `additionalProperties: false`, and no `maxItems` on the two
object arrays and no `maxLength` anywhere, because the grammar converter
refuses them. `validate` holds every ceiling instead: headline 140, at most 5
points of 200, 4 asks of 200 (person 80), 3 prep lines of 120, empty strings
dropped; thread numbers are 1-based in the message and the answer, and are
turned 0-based, with anything outside the numbered list (or ≤ 0) becoming -1,
so a line can never link to a thread that is not there.

**The handler** (`MeetingBriefHandler`, kind `meeting_brief`, source
`calendar`, entity = event id) re-reads the event (missing → skipped
`gone`), gathers (ineligible → skipped with its word, no call), and returns
without a call when the stored brief is `ready` with the same hash — unless
the row's payload is `{"asked":true}` (`BriefRequest`, Regenerate's), which
always writes. Otherwise
it runs the task and stores `ready` with the brief JSON — plus a `threads`
list of `{source, conversation_key, subject}` in the order the model was
shown them, so the panel links a point to its thread without gathering again
— and the resolved model name. An empty headline is an `LlmFormatException`.
A dead server (`LlmUnavailableException` and its subclasses) propagates and
PARKS the kind like a draft, writing nothing; any other failure writes
`failed` and rethrows, so the worker's retry-once-then-error policy applies.
**A ready brief is never destroyed** by a later run: over one, a failure or a
skip keeps `brief_json` and `status = ready` and moves only `generated_at`
(`CalendarStore.touchBrief`), so the two-hour rule throttles the retries; the
activity note says `kept: ready`.

`AiWorker.sources` carries `calendar` for these rows: a work row's source is
the row's origin, and a brief's is the calendar.

**The lane.** The draft lane, after `draft` — see
[10-model-routing.md](10-model-routing.md#three-drains) for why.

**Planning** (`BriefPlanner.plan`). After each calendar sync whose outcome is
`synced`, and only while processing is on, `InboxScreen._syncCalendar` fires
the planner (never awaited by the mail load; every failure a trace) and pumps
the draft lane when it queued anything. It returns 0 at once while the
owner's address is unknown (the keychain has not answered): without it the
owner counts among every meeting's people. Otherwise it reads every event
touching the next 36 hours, deletes the briefs of every other event
(`deleteBriefsExcept`, so the table holds only the window, a meeting under
way included), and walks the meetings soonest first, timed before all-day:

- on `briefQuickCheck`, skips it — writing a `skipped` row for `no_others`
  or `too_many` (below);
- leaves a stored brief alone for **2 hours** after it was written, whatever
  changed — a busy thread the morning of a meeting would otherwise buy a
  model call per sync;
- does not gather again an event it gathered less than **15 minutes** ago
  (`BriefPlanner.recheck`, in memory) whose stored row has not moved since;
  an event with NO stored row is never throttled, so after Clear AI results
  the next synced tick plans it at once;
- past that, gathers the fresh hash and marks the meeting due when there is
  no brief, the brief `failed`, or the hash moved;
- when the gather says `no_mail`, `no_others` or `too_many`, writes
  `skipped` with `inputs_hash = ineligible:<word>` (no model call) unless the
  row already says so or holds a ready brief, which stands; once the reason
  goes away the hash differs and the meeting is queued like any other after
  the 2 hours;
- skips a row already `pending` or `processing` without counting it;
- stops at **6** due, then queues them in REVERSE with
  `requeueWork(refreshCreatedAt: true)`, so the soonest meeting carries the
  newest `created_at` and drains first (the lane claims one kind at a time,
  so the stamps order briefs only among themselves). Planner rows carry no
  payload.

**Regenerate** in the panel is `requeueWork('meeting_brief', 'calendar', id,
payloadJson: '{"asked":true}', refreshCreatedAt: true)` — a person asked, so
it goes to the front and is rewritten even when nothing changed — then a
draft-lane pump. It is offered with processing off too; the request waits and
runs when the switch comes back.

**Clear AI results** empties `event_briefs` (a derived table) and the next
sync plans the briefs again. Briefs are per meeting, not per message, so
nothing is added to `clearDerived`'s per-message loop.

**The panel.** `BriefSection` (prop-only, `lib/widgets/brief_section.dart`)
over `eventBriefProvider(<shown occurrence id>)`, drawn while the meeting has
not ended. In order of precedence: a ready brief (headline, points with a chip
naming the thread, Open asks, Prep, "Generated 2h ago · Regenerate" — or
"Rewriting…" while a new one is queued; the old brief stands until the new one
lands); "Writing the brief…"; "Briefs are paused while processing is off.";
a skipped row's reason ("No brief — no recent mail with these people.",
"No brief — nobody else is invited.", "No brief — too many people for a
brief.", "No brief — this meeting has started.", else "No brief for this
meeting."); "The brief couldn't be written." with Regenerate; when the
no-read rules already say no, the same sentence for their word ("A brief is
written in the 36 hours before the meeting." for `too_far`); else "Brief
coming after the next calendar sync." The view
re-reads on the calendar revision, `briefRevisionProvider` (bumped by the
handler's `onStored` and by Regenerate) and `briefWorkTickProvider` (the draft
lane's progress for this kind, which lands after the work row is written).

**The agenda teaser.** `briefHeadlinesProvider(day)` → `DayPane
.briefHeadlines`: a ready brief's headline as a muted one-line line under the
meeting's subject; none on a cancelled meeting.

**Activity.** Kind `meeting_brief`, labelled **Meeting brief**, written by the
worker with the handler's notes: `ok` with `{threads, asks}` → "Meeting brief
— written from 3 threads"; `skipped` with `{reason: <word>}` (a D6 word, or
`unchanged`) → "Meeting brief — skipped (no recent mail with these people)";
`error` → "Meeting brief — failed"; either over a ready brief (`kept: ready`)
adds "; the last brief stands"; a park keeps the general sentence. Counts
and enum words only.

## Commands

The Day stop's command bar (Phase 8; the bar itself is part 2) reads short
requests — "move my 3pm with Dana to tomorrow morning", "what's on Friday",
"find 30 min with Lee next week" — through an engine in
`lib/services/calendar/command/`. A calendar command is short text over
FINITE, KNOWN sets, so reading one is mostly lookup, not generation:

| Slot | Known set, determined ahead of time | Resolver | Model? |
|---|---|---|---|
| **action**: `create`, `move`, `cancel`, `rsvp_yes`, `rsvp_no`, `rsvp_maybe`, `find_time`, `ask_free`, `ask_agenda`, `ask_person` | closed enum | the lexicon (`command_lexicon.dart`); Phase 9 puts the decision model's command head in front | only on Enter, below the bar |
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
`looksLikeCalendarCommand` (for the ⌘K hand-off) is true for one of three
shapes: a strong verb that LEADS the text beside a day or clock phrase or a
calendar noun (meeting, call, invite, calendar, sync, standup, 1:1, lunch,
event, appointment — "move my 3pm to Thursday", "cancel the standup"); an ask
phrase — free, agenda, a person's meetings, find a time — as a strong phrase
anywhere ("what's on tomorrow", "find 30 min with Sam next week"); or a day or
clock phrase beside a calendar noun, verb or none ("tomorrow's meeting",
"invite Dana Friday"). A verb alone is never enough — "push notifications",
"cancel subscription", "book club", "delete account" are searches for mail —
and a needle carrying a Find facet (`label:`, `-label:`, `from:`, `to:`,
`is:`, `has:`, `in:`, `before:`, `after:`) is a search being built, so it is
never handed over.

**The parser** (`parseCommand`, SYNCHRONOUS — the live preview runs it per
keystroke) composes the lexicon, the resolver (in question mode for the three
asks, booking otherwise), the people match and the event match. **The
leftover rule:** take away the verb phrase, every when-phrase, every person and
the filler ("my", "the", "with", "meeting", "please", "in my calendar"…), and
the words that remain are the subject; quoted text is the subject verbatim
and is never read as a when or a person. **The move split:** the words before
the last "to"/"until" followed by a when-phrase say WHICH meeting
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
person did not say.

**The planner never invents a time.** A create with no clock time, and a
move to a PART of a day ("to tomorrow morning"), is a `SlotChoice` of up to
three real openings: the owner's own free slots
(`freeSlotsOnDay` / `freeSlotsInRange`, working hours from the cached mailbox
settings) when nobody else is invited, `find_meeting_times` with the bare
addresses when somebody is (a personal account's `unsupported_account` falls
back to the owner's own, and the title says so). With no when at all it looks
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
a decline and told why. An answer to a series master says "every meeting in".
Questions are `Answer`s: a yes or no for a named time ("No — on Fri Oct 16 at
2:00 PM you have Budget review."), the openings in a window, the day's
meetings, next and last met.

**The router** (`CommandRouter.submit`, Enter) asks the classifiers in order,
parses, and calls the generative model (`calendar_intent`,
`CalendarIntentTask`) ONCE, and only when the best classifier is under the
bar (0.8) or a required slot is unresolved with leftover words. The model
names the action when the rules could not and COPIES phrases — when, people,
event reference, subject, duration — out of the request; it never computes a
date. Each phrase is checked against the request and dropped when it is not
in it — as whole words over the whitespace-collapsed text, so "Dan" is not in
"Danielle" — then goes through the same resolvers as typed text. A slot the
rules filled keeps its value, with one exception: when the ACTION was the
model's, its subject replaces the rules' (the rules never read the leftover
words as a subject then, they only failed to read them). A move's `when` is
never merged: the planner reads a move's target from the typed words after
the split, so a merged `when` would be drawn and never used. The outcome's
`path` is `generative` only when the model's answer changed the action or
filled a slot; an answer that added nothing leaves `lexicon`. When the model
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

### The bar

`DayCommandBar` (`widgets/day_command_bar.dart`) sits under the Day stop's
title row in the agenda AND the grid (never in the invites view), hint "Ask
or tell: move my 3pm with Dana to tomorrow morning". It is prop-only: the
screen binds the clock, the zone, the people (`knownPeopleOfRooms` over the
People rooms) and the meetings (`upcomingEventsProvider(today)`, the next
two weeks) into `CommandRouter.preview` and `submit`, through
`commandRouterProvider` / `commandPlannerProvider`.

- **The live preview.** 150 ms after the text stops moving, the synchronous
  parse is read back as chips: the action ("Move", "Create", "Yes"…; none for
  `unknown`), the when on the display zone's clock ("Thu Oct 15 · 2:00 PM",
  "Thu Oct 15 morning", a range, or the resolver's reason), the people
  (matched names, "Dana? (2)" for a shared first name, "Sam?" for a name
  nobody in the mail has — the last two tinted for attention), the meeting
  (its subject, or "2 matches"), the duration ("45 min"). No model, no
  network, per keystroke. For a MOVE the when chip is where the meeting
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
`looksLikeCalendarCommand` accepts (the three shapes above, never with a
Find facet), while the calendar is shown (`calendarShowsMirror`), gets ONE
dynamic row in Find's strip, "Ask Day: <text> ↵" (`AskDayIntent`). It is not a `findCommands` entry — that
list stays fixed at eleven. Enter on it clears Find, selects the Day stop
and hands the text to the bar, which writes it in and submits it a frame
later.

## Later phases

- The decision model's command head (Phase 9).
