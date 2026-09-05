# 2 · Gates and detail fetch

Gates exist to skip what is not worth a model call. They run in two tiers
around the body fetch, because the cheap signals arrive with the delta and the
header signals only arrive with the full message.

**No model call in any of this** — gates are pure functions over sender
strings and headers.

## Tier 1 — sender-only, on delta fields

Before fetching anything: the user's own outbound messages, and no-reply
local-parts (`no-reply`, `notifications`, `alerts`, …) are gated out.
`gateFor` in `app/lib/services/gates.dart` dispatches to `_emailGate` /
`_teamsGate` per source. Driven from the claim loop in
`app/lib/services/triage_queue.dart`.

## Detail fetch (mail only)

`ensureMessageBody` pulls the full body and internet headers. Failure
*degrades* (triage proceeds on what it has) rather than parks — except
`NotSignedIn` / `ReconsentRequired`, which park the queue until the session is
usable again. See `triage_queue.dart`.

## Tier 2 — header gates

With headers in hand, the list/auto-generated checks run: `List-Unsubscribe`
/ `List-Id`, `Precedence: bulk|list|junk|auto_reply`, `Auto-Submitted`, and
`X-Auto-Response-Suppress`. Also in `gates.dart`.

## Reading the file

The header comment in `gates.dart` is the real documentation: it explains the
two-tier split, an anchoring subtlety in the local-part regexes, and — most
usefully — two gates that deliberately do **not** exist. Keep that comment
authoritative; this page is the map to it.

A gated message is not hidden: it lands with a drop reason, visible via the
home screen's "Show dropped" toggle (PR #10) and the Archive section's
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
