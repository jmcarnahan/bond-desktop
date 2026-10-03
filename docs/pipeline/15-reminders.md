# 15 · Reminders

**What happens.** When the app decides the owner should be reminded of
something — answer this thread by Thursday, chase Dana if she has not replied
in two days, a deadline someone named falls today — the reminder goes INTO
Microsoft To Do as a task with a reminder on it. To Do and Outlook raise the
notification, on every device the owner has them on. The app raises no alert
of its own.

Built in the calendar-automation round's Phase 5 (2026-10, schema v27): the
carrier, the table, the service and the planner, then the doors on top of
them — the thread bar's **Remind me**, the composer's **Follow up** pills,
the poll hook and the Day timeline's reminder rows ("The three doors" and
after).

## Why To Do, and not the app's own alerts

The owner's rule (2026-10-03): no notifications that duplicate what Outlook
already has. A reminder the app raised itself would ring only on this Mac,
only while the app runs, and beside Outlook's own. A To Do task rings on the
phone too, shows in Outlook's task pane, survives the app being closed, and
is the owner's to move, snooze or tick off by hand. No calendar block is
written as a fallback: the calendar stays the owner's meetings.

## The four kinds and their doors

| `kind` | What it is | Door (`created_from`) |
|---|---|---|
| `reply_by` | the owner's own "Remind me" on a thread they owe an answer | `bar` (the thread bar) |
| `follow_up` | "Follow up if no reply", set at send: the owner is waiting on someone | `send` (the composer) |
| `deadline` | a Needs You thread whose newest inbound message named a deadline, reminded at 09:00 that day | `auto` (the planner, below) |
| `custom` | reserved: nothing creates it yet (the wire and column vocabulary keeps it) | — |

`ReminderKind`, `ReminderOrigin` and `ReminderStatus` (`active | done |
cancelled`) are in `app/lib/models/reminder_models.dart`; their wire words are
the column values and the activity words.

## The carrier

`TasksBackend` (`app/lib/services/backend/tasks_backend.dart`) is the seam.
`McpTasksBackend` (`app/lib/services/mcp/mcp_tasks_backend.dart`) speaks
bond-mcps' `manage_todo_task` and `mark_mail_flag` (the handoff's §3.14,
§3.16, §5.6); SDK mode and the sample sandbox get `UnavailableTasksBackend`,
whose every call throws `TasksUnavailable`. The provider is
`tasksBackendProvider`, beside `calendarBackendProvider`, with the same mode
checks.

The contract rules the calendar tools taught hold here too: `options` is a
JSON object encoded as a string, each action sends exactly the keys it takes
(`manage_todo_task` refuses any other, inside `linked_resource` too), a null
is omitted rather than sent as `""` (on an update `""` means "clear"), and a
refusal is keyed on `error`. The errors (`tasks_errors.dart`):

| `error` | Type | Means |
|---|---|---|
| `tasks_scope_missing` | `TasksScopeMissing` | no Tasks.ReadWrite yet: the feature is off, never retried |
| `not_connected` | `ReconsentRequired` | the session routing's own, unwrapped |
| `not_found` | `TasksGone` | the task or list was deleted in To Do |
| anything else (`external_sender`, `invalid_options`, …) | `TasksRefused(code, reason)` | permanent |
| a tool or transport failure | `TasksTransient` | retry later |

Instants go out as `YYYY-MM-DDTHH:MM:SSZ`, whole seconds
(`McpCalendarBackend.utcWire`), never the store's six-digit `isoStamp`.

### The one list

Every task goes into ONE list, **Bond follow-ups**, found or created by
`ensure_list` once per account and its id persisted under the pref
`todo_list_id` (`todoListIdKey`): the tool is find-then-create, not atomic,
so calling it per reminder could make two. A create that answers `not_found`
means the list was deleted in To Do; the service calls `ensure_list` once
more, overwrites the stored id and retries the create once.

