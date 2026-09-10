# 13 · Context directories

**What happens.** The owner registers a local folder once — typically a Claude
Code project: a `CLAUDE.md`, `.claude/skills`, `.claude/rules`, docs, code,
rendered HTML analyses, notebooks, CSVs. From then on **the app re-reads that
folder at the tail of every mail sync**, whether or not anything is linked to
it, and keeps its passages indexed the way it indexes an attached document.
Later the owner links a directory to a thread or a storyline, and what a reply
reads is the folder's *current* contents rather than a snapshot taken when the
link was made.

Nothing here goes over a network except the embeddings. There is no connector,
no MCP tool and no chat model in this stage — it is `dart:io`, a walk, a
chunker and the embedding server on `:8081`.

> **Live as of schema v15.** Registration, the reconcile pass, the two derived
> indexes, the sync-tail enqueue, the Claude conventions, the per-file digests,
> the per-directory brief, the linking panel, the retrieval into drafts and
> every consumer below — the charter offer, the recap footer, the home
> search's third list, the file panel and the three doors into it — all run.

Everything below calls a per-file summary a **digest**, which is what the
column, the work kind and the code call it. The Settings switch for this is
labelled **Summaries** — the user's word for the same thing, kept because it
is the one a person reading a settings screen understands.

## The data model

Five tables (`app/lib/data/schema.drift`, schema v15), split by lifetime and
size the way the attachment tables are.

| Table | Holds | Written by |
|---|---|---|
| `context_dirs` | the registration, the two switches, and the ledger of the last walk | the Settings section, then the reconcile handler |
| `context_links` | what each directory is pointed at — the ONLY table tying one to a room | the link panel and Settings |
| `context_files` | one row per file, as the last walk saw it | the reconcile handler |
| `context_text` | the extracted words | the reconcile handler |
| `context_chunks` | the embedded passages, and the source of truth for their vectors | the reconcile handler |

Four column conventions carry weight:

- **`context_dirs.id` is the first 16 hex of `sha256(path)`**, not a
  surrogate. Registering the same folder twice is the same row without a
  lookup, and a caller holding only a path can name the row it wants
  (`ContextStore.idForPath`).
- **Register once, link many.** `context_links(dir_id, scope_kind, source,
  scope_key)` is the whole of the mapping. Unlinking is a row delete and costs
  no re-index, which is why every index table hangs off `dir_id` and not off a
  thread. `scope_kind` is an open set — `thread` and `storyline` today,
  `sender` and `all` are future values rather than future migrations. `source`
  is the connector for a thread and `''` for a storyline, whose ids are
  already global.
- **A thread inherits its storylines' links**, exactly as it inherits a pinned
  document. `ContextStore.dirIdsInScope` is one `SELECT DISTINCT` over both
  halves.
- **A reconcile pass never clobbers what a model call paid for.**
  `upsertFile` writes the walk's metadata and nothing else; `digest_json`,
  `digest_status` and `desc_embedding` move only through
  `setFileDigest` / `resetFileDigest` / `setFileDescEmbedding`, so re-reading
  an unchanged file is free.

`drafts.context_json` is appended by the same migration and written from a
later phase: the inventory of what one draft read, so the composer's
provenance line can name the file a fact came from. `payload_json` cannot
carry it (a requeue nulls it) and a second table would say what the drafts row
already says.

## Registering, and keeping permission

The app is sandboxed with `files.user-selected` and nothing more, so a folder
picked in the open panel is readable **for that launch** and then gone. A
security-scoped bookmark is the one Apple-sanctioned way to hold the grant
across a relaunch without asking for a Documents-folder entitlement the app
would then keep forever.

`DirectoryAccess` (`app/lib/services/context/directory_access.dart`) is the
seam. `ChannelDirectoryAccess` talks to a `MethodChannel` named
`com.bondinbox.app/bookmarks` with two methods, `create(path)` and
`resolve(bookmark)`. `PlainDirectoryAccess` answers null to both — what every
test and any unsandboxed build takes.

**Null is not a failure.** Every bad ending on that channel comes back as
null, including `MissingPluginException` from a `flutter test` binary with no
Runner behind it, because the caller's next step is identical for all of them:
fall back to the stored path, and call the directory `unavailable` only if
THAT cannot be read.

### The Swift behind the channel

`app/macos/Runner/BookmarkChannel.swift` is the other end, registered from
`MainFlutterWindow.awakeFromNib` right after `RegisterGeneratedPlugins` — this
is the app's own Swift rather than a plugin, so nothing registers it for us,
and it has to be up before the first frame because the settings pane can ask
to resolve a stored bookmark as soon as it renders.

| Method | Arguments | Answers |
|---|---|---|
| `create` | `path` | the bookmark bytes, or `FlutterError("bookmark_failed")` |
| `resolve` | `bookmark` | the resolved path, or `FlutterError("resolve_failed")` |

`create` is `bookmarkData(options: [.withSecurityScope], …)`. `resolve` is
`URL(resolvingBookmarkData:options:[.withSecurityScope]:…)` followed by
`startAccessingSecurityScopedResource()`, and the URL is kept in a `static
Set<URL>` for the **lifetime of the process** with no balancing
`stopAccessing…`. That is deliberate: the access is not a single read — the
walk lists the tree, the extractors open every changed file, and a draft may
read one again minutes later — so scoping it to any one of those would revoke
it under the next. A `Set` so a directory resolved on two syncs enters its
scope once.

A **stale** bookmark still answers with its path. Stale means the system wants
the bookmark re-made, not that the resolved URL is wrong, and access has
already been granted; the app re-creates the bookmark the next time the user
adds that directory.

All four entitlement files carry
`com.apple.security.files.bookmarks.app-scope` beside
`files.user-selected.read-write`. Keep the pairs in step — the two `Signed`
variants differ from their defaults only by `keychain-access-groups`, and the
comments at the top of each file say so.

## Registering it: the Settings flow

**Settings → Context directories** (`docs/settings.md`) is the library, and it
is the only place a directory is added or forgotten. The section is in **both
scopes**, because what the model may read is a question about the model.

**Add directory…** is four steps in one order that matters:

1. `FileDialogs.chooseDirectory()` — the open panel, which IS the sandbox's
   grant.
2. `DirectoryAccess.bookmark(path)`, immediately, inside that grant. A
   bookmark asked for later is an error rather than a bookmark. Null on a
   build that keeps none, which is legal.
3. `ContextStore.registerDirectory` — `INSERT OR IGNORE` keyed on the path
   hash, so re-adding the same folder is the same row.
4. `requeueWork('context_reconcile', 'local', id, payloadJson:
   '{"force":true}')` and a `pump()`. Forced, because the person is standing
   in front of it and the sixty-second freshness rung would otherwise answer
   `fresh`.

**Re-read now** is steps 3–4 again, as ONE `requeueWork`. It is an upsert on
the work row's primary key `(task_kind, source, entity_id)`: it inserts a row
where there is none, moves a `done` or `error` one back to pending with this
payload, and leaves a `pending` or `processing` one exactly where it is. That
is every state a work row can be in, so nothing follows it — an `enqueueWork`
after a `requeueWork` is dead code.

**Summaries switched ON** queues the same forced pass. The digests are queued
by the reconcile pass and by nothing else, and the pass answers `fresh` for a
minute, so without it the switch looks like it does nothing. Switching it off
queues nothing: the digest handler declines a directory whose switch is off,
and the rows it leaves `pending` are what makes turning it back on pick up
where it stopped.

Every one of those writes lives in
`app/lib/providers/context_provider.dart` (`ContextDirectoriesActions`); the
section and the screen above it are prop-only. `contextDirectoriesProvider` is
the read model — one `ContextDirRow` per directory carrying its link, passage
and embedded counts — and it re-reads on every recorded activity event, the
same liveness mechanism `syncStampsProvider` uses.

