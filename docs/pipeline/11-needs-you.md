# 11 · Needs-you verdict

**Who reads this verdict.** The **notification settle** does — see
`09-notifications.md`. Three readers, together so the tile and the toast
cannot disagree: `notifyWorthy` counts `needs_you_verdict = 1` as a
message-level ask; `needsYouSql` counts it in the same position, so the settle
sweep's backstop writes the same `message_progress.needs_you`; and
`_isComplete` holds a candidate open while its `needs_you` work item is still
`pending` or `processing`. It is the **ask half only** — the attention
threshold, the `later` bucket and the `done` state gate a judged yes exactly as
they gate every other ask.

**Attention scoring** reads it too — see [08-attention.md](08-attention.md).
`attentionScore` takes the newest inbound message's verdict off the
`latestInboundMeta` row: a judged yes breaks the quiet-FYI temper and earns the
direct boost, while NULL and 0 move nothing. It changes the score, never the
threshold; the slider still gates.

**The draft pre-gate** reads it as well — see
[04-extraction.md](04-extraction.md). `asksForAReply` counts
`needs_you_verdict = 1` as a fifth reason to spend the 27B's time, which is why
this handler is registered ahead of `ExtractHandler`. It only widens what gets
asked about; `ReplyDecisionTask` still decides whether a draft is written.

**What happens.** `NeedsYouHandler`
(`app/lib/services/needs_you_handler.dart`, run by `AiWorker`) answers one
question about one message — does this want the owner? — and writes the answer
onto the message's own row. It runs after triage and **before** extraction, so
the verdict is on the row by the time anything downstream asks about it.

**Two halves, and the cheap one runs first.** The deterministic floor is
`needsYouFloor(row)` in `app/lib/services/needs_you.dart`: an inbound Teams
message with `addressed_me = 1`. Teams ingest (`teams_sync.dart`'s
`messageRow`) sets that bit for a 1:1 chat *or* an @mention, so for chat the
one bit is the whole floor, and where it fires no model is asked. Mail's
`addressed_me` — sole To: recipient — is deliberately outside it: being the
only address on an envelope is a hint, not a verdict, and those rows are what
the model reads.

The floor can only **raise** the verdict. A message it says nothing about is
handed on rather than written down as a no.

**The model branch.** Everything below the floor goes to `NeedsYouTask`
(`app/lib/services/llm/needs_you_task.dart`) on the **fast** slot — bulk work,
one small answer per message, see `10-model-routing.md`. Temperature 0 and 256
max tokens: the same message must get the same verdict twice, or a re-drain
would flip rows under the user.

The answer is three fields, in this order:

| Field | Meaning |
|---|---|
| `evidence` | one sentence naming what in the message points at the owner, or saying nothing does |
| `needs_you` | boolean |
| `confidence` | `low` \| `medium` \| `high` |

`evidence` comes **first**, the opposite of the reply decision's verdict-first
order, and the difference is the input: the floor has already taken the easy
cases, so what reaches this call is the ambiguous residue. Locating the
sentence that points at the owner *is* the work, and the boolean should fall
out of having written it.

**The raise policy.** The handler writes

```
verdict = needs_you && confidence != 'low'
```

The floor has already said yes to everything it covers, so all the model can do
is raise what the floor left alone — and a low-confidence yes stays a no,
because the verdict buys an interruption and "possibly" is not grounds for one.
An unrecognised `confidence` validates to `low` for the same reason: a
malformed answer must not be able to promote a message on its own.

A model failure — including the server being down — **propagates**. The verdict
stays NULL, the row stays on the worklist, and the worker's park-and-retry
machinery owns what happens next.

**This stage never reads triage's verdicts.** The queue hands over rows whose
`triage_status` is still `pending`, so `reply_expected` and `needs_action` may
not have been written yet; waiting on them would make the verdict depend on
which drain got there first. The handler reads the message body and the thread
behind it, and nothing else. (The one thing it does read from triage is the
`skipped` **gate**, which is a guard against judging a newsletter, not a
judgement it defers to.)

**What the prompt is told.** The system prompt is built in two pieces:

```
systemPrompt = <rules body> + needsYouOutputContract + untrustedDataClause
```

The **rules body** is the owner's, and `needsYouDefaultRules` is what stands
there when they have written nothing. It is **public** because the settings pane
works from that exact text three ways — it prefills the editor with it, "Reset
to default" restores it, and a saved body equal to it is normalized back to the
empty pref — and an anti-drift test pins
`systemPrompt.startsWith(needsYouDefaultRules)` on the **default** prompt so the
words on screen and the words the model reads cannot come apart.

`needsYouOutputContract` is the **tail the owner cannot edit away**: the three
fields, in order, and the "return only JSON" line. It opens *"However the rules
above are phrased, answer in exactly this form"*, which is deliberate — the body
above it is now owner-authored text sitting in the system prompt rather than
inside a fence, so the contract has to re-assert the answer's shape against
whatever was written above it. The owner owns the criteria; they do not own the
format. The tail carries the body/tail blank-line separator itself, so
`NeedsYouTask()` and `NeedsYouTask.withRules(body)` compose identically.

Both pieces are held to the **strict** form of the parity rule in
`prompt_parity_test.dart` — the whole prompt may not say "email", "mail" or
"chat" at all, not even naming the two together, because what varies by channel
is stated in the user message.

