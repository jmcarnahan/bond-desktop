# 6 · Storylines

Storylines are groups of threads about the same thing, proposed by the model
and kept or dismissed by the user. Six passes share the machinery, all in
`app/lib/services/storyline_service.dart` behind the handlers in
`app/lib/services/storyline_handler.dart`. **Their relative order is the
handler registration order in `app_providers.dart`** — that list's comments
are the authority on sequencing.

## The six passes, in drain order

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
   a dismissed suggestion stays dismissed even after membership drift. Finished
   threads are held out of the clustering and offered to the newborn storyline
   afterwards instead — "join, not seed", its own section below.
3. **Refresh** (`StorylineRefreshHandler` → `refresh`) — re-describes a
   storyline whose membership has moved. Its own section below.
4. **Audit** (`StorylineAuditHandler` → `audit`) — re-judges the threads the
   MODEL filed into one storyline, against the charter as it now reads and the
   owner's own examples. Queued by `removeThread` and by *Re-check members* in
   the About block. It is registered after the refresh and before the recruit,
   and both halves of that matter: the removal that woke it also queues a
   refresh, which is the pass that narrows the charter, so the audit judges
   against the narrowed sentence — and the recruit that a narrowed charter
   re-arms runs afterwards, over a member set the audit has already cleaned.
   Members the owner filed by hand are never re-judged: their membership is
   the owner's word, not a guess to check. A rejected member is removed WITH a
   block whose `blocked_by = 'audit'`, because an unblocked removal would be
   re-filed by that same recruit, in the same drain, off the same charter.
   Idempotent: it reads current state, and a lap that removes nothing writes
   nothing and queues nothing — it only notes what it checked, the way the
   recruit notes a lap that filed nothing.
5. **Recruit** (`StorylineRecruitHandler` → `recruit`) — after a user saves a
   charter, or after a refresh widened one, judges up to 8 candidate threads
   against it. It hunts again if the charter moved while it ran: a save landing
   after the row went `processing` enqueues against that row and is swallowed,
   and this is the one pass with no sweep catch-up to find it later, so the
   wakeup has to live inside the pass. Bounded by the user rather than the
   model — an extra lap needs a save *during* the previous one, and at
   temperature zero a lap with no save would ask the same questions of the same
   threads.
6. **Recap** (`StorylineRecapHandler` → `recap`) — re-writes the storyline's
   running state of play from the newest messages across its member threads.
   Its own section below.

A thread somebody takes out of a storyline is blocked, and what that block
does — to the prompts, to the passes, and on screen — is *Removing a thread*
below.

The first five run on MEMBERSHIP and go quiet once the member set settles. The
recap runs on what was SAID and keeps moving as long as people are talking.

## The refresh pass

Storylines used to converge and stop: named once, on the day they were
proposed, and never again however many threads joined. `refresh` is what makes
the description follow the membership.

**The gate** is `refreshed_member_hash == member_hash` (schema v10). Equal
means the members have not changed since the description was written and the
pass returns before any model call; NULL means never described, which is not
the same as unchanged. Both hashes use the one write recipe (`_hashOfThreads`,
source folded in). A NULL `member_hash` — a fixture, or a row from before the
column was written — is derived from the member rows for the gate *and healed
into the column* by the same stamp: the gate reads Dart and the catch-up reads
SQL, and `NULL IS NOT <hash>` keeps such a row stale forever if the two do not
speak the same value. The heal re-reads the column first, so a hash written by
a thread filed mid-call is never overwritten with the older derived one.

**An empty member set is still an answer.** A storyline whose members were all
removed, or whose conversation rows are gone, has no cards to describe it from,
so the pass makes no model call — but it stamps. Nothing to describe *is* a
description of the empty set, and without the stamp the catch-up re-queued the
pass on every sync for the life of the database. A thread joining later moves
`member_hash` and re-fires it.

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
| `assignConversation` tail | **gated**: summary empty, or charter empty and unlocked, or `member_count - refreshed_member_count >= 2`. The growth clause needs a recorded count — a described-but-uncounted row is a pre-feature one, and the sweep catch-up owns it. And on a sync drain the gate is moot anyway: any assignment moves `member_hash`, so the same drain's sweep catch-up queues the refresh whatever the gate said. What it really governs is drains with no pending sweep row — a UI pump |
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

