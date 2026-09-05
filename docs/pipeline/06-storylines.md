# 6 · Storylines

Storylines are groups of threads about the same thing, proposed by the model
and kept or dismissed by the user. Five passes share the machinery, all in
`app/lib/services/storyline_service.dart` behind the handlers in
`app/lib/services/storyline_handler.dart`. **Their relative order is the
handler registration order in `app_providers.dart`** — that list's comments
are the authority on sequencing.

## The five passes, in drain order

1. **Assign** (`StorylineAssignHandler` → `assignConversation`) — when a
   conversation's card changes, cosine-shortlist it against live storyline
   centroids, then ask the model to confirm the best candidate. Every
   candidate's members and blocks are read in one query each for the whole
   pass (`memberContextRows`, `blockedStorylineIdsFor`), so filing one thread
   costs the same against a mailbox of fifty storylines as against two. On
   join, it *queues* a refresh rather than naming inline — under the gate in
   the next section.
2. **Sweep** (`StorylineSweepHandler` → `sweep`) — clusters *unassigned*
   threads by embedding similarity (gate: 2 similar threads form a proposal),
   names the proposal, then confirms each member individually. Pair-discovery
   runs on the sqlite-vec index when there is one and on Dart arithmetic when
   there is not, to the same clusters either way — its own section below.
   Rejected clusters are tombstoned by immutable `cluster_hash` (schema v7) so
   a dismissed suggestion stays dismissed even after membership drift.
3. **Refresh** (`StorylineRefreshHandler` → `refresh`) — re-describes a
   storyline whose membership has moved. Its own section below.
4. **Recruit** (`StorylineRecruitHandler` → `recruit`) — after a user saves a
   charter, or after a refresh widened one, judges up to 8 candidate threads
   against it.
5. **Recap** (`StorylineRecapHandler` → `recap`) — re-writes the storyline's
   running state of play from the newest messages across its member threads.
   Its own section below.

A thread the user removes by hand is blocked — the model cannot put it back.

The first four run on MEMBERSHIP and go quiet once the member set settles. The
recap runs on what was SAID and keeps moving as long as people are talking.

## The refresh pass

Storylines used to converge and stop: named once, on the day they were
proposed, and never again however many threads joined. `refresh` is what makes
the description follow the membership.

**The gate** is `refreshed_member_hash == member_hash` (schema v10). Equal
means the members have not changed since the description was written and the
pass returns before any model call; NULL means never described, which is not
the same as unchanged. Both hashes use the one write recipe (`_hashOfThreads`,
source folded in).

**A proposed storyline is born described.** `_propose` stamps
`refreshed_member_hash`/`refreshed_member_count` on the kept path, right where
it inserts the row: `NameStorylineTask` has just written that title, summary and
charter from exactly those confirmed members, so the columns record something
true rather than claiming a pass ran. Without the stamp the next sweep's
catch-up would read the row as never described and spend a Refine call
re-writing a description seconds old over a member set that has not moved. It is
the same claim the v10 backfill makes about the storylines it found already
described. The below-minimum tombstone branch stamps nothing — it has no member
rows to describe.

**Triggers** — every path that can change what a storyline is about, all via
`requeueWork` (never `enqueueWork`; `payload_json` is NULL, so nothing carries
provenance through the queue):

| Trigger | When |
|---|---|
| `addThread` / `removeThread` | always — a user filing by hand is telling the app the group changed, and is looking at it |
| `setCharter('')` | always — this is what makes the About block's "clearing it lets the model redraft" promise true |
| `assignConversation` tail | **gated**: summary empty, or charter empty and unlocked, or `member_count - refreshed_member_count >= 2` |
| `recruit` tail | when it filed ≥1 thread |
| `sweep` catch-up | every live storyline where `refreshed_member_hash IS NOT member_hash` |

The assign gate is the cost control: threads arrive one at a time all day, and
re-describing on each would dial the 27B per filed thread to rewrite the same
sentence. Single-thread growth coalesces into the sweep's catch-up instead. The
count comparison is deterministic — a re-run after a restart decides the same —
which a timer would not be. Either way `requeueWork` is keyed on
`(kind, source, entity_id)`, so a storyline that collects ten threads in one
drain gets one refresh.