### What a task carries

- **title** — `Reply to <name>: <subject>` for a reply or a deadline,
  `Waiting on <names>: <subject>` for a follow-up.
- **body** — the ask's own words (above any quoted reply), capped at 300
  characters on a word (`ReminderService.bodyCap`).
- **due date** — the reminder's day on the owner's wall (`zone.dateOf`), with
  `due_timezone` = the mailbox's Windows zone name, because To Do's default
  UTC shows the date a day early west of Greenwich.
- **reminder** — `reminder_at`, the instant To Do rings.
- **status** — `waitingOnOthers` for a follow-up, `notStarted` for the rest.
- **link** — a `linked_resource` back to the mail: the anchor message's
  Outlook-on-the-web link (`Message.webLink`, kept by the detail fetch since
  this phase — [01-sync-ingest.md](01-sync-ingest.md)) when it is http(s),
  with `external_id` = the reminder's own id. No link when there is none.

### The flag on a sent mail

A follow-up also flags the sent reply (`mark_mail_flag`, status `flagged`,
`due` = the reminder; a due with no start makes start = due), so Outlook
shows it in the flagged list. Best effort: a failure writes one
`reminder {action: flag}` error row and never fails the reminder. A
follow-up made at send is anchored to the local echo (`local:<draftId>`),
which has no Graph id, so its flag waits for the reconcile below. Completing
the reminder completes the flag; cancelling it clears the flag.

## Dark until consent

Tasks.ReadWrite is in nobody's token yet, so every To Do call answers
`tasks_scope_missing` until the owner's consent round. The app asks first:
`tasksPrecheck` (`app/lib/services/reminders/tasks_availability.dart`) turns
the mode and `hasScope('tasks.readwrite')` into `TasksAvailability {available,
scopeMissing, sdkMode}` before any call, `tasksAvailabilityProvider` holds it
(re-read after each calendar tick, so a reconnect lights it up), and
`ReminderService.create` throws `TasksScopeMissing` / `TasksUnavailable`
before anything is called or written. The surfaces say
`tasksUnavailableSentence`: *Reminders need the To Do permission — Settings ›
Connection*. The reconcile and the planner do nothing at all while it is not
available.

The owner's consent checklist (bond-mcps handoff §6), in this order:

1. Admin consent on the Entra app for **Tasks.ReadWrite** (delegated).
2. Append `Tasks.ReadWrite` to `MS_SCOPES` (the full list: it replaces the
   default) in the deployment's tfvars and `mcps/microsoft/.env` — after
   step 1, or every sign-in walls behind "Approval required".
3. Deploy, then smoke-test `connection_status` and
   `manage_todo_task(action="ensure_list")`.
4. **Every user reconnects** — a refresh token keeps the scopes it was issued
   with. Afterwards `connection_status` lists `tasks.readwrite` and the
   Settings row **To Do reminders** ticks.

## The service

`ReminderService` (`app/lib/services/reminders/reminder_service.dart`,
`reminderServiceProvider`):

- `create(ReminderRequest)` — the availability check, the list, the task,
  then the row (`active`, with the list and task ids), then the follow-up's
  flag. The row is written before the flag so a task that exists always has
  its row. Ids are 32 hex characters from `Random.secure`
  (`defaultReminderId`).
- `complete(id, reason:)` — `completeTask` (a task already deleted in To Do
  is fine), the flag completed, the row `done` with `done_at`. `reason` is
  `reply` or `done`; `owner` is reserved (nothing completes a reminder by
  hand yet).
- `cancel(id)` — the Undo: `deleteTask` (already gone is fine), the flag
  cleared, the row `cancelled`. The store moves a row to `done` or
  `cancelled` only while it is still `active` (`updateReminder`'s
  `AND status = 'active'`), so a complete racing a cancel cannot flip one
  into the other.
- `reconcile()` — below.

## Reconcile: completion is local