**The documents in the window.** After the gate and before the call, the
service reads `MessageStore.digestsForMessages` **once per distinct source in
the window** — a second query, never a join onto the window read, which is
already a UNION across every member thread. Each message line then carries one
aside per digested attachment that recorded facts: ` ⟨attached <name>:
<fact>; <fact>⟩`. The facts and not the summary, because "the quote came in" is
what the message line already says and "48,200 total, valid 30 days" is what it
cannot. A document with no facts contributes nothing.

Digests are **never filtered by direction** — the window carries the owner's
own messages on purpose, and the quote they sent is as much of the story as the
one they received.

**The pinned footer.** After the message lines, one line per document pinned to
this storyline whose message is **not** already in the window:
`⟨pinned <name>: <summary>⟩`, or `⟨pinned <name>⟩` when nothing has read it. A
footer rather than an interleaved line because the window is chronological and
a pin has no place in that order; the summary rather than the facts because a
pinned document is being named for what it *is*. A pin whose message is in the
window is skipped — its own line already carries it, and saying it twice is how
a recap starts reading as though two things happened.

Both are clamped to 160 characters, and the clamp bites the text *inside* the
angle brackets so the closing `⟩` survives. `_recapLineCap = 400` still applies
to the message text before its aside, and `StorylineRecapTask._messagesCap =
6000` is the final clamp on the whole window — there is no third one.

**The gate** is the `recap_through` watermark (schema v10): the pass returns
before any model call when `recap_through >= ` the newest `received_at` in the
window. ISO-8601 with a fixed offset compares correctly as a string, so no
parsing is involved. The stamp is the **pre-call** watermark, for the reason
the refresh stamps its pre-call hash: a message that landed while the model was
thinking is a message this recap never read, and stamping what is true *now*
would leave the gate reading fresh and that message would never be recapped.

**The gate is time AND membership**, because a watermark alone answers the
wrong question. It measures the window it was taken over, and a membership
change makes that a different window — so every site that writes
`member_hash` clears `recap_through` in the same `updateStoryline` call:
`assignConversation`, `recruit`'s per-candidate write, `addThread`,
`removeThread`. (`_propose` needs no clear; a newborn's watermark is already
NULL.) Without it a thread filed by hand — usually an old one, since it is a
thread the user went *looking* for — is a silent no-op on every trigger that
queues a recap, because the mark is already past every message on it. The clear
is explicit rather than an omission: `recap_through` takes the v10 `_unset`
sentinel, and omitting it is what "leave this column alone" means.

It adds no permanent work. After the clear the catch-up's NULL arm selects the
storyline only when an eligible message exists; the pass then reads and stamps
a fresh mark, and a model that declines the window stamps it anyway (see *Empty
answers* below), so there is no arm that clears without eventually stamping. A
storyline emptied of everything readable is not selected at all — no eligible
message — and converges as silence.

**Triggers** — every path that changes what has been *said*, all via
`requeueWork`:

| Trigger | When |
|---|---|
| `ExtractHandler` tail | a message's facts land in a thread that is already in ≥1 storyline (`storylineIdsFor`), one requeue per storyline. Deliberately outside `_refreshCard` and not behind a successful embed — the recap has nothing to do with the vector, and a down embedding server must not cost it a message |
| `addThread` | always — a hand-filed thread brings its own messages, and the user is looking. The membership clear is what lets that recap past the gate when those messages are old ones |
| `refresh` tail | always, once it gets past its own gate — a membership change is a change to the story. This is `removeThread`'s route in |
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

`removeThread` is absent where the refresh table has it because it needs no row
of its own: the refresh it queues re-queues the recap from its own tail. What
makes that reach the model is the watermark clear above — and the recap text is
cleared with it, so the pass rewrites rather than carries forward; see *The
recap goes with the members* under *Removing a thread*. A removal is the case
the watermark clear was most needed for — it is the one membership change that
adds no message anywhere, so nothing else could ever make the recap stale.
Before the clear, a recap went on narrating a thread the user had just filed
out until something new was said in the threads that remain; the catch-up could not close
it either, since its `EXISTS` asks whether a member thread holds a message
*newer than the watermark* and a removal leaves that answer no.

