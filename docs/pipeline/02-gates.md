# 2 · Gates and detail fetch

Gates exist to skip what is not worth a model call. They run in two tiers
around the body fetch, because the cheap signals arrive with the delta and the
header signals only arrive with the full message.

**No model call in any of this** — gates are pure functions over sender
strings and headers.

## Tier 1 — sender-only, on delta fields

Before fetching anything, five questions about the address, in this order, and
the first answer wins. `gateFor` in `app/lib/services/gates.dart` dispatches to
`_emailGate` / `_teamsGate` per source, driven from the claim loop in
`app/lib/services/triage_queue.dart`.

| reason | what it catches |
| --- | --- |
| `self` | the user's own address, however the message came back to them |
| `sender_rule` | an address the owner dropped by hand — below |
| `no_reply` | `noreply` / `donotreply` anywhere in the local part — the compact word as a plain substring (`noreply@`, `orders-noreply@`, `noreply+billing@`, `noreply2@`, `opsnoreplyrelay@`), the punctuated spellings (`no-reply`, `do.not.reply`) as delimited TOKENS — plus the prefix family `notifications?`, `alerts?`, `mailer-daemon`, `postmaster`, `bounces?` |
| `monitoring` | `monitoring@`, `monitoring-eu@`, `prod-monitoring@` |
| `machine_sender` | `svc-…@`, `bot-…@`, `…-bot@`, and the exact local parts `pipelines@`, `builds@`, `ci@` |

The punctuated `no_reply` forms are delimited on both sides and the rest are
anchored or exact, which is the whole of their precision: `nota@`, `renotify@`,
`salerts@`, `abbott@`, `cicd-team@` and `remonitoring@` all reach the model.
The compact `noreply` needs no boundary because no name contains it — on the
golden set the bare substring adds one gold drop and no gold keep.
The last two slugs are the golden set's own drop-reason names, not names
invented here, so `make golden-gate` scores the REASON column and not only the
verdict.

**The sender rule is data, and it is the only per-tenant gate.** It comes from
`sender_prefs.disposition = 'drop'`, which the owner writes through **Drop this
sender** in the thread's overflow menu or through the quiet offer the message
story makes once the owner has Ignored three different messages from one
address (`senderDropOfferAfter`, in `app/lib/providers/app_providers.dart` —
counted per message, offered, never automatic). It is asked immediately after `self`, because a person's
standing instruction outranks every pattern below it while the owner's own mail
is still their own. It is skipped for a restored row exactly as the other gates
are. `gateFor` stays pure: the disposition arrives as an argument, read once per
claim by `_triageClaimed` and handed to both tiers. Undo is the one the sender
corrections already have — `restoreSenderPref`, which puts the previous rule
back and re-files the threads from it.

**One gate deliberately does not exist here**, beside the two the header block
below names: issue trackers and code hosts sending from their bare local parts
(`jira@`, `github@`, …). On the golden set that exact shape is two gold drops
AND two gold keeps — the same address sends the digest nobody reads and the
mention addressed to the reader — so no name rule can split them. What
separates the two populations is which tenant is talking, which is the sender
rule above or a header, never a pattern compiled into the app.

## Detail fetch (mail only)

`ensureMessageBody` pulls the full body and internet headers. Failure
*degrades* (triage proceeds on what it has) rather than parks — except
`NotSignedIn` / `ReconsentRequired`, which park the queue until the session is
usable again. See `triage_queue.dart`.

One shape of failure is DEFERRED instead: a fetch that failed leaving no
headers at all, on a sender whose local part looks like a machine
(`suspectMachineSender` in `gates.dart` — wide, anywhere in the local part,
and explicitly NOT a gate). The message goes back to `pending` with a
`triage_attempts` bump and a `triage` / `retry` activity row carrying
`reason: headerless`, and the drain excludes it from its own later claims so
it moves on to the message behind it. The bound is `_maxAttempts`, shared with
the model failures: after two attempts the message is classified headerless
exactly as it always was.

## Tier 2 — header gates

With headers in hand, the list/auto-generated checks run: `List-Unsubscribe`
/ `List-Id`, `Precedence: bulk|list|junk|auto_reply`, `Auto-Submitted`, and
`X-Auto-Response-Suppress`. Also in `gates.dart`.

## A gate drop and the thread

The thread state machine folds `needs_reply` onto a thread the moment an
inbound lands, and every gate above speaks afterwards. `refoldThreadState`
(`app/lib/data/message_store.dart`) is how the thread finds out. It re-derives
the state from the messages the gate KEPT — `keptMessageSql`, which is
`messages.triage_status <> 'skipped' OR gate_reason = 'teams_source'` — and
writes it through `setConversationState`, so `state_changed_at` is stamped.