On each poll (after the mail load, beside the calendar sync) the reconcile
reads every active reminder against the STORED mail — no To Do read — and
changes at most 20 rows a pass (`reconcileCap`):

- **`follow_up`**: an inbound message on the thread received after the
  reminder was made, and not an auto-reply (`Message.isAutoReply`, from
  `read_email`'s `is_auto_reply`) → complete, `reply`. NEVER on Done: with
  **Sending a reply marks it done** on, the send that set the follow-up
  closes the thread in the same breath, and the follow-up is about THEM
  answering. It ends on their reply or the owner's Undo.
- **`reply_by`, `deadline`, `custom`**: the thread is Done → complete,
  `done`; the owner wrote on it after the reminder was made
  (`last_outbound_at`) → complete, `reply`.
- **Echo re-anchoring**: a reminder anchored to a `local:` echo whose echo is
  gone (the drain deletes it in the page transaction that writes the Sent
  Items copy, matched on `internet_message_id`) moves to the thread's
  outbound message stamped closest to the reminder's creation and within 15
  minutes of it (`echoMatchWindow`) — the copy carries the send's own time —
  and a follow-up with no flag yet is flagged then. Timestamps are compared
  as instants, never as strings (`received_at` has whole seconds, the
  reminder's stamps six digits).

Each reminder is tried on its own: a failure is printed by type and the row
stays active for the next poll. `ReconsentRequired` propagates.

## The deadline planner

`ReminderPlanner` (`app/lib/services/reminders/reminder_planner.dart`,
`reminderPlannerProvider`) runs on the poll after the reconcile, over the
conversations the inbox already holds:

- only while the Settings switch **Remind me in To Do about deadlines** is on
  (pref `remind_deadlines`, default on) and To Do is available;
- for a thread that is Needs You (`isNeedsYou`, now in
  `services/decision/needs_you_predicate.dart` so a service can ask it)
  whose `latestDeadline` reads as a day (`showableDeadline` +
  `parseDeadline`, anchored to the mail that named it, as the Day timeline
  reads it) that is today or later;
- with no active reminder of any kind on the thread;
- reminded at **09:00** on that day on the owner's wall; a 09:00 already
  past is skipped, not moved;
- at most **5** a pass (`perPass`), the rest on the next poll. A create that
  throws ends the pass.

## The three doors (the UI, Phase 5 part 2)

The Remind me icon is drawn on every thread that is not done; its strip
offers the pills only while To Do can carry a reminder
(`tasksAvailabilityProvider` is `available`), and otherwise holds the
sentence saying why, with nothing to pick. The composer's follow-up choices
are drawn only while available, and a choice made before To Do stopped being
available is dropped at the send, never set. The two sentences are
`tasksUnavailableSentence`'s:

- MCP without the scope — *Reminders need the To Do permission — Settings ›
  Connection*
- SDK mode or the sample sandbox — *Reminders need the Bond server
  connection (Settings › Connection).*

### Remind me, on the thread bar

`ThreadActionBar`'s **Remind me** icon (`thread-action-remind`, tooltip
*Remind me — in To Do*, no key of its own: `r` is the list's Reply) is on
any thread that is not done. A press opens its choices under the bar — Mark
done's inline strip, focused as it opens, Escape or ✕ shuts it, one strip at
a time — keyed `thread-action-remind-choices`:

- the pills, every instant worked out by the HOST from the clock and the
  display zone (`remindChoices`, `services/reminders/remind_choices.dart`):
  **In 2 hours**, **5 pm today** (only while it is more than ten minutes
  off), **Tomorrow 9 am**, **Next Monday 9 am** (strictly after today;
  dropped on a Sunday, when it is tomorrow), and **On the deadline · Fri
  Oct 2** — 09:00 on the day the thread's deadline names
  (`remindDeadlineDay`, the planner's and the Day timeline's reading), while
  that 09:00 is still ahead. Keys `thread-action-remind-pill-<id>` (`in-2-hours`,
  `five-pm`, `tomorrow`, `next-monday`, `deadline`).
- a typed time (`thread-action-remind-typed`, hint *or type a time: "Thu
  3pm"*), read by the host (`resolveRemindText`: `resolveWhen` in booking
  mode — a day and a time are that instant, a day alone 09:00, a time or a
  part of the day alone today, a part of the day its start; nothing ahead is
  no reminder) and previewed absolutely under the field (*Thu Oct 1, 3:00
  PM*, `thread-action-remind-preview`), the Move to… field's rule. Enter sets
  it.

A pick creates a `reply_by` reminder (`created_from: bar`) about the
thread's newest inbound message: title `Reply to <their name>: <subject>`,
body that message's own words (`askOwnWords`), its Outlook link, anchor and
Graph id its `source_message_id`. The toast says *Reminder set in To Do ·
Tomorrow 9 am* with an Undo that cancels it (task deleted, row
`cancelled`); the toast never counts toward the pile's progress line.

A second Remind me on the same thread MOVES the first: the new reminder is
set, then every earlier active bar reminder (`reply_by` from `bar`) on the
thread is cancelled, so one thread never holds two of the owner's own tasks
— a create that fails leaves the old one standing. Each cancel is tried on
its own: one that fails is traced and the old reminder stands beside the
new, and the toast still says the new one was set. A follow-up or the
planner's deadline reminder on the thread is another kind and stands.

A failed Undo says *Couldn't reach To Do. The reminder stands.* (or the
carrier's sentence; the reconnect sentence ends *The reminder stands.*).

Unavailable, the strip holds the sentence and a **Settings** button
(`thread-action-remind-settings`) that opens Settings.

### Follow up, at send

The docked reply box shows **No follow-up | 2 days | 1 week**
(`composer-follow-up`, each `composer-follow-up-<choice>`, tooltip *Follow up
if nobody replies*) on a line of its own just above Send, on a MAIL thread
whose reply this build really sends (`SendCapability.send`), while To Do is
available. The choice is held by the inbox per reply box and read at the
moment of the send; the in-list box and the suggestion cards carry none.

A send that returned `sent` with a choice creates the `follow_up` reminder
(`created_from: send`) at once — the re-anchor below is a time match on its
`created_at` — at 09:00 on the 2nd or 5th working day after the send
(`nextBusinessDaysAt`), titled `Waiting on <the other people>: <subject>`.
Its anchor AND Graph id are the local echo's id (`local:<draft id>`, which
`DraftNotifier.lastEchoId` exposes after a mail send), so nothing is flagged
at the send; the reconcile flags the Sent Items copy once it lands.

The toast:

- reply-marks-done OFF — *Reply sent · Following up Thu 9:00 AM*, whose Undo
  cancels the REMINDER only (the reply has gone).
- reply-marks-done ON — the done's toast with the follow-up as a line:
  *Reply sent · Marked done · Following up Thu 9:00 AM*. Its one Undo stays
  the done's; the reminder gets no Undo of its own there (it is cancelled in
  To Do, or completes itself when they answer).