The sweep's catch-up runs **before** the sweep's early returns, and that
placement is load-bearing: `requeueWork` revives only `done`/`error` rows, so a
refresh queued while an earlier one was `processing` is swallowed, and every
other trigger fires on an event that has already gone by. The sweep returns
early on nearly every pass (no room, nothing unassigned), so a catch-up at the
bottom would almost never run. `staleRefreshStorylineIds` uses `IS NOT` rather
than `!=` — `!=` answers NULL for the never-described rows that most need
finding — and its NULL-on-both-sides case excludes the tombstone shape.

**Two branches.** Describing a storyline for the first time and re-describing
one are different questions:

- **Bootstrap** — summary empty, or charter empty and unlocked. Runs
  `NameStorylineTask`, exactly as a fresh cluster gets.
- **Evolve** — anything else. Runs `RefineStorylineTask` with the current
  description, every member card, and the cards of the threads that joined
  since. "Since" is derived from `member_count - refreshed_member_count` taken
  off the tail of the members in `added_at` order — an approximation, and a
  deliberate one, because the queue carries no provenance.

**Locks.** Read before the call so the model knows (rendered as
`Title is fixed: yes|no` inside the storyline fence), and re-read *after* it so
a user who renamed the storyline while the model was thinking still wins. A
locked title is returned verbatim; the summary is refreshed either way — it
says where things stand, which no rename claimed. A locked charter is **never**
overwritten: the model's version is parked in `charter_suggestion`, and a
suggestion that matches the stored charter (compared with whitespace flattened
and case folded) clears rather than parking. What the About block then does
with a parked suggestion — and what happens when the user answers it — is
under *What the user sees*.

**The stamp is the pre-call hash and count**, never the current ones. A thread
filed by hand while the model was thinking is a thread this description never
saw; stamping what is true *now* would leave the gate reading "unchanged" and
that thread would never be described. Stamping stale re-fires the pass, which
is the correct outcome.

**Re-arm**: a refresh queues `storyline_recruit` only when it actually wrote a
new charter to the `charter` column and the text changed under a normalized
compare. A parked suggestion never re-arms — it changes no criteria until the
user accepts it. That, plus handler ordering (refresh is registered *before*
recruit, so a recruit's refresh waits a pump while a user edit refreshes and
recruits in one drain) and monotone membership, is what bounds the one cycle
these two passes could form.

## The recap pass

The storyline screen's centrepiece, and the only pass written for the reader
rather than for the app. It answers "I have been away — where does this stand?"
without them re-reading the last few days of every thread: two to four
present-tense sentences of state, a list of what is still open (who owes whom
what), and a list of what has recently been decided. The one-line `summary`
stays for the compact surfaces (rail, cards); the recap is what the storyline
screen leads with.

It must be useful when there is **nothing to do**. An inbox that only speaks up
about work owed is silent about the storylines that are going well, and "going
well" is what someone coming back from a week away most wants to be told —
which is why an empty `open_items` list is stated in the prompt as an honest
answer rather than a failure to find something.