An **identity wipe** drops `context_links` and keeps everything else. Both
doors call it: `IdentityGuard`'s `onWipe` in `app_providers.dart`, and
`_signOut` in `inbox_screen.dart`. See **Sign-out** below for why.

## The walk

`app/lib/services/context/context_walk.dart` is pure over `dart:io` and is
the only part of this feature that touches the file system. It runs on every
sync against every registered directory, so the ordinary pass is a stat walk:
the only bytes it opens are the first 8 KB of a text candidate.

| Rule | What it does |
|---|---|
| `contextDenylist` | `.git`, `node_modules`, `.dart_tool`, `build`, `dist`, `.venv`, `__pycache__` — skipped wherever the directory name appears |
| the dot rule | any directory whose name starts with `.` is skipped, EXCEPT `.claude` |
| `contextFileDenylist` | `*.lock`, `.env*`, `*.pem`, `*.key` — matched against the file's NAME at any depth, because a `.env` three folders down is still a secret |
| `.bondignore` | one glob per line at the root, `#` comments, blank lines; matched against the rel path |
| `.gitignore` | the same subset, honoured **only** when `honor_gitignore` is on |
| symlinks | never followed — a link to a parent is a walk that never ends, and a link out of the folder is a path the user never granted |
| text allowlist | an extension list plus the four names with no extension (`CLAUDE.md`, `README`, `Makefile`, `Dockerfile`); everything else is LISTED with `isText = false` |
| `maxContextFileBytes` | a text candidate over 4 MB is listed and not read (`reason: too_large`) |
| the NUL sniff | a 0 byte in the first 8 KB demotes the file (`reason: binary`) |
| `maxFiles` / `maxTextBytes` | 5,000 files and 50 MB of text per directory |

**The recursion is explicit, and both reasons matter.** A denied directory is
pruned before it is entered, so a `node_modules` of fifty thousand files is
never listed rather than listed and filtered once a minute; and a folder the
permissions will not open is counted and stepped over, where
`Directory.list(recursive: true)` would put a `FileSystemException` into the
stream and leave the whole project unindexed over one folder. `skipped`
counts a pruned or unreadable DIRECTORY once, not once per file inside it.

**`.gitignore` is off by default, deliberately.** Claude Code analyses land in
gitignored `output/` and `reports/` folders — the very files this feature
exists to read. The hard denylists and `.bondignore` apply either way.

**When a cap bites, precedence decides what survives**: everything under
`.claude/`, then every `CLAUDE.md`, then every `README*`, then everything
under `docs/`, then the rest by path. A directory too large to index whole
should still index the part that says what it IS. `WalkResult.truncated` says
so, and the byte cap DEMOTES a file rather than dropping it — the row stays,
so the next pass does not rediscover it as new.

`contextKindFor(relPath)` classifies from the path alone, because the answer
decides how the file is chunked and both have to be settled before anything
reads a byte:

| Path | Kind |
|---|---|
| `CLAUDE.md` at any depth | `claude_md` |
| `.claude/skills/<name>/SKILL.md` | `skill` |
| `.claude/rules/*.md` | `rule` |
| `.dart .py .js .ts .sql .sh .go .rs .java .kt .swift .rb .r .c .h .cpp .cs .php` … | `code` |
| `.csv .tsv .json .parquet .xlsx` | `data` |
| `.md .markdown .txt .rst .html .htm .ipynb .yaml .yml .toml .xml` | `doc` |
| anything else | `other` |

`claudeChainFor(relPath, claudeMdPaths)` returns every `CLAUDE.md` above a
file, root first — Claude Code's own on-demand rule. It is stored per row
(`context_files.claude_chain`) so a retrieved passage can arrive with the
notes that govern its subtree attached, without the app having briefed every
nested `CLAUDE.md` in the project.

## The extractors

`app/lib/services/context/context_extract.dart`, pure, capped at
`maxContextTextChars` = 1,000,000 (head, `truncated` set). Decoded as UTF-8
with `allowMalformed: true`: one wrong glyph beats a `FormatException` that
costs the whole file.

| Shape | What comes out |
|---|---|
| `.html` `.htm` | a tag stripper — see below |
| `.ipynb` | markdown cells verbatim, code cells fenced, `stream` and `text/plain` outputs kept, images dropped; a malformed notebook falls back to its raw text |
| `.csv` `.tsv` | the header and 40 rows, then `[… N more rows]` |
| everything else | as-is |

**The HTML extractor is a stripper and not a DOM, deliberately.** There is no
HTML parser in this app's dependencies (`xml` is XML-only and throws on the
first unclosed `<br>`). The order matters: comments first, then every matched
`<script> <style> <svg> <noscript> <head>` block, then any UNCLOSED one
running to the end of the file — a page that was truncated mid-download ends
inside its `<script>`, and without that third sweep the tag alone is stripped
and the JavaScript is indexed as English. Only then do block tags become
newlines (`h1`–`h6` prefixed with `#`×level, `td`/`th` closed with a tab),
`alt` / `aria-label` / `title` text is lifted onto its own lines, remaining
tags go, and entities are decoded — `&amp;` LAST, so a double-escaped
`&amp;lt;` becomes `&lt;` and not `<`.

The case it exists for is a Plotly export: megabytes of embedded JavaScript
wrapped around one page of findings. Only the page survives.

## The chunker

`app/lib/services/context/context_chunker.dart`, pure and **deterministic by
contract** — the same text and the same code produce the same passages, in the
same order, with the same locators. `replaceChunks` is a delete and an insert,
so a pass that re-derives the same list replaces the passages with themselves
rather than doubling them, and a park on the embedding server resumes instead
of restarting.

| Shape | Cut on | Locator |
|---|---|---|
| markdown (`.md`, `.markdown`, `CLAUDE.md`, `SKILL.md`) | ATX headings, then the paragraph packer | `Pricing > Q4 rates`, plus ` · part 2` when a section needs more than one passage |
| code, and `.yaml .yml .toml .json .xml` | 60-line windows, 10 overlapping | `lines 61–120` |
| everything else | the paragraph packer | `part 2`, or empty for a single passage |

The breadcrumb is the deepest path and not just the last heading, because a
project has four sections called "Notes" and a citation that says which one is
the difference between a checkable claim and a shrug. A heading closes every
deeper one, and headings inside a fenced code block are Python comments rather
than sections.

The paragraph packer is `packProseChunks` in
`app/lib/services/attachments/attachment_chunker.dart` — the app's ONE packing
rule (~1,000 chars, ~150 chars of overlap trimmed forward to a word boundary),
reused rather than copied so the two cannot drift.

**Every stored passage opens with a contextual header** — `<rel path> ·
<locator>` on its own first line, or `<rel path>` when there is no locator. It
is deterministic (no timestamp, no counter) and it is STORED rather than added
at read time, because the embedding has to carry it: a paragraph about "the Q4
number" is near every other paragraph about a Q4 number in every project, and
the path is what makes it near the right one. Capped at
`maxChunksPerContextFile` = 60.

## The reconcile pass

`ContextReconcileHandler` (`app/lib/services/context/context_reconcile_handler.dart`),
kind `context_reconcile`, source `local`, concurrency 1 — two passes over one
directory would each be deciding what changed against a table the other is
rewriting.

The ladder, in order:

1. **The row is gone** — the user de-registered the folder between the
   enqueue and the claim. `skipped`, reason `gone`.
2. **`walked_at` is inside `freshFor` (60 s) and the payload is not
   `{"force": true}`** — `skipped`, reason `fresh`. The enqueue happens on
   every sync and a Re-read now lands beside one; without this rung a hurried
   minute walks the same folder three times.
