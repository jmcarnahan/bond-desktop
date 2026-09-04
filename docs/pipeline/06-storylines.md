# 6 · Storylines

Storylines are groups of threads about the same thing, proposed by the model
and kept or dismissed by the user. Four passes share the machinery, all in
`app/lib/services/storyline_service.dart` behind the handlers in
`app/lib/services/storyline_handler.dart`. **Their relative order is the
handler registration order in `app_providers.dart`** — that list's comments
are the authority on sequencing.

## The four passes

1. **Assign** (`StorylineAssignHandler` → `assignConversation`) — when a
   conversation's card changes, cosine-shortlist it against live storyline
   centroids, then ask the model to confirm the best candidate. Every
   candidate's members and blocks are read in one query each for the whole
   pass (`memberContextRows`, `blockedStorylineIdsFor`), so filing one thread
   costs the same against a mailbox of fifty storylines as against two. On join,
   **Name** refreshes the storyline's title/summary/charter (`_refreshName`) —
   but only when the summary or charter is missing or unlocked; a user-locked
   charter is never overwritten.
2. **Sweep** (`StorylineSweepHandler` → `sweep`) — clusters *unassigned*
   threads by embedding similarity (gate: 2 similar threads form a proposal),
   names the proposal, then confirms each member individually. Rejected
   clusters are tombstoned by immutable `cluster_hash` (schema v7) so a
   dismissed suggestion stays dismissed even after membership drift.
3. **Recruit** (`StorylineRecruitHandler` → `recruit`) — after a user saves a
   charter, judges up to 8 candidate threads against it.

A thread the user removes by hand is blocked — the model cannot put it back.

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
membership criteria so future threads can be judged against it. The doc
comment above the prompts explains the charter-vs-summary distinction — the
charter is the membership contract, the summary is display text.
