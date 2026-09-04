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
   centroids, then ask the model to confirm the best candidate. On join,
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
