# 11 · Needs-you verdict

**Every reader of this verdict lands in a later phase of this round.** As of
this phase the stage judges a message and stores the answer; nothing in the app
reads `needs_you_verdict` yet.

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

**What the prompt is told.** The rules are `needsYouDefaultRules`, and they are
**public** for two reasons: the settings pane that lets the owner add their own
criteria renders them above the field, and an anti-drift test pins
`systemPrompt.startsWith(needsYouDefaultRules)` so the words on screen and the
words the model reads cannot come apart. The prompt is held to the **strict**
form of the parity rule in `prompt_parity_test.dart` — it may not say "email",
"mail" or "chat" at all, not even naming the two together, because what varies
by channel is stated in the user message.

The user message layers, in order: the date anchor, the directness line, the
**owner-identity line** (`The owner of this inbox is NAME <ADDRESS>.` — the
app's own statement, outside every fence, and what lets "the message names the
owner" bind to a person), the owner's rules, the thread's newest three turns,
and last the judged message. Everything variable is fenced with
`wrapUntrusted`; the judged message is fenced as `inbound_message`, the same
tag every other task uses.

The owner identity comes from an `OwnerLookup` callback, asked **once** per
handler: it is a keychain read, and the answer only changes on sign-out, which
disposes the provider that built the handler.

**The `needs_you_rules` pref.** One global text (`app_prefs`, key
`needs_you_rules`, re-exported by `prefs_provider.dart`), read per message so
an edit mid-drain applies to the rest of the drain. Stored **verbatim** — the
pane trims before it calls, and trimming again in the store would mean the text
in the field and the text the model reads are not the same string. Capped at
`needsYouRulesCap` = 800, which is also the `maxLength` the editor will
enforce: a cap the editor did not show would silently drop the end of what
somebody typed. It is one person's text, so `wipeAll` clears it alongside
`about_me` — inherited by the next identity it would decide what *they* get
interrupted about.

The owner's about-me text is deliberately **not** in this prompt. Two
owner-authored free-texts in one call is the charter-versus-summary confusion
this app avoids elsewhere; the needs-you rules are the one owner text this
judgement reads. The rules paragraph is also the single place a prompt here
grants fenced text a narrow licence to be *used* rather than only analysed —
bounded, in the same paragraph, to the criteria for this one true/false answer.

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