**The window** is `MessageStore.recentStorylineMessages(id, limit: 12)`: the
newest messages across *every* member thread, merged into one chronology by
`received_at DESC LIMIT ?` and reversed by the service so the model reads them
oldest-first. Not per thread — a storyline is one story told in several places,
and a per-thread recap is the thing the reader is already doing by hand. Each
line is `[subject] sender: preview`, with the owner's own messages rendered as
`You` (the triage prompt's idiom) and no timestamp — the sequence is already in
order, and a date per line is a date the model can misattribute in a prompt
whose strictest rule is to invent none. The subject falls back to the
*conversation's* (`COALESCE`), because a chat message carries no subject at all
and every line of a chat thread would otherwise arrive unnamed. Gated messages
are excluded on exactly `EmbedHandler`'s rule — `triage_status = 'skipped'`
unless `gate_reason = 'teams_source'` — so a recap never narrates the vendor's
newsletters, and a chat row `skipped` only for being a chat still counts.

**The owner's own messages are never excluded**, whatever their triage columns
say: `direction = 'outbound'` is the first arm of that predicate.
`triageStatusOnInsert` marks every outbound message `skipped`/`outbound`, but
that gate answers *does this need the user?* — it is cost control, about not
spending model calls on the user's own mail, and it was never a claim about the
narrative. The recap's entire subject is who owes whom, and the reply the user
sent is the largest single fact in that judgement; without the arm the window is
every question ever put to them and not one of their answers, and the model
writes open items they settled last week. Nothing above the SQL needed changing
— the prompt already renders these lines as `You`.

**The gate** is the `recap_through` watermark (schema v10): the pass returns
before any model call when `recap_through >= ` the newest `received_at` in the
window. ISO-8601 with a fixed offset compares correctly as a string, so no
parsing is involved. The stamp is the **pre-call** watermark, for the reason
the refresh stamps its pre-call hash: a message that landed while the model was
thinking is a message this recap never read, and stamping what is true *now*
would leave the gate reading fresh and that message would never be recapped.

**Triggers** — every path that changes what has been *said*, all via
`requeueWork`:

| Trigger | When |
|---|---|
| `ExtractHandler` tail | a message's facts land in a thread that is already in ≥1 storyline (`storylineIdsFor`), one requeue per storyline. Deliberately outside `_refreshCard` and not behind a successful embed — the recap has nothing to do with the vector, and a down embedding server must not cost it a message |
| `addThread` | always — a hand-filed thread brings its own messages, and the user is looking |
| `refresh` tail | always, once it gets past its own gate — a membership change is a change to the story |
| `_propose` | always, on the kept path — the recap handler drains after the sweep's, so a storyline born in this pass shows its recap in the same drain rather than a sync later |
| `DraftNotifier._sendChat` | a chat reply the user sent from this app, per storyline the chat is filed in. **The only outbound row wired directly**, because it is the only one no ingest will ever see: the chat send writes its own row with the id Graph assigned, and the next pull skips it as already-known |
| `sweep` catch-up | every live storyline holding a message the recap has not read: `recap_through` NULL, or a newer `received_at` than it. `staleRecapStorylineIds` repeats `recentStorylineMessages`' gate exclusion (`triage_status <> 'skipped'` unless `gate_reason = 'teams_source'`) and its own `received_at` guard, because the question asked must be the one the pass answers — a storyline queued over messages the recap cannot read would stamp no watermark and be queued again forever. A storyline with no qualifying messages at all is left alone for the same reason |

The recap's catch-up matters more than the refresh's, because every other
trigger here fires on a message *arriving*: a storyline that is already
described and has had no new mail reaches none of them. That is every row the
v10 backfill called described — none of which had ever been recapped — plus any
recap wakeup a `processing` row swallowed. Like the refresh's, it runs at the
head of `sweep` so an early return does not skip it.

It is also the **reply path**, and deliberately so. Every outbound row but the
chat send's lands at ingest — the sent copy folding in from `sentitems`, or a
reply sent from Outlook, a phone, or Teams itself arriving on a pull — and every
sync ends by requeueing `storyline_sweep`, so the sync that folds a reply in is
the drain that recaps it. Wiring a per-message requeue into the mail ingest
would buy no latency and would cost a `storylineIdsFor` query per message inside
`_ingestPage`'s page transaction, on first syncs that run to six figures. One
indexed question per sync replaces it.

`removeThread` is absent where the refresh table has it, and the watermark is
why. Removing a thread adds no messages, so the newest `received_at` left in
the storyline is older than the recap has already read: the refresh a removal
queues does re-queue the recap, and that recap returns at the gate. A recap can
therefore go on describing a thread that has just been filed out of the
storyline until something new is said in one of the threads that remain. That
is the one place the watermark's cheapness shows, and it is a known edge rather
than a design: the pass is keyed to *messages arriving*, and a removal is the
only event that changes the story without one. The catch-up does not close it
either, and could not: its `EXISTS` asks whether a member thread holds a message
newer than the watermark, and a removal — which adds no messages — leaves that
answer no.

Bursts coalesce for free: `requeueWork` is keyed on
`(kind, source, entity_id)`, so ten messages landing in one drain leave one
row, and the one pass that runs reads the whole burst because it reads current
state at run time rather than a payload. Nothing carries provenance through the
queue.

**Empty answers keep the previous recap standing.** A model that comes back
with no recap text writes *nothing at all* — not the text, not the lists, not
the watermark. A thin answer must never cost the user the catch-up they had,
and leaving the watermark behind means the next message to land asks again.

## What the user sees

The storyline screen (`StorylineTimelinePanel`) leads with the recap: the
paragraph in body type directly under the title, then a compact **OPEN** list
and a **DECIDED** list — each rendered only when the pass found something for
it — and a quiet "as of *n*h ago" read off `recap_through`, which dates the
paragraph by the newest message it has *read* rather than by when it ran. The
recap **replaces** the one-line `summary` in that header; the summary is still
what the rail and the overview cards show, and it is the header's text until
the recap pass has written one. `recapOpenItems` / `recapDecisions` on
`Storyline` are the only decoders of the two JSON columns, and they are
tolerant in the same way the message models are: a half-written column costs
the lists, never the render.

The parked charter surfaces in the About block, under the charter itself, as
**SUGGESTED UPDATE** with **Use this** and **Discard** (not "Dismiss" — that
word already retires the whole storyline in the header above). *Use this* is a
two-step, as removing a thread is, because it overwrites a sentence the user
wrote: the second tap reads *Replace the charter*. Accepting routes through
`setCharter`, so it does everything a hand-typed save does — trims, locks,
clears the suggestion, and queues the recruit that hunts for threads matching
the new criteria. *Discard* is one tap and clears the column alone. Typing a
charter by hand clears it too — both arms of `setCharter` do, including the
empty one that unlocks and queues a redraft — because the user has just
answered the question the suggestion was asking. Neither offer appears while
the charter field is open: the field is where the user would be answering the
suggestion anyway.

Refresh and recap both report progress under their own kinds, and
`StorylinesNotifier` listens for both, so a pass that rewrites a title or a
recap lands on the rail and the open storyline within the list's 400 ms
debounce rather than at the next poll.

## Filing a thread by hand

`StorylineService.addThread` / `removeThread` are the user's own passes, and
they write the same per-message pointer the automatic ones do —
`message_progress.storyline_id`, through the narrow
`MessageStore.stampStorylineId`. This is what makes a hand-filed thread
visible: the home feed's storyline link and the hot-storylines strip both join
on that column and know nothing about `storyline_members`, so before this the
timeline and the rail showed the filing and the feed did not.

The write is deliberately NOT `writeStorylineProgress`. That one records how
far the assignment pass got — `storyline_state`, `storyline_at` — and those
stages are what the settle machine and the draft close-out read; a hand filing
moved a pointer, not a stage. It is also unguarded on `settle_state`, unlike
the pass, which is bounded by it so a growing thread cannot rewrite the
history above it. A person filing a thread means exactly that rewrite: they
are saying what the old messages were always about.

Which id gets stamped is `storylineIdsFor(source, key).first` — oldest
membership first, the identical pick `PipelineProgress.assignedStorylineId`
makes for the automatic path. So adding a thread to a *second* storyline
leaves the pointer on the first one it joined; the two answers have to agree
or they would fight over the column. Removal clears by name
(`… AND storyline_id = ?`), so a thread in two storylines keeps the other's
stamp, and then re-stamps from whatever membership is left.

Both surfaces that read the column are windowed by `received_at`, so stamping
history moves their numbers: `homeMetrics.storylined` counts progress rows in
the window with a non-null `storyline_id`, and `hotStorylines` groups by it —
filing one long thread by hand can add many messages to both at once. That is
the intended reading (the messages really are in that storyline), not a
double-count.

## How the sweep finds its pairs

Clustering is two halves, and only one of them moved. **Forming** the clusters
is single-link greedy agglomeration in `StorylineService._clusterBy` — each
thread, in the order the store handed them over, joins the first existing
cluster holding a member it links to. That is a pure function of its input, and
has to stay one: `cluster_hash` is what tombstones a dismissed suggestion, so
the same threads must group the same way on every run for a dismissal to hold.
**Finding** the linked pairs is the half an index can do faster, and it now
does — `ConversationVectorIndex` (see `05-embeddings.md`), diff-backfilled at
sweep start, one KNN probe per candidate, `1 - distance` converted back to the
cosine similarity the same `>= clusterLinkThreshold` decides on.

**The results are identical, unconditionally, by design.** Each probe asks for
as many neighbours as the *index* holds — not as many as there are candidates —
so it comes back with the whole corpus and no link can be crowded out by a
thread that is already filed. What that buys is native distance arithmetic over
packed float32, not a better asymptotic: an index that made the sweep faster by
proposing different storylines would be a bug wearing a benchmark.

**Brute force is the fallback, and it is not exceptional.** The sweep does its
own arithmetic when there is no usable index (the ordinary state of a build
without the native extension), when the diff backfill cannot complete, when a
candidate's vector is not the index's width — a corpus caught mid-model-change
has rows the index skipped, and a hole in the index is a link the probes cannot
find — and when a probe fails to find its own row, which is the cheap check
that the index really does hold every candidate. Falling back is a `debugPrint`
once per process and nothing else: never a park, never a crash, and never a
different answer.

## Cross-source identity

A thread is `(source, conversation_key)`, never the key on its own. Mail and
chat are clustered in one pool, and the two connectors mint their keys with no
knowledge of each other — so the sweep's taken-set, the member sets both
comparison passes carry, and every block are keyed on the `'<source>\n<key>'`
composite. A chat already filed away no longer hides a mail thread that happens
to share its key.

The dedupe hashes fold the source in for the same reason: `cluster_hash` and
`member_hash` are taken over the sorted composites, so two groups that differ
only by connector are two groups. Recognising a dismissal asks **both**
recipes, though. Hashes written before the source was folded in can never be
rewritten — a cluster tombstoned below `minClusterSize` has no member rows to
rebuild it from — so `MessageStore.dismissedHashExistsAny` is handed the
composite hash and the old bare-key hash for the same candidate set, and
matches either against either column in one query. Every write uses the new
recipe; a dismissal made under the old one holds forever.

## The model calls

**ConfirmMembershipTask** — `app/lib/services/llm/storyline_tasks.dart`,
schema `storyline_membership`, **fast / bulk slot** (`confirmClient` in
`app_providers.dart`), **temperature 0** at all three call sites (assign,
recruit, sweep-member). Given a storyline described by its *charter* and one
candidate thread: an evidence sentence first, a boolean `belongs`, and a
low/medium/high confidence — **low is treated as a no**. The prompt's real
work is what *not* to weigh: two threads of the same kind (two invoices, two
trips) do not belong together, and the participant list is context, not a
requirement.

**NameStorylineTask** — same file, schema `storyline_name`, **prose / 27B
slot**, **temperature 0**. Names a group of threads: evidence sentence, a
≤6-word title in the owner's own vocabulary (generic labels explicitly
banned), a present-tense one-sentence status summary, and a charter phrased as
membership criteria so future threads can be judged against it. Called from
the sweep's `_propose` and from the refresh pass's bootstrap branch. The doc
comment above the prompts explains the charter-vs-summary distinction — the
charter is the membership contract, the summary is display text.

