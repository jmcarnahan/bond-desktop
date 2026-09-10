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
> indexes, the sync-tail enqueue, the Claude conventions, the per-file digests
> and the per-directory brief all run. The linking UI and the retrieval into
> drafts are later phases of the same round and are documented as they land.

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
- `app/lib/services/context/context_chunker.dart` — the passages.
- `app/lib/services/context/context_reconcile_handler.dart` — the pass, the
  two enqueues and the skill-description vectors.
- `app/lib/services/context/claude_conventions.dart` — frontmatter, skills,
  rules, `@` imports.
- `app/lib/services/context/context_digest_handler.dart` — one digest per
  file.
- `app/lib/services/context/context_brief_handler.dart` — one brief per
  directory.
- `app/lib/services/llm/context_digest_task.dart`,
  `app/lib/services/llm/context_brief_task.dart` — the two prompts and their
  schemas.
- `app/lib/services/llm/model_slots.dart` — the two fast-slot stage rows.
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