The one case left is a storyline emptied down to nothing: the refresh finds no
cards, so it stamps and returns without queueing a recap, and the stale recap
text stays on the row. It is visible only on a live storyline with no readable
members, and the alternative — a recap pass over an empty window — has nothing
to write.

Bursts coalesce for free: `requeueWork` is keyed on
`(kind, source, entity_id)`, so ten messages landing in one drain leave one
row, and the one pass that runs reads the whole burst because it reads current
state at run time rather than a payload. Nothing carries provenance through the
queue.

**Empty answers keep the previous recap standing.** A model that comes back
with no recap text leaves the text and both lists exactly as they were: a thin
answer must never cost the user the catch-up they had. The watermark still
moves, and it is not claiming the recap covers those messages — it records that
the model was *asked* about this window and declined it. Without the stamp the
sweep's catch-up finds the storyline stale on every sync and re-dials the 27B,
at temperature zero, over the same window, for an answer that cannot come back
different. The next message moves the window, and a different window is a
different question — which is when asking again is worth a call.

## What the user sees

The storyline screen (`StorylineTimelinePanel`) leads with the recap: the
paragraph in body type directly under the title, then a compact **OPEN** list
and a **DECIDED** list — each rendered only when the pass found something for
it — and a quiet "as of *n*h ago" read off `recap_through`, which dates the
paragraph by the newest message it has *read* rather than by when it ran. Both
lists arrive folded to their heading and count — **OPEN · 2** — and each
unfolds on a tap of its own, because a long storyline can carry half a dozen
items in each and twelve bullet lines between the paragraph and the spine is a
header nobody reads to the end of. The recap **replaces** the one-line
`summary` in that header; the summary is still what the rail shows, and it is
the header's text until the recap pass has written one. `recapOpenItems` /
`recapDecisions` on `Storyline` are the only decoders of the two JSON columns,
and they are tolerant in the same way the message models are: a half-written
column costs the lists, never the render.

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

