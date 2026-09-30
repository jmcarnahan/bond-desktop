# 14 · Calendar

**What happens.** The owner's **primary** Outlook calendar is mirrored into
one local table, `calendar_events`, over a rolling window, by a sync that runs
fire-and-forget after every mail load. Everything the calendar features read —
a day, the invites still owed an answer, the meeting before and after a
person, the messages that carried an invite — reads that mirror, never the
server, so a slow or failing calendar costs the screen nothing.

No chat model is involved. The mirror is `sync_calendar` pages written into
sqlite.

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
| `event_briefs` | one pre-meeting brief per event (Phase 7) | **derived** | nothing yet |

`calendar_events` is in `MessageStore.syncedTables`: it is mailbox data, so
**Clear AI results** leaves it and a mailbox wipe (`wipeAll`, sign-out,
**Forget everything and re-sync**) empties it. `event_briefs` is in
`derivedTables`: Clear AI results empties it, and a brief is written again on
demand.

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
| Create (service only so far) | whoever it invites | when it invites anyone | delete it, when it invited nobody |

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

## Later phases

- Pre-meeting briefs into `event_briefs`.
- The command bar's calendar verbs.