"Kept" has two edges worth stating. A chat stored before chats were triaged was
born `skipped` under the retired `teams_source` reason and is a real message
from a real person. And a settle-time `not_worthy` drop is a verdict ABOUT a
kept message: it lives on `message_progress` and never touches
`triage_status`, so it never moves a thread.

The rule is the fold's own, re-read off the table: `needs_reply` iff a kept
inbound exists and is STRICTLY newer than the newest outbound (no outbound at
all counts as newer), else `waiting`. Ties settle the thread. Outbound carries
no kept clause — every outbound is born `skipped`/`outbound`, and an outbound
is the owner's own word whatever the gate stamped on it.

It moves in ONE direction, and the caller says which:

- `restored: false` may only lower `needs_reply → waiting`. A gate drop can
  only take an obligation away. Raising here would let a widened sync window
  reopen threads the user closed months ago — exactly what the fold's
  `historical` flag exists to prevent, and the store does not remember which
  rows were historical, so the only way to honour that flag is never to raise
  on this path. The flag is honoured for RAISING and is not consulted when
  lowering, which is deliberate: a Sent copy a widened window backfilled — an
  outbound newer than an ask the store already held — settles the thread on
  the next lowering refold, where `foldMessage(historical: true)` refused to
  at ingest. The user did answer that ask; the incremental fold could not know
  it because `historical` says which sync pass carried the row rather than
  what the row says, and the refold answers from the whole mailbox as stored.
- `restored: true` may only raise `waiting → needs_reply`. The owner pulling a
  message back out of the dropped pile is a reason for the thread to ask again
  and never a reason to quieten it.

`done` is a human's decision and neither direction moves it. A lowering refold
that finds NO kept inbound at all also clears `cta_text` / `cta_urgency` and
the thread's Needs You chips: an ask can only come from a kept message.

Four writers call it. `TriageQueue._triageClaimed` after either tier's skip,
before `_emit()`, so the rails' reload behind that tick reads the new state.
`dropMessage` (Ignore) inside its own transaction. `capPendingTriage`, which
now returns the demoted messages' `conversation_key`s and refolds each thread
once. And `RestoreService._restore` with `restored: true`, after
`restoreMessage`.

The consequence upstream is that the rail's `isNeedsYou` has three tests again
— Later, done, threshold — with no "everything was dropped" mask: the ingest
and the gates keep the state honest, so a thread with nothing kept cannot
reach the rail saying `needs_reply`. See [01-sync-ingest.md](01-sync-ingest.md)
for the ingest half and the one-shot repair.

## Reading the file

The header comment in `gates.dart` is the real documentation: it explains the
two-tier split, a delimiter subtlety in the local-part regexes, and — most
usefully — three gates that deliberately do **not** exist. Keep that comment
authoritative; this page is the map to it.

A gated message is not hidden: it lands with a drop reason, visible under the
Inbox's Dropped tile (`HomeFilter.dropped`) and in the Archive section's
Dropped tab, which is also where Restore lives.

## Restoring a gated message

A gate verdict is a derivation, re-run on every triage claim — so clearing
`gate_reason` alone would last exactly one sync. Restore instead stamps
`messages.gate_override` (schema v12, tri-state: `NULL` = the pipeline's
call stands, `'user'` = the owner restored this message), and the stamp is
durable: both `gateFor` calls in `_triageClaimed` are skipped for a stamped
row, and `capPendingTriage` exempts it from the backlog demotion a first-run
sync would otherwise apply. The gate functions in `gates.dart` stay pure —
the override lives at the call site, because it is a fact about what the
user did, not a judgement about the message.

The sender rule is bypassed with the rest: a stamped row skips both `gateFor`
calls, so restoring one message from an address the owner dropped brings that
message back without touching the rule about the address.

`RestoreService` (`app/lib/services/restore_service.dart`) runs the whole
sequence: reset the message row and the `message_progress` cascade, fetch
the mail body (gated mail was skipped before tier 2 ever fetched; Teams
bodies arrived whole at ingest), requeue `extract` / `needs_you` /
`embed_message` (the draft is chained from the extract handler, as always),
then pump triage and the AI worker — chained in that order under the shared
`DrainGate`, so the handlers never read an untriaged row.

A restored message never toasts, deliberately: `admitNotifyCandidates` is
recency-floored and inserts with `INSERT OR IGNORE`, and restore is the user
pulling history back, not new mail arriving.

## Ignoring a kept message