- a follow-up that was not set — *Reply sent. Couldn't reach To Do. Nothing
  was set.* (or the carrier's sentence), no Undo.
- the display zone not yet resolved — *No follow-up set — the time zone is
  not known yet.* Nothing is created: the 09:00 is a wall time, and a UTC
  stand-in would ring at the wrong hour.

### The deadline reminder

Automatic: the planner above, on the poll.

### Errors at a door

By type, never the exception's text: `TasksScopeMissing` / `TasksUnavailable`
say their own sentence; `ReminderPast` (a pill worked out at build whose
instant has passed on a pane left open — `ReminderService.create` refuses any
`remindAtUtc` not after its clock, before any call or row) says *That time
has passed. Nothing was set.*; `ReconsentRequired` / `NotSignedIn` say
*Reconnect Microsoft in Settings, then try again. Nothing was set.* (the
calendar writes' sentence); anything else *Couldn't reach To Do. Nothing was
set.*

## The poll hook

`_refresh`'s `finally`, beside `_syncCalendar`, starts `_tendReminders()`
un-awaited: `reconcile()` then `plan(zone:, needsYouThreshold:,
conversations:)` over the loaded list, in ONE try that catches everything
(traced by type only), so nothing escapes the poll. Single-flight: a poll
landing on a running tend gets the same future. Skipped while the display
zone has not resolved (the planner's 09:00 is a wall time), so the first
poll after launch may skip it. `reminderRevisionProvider` is bumped when
either changed a row, and after every create and cancel at a door — the
service bumps nothing.

## On the Day timeline

`remindersProvider` (active, soonest first) feeds `buildDayItems`,
`rangeMarkers` and `upcomingDays`: each reminder is a `ReminderItem` on the
LOCAL day of its `remind_at`, ranked with the returns from Later by instant.
The agenda row (`day-reminder-<id>`) shows the time, *Reminder · in To Do*
and the title, and opens the thread; the grid's header tile reads *Reminder
· <title>* (`day-grid-marker-reminder-<source>-<reminder id>`, keyed by the
reminder's id since a thread may carry two) and opens the thread; a day row
in the list column counts them (*· 1 reminder*). The Inbox stack's Today
section does not list them.

## Activity

One row kind, `reminder`, labelled **Reminder** in the log. Its detail is
enum words and booleans only — never a title, a subject, a person or a link:

| `action` | detail | Sentence |
|---|---|---|
| `create` | `kind`, `created_from`, `flagged`, `linked` | Reminder set in To Do (reply by \| follow up \| deadline \| reminder) |
| `complete` | `kind`, `reason` | Reminder done — answered \| thread done \| by you (`owner`, reserved: nothing produces it yet) |
| `cancel` | `kind` | Reminder cancelled |
| `flag` (status `error`) | `kind` | Could not flag the mail |

## The table and the prefs

`reminders` (schema v27, `from26To27`) is **KEPT**
(`MessageStore.keptTables`): each row points at a task in the owner's To Do,
so Clear AI results must not orphan it. **Forget everything and re-sync**
(`wipeAll(keepIdentity: true)`, Settings) keeps it too: the same mailbox is
re-synced and its conversation keys are Graph ids, so each row still names
its thread — deleting them would orphan the tasks, strand the follow-ups and
let the planner make duplicate deadline tasks. Only the full wipe (sign-out,
and `IdentityGuard` on a different account) deletes it, with
`todo_list_id`. Columns: `id` (also the task's `external_id`), `kind`, `source`,
`conversation_key`, `anchor_message_id`, `title`, `remind_at` (isoStamp UTC),
`due_date` (`yyyy-mm-dd`, the owner's zone), `status`, `created_from`,
`todo_list_id`, `todo_task_id`, `flag_message_id`, `created_at`,
`updated_at`, `done_at`; indexes on `(source, conversation_key, status)` and
`(status, remind_at)`. Store methods: `insertReminder`, `updateReminder`,
`activeReminders`, `remindersForThread`, `remindersBetween`, `reminderById`,
`hasActiveReminder`.

Prefs: `todo_list_id` (per person: `wipeAll` clears it unless the identity is
kept) and `remind_deadlines` (a user preference: no wipe touches it).

## Owner checks (owed live, after the consent round)

`connection_status` lists `tasks.readwrite`; a reminder lands in To Do with
its reminder, due date and link; a follow-up is `waitingOnOthers` and its
sent mail is flagged (handoff §7 #4: does a flagged Sent Items message show
in To Do's Flagged email?); a reply completes both; a deadline reminder
appears for a Needs You thread; Undo deletes the task.