**RefineStorylineTask** — same file, schema `storyline_refresh`, **prose / 27B
slot**, **temperature 0**. The same four fields as naming, asked of a
storyline that already has them: three fences (`storyline` with the current
text and the two lock lines, `threads` with every member card, `new_threads`
with what just joined — always present, `(none)` when nothing is known to be
new). Its prompt is mostly about *not* changing things — continuity as the
default answer, minimal drift on the charter, no noun that is not in the
threads — because every word it moves is a word that moved under a person who
had already read it. Its validator is separate from naming's for one reason:
an empty title here keeps the stored one, where naming substitutes
`Untitled storyline`.

**StorylineRecapTask** — same file, schema `storyline_recap`, **prose / 27B
slot**, **temperature 0**. Two fences (`storyline` with the title, charter and
previous recap; `messages` with the window). Four fields: `evidence`, then a
2–4 sentence present-tense `recap`, then `open_items` and `decisions` as plain
string arrays — the shape `triage_task.dart` proves this server's grammar
converter handles, no `$defs`. The previous recap rides *inside* the fence
even though this app stored it: a model wrote it out of other people's mail,
and text laundered through one of our own columns is still theirs. Its
validator drops non-string list entries rather than stringifying them (the
other five items are still good items) and caps each list at 6 — a reader with
twelve open questions has a backlog, not a recap.