The Storylines overview cards lead with the recap too — the paragraph alone, up
to four lines, falling back to the `summary` until a recap exists; what is open
and what was decided stay on the storyline screen, where there is room to read
them rather than skim past them. Beside the *Storylines* heading is a quiet
**Sync**, which runs the ordinary sync (both connectors, exactly as the poll
and the rail's refresh do) and reads *Syncing…* while it does: nothing
storyline-shaped is needed, because that pass ends by requeueing the sweep and
the sweep's catch-ups drain the refreshes and recaps that were owed. The same
button sits at the end of the storyline screen's own button row, so opening a
storyline does not mean going back to the overview to ask for the pass that
brings it up to date. It is one action and one flag: the screen owns the sync
and hands the panel the label, which is why both buttons read *Syncing…*
together.

Beside *About* in that same row sits **Documents**, which counts what it holds
— *3 documents*, or the bare word when the storyline's threads carry no files
at all, so a storyline answers "is there anything on the shelf" without a tap.
It unfolds `AttachmentDocumentsStrip` under the header, where the member strip
and the About block unfold, and folds again on a second press.

The shelf is **every document on the storyline's threads, the pinned ones
first** — `storylineDocumentsProvider` over `attachmentsForStoryline`, not a
pin list. A storyline is several conversations about one thing and the file
somebody is looking for is nearly always simply on one of them; pinning is how
they float the one that matters most, and how they keep a file whose thread
later leaves. Inline images are excluded by the store: a signature graphic is
not a document. Each entry is the file's glyph and name over its size and the
model's one-line read, with a 📌 in front of a file pinned to *this* storyline;
tapping one opens it.

Both directions are on the entry itself. An unpinned document offers **Pin**,
one tap, and floats to the top. A pinned one offers **Remove**, two taps in
place — the second reads *Remove document* beside a *Cancel*. Unpinning takes
the pin, not the file: a document whose thread is still a member stays on the
shelf and simply stops floating, which is why the bar reads *Unpinned
<name>.* A pane handed no pin or unpin closure shows neither control.

Files also get onto that shelf from the other end: **Pin to storyline** on the
preview panel and on the full viewer, which is the only way a file on a thread
that is *not* a member gets here. From an open thread the pin goes to the
oldest storyline that thread is live in — the same `storylineIdsFor(...).first`
pick the hand-filing stamp makes, for the same reason: two answers about "this
thread's storyline" have to agree. From the storyline pane it goes to the
storyline on screen. A thread in no storyline is offered no button rather than
a dead one, and a file already pinned reads *Pinned* and does nothing.

A chip or a thumbnail inside one of the spine's messages opens the file too,
and on this pane it opens the **full viewer**: there is no split here, because
the storyline pane is already several conversations side by side and halving
it again leaves neither readable. *Back* out of that viewer lands on the
storyline, not on a split that was never there.

The About block also ends with what has been taken *out* of the storyline —
two lists and a *Re-check members* button, all under *Removing a thread* below.

The same two lists are readable from the other end. A message's history screen
(`MessageHistoryScreen`, [README.md](README.md#finding-out-what-happened-to-a-message))
carries a **Storylines** section holding every `storyline_members` row this
message's thread is in — with the storyline's title, the `evidence` behind the
filing, *filed by you* where `added_by = 'user'`, and the storyline's own
status where it is no longer live — and under them every `storyline_member_blocks`
row. The blocks are ONE list here, each entry saying which pass removed it:
*Removed by you* or *Removed by re-check*. The four buttons beside them —
*Remove* (two taps, as it is in the About block), *Allow again* and *Add back*
on every entry whose storyline is still live, whichever pass wrote the block,
and *Add to storyline…* which opens the same picker pane the thread view opens
— all route through the same `StorylinesNotifier` methods the About block
calls. Two doors onto one decision, never two decisions: a removal from here
writes the same block, teaches the model the same lesson, and offers the same
way back. A storyline that is dismissed or gone offers no lever at all — not
*Remove* on a filing, and neither button on a block — because there is nothing
left to answer for it.

Dismissing a storyline was the one storyline decision with no way back: the row
left the rail, and nothing on screen remembered it. The rail now carries a fold
under the live storylines reading **Dismissed · *n***, shut on every build,
holding one row per dismissed storyline with a single **Restore**. Restoring
puts the status back to `suggested` — the state the row was in when the
question was first put — so the same Keep / Dismiss pair comes back with it.
That also lifts the tombstone: `dismissedHashExistsAny` keys on
`status = 'dismissed'`, so a restored storyline's member set can be proposed
again. Members were kept on dismissal, so nothing is rebuilt.

Refresh, audit and recap all report progress under their own kinds, and
`StorylinesNotifier` listens for all of them, so a pass that rewrites a title,
takes a member out, or writes a recap lands on the rail and the open storyline
within the list's 400 ms debounce rather than at the next poll.

## Filing a thread by hand

`StorylineService.addThread` / `removeThread` are the user's own passes, and
they write the same per-message pointer the automatic ones do —
`message_progress.storyline_id`, through the narrow
`MessageStore.stampStorylineId`. This is what makes a hand-filed thread
visible: the home feed's storyline link and the hot-storylines strip both join
on that column and know nothing about `storyline_members`, so before this the
timeline and the rail showed the filing and the feed did not.

A hand-filed membership also **teaches**. `addThread` writes `Filed by you` as
the member row's evidence, and that is not decoration: user members ride into
every `ConfirmMembershipTask` call as the `kept_by_owner` fence — up to three,
newest first, because the owner's latest word is what teaches and a fourth card
buys tokens on every membership question the storyline will ever ask. A row
with no evidence would also hand a later removal a negative example that says
nothing, since a removal copies the member's evidence onto its block. The
sweep's own proposal confirms carry `(none)` in both example fences by
construction: they judge candidates against an unsaved proposal, which has no
row in the database, no members and no blocks.

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

## Removing a thread

Taking a thread out of a storyline used to be a delete and a block: the
membership row went, a row in `storyline_member_blocks` stopped the next pass
putting it back, and that was the end of it. The removal changed nothing about
how the model judged the *next* thread, so the same reasoning that filed the
wrong one filed its twin the following morning. Removing a thread is now the
strongest thing a person ever says about what a storyline is, and it is carried
all the way through.

**The block records who and why.** `storyline_member_blocks` carries
`blocked_by` (`'user'` or `'audit'`) and `evidence` from schema v14. The
evidence is copied off the member row inside the same transaction that deletes
it — that row is the only place the membership's reason was ever written, and
it is about to be gone — so the owner's block remembers what the model thought
when it filed the thread they are now taking out. An audit's block carries the
audit's own reason instead.

**The owner's blocks are negative examples.** `ConfirmMembershipTask` takes a
`removed_by_owner` fence: up to three of them, newest first, as the same
enriched cards the candidate is described with. The prompt reads them as the
owner's "no" — a candidate of the same kind, the same sender pattern, the same
sort of message, does not belong, even when the charter reads as though it
might. `blocked_by = 'user'` **only**: an audit's rejection is a consequence of
a lesson the owner already taught, and feeding it back would let the model
teach itself.

**The refresh may narrow the charter for them.** `RefineStorylineTask` takes a
`removed_threads` fence, between `threads` and `new_threads`, carrying the same
up-to-three owner blocks. Every other pressure on that prompt widens the
charter, and a charter that only ever grows ends up admitting the very thing
the owner removed — so this is the one input that may make it narrower, and the
prompt says so: when the charter as written would admit one of the removed
threads, add the smallest clause that excludes that *kind* of thread, keeping
every existing sentence word for word.

**The threads already inside get re-judged.** A removal is the owner saying the
model got this group wrong, and the threads the same reasoning filed here are
still sitting in it — so `removeThread` queues a `storyline_audit` alongside
its refresh. What that pass does is under *The six passes* above.

**The recap goes with the members.** A removal — the owner's own, or one the
re-check makes — clears the stored recap text and both of its lists along with
the watermark, so the recap the same removal queues is written from the
remaining threads alone rather than carried forward from a paragraph that still
narrates the thread that left. The recap pass is handed the previous recap and
told to carry forward what is still true, and it has no way to know which
sentence came from which thread, so nothing short of the clear could get the
departed thread out of it. An addition clears nothing: new mail adds facts, it
never invalidates the ones already written, and continuity is the point there.

**Audit blocks are never shown to the model, and only the owner lifts them.**
They stay out of both example fences, and no pass clears them; a thread the
re-check took out stays out until a person says otherwise, which is what stops
the audit and the recruit trading the same thread back and forth across drains.

**On screen**, the About block ends with two lists, **REMOVED BY YOU** and
**REMOVED BY RE-CHECK**, each rendering only when it has something in it. An
entry is the thread's subject — or *(thread no longer stored)*, since a block
outlives the conversation row it was written about — over the evidence that was
recorded, and two buttons. ***Allow again*** lifts the block and does nothing
else: the owner is withdrawing a veto, not making a membership, and whether the
thread belongs is a question the model may now answer on its own the next time
a pass looks at it. ***Add back*** files the thread by hand, which clears a
block of either kind on the way in. Both buttons sit on both lists — a
re-check's block is as reversible as the owner's. Under them, ***Re-check
members*** queues the audit by hand and pumps the worker, for a storyline whose
charter has drifted without anything being removed.

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
that the index really does hold every candidate. Falling back says why, once
per distinct reason, and nothing else: never a park, never a crash, and never a
different answer.

## Join, not seed

A finished thread never *seeds* a storyline. The sweep keeps `done` rows out of
the clustering entirely — grouping finished mail would fill the rail with
history nobody asked to be reminded of — and that has not changed. What changed
is what happens to them afterwards: instead of being discarded, they are
diverted into a candidate list, and a storyline that is actually born in this
pass runs one bounded probe over it before `_propose` returns.

The probe is the recruit pass in miniature, against the group that just came
into existence. Candidates have already passed the sweep's taken-set filter, so
a thread already filed into a storyline — or one the user pulled out of one —
is never offered; the rest are scored against the centroid of the *surviving*
members, gated at `assignCosineGateWithOverlap`, and the top
`recruitMaxCandidates` by cosine each get the same `ConfirmMembershipTask` call
recruit and assign make, against the charter the naming call wrote seconds ago,
at temperature zero, with `low` still treated as a no. They are judged against
the participants of the storyline as it actually stands, read back from the
stored members rather than from the pre-confirmation cluster.

This closes an asymmetry rather than opening a door. `recruit` has always
considered done threads — it walks every embedded thread in the mailbox and has
never filtered on state — so a charter edit could already pull a finished thread
in. Only a *sweep-born* storyline was blind to the thread that was marked done
last week, which is exactly the thread most likely to be the beginning of the
story it just formed around.

One pass may propose up to three storylines, and every one of them is offered
the same candidate list, so the probe also carries a taken-set of its own that
grows as the pass runs. The sweep's `assignedOrBlockedKeys` set was read before
any of these storylines existed and cannot cover them; without the running set,
a finished thread sitting between two newborn clusters could join both, which is
a state no other automatic path can produce — `assignConversation` files a
thread into its single best storyline and nothing else.

Two further limits are worth naming. The tombstone branch probes nothing: a cluster the
model threw out below `minClusterSize` must not go recruiting history to make
itself big enough to ship. And when the probe files anything, **both** member
hash columns are recomputed over the final set, so `member_hash ==
refreshed_member_hash` still holds — the storyline is born described, and a
probe join must not send it to `staleRefreshStorylineIds` and spend a 27B Refine
call re-describing what was written moments ago. `recap_through` is cleared as
every other member-add path clears it, so the recap already queued by the birth
covers the joined threads too; the recap handler drains after the sweep's in the
same pass, which is why the probe runs inline rather than as a pass of its own.
`cluster_hash` is never rewritten: it names the group the user is being asked
about, and the probe did not change that question.

In the activity row the probe reports itself as `joined`, kept separate from
`confirmed` and `rejected` — those two count the cluster's own members being
judged, and a finished thread that was offered and turned away was never one.

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
`app_providers.dart`), **temperature 0** at all four call sites (assign,
recruit, sweep-member, audit). Given a storyline described by its *charter* and
one candidate thread: an evidence sentence first, a boolean `belongs`, and a
low/medium/high confidence — **low is treated as a no**. The prompt's real
work is what *not* to weigh: two threads of the same kind (two invoices, two
trips) do not belong together, and the participant list is context, not a
requirement. Dates are the same rule one step finer: a storyline about a
specific dated occasion — a meeting on a named day, a trip, a deadline — admits
only threads about *that* occasion, because another meeting is not this
meeting.

Four fences, in the order `storyline`, `kept_by_owner`, `removed_by_owner`,
`candidate_thread`. The two example fences are what the owner has taught this
storyline (*Filing a thread by hand*, *Removing a thread*), and both are always
present, rendering `(none)` when there is nothing — an empty fence says the
owner has taught nothing yet, which is the fact the pass has, and a fence that
appeared and vanished between calls would change the shape of the message for
no gain. The candidate goes **last** on purpose: within one recruit lap the
storyline and its examples are identical across every call while the candidate
varies, so the constant part first is what keeps the server's prefix cache warm
across the eight confirmations a lap makes. The examples are always passed *in*
by the caller and never read from the storyline's id inside the task, because
the sweep judges candidates against an unsaved proposal.

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
storyline that already has them: four fences (`storyline` with the current text
and the two lock lines, `threads` with every member card, `removed_threads`
with up to three the owner took out, `new_threads` with what just joined — the
last two always present, `(none)` when nothing was removed or nothing is known
to be new). Its prompt is mostly about *not* changing things — continuity as
the default answer, minimal drift on the charter, no noun that is not in the
threads — because every word it moves is a word that moved under a person who
had already read it. `removed_threads` is the single exception, and the only
input that may make a charter *narrower*: see *Removing a thread*. Its
validator is separate from naming's for one reason: an empty title here keeps
the stored one, where naming substitutes `Untitled storyline`.

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
