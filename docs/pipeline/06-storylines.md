# 6 · Storylines

Storylines are groups of threads about the same thing, proposed by the model
and kept or dismissed by the user. Four passes share the machinery, all in
`app/lib/services/storyline_service.dart` behind the handlers in
`app/lib/services/storyline_handler.dart`. **Their relative order is the
handler registration order in `app_providers.dart`** — that list's comments
are the authority on sequencing.

## The four passes, in drain order

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
   names the proposal, then confirms each member individually. Rejected
   clusters are tombstoned by immutable `cluster_hash` (schema v7) so a
   dismissed suggestion stays dismissed even after membership drift.
3. **Refresh** (`StorylineRefreshHandler` → `refresh`) — re-describes a
   storyline whose membership has moved. Its own section below.
4. **Recruit** (`StorylineRecruitHandler` → `recruit`) — after a user saves a
   charter, or after a refresh widened one, judges up to 8 candidate threads
   against it.

A thread the user removes by hand is blocked — the model cannot put it back.

## The refresh pass

Storylines used to converge and stop: named once, on the day they were
proposed, and never again however many threads joined. `refresh` is what makes
the description follow the membership.

**The gate** is `refreshed_member_hash == member_hash` (schema v10). Equal
means the members have not changed since the description was written and the
pass returns before any model call; NULL means never described, which is not
the same as unchanged. Both hashes use the one write recipe (`_hashOfThreads`,
source folded in).

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
overwritten: the model's version is parked in `charter_suggestion` for the
About block to offer, and a suggestion that matches the stored charter
(compared with whitespace flattened and case folded) clears rather than
parking. Both arms of `setCharter` clear a parked suggestion — the user has
just answered the question it was asking.

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