3. **Resolve the root.** A stored bookmark first (`DirectoryAccess.resolve`);
   null falls through to the stored path. A path that does not exist, or a
   directory the sandbox will not list, sets `status = 'unavailable'` with a
   sentence and stops. **The index is kept** — the folder may come back, and
   throwing it away would make a reconnected disk cost a full re-read.
4. `status = 'reading'`, then the walk — everything from here to step 9 runs
   inside a `try`, because only step 9 clears `reading` and a throw in
   between would leave that on the Settings row for good, long after the
   worker had spent its two attempts. Anything but `LlmUnavailableException`
   writes `status = 'error'` with the sentence, then rethrows so the work row
   still records the failure.
5. **The diff.** `(size, mtime)` unchanged → the row is touched and nothing
   is opened. Otherwise the bytes are hashed once. An unchanged hash costs the
   hash and nothing more. A hash that matches a row the walk NO LONGER SEES is
   a **move**: `renameFile` keeps the row's id, and therefore its passages,
   its vectors and its digest. A move that changes the file's KIND —
   `notes/thing.md` filed as `.claude/skills/<name>/SKILL.md` — re-reads the
   conventions off the bytes already in hand (`_conventionsFor`, shared with
   the edited branch) and clears the description vector on either side of the
   change, so step 8's tail embeds the new one and never keeps the old.
   Everything else is new or edited, and only that branch reads words: extract → `upsertFile` → `setFileText` →
   `chunkContextText` → `replaceChunks` → `resetFileDigest`. The row's
   `status` carries the extractor's verdict — `ok`, or `truncated` when a cap
   bit — so nothing downstream presents part of a file as the whole of one.
   A rename also calls `invalidateKeywordRows`: the passages are kept, so the
   word index's backfill fence never moves and its rows would keep the old
   path; deleting them moves the count, and step 9 re-files them.
6. **Deletions.** Every stored row the walk did not account for is dropped
   with its words and its passages.
7. **Re-chaining.** A `CLAUDE.md` appearing or disappearing changes the
   standing notes for every file BELOW it, including files this pass never
   touched. Compared rather than rewritten, so the ordinary pass writes
   nothing.
8. **Embedding.** Every un-embedded passage in the directory — not only what
   this pass changed, because a previous pass may have parked part-way through
   and nothing else would notice the tail. One POST at a time under
   `EmbeddingsClient.documentPrefix`, stored with
   `EmbeddingsClient.documentModelTag`.
9. `indexPendingChunks()` and `ensureKeywordIndex()`, then
   `setDirectoryWalked` — `walked_at`, `root_hash` (one sha256 over the sorted
   `relPath|sha256` lines), the counts, `status = 'ready'`, error cleared.

**Two kinds of failure, kept apart.** A `FileSystemException` on one file is
counted in `errors` and stepped over — a permissions oddity three folders down
must never stop a project being indexed, and the row it already has is left
alone so it does not fall into the deletion sweep. An unavailable embedding
server is different: the walk is stamped FIRST (so everything read this pass
survives and the next pass finds nothing changed) and then
`LlmUnavailableException` is thrown, which parks this kind alone with no
attempt spent. `EmbedOutcome.rejected` keeps a NULL embedding and carries on.

After step 6 the pass queues what the compiled layer owes: one
`context_digest` per file still pending (capped at
`maxDigestsPerPass` = 40), and one `context_brief` for the directory. Each is
ONE `requeueWork` — the upsert on the work row's primary key, which inserts a
missing row, revives a `done` or `error` one and leaves a `pending` one where
it is. See **Digests** and **The brief**.

Between step 8 and step 9 the pass also embeds every skill description that
has no vector yet (`skillsNeedingDescEmbedding`), through the same
stamp-then-throw park the passage loop uses.

## The conventions

`app/lib/services/context/claude_conventions.dart` is pure — no `dart:io`, no
store, no clock — and it reads what a Claude Code project has already written
down about itself. **No model call touches any of this.** A project that
maintains skills and rules for Claude Code has described them once already;
asking a model to guess at the same thing would be paying for an answer that
is sitting in the frontmatter.

| Function | Reads | Answers |
|---|---|---|
| `parseFrontmatter(text)` | a leading `---`, YAML, a closing `---` | `(yaml, body)`; unknown keys KEPT, and a missing fence, a non-map document or YAML that will not parse all answer `(const {}, text)` |
| `cleanDescription(raw)` | a frontmatter value | angle-bracket runs removed, whitespace collapsed, clamped at 500; anything that is not a string is `''` |
| `skillOf(relPath, text)` | a `skill` file | `(name, description)`, or null |
| `ruleOf(relPath, text)` | a `rule` file | `(paths, description)`; a non-rule is empty on both halves |
| `resolveImports(text, read, {hops: 2, baseDir})` | `@path` lines | the notes with the imports pulled in |

**The folder name always wins for a skill.** `.claude/skills/<name>/SKILL.md`
is invoked as `<name>`, whatever the frontmatter `name` says, so a header that
has drifted from its folder would have the app matching on a word nobody can
type. A skill with no `description` falls back to the first non-blank,
non-heading line of its body, clamped at 300 — a skill with no description at
all is invisible to the cosine match a later phase runs over these.

**A rule's `paths` is read in all three shapes found in the wild**: a YAML
list, one string, or one string with commas in it. Entries are trimmed, empties
dropped, and a leading `./` stripped, because a rel path never carries one.