The mirror of Restore, and the owner's own gate. `MessageStore.dropMessage`
writes `messages.triage_status = 'skipped'` with `gate_reason = 'user'`,
clears `triage_error`, and runs the SAME progress cascade a gate does through
`writeTriageProgress` — pending stages close as `skipped`, the row settles
`dropped` under that reason, and a stage that already finished keeps what it
did. It also refolds the thread through `refoldThreadState` (above) — Ignore
is the owner working a gate by hand, so it lowers the thread exactly as a gate
does — clears the thread's needs-you chips, and records a `down` / `explicit`
row in `feedback_events`, because a button press is exactly that.
The message's pending `message_notify` row is settled `suppressed`/`gated` in
the same transaction, so a later coordinator sweep cannot re-decide a message
the owner has already thrown out. And a triage answer that lands after the
Ignore is discarded: `writeTriage` refuses a row that is `skipped` under
`gate_reason = 'user'`.

Almost nothing that was already queued has to be cancelled: the handlers all
skip a gated row on their own, so whatever is on a queue for this message reads
the new `triage_status` and declines. The exception is the thread's own pending
`storyline` row, which the late-verdict repair below deletes when the Ignore
leaves the thread with nothing kept in it. The thread stops holding an open
ask for the same reason — the open-ask predicate excludes gated rows — which
is why the verdict itself is deliberately left alone. `needs_you_verdict` is what the
judge decided about the words, and an Ignore is the owner saying they do not
want the message, not that the judge misread it.

`gate_override` is not cleared either, so a message that was restored and then
ignored carries both facts, and the history screen shows both. Restore
reverses an Ignore exactly as it reverses any other gate — the reason is a
`gate_reason` like the rest — which is what makes the pair on the history
screen safe to press.

## A late verdict and what it repairs

A gate normally speaks before anything is built — see 03-triage.md for the
claim invariant. Three things break that order, and all three call
`GateRepairService.afterGate` / `.repairAll`
(`app/lib/services/gate_repair_service.dart`):

- the triage drain's own gates, at either tier (`onGated` on `TriageQueue`);
- the owner's Ignore, after `dropMessage` (`onGated` on
  `PipelineRepairService`);
- the one-shot over the whole database, run once per install behind the
  `gated_conversation_repair` pref from the mail sync (01-sync-ingest.md).

The test is the store's own: `keptInboundCount(source, key) == 0`, the same
"kept" spelling the thread refold uses. A conversation with zero kept inbound
messages is one the app must stop describing — every inbound in it was gated,
so nothing in it was ever meant for a model.

What moves, for such a thread:

- **storyline memberships** whose `added_by <> 'user'` are evicted through
  `StorylineService.evictGatedThread`, which does everything an owner's
  removal does — member row gone, member hash recomputed, recap text and
  watermark cleared, thread pointer re-stamped onto whatever membership is
  left, `storyline_refresh` requeued — and writes the block as
  `blocked_by = 'gate'` with the fixed evidence `every inbound message in this
  thread was gated`. A `user` membership is left alone: the owner filed that
  thread by hand and a gate does not overrule a person.
- **the conversation's embedding**, cleared with its hash and model tag
  (`clearConversationEmbedding`), which is what takes the thread out of the
  vec0 clustering index at the next sweep's backfill.
- **the pending `storyline` work row** for that key, deleted rather than
  parked — `requeueWork` revives only `done` and `error`, so a parked row
  would block that key's queue forever.

**No audit is queued.** An audit means "the owner says the model got this
group wrong"; a gate says nothing about the model's reasoning, because the
thread should never have reached it. For the same reason a `gate` block never
enters a prompt: the confirm prompt reads `blocksOf(blockedBy: 'user')`, and
only the owner's "no" is a lesson. Nothing lifts a `gate` block automatically:
not a Restore, and not a later genuine reply landing kept in the same thread.
The thread may still be filed into any OTHER storyline, or seed a new one; for
the storyline it was evicted from, "Allow again" is the owner's word. The
asymmetry is deliberate — a block that came and went with the kept count would
let a thread flap in and out of a group's recap.

The one-shot has a cost worth naming. Every storyline that loses a thread has
its recap text and watermark cleared, exactly as an owner's removal clears
them, so the first sync after the upgrade queues a refresh and a recap for
each affected storyline — one model pass per storyline, proportional to how
many the pre-invariant races had filed, and once.

The counter the pipeline roadmap asks for is `extracted_then_gated`: whenever
a gate lands on a message that already has `message_ai.extraction_json`, the
`gate_repair` activity row carries `extracted: 1`, and the one-shot's row
carries the DB-wide count from `extractedThenGatedCount()`. A gate on an
unextracted message in a thread with nothing built writes no row at all — that
is the common case, and it is not news.