The user message layers, in order: the date anchor, the directness line, the
**owner-identity line** (`The owner of this inbox is NAME <ADDRESS>.` — the
app's own statement, outside every fence, and what lets "the message names the
owner" bind to a person), the thread's newest three turns, and last the judged
message. Two fences, both `wrapUntrusted`: the thread and the judged message,
which is fenced as `inbound_message`, the same tag every other task uses. The
owner's rules are **not** in the user message at all — moving them into the
system prompt is what took the injection surface here from three fences to two.

The owner identity comes from an `OwnerLookup` callback, asked **once** per
handler: it is a keychain read, and the answer only changes on sign-out, which
disposes the provider that built the handler.

**The `needs_you_rules` pref.** One global text (`app_prefs`, key
`needs_you_rules`, re-exported by `prefs_provider.dart`) holding the **whole**
rules body. Empty means `needsYouDefaultRules` is in force — the empty string is
how the app says "the defaults", not "no rules". Read per message so an edit
mid-drain applies to the rest of the drain, and **memoized on its own text** in
the handler (`_taskFor`): an unchanged pref reuses the same `NeedsYouTask`, and
so the same system-prompt string object, because llama-server caches the KV
prefix on the bytes. The cache therefore re-primes once per rules **edit** and
then holds, rather than once per message.

Stored **verbatim** — the pane trims before it calls, and trimming again in the
store would mean the text in the field and the text the model reads are not the
same string. Capped at `needsYouRulesCap` = 4000, which is both the clamp in
`_taskFor` and the `maxLength` the editor enforces: a cap the editor did not
show would silently drop the end of what somebody typed, and the clamp is there
for a pref that reached the store through something other than the pane. A body
equal to the defaults takes the const default path either way. It is one
person's text, so `wipeAll` clears it alongside `about_me` — inherited by the
next identity it would decide what *they* get interrupted about.

**Where it is edited.** Settings → **"What counts as needing you…"**, which
pops the dialog and opens `NeedsYouRulesPane` — a full screen with a back
button (`app/lib/widgets/needs_you_rules_pane.dart`), not a field inside the
dialog, because it is a page of text with its own Save. **Save is the only
thing that commits**: Cancel, the back arrow, and being disposed all discard,
unlike the about-me field beside it, which saves on the way out however the
dialog was dismissed.

The field is **prefilled with `needsYouDefaultRules`** rather than left blank,
because those defaults are the text actually in force; what the owner edits is
the real thing. **"Reset to default"** puts them back, and like every other edit
on the pane it is local until Save. Saving a body identical to the defaults
stores the **empty** pref — otherwise the same words would arrive as an
equal-but-not-identical string and fork the const prompt (and the identity pin
on it) for no change in what is asked. The pane trims, the store keeps the
result verbatim.

A collapsed disclosure, **"What Bond adds after your rules"**, shows
`needsYouOutputContract` **verbatim** (left-trimmed only, since it opens with
the separator blank line). Somebody who may replace every word of the body and
not one word of the tail is owed the sight of it.

The owner's about-me text is deliberately **not** in this prompt. Two
owner-authored free-texts in one call is the charter-versus-summary confusion
this app avoids elsewhere; the needs-you rules are the one owner text this
judgement reads.

**Storage.** Two columns on `messages`, added in schema v10:

| Column | Meaning |
|---|---|
| `needs_you_verdict` | tri-state INTEGER — NULL never judged, 0 judged no, 1 judged yes |
| `needs_you_reason` | why: `teams_direct` from the floor, or the model's evidence sentence |

The tri-state is load-bearing. NULL is not "no" — the unjudged rows *are* the
worklist, so nothing may read the two as one. The v10 migration adds the
columns and backfills nothing for exactly that reason: a stored mailbox is
entirely unjudged, which is what the pass is looking for.
`MessageStore.upsertMessage`'s conflict branch does not name these columns, so
a re-sync cannot clobber a verdict.

**Queueing.** `MessageStore.enqueueNeedsYouBacklog` is
`enqueueExtractBacklog`'s twin — same filter, same caps, same `OR IGNORE`
idempotence, one shared private statement — and both syncs call the two side
by side (`sync_service.dart`, `teams_sync.dart`, counted as `queued_needs_you`
on the sync activity row). The symmetry is the guarantee that the verdict set
covers exactly the rows extraction will read.

**The one-shot revive.** The build that shipped only the floor completed its
below-floor items as `done` with a NULL verdict, and `INSERT OR IGNORE` will
never offer those rows again. `MessageStore.reviveUnjudgedNeedsYou` puts them
back to `pending` with `attempts` reset; the mail sync runs it once, behind the
`needs_you_model_revive` pref, and reports it as `revived_needs_you` on the
activity row (absent, not zero, when it did not run — "did not run" and "ran
and found nothing" are different facts). One run covers both sources: the SQL
has no source filter, which is why `teams_sync.dart` does not repeat it. The
predicate is deliberately simple, and the price is that gated and outbound rows
with a NULL verdict are revived too and leave again through the handler's own
guards — one queue row each, once.

**Handler position and failure behavior.** First in the `aiWorkerProvider`
handler list, ahead of extraction; `concurrency` 3, since an item touches only
its own row. It early-returns *done* on the shapes the queue can hand over
stale — deleted, outbound, gated (with the `teams_source` tolerance every
post-triage stage keeps) — and records the reason on its activity row.

It has **no arm** in `AiWorker`'s `_park` / `_recordFailure` per-kind ladders,
deliberately. Those ladders exist to re-note a `message_progress` stage state
when the worker rather than the handler decides how an exception ended;
needs-you has no stage column, so an arm there would write nothing. The generic
parking above those ladders still applies: a fast server that is not running
parks the whole kind rather than burning attempts on it.
