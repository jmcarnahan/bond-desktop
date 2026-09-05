# 8 · Attention rescore

**What happens.** `AttentionService.recomputeAll`
(`app/lib/services/attention_service.dart`) scores every open thread for the
Needs You rail: thread state, recency of movement, what the model found in it
(triage/extraction verdicts), and how often that sender gets answered. A
Settings slider sets the score threshold for appearing. Threads awaiting the
user's reply rank first; threads waiting on somebody else follow, dimmed.

**No model call.** Pure arithmetic over stored rows — which is why it can be
awaited synchronously right before the list renders (called from
`conversations_provider.dart`).

**Clearing rules.** `needs_you` clears on the user's own exits — a reply from
anywhere, or marking done — never on merely reading (PR #10). Attention v2
(PR #8) added quiet-hours tempering and a direct-address boost.

**The needs-you verdict as an input.** `attentionScore` takes the newest
inbound message's `needs_you_verdict` (see [11-needs-you.md](11-needs-you.md)),
carried to it on the same `latestInboundMeta` row as triage's judgments. It
moves the score in exactly two places: a judged **yes** breaks the quiet-FYI
temper — the thread scores from the needs-reply base and keeps its reply-rate
nudge rather than dropping to the waiting base — and earns the direct boost on
its own, without `addressed_me`. Together those are what lift a 1:1 Teams FYI
the stage read as a real ask over the default threshold.

The two fences are asymmetric on purpose: `!= true` on the temper, `== true` on
the boost, so NULL (never judged) and 0 (judged no) move **nothing** and score
exactly as they did before the stage existed. And the verdict deliberately does
not touch the **threshold** — it raises the score through the same arithmetic
every other signal uses, and the user's slider still gates what reaches the
rail. There is no bypass.

**Known documentation gap.** The code documents ownership rules well, but the
scoring formula itself is under-commented — `recomputeAll` is the place to
add prose if the formula changes. Also a recorded residual from PR #9:
`latestInboundMeta` and attention still key on bare conversation keys rather
than `(source, conversationKey)`.
