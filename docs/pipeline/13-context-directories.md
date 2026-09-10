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
> indexes and the sync-tail enqueue all run. The per-file digests, the
> per-directory brief, the linking UI and the retrieval into drafts are later
> phases of the same round and are documented as they land.

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
4. `enqueueWork('context_reconcile', 'local', id, payloadJson:
   '{"force":true}')` and a `pump()`. Forced, because the person is standing
   in front of it and the sixty-second freshness rung would otherwise answer
   `fresh`.

**Re-read now** is steps 3–4 again, as `requeueWork` then `enqueueWork` — the
first moves a `done` or `error` row back to pending and rewrites its payload,
the second covers there being no row at all. Both are idempotent, and either
alone would silently do nothing in one of those two states.

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
   its vectors and its digest. Everything else is new or edited, and only that
   branch reads words: extract → `upsertFile` → `setFileText` →
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

Phase 2 hangs the digest and brief enqueues off a marked seam after step 6.

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

## Activity

`ActivityLogPanel` labels the kind **Read directory** and reads these keys:

| Key | Meaning |
|---|---|
| `files_seen` | how many files the walk listed |
| `changed` | how many were read — the number a person actually wants |
| `removed`, `renamed`, `rechained` | the other three movements, absent when zero |
| `chunks`, `embedded` | passages written, and how many got a vector |
| `errors`, `truncated` | one unreadable file, and a cap that bit |
| `reason` | on a `skipped` row: `gone`, `fresh` or `unavailable` |

A row counts CHANGES and not files, because a project of two thousand
unchanged files reads as `0 files changed` — which is the whole point of the
pass being cheap.

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
  `ContextLink`, `ContextScopeKind`, `ContextChunkHit`.
- `app/lib/services/context/directory_access.dart` — the bookmark seam.
- `app/lib/services/context/context_walk.dart` — the walk, the kinds, the
  chains.
- `app/lib/services/context/context_extract.dart` — the extractors.
- `app/lib/services/context/context_chunker.dart` — the passages.
- `app/lib/services/context/context_reconcile_handler.dart` — the pass.
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