**`@path` imports, and the four things that are not one.** A line whose
trimmed form starts with `@` followed by a path is replaced by that file's
contents, fenced as `<!-- imported: <path> -->` … `<!-- end <path> -->`;
whatever the author wrote after the path stays as text. Not imports: a line
inside a ``` fence (a `CLAUDE.md` documenting this syntax must not import
itself into its own example), an `@` that is not at the start of the line or
is followed by whitespace, `@~/…` and `@/…` (outside the directory, and
therefore outside the index), and a relative path that normalises out of the
root. Recursion is two hops by default; a cycle, and a `read` that answers
null, both leave the line exactly as written. The result is clamped at 20,000
characters.

The reader is a CALLBACK rather than the disk, and that is load-bearing: the
brief handler runs long after the walk, on a queue of its own, against a
folder the sandbox may no longer be inside. It resolves imports through
`context_text`, so what the brief is compiled from is what the last pass
stored.

**Where the results land.** The reconcile pass computes them in the one branch
that has the words in hand — new or genuinely edited — and writes them through
`upsertFile`:

| Kind | `description` | `paths_json` | `desc_embedding` |
|---|---|---|---|
| `skill` | `skillOf(...).description` | untouched | cleared on every byte change, re-embedded at the tail of the same pass |
| `rule` | `ruleOf(...).description` | `jsonEncode(paths)` | never — a rule is matched by its globs |
| anything else | carried forward | carried forward | untouched |

Every other branch of the diff carries the stored values forward: a stat that
moved is not a frontmatter that changed.

## Digests

**On by default** (`context_dirs.digests` = 1; the Settings switch is
**Summaries**). `ContextDigestHandler`
(`app/lib/services/context/context_digest_handler.dart`), kind
`context_digest`, source `local`, concurrency 1, fast slot, 512 tokens,
temperature 0.

The entity id is `'<dirId>|<fileId>'` (`entityIdFor` / `splitEntityId`). The
directory is half of the key because the directory is what decides whether the
call happens at all — a queued item that could not say whose file it was would
have to read the row to find out it should not have been queued.

The ladder, each rung a `skipped` with a reason:

| Rung | Reason | Row after |
|---|---|---|
| the entity id is not two halves | `malformed_entity` | — |
| the file is gone, or belongs to another directory | `gone` | — |
| the directory is gone | `gone` | — |
| `digests` is off | `off` | **left `pending`** — the switch can go back on |
| the digest is already `done` | `already_digested` | unchanged |
| `text_chars` < 200 (`ContextStore.digestMinChars`) | `too_short` | `skipped` |
| the row claims words the table does not have | `no_text` | `skipped` |

Then one call, and two writes. `digest_json` / `digest_status = 'done'` on the
file row, and the digest APPENDED as a passage of the file: locator `digest`,
text `<relPath> · digest` + purpose + findings + questions, carrying the
chunker's own header convention so the renderer strips the first line and
cites `rel_path` off the file row. The vector is of that STORED text, header
line and all, because the reconcile pass's tail embeds `chunk_text` verbatim
when it picks this passage up un-embedded — two paths writing one row's
vector have to send the same string.

**The digest passage is NOT filtered out of excerpts.** It is a model's
summary of the owner's own work, labelled `digest` where it is cited, and it
is the one passage a question about FINDINGS can land on — a question about a
conclusion very rarely shares vocabulary with the code that produced it.

**An embedding server that is down does not throw here**, unlike in the
reconcile pass: the model call is already paid for, and parking the kind would
put it at risk of being spent twice. The passage keeps a NULL embedding, which
is invisible to the index and to every KNN until something re-reads the file.
A fast slot that is down DOES park, leaving `digest_status = 'pending'`.

**The cap paces a new project.** `maxDigestsPerPass` = 40 per reconcile pass,
worklist `digest_status = 'pending' AND text_chars >= 200` ordered by
`updated_at DESC, id` — the freshest edits first, because what the owner wants
read first is what they were last working on. The drain runs every handler to
EXHAUSTION in registration order and the three context kinds sit ahead of the
storylines and the drafts, so the cap is not a rate: it is how many fast-slot
calls one pass may spend before the drafts run, about a minute of fast-slot
time at the sync cadence. A backlog past the cap lands on the following
passes, and that is why the brief is queued whenever THIS PASS queued anything
rather than only when the disk moved.

**A digest the model cannot answer closes its own file row.** The reconcile
pass revives a `done` or `error` WORK row on every pass, so the work row
cannot be the memory that the model gave up. When the failure is FATAL the
handler writes `digest_status = 'error'` before it rethrows, and
`filesPendingDigest` reads `pending` only — so the file leaves the worklist
until its bytes change and `resetFileDigest` puts it back. Fatal is
`AiWorker.isFatal`, the worker's own rule and not a restatement of it: a 400
from a `json_schema` request is fatal on the FIRST attempt, everything else
once `maxAttempts` is spent. Two copies of that rule would be a file row
left `pending` against a work row already written `error`.

## The brief

**One per directory.** `ContextBriefHandler`
(`app/lib/services/context/context_brief_handler.dart`), kind `context_brief`,
entity the directory id, fast slot, 768 tokens, temperature 0.

Two inputs, and only two:

1. the root `CLAUDE.md` with its `@` imports resolved, read through the index;
2. the digest map — up to 200 rows carrying `digest_json`, newest first, one
   line each as `path · purpose · questions`, clamped at 8,000 characters. A
   row whose JSON will not decode is dropped rather than rendered as a bare
   path.

Nested `CLAUDE.md` files are deliberately NOT briefed. Each file row carries
its own `claude_chain`, and the nested notes ride along with a retrieved
passage instead — Claude Code's own on-demand rule, and zero extra calls per
subtree.

**Neither input** → `setDirectoryBrief(null, null)` and `skipped`, reason
`nothing_to_brief`. Cleared rather than left alone: a project that lost its
notes must not keep handing replies the guidance it used to give.

**The hash is what keeps this to one call.** `sha256(claudeMd + ' ' +
fileMap)`; equal to `brief_hash` → `skipped`, reason `unchanged`. It is
written only WITH the brief it describes, so a call that failed leaves the
previous hash and the previous brief exactly where they were. That hash is
what makes the reconcile pass free to queue this kind on every pass that
queued anything.

The stored `brief_json` is `ContextBrief`: `about` (≤400), `reply_guidance`
(≤6 × 200), `key_facts` (≤8 × 200), `pointers` (≤10 `{topic, path}` pairs),
`vocabulary` (≤12 × 60). `pointers` is the one array of OBJECTS in any schema
this app sends, so it carries no `minItems`/`maxItems` — the grammar converter
handles those on arrays of scalars only — and its ceiling holds in `validate`.

Settings shows `about` under the path, and `summaries K of M` in the status
line whenever the switch is on and the count is behind.

## The two derived indexes

Both are lazy, both are built at first use, and **neither is ever created in a
migration or in `beforeOpen`** — drift's `SchemaVerifier` diffs the whole of
`sqlite_master`, so a virtual table appearing during a step fails every
migration pair in the suite.

| Index | Table | Shape |
|---|---|---|
| `ContextChunkIndex` (`app/lib/data/context_chunk_index.dart`) | `vec_context_chunks` | vec0, `float[768] distance_metric=cosine`; scope applied INSIDE the KNN as `file_id IN (SELECT id FROM context_files WHERE dir_id IN (…))` |
| `ContextKeywordIndex` (`app/lib/data/keyword_index.dart`) | `fts_context_chunks` | fts5 `(path, body, chars UNINDEXED)`, weights `[2.0, 1.0, 0]`, porter unicode61; scope applied INSIDE the ranked query as `rowid IN (SELECT c.id FROM context_chunks c JOIN context_files f …)` |

A third pair rather than more rows in the attachment indexes, and the reason
is what each corpus is FOR: an attached document is scoped by the thread that
carried it, where a registered directory is scoped by a link the user made,
belongs to no message, and is re-read on every sync. Mixing them would mean
every scope predicate naming a column the other half does not have.

Both are derived and disposable: losing one costs `ContextStore.rebuildIndexes()`
and not one model call, because every float and every word is already stored.
That rebuild is also the only cleanup for the rowids `replaceChunks`,
`deleteFiles` and `removeDirectory` orphan — vec0 has no cascade and FTS5 no
foreign key, so an orphan hydrates to nothing through the join and is dropped.

`removeDirectory` DOES reach the queue, in the same transaction: the
`context_reconcile` and `context_brief` rows for the directory and every
`context_digest` row whose entity id starts `<dirId>|`, since work naming a
directory nobody registered only wakes a handler to say `gone`. A row a
worker is holding (`processing`) is left alone — taking it out from under a
running handler is the one way to make the drain's bookkeeping wrong, and
that handler's own `gone` rung is already the right answer for it.

The keyword index's backfill is fenced behind three cheap numbers (count, max
id, `SUM(chars)`), which is what makes it affordable on every read. The
residual it accepts: a re-chunk landing on exactly the same ids with exactly
the same total length and different words is not noticed until something else
about the table moves.

**The scope goes inside the neighbour search.** Filtering afterwards gives the
k nearest passages in every project the user owns that happen to be in scope,
which on a library of several projects is regularly none of them. An empty
scope answers `const []` before any read at all: a caller that cannot say
which room it is on must not be handed one client's notes for another client's
reply.

## Serving: the context pack

Everything above is the index. This is the read a REPLY makes against it —
`ContextRetriever.packFor` (`app/lib/services/context/context_retriever.dart`),
run **once** per draft by `DraftHandler` and handed to both model calls, for
the reason the attachment excerpts are: the decision and the draft ask about
the same message on the same thread, and a second pass would be a second
embedding call for an answer that cannot come back different.

It answers a `ContextPack`: a brief line per directory, an ordered list of
guidance blocks, the passages that fit, the names of the skills that matched,
and `directories` — the display names of the directories that CONTRIBUTED one
of those, in scope order and said once each. Contributed, not "in scope": a
room can link a project registered a minute ago that holds no brief and
nothing indexed, and `directories` is what the provenance row and the
composer's caption name. A caption saying a reply was drafted from «acme»
when not one of acme's words reached the prompt is a claim about the model
that is not true, so `pack.directories` non-empty implies something rendered.

**Nothing in it throws.** A draft is the product and the directory is what
makes one better, so every failure returns the pack built so far — a
directory whose brief was read and whose index then fell over still says what
the project is. The handler above notes the reason as `context_error`.

The steps, in this order and no other:

1. **Scope.** `dirIdsInScope(source, conversationKey, storylineIds)` — this
   thread's own links UNION every link on a storyline it belongs to. An empty
   scope answers `ContextPack.empty` **before any other read**: no query, no
   vector, no embedding POST. That is the overwhelming majority of rooms.
2. **The directories.** One row each, skipping a link whose directory was
   removed between the two reads. Any whose `walked_at` is null or older than
   `ContextTuning.staleAfter` (10 minutes) is `requeueWork`'d for a reconcile
   and **never awaited** — the reply being drafted reads what the last pass
   indexed, and waiting on a file-system walk would put a folder between a
   person and their draft.
3. **The briefs.** `ContextBrief.decode` per directory: `about`, `key_facts`
   and `vocabulary` become the brief line; `reply_guidance` becomes a
   `guidance` block. With more than one directory in scope every guidance
   label is suffixed `«name»`, because two projects both carrying standing
   notes would otherwise hand the model two identically-labelled blocks of
   contradictory instructions.
4. **Root `CLAUDE.md`, only when there is no brief.** The brief was compiled
   FROM those notes (§The brief), so both would be the same instructions
   twice — once summarised and once whole. Clamped to
   `ContextTuning.rootClaudeMdCap` (800).
5. **The `LIMIT 1` guard.** `hasChunksInScope` before any vector work, the
   same rung `AttachmentRetriever` keeps: a directory registered a minute ago,
   or one holding nothing but binaries, has a brief and no passages.
6. **The query vector.** `replyToQueryVector` — the reply-to message's own
   stored vector under the current model tag, else the same card re-embedded
   under `documentPrefix`, never the query prefix. It is a top-level function
   in `attachment_retriever.dart` because the documents and the directories
   are two corpora searched with ONE question, and a draft that embedded the
   same card twice would pay for one answer twice. `DraftHandler` makes that
   literal: it memoises one call to it and passes the closure to both
   retrievers as `queryVector`, and each of them calls it only after its own
   `LIMIT 1` guard, so a room with an empty index still costs no POST. A
   retriever handed no closure builds its own vector. A null vector costs the
   passages and the skills; the brief still stands.
7. **Fusion, per PASSAGE.** `chunkKnn(k: k * 2)` and `keywordChunks` are
   merged on `chunk_id` with the app's own arithmetic —
   `0.5·vectorRelevance(distance) + 0.5·keywordRelevance(bm25, best,
   coverage)`, floor `SearchTuning.minScore` — and NOT with RRF, for the
   reason `05-embeddings.md` gives. Per passage rather than per file is the
   difference from `fuseDocuments`: a search names documents, and this quotes
   paragraphs. The keyword text is the extraction's `topics + project +
   organizations` plus the subject with its reply markers off; a message with
   neither is answered by the vector half alone. Ties break on `chunk_id`, so
   two identical drafts read the same prompt.
7b. **A named file is READ, not merely ranked.** `consultFirst` is not a
   re-sort of the neighbour page. That page is a dozen passages wide and a
   file somebody pointed at is usually not on it — which is why they pointed
   — so each named file is asked for its own nearest passages with a second
   `chunkKnn(fileIds: …)`, scoped by BOTH the directory ids and the file ids,
   so naming a file is never a way past the directory scope. A named file the
   vector index cannot answer for — no vector written yet, the native index
   missing, the embedder down — is read from the top by `chunksForFile`,
   because reading from the top is what "read this file first" means when
   nothing knows which part is nearest. This is also why a pass with no
   question at all still builds a pack when a file was named: finding it never
   needed the question. Skills are the one thing such a pass adds nothing of,
   since a skill is chosen by nearness to the question.
8. **The order after the floor**: the files the caller named in
   `consultFirst` are READ before the ranking runs (see step 7b), and their
   passages float to the front (stable, and exempt from the floor — a person
   saying "read this" outranks a score), then at most `perFile` passages per
   file,
   then the top `k`, then a character budget of 2,500. A passage that does not
   fit is SKIPPED rather than ending the list, so one long passage cannot hide
   the three short ones behind it. The 80-character allowance per passage is
   the bracket line the renderer writes above it.
9. **The digest passage is NOT dropped** — the one place this differs from the
   attachment path (D7). An attachment digest summarises a stranger's
   document and the fence above it promises excerpts; a directory digest
   summarises the OWNER'S own file and is very often the only passage that
   answers a question about what an analysis found. It rides, labelled
   `digest (a model's summary of this file)`.
10. **Skills.** `ContextStore.skillVectors(dirIds)` returns every `kind =
    'skill'` row in scope that has a `desc_embedding`, with the blob; the
    cosine distance from the query vector decides. At most
    `ContextTuning.maxSkills` (2) within `skillMaxDistance` (0.60) — looser
    than the passage floor, because a skill's description is one sentence
    about a KIND of message being compared against a whole message card. The
    block is the description then the body, clamped to `skillBodyCap` (600):
    a model reading the steps without the sentence saying when they apply is
    reading steps for nothing. The NAME is resolved before a slot is spent,
    not after: a skill with neither a frontmatter name nor a folder above it
    cannot be rendered, and one that took a slot and then dropped out of it
    would cost the second-nearest skill its place for a block nobody sees.
10b. **Look closer.** The one model call this read makes, in its own
    `try`/`catch`: up to two sections read WHOLE and up to two skills, in
    front of the ranked passages. It is the next section of this page, and it
    is placed HERE, before the two steps below, on purpose — a section pulled
    in from a pointer is a file the ranking never surfaced, and the notes and
    the rules that govern it are gathered from the excerpts as they finally
    stand.
11. **Nested `CLAUDE.md`.** For each kept passage's file — the expanded
    sections included — its `claude_chain`
    minus the root entry, de-duplicated in first-seen order and keyed by
    directory. Clamped to `nestedClaudeMdCap` (400). Claude Code's own
    on-demand rule: notes beside a file apply to that file, and are read when
    it is.
12. **Rules.** `ContextStore.rulesFor(dirId)` reads the rule rows of a
    directory as rules — a project is tens of thousands of files of which a
    handful are rules, and this runs on every draft that kept a passage, so
    the predicate belongs in the query rather than in Dart. One applies when
    any glob in its `paths_json` matches the rel path of any passage the pack
    ENDED with, expanded sections included, **in its own directory** —
    `docs/**` in one project has nothing to say about another project's
    `docs/`. A malformed list or a glob `package:glob` will not parse means
    "this rule does not apply here", never a draft that failed. Clamped to
    `ruleBodyCap` (400).

**Guidance order in the pack**: the brief's `reply_guidance`, the root notes
(when there is no brief), the nested notes, the matched skills, the rules.
Broad to narrow, which is the order a person would read them in.

## Look closer: select-expand

Six passages of a thousand characters can miss the one section that carries
the number, and no ranking can know it has: a section is near a question
because of what it is about, and the sentence with the figure in it is the one
sentence in it that is not. So the last step of `packFor` shows the model what
was found and asks whether it wants to read any of it properly.

**Trigger** — all three: the retriever was built with a fast client; the
preference `context_select_expand` is on; and the pack has either a brief with
pointers OR at least `ContextTuning.selectMinCandidates` (8) ranked passages.
A pack WITH pointers qualifies however short its ranking is — a pointer names
a file the neighbour page may never have reached — and a pack without them and
only a handful of passages does not, because choosing two of five the model
can already see in full is a call spent reordering a short list. There is
never a second embedding POST: this call reads only what is already in hand.

**Which is why it also runs with no vector at all.** The embedding server
being down, or a message the embed queue has not reached, ends the ranking —
`query` is null and there is nothing to rank — but it does not end this. The
pointers are already decoded from the briefs and the selector chooses by
reading them, so a pack whose only signal is a brief saying *renewal rates ·
docs/pricing.md* still gets that file read whole. The one thing that does end
it earlier is the `LIMIT 1` guard at step 5: the text and the passages are
written by the same reconcile pass, so a directory with no passages has no
section to hand back either.

**The notes and the rules are gathered after it**, which is the whole reason
this step sits where it does in the list above. A section pulled in from a
pointer is a file the ranking never surfaced, so gathering them first would
give the model a `docs/CLAUDE.md` for every file except the one it asked to
read. They run after the step's own `try`/`catch`, so a selector that fell
over still gets them over the ranked list.

**Input** — four fences (`ContextSelectTask`), each empty half omitted:

| Fence | What it holds |
|---|---|
| `message` | the subject with its reply markers off, then the body, clamped to 1,500 |
| `pointers` | `topic · path` from every brief in scope, ≤ 10 |
| `skills` | `name · description` for every skill in scope, ≤ 12 — `ContextStore.skillsFor`, which does NOT require a `desc_embedding`: the embedder being down must not hide a project's own instructions |
| `candidates` | `path · locator · first words` for ≤ 12 ranked passages, the preview whitespace-collapsed and clamped to 120 |

The candidates come from `_rank`'s `ordered` — every passage that cleared the
floor, BEFORE the per-file cap and the take — because a file whose three best
passages the cap trimmed to one is exactly the file worth reading whole. Each
path is the FILE row's, never the passage's stored header line, which a rename
can leave stale.

**Answer**: `{read: [{path, locator}] (≤2), skills: [string] (≤2), reason}`, at
temperature 0 and 256 tokens. Empty, malformed or thrown → the pack exactly as
it was.

**The section reader** is `contextSection(relPath, text, locator)` in
`context_chunker.dart` — pure, and deciding the shape by the same path rule
the chunker cuts with, so a file chunked as markdown is read back as markdown:

- **markdown** — the section whose breadcrumb is the locator, plus every
  following section nested UNDER it: the whole of `## Pricing` carries its
  `### Q4 rates` with it. A trailing ` · part N` is stripped first. An empty
  locator is the whole file; a breadcrumb this text does not have is `null`.
- **`lines a–b`** (either dash) — line `a` through two windows on, not one,
  because a function rarely ends where the sixty-line window it was cut at
  did. Malformed is `null`.
- **anything else** (`part N`, `digest`, empty) — the whole text.

Each section is clamped to `ContextTuning.expandedSectionCap` (3,000) — three
times a ranked passage, because the point of asking to read something whole is
that a thousand characters of it was not enough.

**Placement**: the chosen sections go to the FRONT of the excerpts, flagged
`expanded`, and the renderer says `Pricing, read in full` in the bracket line.
That flag changes what a model may conclude from a silence: a ranked passage
that does not carry the number is an extract that does not carry it, while a
section read in full that does not is a section that does not. Then the
passages the section already CONTAINS are dropped — the same locator, one of
its ` · part N` passages, any deeper breadcrumb under it, every passage of the
file when the locator was empty, and a line window that falls ENTIRELY inside
the expanded span. That last one is the case the breadcrumb rules cannot see:
a code file is cut every fifty lines into sixty-line windows while the reader
hands back a hundred and twenty, so an expanded `lines 61–120` really covers
61 to 180 and the ranked `lines 101–160` is sixty duplicated lines. Entirely
is the test — a window that only overlaps the tail still carries lines the
section does not, so it stays. A paragraph quoted beside the section it was
cut from reads as two sources saying the same thing, and spends the fence
twice. The sections have their own ceiling (two × 3,000); the ranked tail
keeps the `budgetChars` it was already trimmed to, and nothing re-budgets.

**Two reads that overlap each other are one read.** An answer naming both
`Pricing` and `Pricing > Q4 rates` has named one thing and part of it, and
expanding both would put the child's text in the fence twice — the very
duplication the drop rule exists to prevent. The larger wins either way round:
a read already held by a section taken is skipped, and a read that holds one
taken earlier replaces it, its label with it.

**Skills**: an answered name is matched against the folder name of a skill in
scope, exactly and case-sensitively — a near-miss is a name the model made up.
The folder name is also what the model was SHOWN and what the rendered block
is labelled with, because `skillOf` resolves a skill to the segment above its
`SKILL.md` whatever the frontmatter says (§The conventions). One name, three
places: that is what makes the check below a real de-duplication rather than a
comparison of two spellings of the same file.
One already offered by the cosine is skipped; otherwise it goes FIRST, and the
list is then cut to `ContextTuning.maxSkills` (2). The picks DISPLACE the
cosine's second-nearest rather than stacking on top of it, for the reason that
ceiling exists at all: three sets of instructions about three kinds of message
is a draft obeying whichever one it read last.

**Scope, again.** Each answered path is resolved with
`ContextStore.fileByPath` per directory in scope order (a leading `./` tried
too); the first hit wins, and a file whose `dirId` is not in scope is skipped.
A path the model spelled is a path the model could have invented.

**Failure is unchanged plus a note.** The whole step sits in its own
`try`/`catch` inside `packFor` — not under the outer one, which would hand
back a pack that had never run the rules — and it builds every new list
locally, committing them only at the end. So a throw half way through leaves
the excerpts, the skills and the guidance exactly as the ranking left them,
and `ContextPack.selectError` carries the sentence for the activity row.

**The fence grows, on the draft side only.** `directory_excerpts` is 8,700 in
`draft_task.dart`: 2,500 of ranked passages plus exactly two 3,000-character
sections and the two bracket lines the render writes above them. It is a
ceiling for a pack that asked to read closer, not a target.
`reply_decision_task.dart` stays at **800** — the decision reads the head of
the first section, which is the most relevant text there is, and a yes-or-no
about whether a reply is owed needs no more than that.

**The preference** is `AppPrefs.contextSelectExpand`, key
`context_select_expand`, default **ON** — the one bounded call per
directory-fed draft is the whole feature. It reaches the retriever as a
closure (`services/` never imports `providers/`), read while a pack is being
built, so flipping it rebuilds nothing. The switch is in Settings → Context
directories: *Let the model pick two sections to read in full before
drafting*.

## Linking

`context_links` is the only table tying a directory to anything, and the panel
that writes it is the sixth `SidePanel` kind, `ContextPanel`
(`app/lib/widgets/context_panel.dart`). A **Context** action on the thread
header and on the storyline header opens it beside the room; from a thread
that is itself beside, it replaces that thread, the rule every side panel
follows. The action's label carries the count — `Context · 2` — because it is
the tooltip on an icon button and a count nobody hovers is a count nobody
reads.

The body draws the WHOLE library with a switch each, not only what is linked:
the question a person opens it to answer is "should this room read that
project?", and a list of the answers cannot be used to answer it. A thread
also lists, in muted type and with no switch, what it inherits from its
storylines — that is not this thread's link to turn off, and a switch here
would unlink somebody else's storyline from inside a room that merely benefits
from it.

**Add directory… inside a room registers AND links.** Pressing Add there is
how a person says "read this here"; registering the folder and leaving the
switch off would answer a question nobody asked
(`ContextDirectoriesActions.addDirectoryTo`). **Manage directories in
Settings ›** opens the library, which is where a directory is re-read,
renamed or removed.

Two providers back the panel, both re-read on every activity event like the
library is: `contextLinksProvider(scope)` for the switches, and
`contextInheritedProvider(target)` for the muted lines.

## Consumers

Everything above builds the index and serves one reply out of it. These are
the other five places the app spends it.

### The charter offer

A directory's brief answers "what is this project", which is the other thing a
storyline's **charter** can be — and unlike the refresh pass, which reads the
member threads and says what they have in common, this reads what the owner
wrote down before any of those threads existed.

`ContextBriefHandler` takes an `onBriefChanged` callback and calls it with the
directory id **only after a new brief was written** — never on `unchanged`,
never on the clear. A callback and not the service itself, because `services/`
reaches down and never sideways: a handler importing the storyline service
would tie the directory queue to the mailbox's clustering for one sentence of
prose. `app_providers.dart` wires it to
`StorylineService.offerDirectoryCharters`; Riverpod resolves a provider when
it is READ, so reaching forward to a provider declared further down the file
is ordinary rather than a cycle.

`offerDirectoryCharters(dirId)` walks `linksFor(dirId)`, keeps the
`storyline` links, and for each live storyline (`active` or `suggested`)
applies three rules:

| State | What happens |
|---|---|
| no charter, not locked | the `about` is offered as `charter_suggestion` |
| locked, nothing parked | offered — a lock says the stored sentence is theirs, not that they never want another idea |
| locked, a suggestion already parked | untouched — they have not answered the first one |

An UNLOCKED storyline that already has a charter is the refresh pass's
business: that sentence moves with the member set, and a directory link is not
a change to who is in the group. A brief whose `about` equals the charter
modulo whitespace and case offers nothing, on the refresh's own `_normalized`
rule.

**The write is a SUGGESTION even onto an empty charter.** A charter is the
membership criteria — `recruitForCharter` hunts the mailbox on it and threads
get filed under it — so a sentence a model lifted out of a `CLAUDE.md` that
the person has never read must not start recruiting threads on their behalf.
Use this is one tap, and it is the tap that makes it theirs.

The offer is made AFTER the brief is stored and inside its own `try`: what the
handler owes the app is the brief, which a model call was already spent on, so
an offer that throws costs the offer, notes `charter_error`, and leaves the
brief standing. A pass that offered at least one charter notes
`charters_offered` with the count, and `ActivityLogPanel` appends
`· N charters offered` to the brief's line — a second sentence on the same
row rather than a row of its own, since nothing was queued for it.

### The recap line

`StorylineService.recap` appends one `⟨directory <name>: <about>⟩` line per
linked directory that has a brief, AFTER the pinned-document footer. A footer
for the pins' reason: the window is a chronology and a registered folder did
not happen on a date; last of them because it is the broadest thing in the
prompt, the project the whole story sits inside.

`about` and not the facts or the guidance — `about` says what the project IS,
which is all a summary needs; the facts are for a reply that has to be correct
about a number. A linked directory with **no brief contributes nothing**
rather than its name alone: no brief means nothing has read the folder yet,
and a bare name is a word the model would have to guess the meaning of.

### Search: `In your directories`

The third corpus on the home search (`05-embeddings.md` §Search counts them),
listed above `In documents` and above the message rows. `MessageSearch` takes an optional `ContextStore`; both passes ask
`allDirIds()` first and hand the whole list to `chunkKnn` / `keywordChunks` as
a SCOPE, because "every directory" still goes INSIDE the query — a corpus-wide
match narrowed afterwards is the mistake the scoped reads exist to prevent.

**Digests are excluded in SQL**, `excludeDigests: true`, on the attachment
search's rule (`05-embeddings.md` §Search): a search result promises the
file's own words, and a digest is a model's summary of them. The reply
retriever does NOT exclude them (D7), which is why the flag defaults to false.

Both directory reads sit in their own `try`/`catch` that yields null: a
directory index that cannot be read must never make a search of the MAILBOX
report itself unavailable or narrowed. `fuseDirectories` is `fuseDocuments`'s
arithmetic per FILE — a twin rather than a generic, because the identity
differs: a document is a blob and needs a hash, a directory file is a row and
`context_files.id` is already on the hit.

### The file panel

`ContextFilePanel` is the **seventh** `SidePanel` kind, opened by a provenance
chip, a `Files ›` row and a search tile. `contextFileProvider` resolves the
row, its directory, its words, its digest and — when a locator was named — the
stored passage under it with the chunker's header line stripped.

`ContextFilePanelBody` draws, in this order: a caption
(`<dir>/<path> · modified <age>`, plus `· truncated`), **Consult for the
reply** when the panel was opened from a room a reply can be written in, the
digest under the `AI` label, then the words. The digest sits ABOVE the words
because a person asking what is in this file is answered in one paragraph
rather than ten pages, and under `AI` because that label is the app's standing
promise about whose sentence a reader is looking at.

The located passage is a highlighted `Container` between two more
`SelectableText`s rather than a coloured span inside one: three selectable
blocks keep the copy-a-number use working, and only a widget of its own has a
`BuildContext` for `Scrollable.ensureVisible` to scroll to. Finding the
passage runs on two rungs: the whole passage verbatim, which is what the
chunker's slice usually still is, and failing that the first 60 characters
split into words and hunted with any run of whitespace allowed between them,
for the file whose extractor re-flowed the breaks between the walk that
chunked it and the walk that stored its words. No match is no highlight and
the whole file renders. The caption names the cited section as
`· § Pricing › Q4 rates` either way, because the two can disagree and a reader
who arrived by a chip is owed the name.

**Consult** calls `generate(contextFileIds: [id])`, which writes
`{"context_file_ids":[…]}` onto the draft work row's `payload_json`.
`DraftHandler._contextFileIdsFrom` reads it with `_pinnedIdsFrom`'s paranoia
plus one rule of its own — a `context_files.id` is a positive integer, so
anything else is "none named" — and passes it as `packFor(consultFirst: …)`,
where the named files are read for their own passages, bypass the relevance
floor and float to the front (see §Serving steps 7b and 8). The note gains
`consulted: N`.

### The chips and `Files ›`

`drafts.context_json` now stores `file_id` per file, written only when there
is one: a row without the key is a draft from before the chips, not a file
that was looked up and had no id. The composer draws one small `TextButton`
per file under the provenance caption, under the same gate as the caption —
once the reader types, the words are theirs. The screen caps the list at
`DraftProvenance.maxFiles`, the same three the caption names before it starts
counting, because a chip is one of those names made tappable and a fourth
would be a door to a file the sentence above it never named. The cap is taken
before the ids are filtered, so it is the first three files NAMED and not the
first three that happen to be openable. Chips and not tappable spans,
because a `TextButton` has a hit target and a focus ring and a
`TapGestureRecognizer` inside an ellipsised two-line caption has neither. The
label uses `DraftProvenance.locatorLabel`, the caption's own breadcrumb rule,
so a chip looks like the sentence above it.

`ContextPanelBody` gains a `Files ›` disclosure per row, capped at
`maxFilesShown` = 200 with a `+N more — search finds them` line under it: a
panel is not a file browser, and search is how anybody finds anything in a
project of thousands of files. The host keeps the open set in plain state and
`_clearOverlays` deliberately does not touch it — it is a preference of the
panel, not a panel.

## Where it sits in the drain

The enqueue is at the tail of the mail sync
(`app/lib/services/sync_service.dart`), right after the `storyline_sweep`
requeue and by the same means, one item per **registered** directory — linked
or not. That is what makes a directory a living context rather than a
snapshot; linked-only would mean a directory the owner links mid-conversation
cannot answer for the first minute of it. It is `requeueWork` and not
`enqueueWork` for the sweep's reason: `OR IGNORE` against a row that finished
does nothing, so the folder would be read once per launch and never again. A
requeue revives a `done` or `error` row, leaves a pending one alone so a row
still waiting from the last sync stays one item, and the handler's freshness
rung does the rest. The
count rides on the `sync_mail` activity row as `context_dirs`, and only when
it is not zero. The Teams sync is user-triggered and gets no enqueue.

`AiWorker._sources` names `local` beside `email` and `teams`. It feeds
`claimPendingWork`'s `source IN (…)`, so a source missing from that list is
work that is enqueued on every sync and never runs — silently, because the row
stays `pending` and nothing reports a queue that is never claimed.

**Three handlers, in one order that matters**
(`app/lib/providers/app_providers.dart`, after `AttachmentDigestHandler` and
before `StorylineAssignHandler`): `ContextReconcileHandler`, then
`ContextDigestHandler`, then `ContextBriefHandler`. The digests come before
the brief because the brief is compiled FROM the digest map — a drain that ran
them the other way round would compile yesterday's map. All three come before
the storylines and the drafts, so a reply written later in the same drain
reads an index and a brief that already know what changed this morning.

## Activity

`ActivityLogPanel` labels the kind **Read directory** and reads these keys:

| Key | Meaning |
|---|---|
| `files_seen` | how many files the walk listed |
| `changed` | how many were read — the number a person actually wants |
| `removed`, `renamed`, `rechained` | the other three movements, absent when zero |
| `chunks`, `embedded` | passages written, and how many got a vector |
| `errors`, `truncated` | one unreadable file, and a cap that bit |
| `skills_embedded` | skill descriptions given a vector this pass, absent when zero |
| `digests_queued` | how many `context_digest` items this pass queued, absent when zero |
| `brief_queued` | `true` when this pass queued the brief, absent otherwise |
| `reason` | on a `skipped` row: `gone`, `fresh` or `unavailable` |

A pass that PARKS on a dead embedding server writes the same map through the
same closure. It read the same folder and queued the same work, and its line
is the one somebody goes looking for.

A row counts CHANGES and not files, because a project of two thousand
unchanged files reads as `0 files changed` — which is the whole point of the
pass being cheap.

The two compiled kinds have rows of their own:

| Kind | Label | Keys |
|---|---|---|
| `context_select` | no row of its own — the pick runs inside a draft, and the `draft` row carries `expanded` (how many sections were read whole) and `select_error` (why the pick did not happen) |  |
| `context_digest` | **Directory file digest** — `<kind_hint>` | `kind_hint`, `findings`, `questions`; `reason` on a skip: `malformed_entity`, `gone`, `off`, `already_digested`, `too_short`, `no_text` |
| `context_brief` | **Directory brief** — `N files mapped` | `files_mapped`, `has_claude_md`, `pointers`; `reason` on a skip: `gone`, `nothing_to_brief`, `unchanged` |

## Sign-out

`context_links` must be deleted on sign-out: they point at conversation keys
and storyline ids `wipeAll` is about to delete. `context_dirs`, the files, the
words and the passages are KEPT — they are the user's own folders and have
nothing to do with whose mailbox was signed in. `ContextStore.unlinkAll` is
that call.

## Code

- `app/lib/data/schema.drift`, `app/lib/data/database.dart` — schema v15,
  `from14To15`.
- `app/lib/data/context_store.dart` — every read and write above.
- `app/lib/data/context_chunk_index.dart`,
  `app/lib/data/keyword_index.dart` (`ContextKeywordIndex`) — the two derived
  indexes.
- `app/lib/models/context_models.dart` — `ContextDir`, `ContextFile`,
  `ContextLink`, `ContextScopeKind`, `ContextChunkHit`, `ContextFileDigest`,
  `ContextBrief`.
- `app/lib/services/context/directory_access.dart` — the bookmark seam.
- `app/lib/services/context/context_walk.dart` — the walk, the kinds, the
  chains.
- `app/lib/services/context/context_extract.dart` — the extractors.
- `app/lib/services/context/context_chunker.dart` — the passages, and
  `contextSection`, which puts one back together whole. `parseLineLocator` and
  `expandedSectionLines` are public for the retriever's drop rule: it decides
  whether an expanded window already holds a ranked one, and a second copy of
  either would be a second answer to what `lines 61–120` means.
- `app/lib/services/context/context_reconcile_handler.dart` — the pass, the
  two enqueues and the skill-description vectors.
- `app/lib/services/context/claude_conventions.dart` — frontmatter, skills,
  rules, `@` imports.
- `app/lib/services/context/context_digest_handler.dart` — one digest per
  file.
- `app/lib/services/context/context_brief_handler.dart` — one brief per
  directory.
- `app/lib/services/llm/context_digest_task.dart`,
  `app/lib/services/llm/context_brief_task.dart`,
  `app/lib/services/llm/context_select_task.dart` — the three prompts and
  their schemas.
- `app/lib/services/context/context_retriever.dart` — `ContextTuning`,
  `ContextPack` and `packFor`: the read a reply makes.
- `app/lib/services/context/context_pack_render.dart` — the three blocks as
  the model reads them.
- `app/lib/models/draft_provenance.dart` — `drafts.context_json` and the
  composer's caption.
- `app/lib/services/attachments/attachment_retriever.dart` —
  `replyToQueryVector`, shared by both retrievals.
- `app/lib/services/draft_handler.dart` — one pack per draft, both prompts,
  the stored provenance and the activity keys.
- `app/lib/services/llm/draft_task.dart`,
  `app/lib/services/llm/reply_decision_task.dart` — the three fences and the
  widened invention rule.
- `app/lib/widgets/context_panel.dart`, `app/lib/widgets/side_panel.dart` —
  the link panel with its `Files ›` disclosure, and the sixth and seventh
  panel kinds.
- `app/lib/widgets/context_file_panel.dart` — one indexed file: the located
  passage, the `AI` digest and **Consult for the reply**.
- `app/lib/widgets/context_search_tile.dart`,
  `app/lib/widgets/home_pane.dart` — the `In your directories` list.
- `app/lib/services/search_fusion.dart` — `fuseDirectories`.
- `app/lib/services/message_search.dart` — the third corpus on the home
  search.
- `app/lib/services/storyline_service.dart` — the recap's directory footer
  and `offerDirectoryCharters`.
- `app/lib/providers/draft_provider.dart` — `generate(contextFileIds: …)`.
- `app/lib/widgets/composer.dart` — the provenance chips.
- `app/lib/widgets/thread_detail_panel.dart`,
  `app/lib/widgets/storyline_timeline.dart` — the **Context** room action.
- `app/lib/services/llm/model_slots.dart` — the three fast-slot stage rows.
- `app/lib/services/sync_service.dart` — the tail enqueue.
- `app/lib/services/ai_worker.dart` — `local` in `_sources`.
- `app/lib/services/attachments/file_dialogs.dart` — `chooseDirectory()`.
- `app/lib/widgets/activity_log_panel.dart` — the label and the sentence.
- `app/macos/Runner/BookmarkChannel.swift`,
  `app/macos/Runner/MainFlutterWindow.swift` — the Swift end of the channel.
- `app/macos/Runner/*.entitlements` ×4 —
  `com.apple.security.files.bookmarks.app-scope`.
- `app/lib/providers/app_providers.dart` — `contextStoreProvider`,
  `directoryAccessProvider`, the handler registration, the sync wiring, the
  wipe's `unlinkAll`.
- `app/lib/providers/context_provider.dart` — the read model and every write
  the library makes.
- `app/lib/widgets/settings_context_section.dart` — the library section.
- `app/lib/widgets/settings_screen.dart`,
  `app/lib/screens/inbox_screen.dart` — the section's props and their wiring.
