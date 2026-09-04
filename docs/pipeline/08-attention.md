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

**Known documentation gap.** The code documents ownership rules well, but the
scoring formula itself is under-commented — `recomputeAll` is the place to
add prose if the formula changes. Also a recorded residual from PR #9:
`latestInboundMeta` and attention still key on bare conversation keys rather
than `(source, conversationKey)`.
