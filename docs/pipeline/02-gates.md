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
home screen's "Show dropped" toggle (PR #10).
