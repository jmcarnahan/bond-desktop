import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable;
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import '../../data/context_store.dart';
import '../../data/message_store.dart';
import '../../models/context_models.dart';
import '../attachments/attachment_retriever.dart' show replyToQueryVector;
import '../conversation_state.dart' show stripReFw;
import '../llm/embeddings_client.dart';
import '../search_fusion.dart';
import 'claude_conventions.dart';

/// Every number the directory retrieval depends on, in one place.
///
/// [SearchTuning]'s neighbours rather than its members: the weights and the
/// floor are the SAME arithmetic the mailbox search was calibrated with and
/// are read from there, while everything below is about the owner's own
/// files and has no mailbox reading behind it at all.
class ContextTuning {
  const ContextTuning._();

  /// A skill is offered when the cosine DISTANCE (1 − similarity) between the
  /// reply-to message's vector and the skill's description vector is at most
  /// this.
  ///
  /// Looser than the passage floor on purpose. A skill's description is one
  /// sentence about a KIND of message ("Quote a renewal rate"), and it is
  /// being compared against a whole message card; the two are about the same
  /// thing long before they are near each other in the way two paragraphs
  /// about the same thing are.
  static const double skillMaxDistance = 0.60;

  /// At most two, because a skill's guidance is instructions the reply is
  /// asked to FOLLOW. Three sets of instructions about three different kinds
  /// of message is a draft obeying whichever one it read last.
  static const int maxSkills = 2;

  /// A directory whose last walk is older than this is re-queued — never
  /// awaited — when a draft reads it.
  ///
  /// The sync tail already queues one per poll, so this is the ladder's
  /// bottom rung rather than its only one: it catches the directory nobody
  /// has synced past in a while, and it costs the draft nothing because the
  /// pass it starts runs after this one has answered.
  static const Duration staleAfter = Duration(minutes: 10);

  /// How much of a directory's standing notes reaches a prompt when there is
  /// no compiled brief to stand in for them.
  static const int rootClaudeMdCap = 800;

  /// A nested `CLAUDE.md` governs a subtree rather than the project, so it
  /// gets half of the root's room — and there may be several of them.
  static const int nestedClaudeMdCap = 400;

  static const int skillBodyCap = 600;
  static const int ruleBodyCap = 400;
}

/// One passage of one file in a registered directory, ready to go in front of
/// a model.
///
/// [AttachmentExcerpt]'s shape for the owner's own files: a [ContextChunkHit]
/// flattened to what a prompt line actually renders, so the renderer cannot
/// reach for a chunk id or a distance and put it in a fence.
@immutable
class ContextExcerpt {
  /// The directory's display name — what a citation says out loud.
  final String dirName;

  /// Read from the FILE row rather than from the passage. A rename keeps the
  /// chunks and their vectors and only refiles the keyword rows, so
  /// `chunk_text`'s own header line can name where the file USED to be.
  final String relPath;

  /// `''`, `Pricing > Q4 rates`, `lines 61–120`, `digest`.
  final String locator;

  /// `yyyy-MM-dd`, or empty when the row carries no modification time.
  final String modified;

  /// The passage, with its `<relPath> · <locator>` header line removed: the
  /// bracket line the renderer writes says all of that already, and saying it
  /// twice spends the budget on it twice.
  final String text;

  final int fileId;
  final String dirId;

  /// The file's words were cut short by the extractor — a 1 MB head, or the
  /// first forty rows of a table. The render says so, because a reply that
  /// concludes something from a file's silence should know the file was not
  /// read to the end.
  final bool truncated;

  const ContextExcerpt({
    required this.dirName,
    required this.relPath,
    required this.locator,
    required this.modified,
    required this.text,
    required this.fileId,
    required this.dirId,
    this.truncated = false,
  });
}

/// What one directory's compiled brief says about itself, as the prompt reads
/// it.
@immutable
class ContextBriefLine {
  final String dirName;
  final String about;
  final List<String> keyFacts;
  final List<String> vocabulary;

  const ContextBriefLine({
    required this.dirName,
    required this.about,
    this.keyFacts = const [],
    this.vocabulary = const [],
  });
}

/// One labelled block of the guidance fence.
///
/// [label] is what the model is told the block IS — `CLAUDE.md`,
/// `docs/CLAUDE.md`, `SKILL vendor-replies`, `rule pricing.md`, `guidance` —
/// and it is the app's own word rather than the file's, so a project cannot
/// name a skill in a way that reads as an instruction to the layer above.
@immutable
class ContextGuidance {
  final String label;
  final String text;

  const ContextGuidance({required this.label, required this.text});
}

/// Everything the owner's own directories have to say about ONE message.
///
/// Retrieved once per draft and read by both model calls, exactly as the
/// attachment excerpts are: the decision and the draft ask about the same
/// message on the same thread, and a second pass would be a second embedding
/// call for an answer that cannot come back different.
@immutable
class ContextPack {
  /// The display names of the directories that CONTRIBUTED something to this
  /// pack — a brief line, a block of guidance or a passage — in scope order,
  /// distinct. What the provenance line names.
  ///
  /// Not "every directory in scope", which is the same distinction the
  /// composer's caption depends on: a room can link a directory that was
  /// registered a minute ago and holds nothing indexed yet, and a caption
  /// saying the reply was drafted from «acme» when not one of its words
  /// reached the prompt is a claim about the model that is not true.
  final List<String> directories;

  final List<ContextBriefLine> briefs;

  /// In reading order: the brief's own reply guidance, the root standing
  /// notes when there is no brief, the nested notes governing a retrieved
  /// passage, the matched skills, then the rules whose paths match.
  final List<ContextGuidance> guidance;

  final List<ContextExcerpt> excerpts;

  /// The names of the skills that matched. Rendered nowhere — read by the
  /// provenance row, which says which of the owner's own instructions the
  /// draft was written under.
  final List<String> skills;

  const ContextPack({
    required this.directories,
    required this.briefs,
    required this.guidance,
    required this.excerpts,
    required this.skills,
  });

  static const ContextPack empty = ContextPack(
    directories: [],
    briefs: [],
    guidance: [],
    excerpts: [],
    skills: [],
  );

  /// True when nothing would be rendered. [directories] is not counted
  /// because it cannot change the answer: a name is only in that list when
  /// one of the three lists below carries something it put there.
  bool get isEmpty => briefs.isEmpty && guidance.isEmpty && excerpts.isEmpty;
}

/// Finds what the owner's own registered directories have to say about the
/// message being answered.
///
/// **The scope is the whole safety property**, and it is the same one
/// [AttachmentRetriever] keeps: [ContextStore.dirIdsInScope] answers with the
/// directories linked to THIS thread and to the storylines it belongs to, an
/// empty scope is answered with nothing before any read, and every index
/// query below carries that scope inside it. A paragraph of one client's
/// project pasted into another client's reply is the one failure this path
/// has to be incapable of.
///
/// **Nothing here throws.** A draft is the product; what the directories know
/// is what makes one better. An embedding server that fell over, a vec0 build
/// that is not available, a file row that went away between two reads — each
/// costs the citations and not the reply, and the pack built so far is
/// returned rather than an empty one.
///
/// Not `final`, so a test can substitute a retriever that answers a fixture.
class ContextRetriever {
  final MessageStore _store;
  final ContextStore _context;
  final EmbeddingsClient _embeddings;

  ContextRetriever(this._store, this._context, this._embeddings);

  /// Everything worth putting in front of the model about this message.
  ///
  /// [consultFirst] is the "look at this file" path: file ids the user named,
  /// whose passages bypass the score floor and float to the front of the
  /// ranking. Empty is the ordinary case.
  ///
  /// [queryVector] is [AttachmentRetriever.excerptsFor]'s parameter and its
  /// contract: a caller searching both corpora with the same question passes
  /// one memoised closure and the message's card is embedded once. Null means
  /// "build it yourself". It is called only after the `LIMIT 1` guard below,
  /// so a room whose directories hold nothing indexed still costs no POST.
  Future<ContextPack> packFor({
    required String source,
    required String conversationKey,
    required String replyToId,
    required List<String> storylineIds,
    List<int> consultFirst = const [],
    Future<Uint8List?> Function()? queryVector,
    int budgetChars = 2500,
    int perFile = 3,
    int k = 6,
  }) async {
    // Five lists rather than one, because the guidance fence has an ORDER —
    // the project's own standing notes before the instructions for this kind
    // of message before the rules governing one file — and the steps that
    // fill them do not run in that order.
    // The directories in scope, in the order the scope read returned them,
    // and the ids of the ones that actually put something in the pack. The
    // two are kept apart because the second is what the provenance names and
    // the first is what the steps below iterate.
    final dirs = <ContextDir>[];
    final contributed = <String>{};
    final briefs = <ContextBriefLine>[];
    final briefGuidance = <ContextGuidance>[];
    final rootGuidance = <ContextGuidance>[];
    final nestedGuidance = <ContextGuidance>[];
    final skillGuidance = <ContextGuidance>[];
    final ruleGuidance = <ContextGuidance>[];
    final excerpts = <ContextExcerpt>[];
    final skills = <String>[];

    /// The pack as it stands. Called at every exit, including the failure
    /// one: a directory whose brief was read and whose index then threw still
    /// knows what the project is.
    ContextPack built() => ContextPack(
          directories: List.unmodifiable(_namesOf(dirs, contributed)),
          briefs: List.unmodifiable(briefs),
          guidance: List.unmodifiable([
            ...briefGuidance,
            ...rootGuidance,
            ...nestedGuidance,
            ...skillGuidance,
            ...ruleGuidance,
          ]),
          excerpts: List.unmodifiable(excerpts),
          skills: List.unmodifiable(skills),
        );

    try {
      final dirIds = await _context.dirIdsInScope(
        source: source,
        conversationKey: conversationKey,
        storylineIds: storylineIds,
      );
      // Before ANY other read, on the retriever's rule: a room with no
      // directory linked to it is the overwhelming majority of rooms, and it
      // must cost no query, no vector and no embedding POST.
      if (dirIds.isEmpty) return ContextPack.empty;

      for (final id in dirIds) {
        final dir = await _context.directory(id);
        // A link pointing at a directory that was removed between the two
        // reads. The link row is cleaned up by the remove; this is the race.
        if (dir == null) continue;
        dirs.add(dir);
        if (_isStale(dir)) {
          // Queued and not awaited. The pass this starts walks a folder and
          // may reach for two servers; the reply being drafted right now
          // reads what the LAST pass indexed, and waiting for a fresher
          // answer would put a file system between a person and their draft.
          await _store.requeueWork('context_reconcile', 'local', dir.id);
        }
      }

      for (final dir in dirs) {
        final brief = ContextBrief.decode(dir.briefJson);
        if (brief == null) {
          // No brief, so the root standing notes stand in for one. When a
          // brief EXISTS it was compiled from those very notes, and adding
          // both would hand the model the same instructions twice — once
          // summarised and once whole.
          final notes = await _rootNotes(dir);
          if (notes.isNotEmpty) {
            contributed.add(dir.id);
            rootGuidance.add(ContextGuidance(
              label: _labelFor('CLAUDE.md', dir, dirs.length),
              text: notes,
            ));
          }
          continue;
        }
        if (brief.about.isNotEmpty || brief.keyFacts.isNotEmpty) {
          contributed.add(dir.id);
          briefs.add(ContextBriefLine(
            dirName: dir.displayName,
            about: brief.about,
            keyFacts: brief.keyFacts,
            vocabulary: brief.vocabulary,
          ));
        }
        final lines = [
          for (final line in brief.replyGuidance)
            if (line.trim().isNotEmpty) line.trim(),
        ];
        if (lines.isNotEmpty) {
          contributed.add(dir.id);
          briefGuidance.add(ContextGuidance(
            label: _labelFor('guidance', dir, dirs.length),
            text: lines.join('\n'),
          ));
        }
      }

      // The cheap read before the expensive one, and the order is the point.
      // A directory registered a minute ago, or one holding nothing but
      // binaries, has a brief and no passages — and one indexed `LIMIT 1`
      // here stands in front of a vector read, two index backfills and the
      // embedding POST a message the embed queue has not reached yet costs.
      if (!await _context.hasChunksInScope(dirIds)) return built();

      // The SAME vector the documents on this thread are searched against —
      // the handler's own closure when it has one, and the same function
      // behind it either way. Two corpora, one question.
      final query = await (queryVector == null
          ? replyToQueryVector(_store, _embeddings, source, replyToId)
          : queryVector());
      // The embedding server is down, or refused the card. Degraded, never
      // thrown — and the skills go with the passages, because they are
      // matched against this very vector.
      if (query == null) return built();

      final vectorHits = await _context.chunkKnn(
            query,
            embedModel: EmbeddingsClient.documentModelTag,
            dirIds: dirIds,
            // Over-fetch: the floor, the per-file cap and the budget all
            // throw hits away below this, and a `k` here would leave the
            // list short.
            k: k * 2,
          ) ??
          // The native index is not in this build. The words alone are a
          // worse answer than both halves and a better one than nothing.
          const <ContextChunkHit>[];

      final keywordHits = await _keywordHits(source, replyToId, dirIds);
      final ranked = _rank(
        vectorHits: vectorHits,
        keywordHits: keywordHits,
        consultFirst: consultFirst.toSet(),
        perFile: perFile,
        k: k,
      );

      final files = <int, ContextFile>{};
      var spent = 0;
      for (final hit in ranked) {
        if (spent >= budgetChars) break;
        var file = files[hit.fileId];
        if (file == null) {
          final read = await _context.fileById(hit.fileId);
          // The file went away between the index read and this one. The
          // passage cannot be cited without a path to cite it by.
          if (read == null) continue;
          files[hit.fileId] = read;
          file = read;
        }
        final text = _withoutHeader(hit.text);
        // The 80 is the bracket line the renderer writes above each passage;
        // budgeting the text alone would let the headers overrun the cap the
        // prompt was sized for. `continue` and not `break`, on the attachment
        // retriever's rule: one long passage in the middle of the ranking
        // must not hide the three short ones behind it.
        final cost = text.length + _headerCost;
        if (spent + cost > budgetChars) continue;
        spent += cost;
        contributed.add(file.dirId);
        excerpts.add(ContextExcerpt(
          dirName: hit.dirName,
          relPath: file.relPath,
          locator: hit.locator,
          modified: _day(file.mtime),
          text: text,
          fileId: file.id,
          dirId: file.dirId,
          truncated: file.status == 'truncated',
        ));
      }

      await _addSkills(dirIds, query, skills, skillGuidance, contributed);
      await _addNestedNotes(excerpts, files, nestedGuidance, contributed);
      await _addRules(dirs, excerpts, ruleGuidance, contributed);
      return built();
    } catch (_) {
      // The handler above notes the failure; this one has no activity log and
      // no business having one. What it owes the caller is the half of the
      // answer that did come back.
      return built();
    }
  }

  /// The bracket line the renderer writes above each passage, in characters.
  static const int _headerCost = 80;

  /// The display names of the directories in [contributed], in scope order and
  /// said once each. Two registered folders can carry the same display name —
  /// `notes` under two different roots — and a caption that named it twice
  /// would read as two sources where there was one.
  static List<String> _namesOf(List<ContextDir> dirs, Set<String> contributed) {
    final names = <String>[];
    for (final dir in dirs) {
      if (!contributed.contains(dir.id)) continue;
      if (names.contains(dir.displayName)) continue;
      names.add(dir.displayName);
    }
    return names;
  }

  /// Whether this directory's last walk is old enough to be worth queueing
  /// another. A directory that has never been walked is infinitely stale,
  /// which is correct: it is the one most in need of a pass.
  static bool _isStale(ContextDir dir) {
    final walked = DateTime.tryParse(dir.walkedAt ?? '');
    if (walked == null) return true;
    return DateTime.now().toUtc().difference(walked.toUtc()) >
        ContextTuning.staleAfter;
  }

  /// A guidance label, with the directory named when more than one is in
  /// scope. Two projects both carrying a `CLAUDE.md` would otherwise hand the
  /// model two identically-labelled blocks of contradictory instructions.
  static String _labelFor(String label, ContextDir dir, int dirsInScope) =>
      dirsInScope > 1 ? '$label «${dir.displayName}»' : label;

  /// The root standing notes of a directory with no compiled brief, clamped.
  Future<String> _rootNotes(ContextDir dir) async {
    final file = await _context.fileByPath(dir.id, 'CLAUDE.md');
    if (file == null) return '';
    final text = await _context.fileText(file.id);
    if (text == null || text.isEmpty) return '';
    return _clamp(
      parseFrontmatter(text).body.trim(),
      ContextTuning.rootClaudeMdCap,
    );
  }

  /// The passages inside the scope whose WORDS bear on this message.
  ///
  /// The query text is what the extraction already made of the message —
  /// topics, the project, the organizations — plus the subject with its reply
  /// markers off, and in that order. It is deliberately not the message body:
  /// a body is a paragraph of function words around three content ones, and
  /// the extraction is those three content ones already picked out.
  Future<List<ContextChunkHit>> _keywordHits(
    String source,
    String replyToId,
    List<String> dirIds,
  ) async {
    final extraction = await _store.extractionFor(source, replyToId);
    final row = await _store.getMessageRow(source, replyToId);
    final words = <String>[
      if (extraction != null) ...[
        ...extraction.topics,
        if (extraction.project.isNotEmpty) extraction.project,
        ...extraction.organizations,
      ],
      stripReFw(row?['subject'] as String?),
    ];
    final query = buildFtsQuery(
      [
        for (final word in words)
          if (word.trim().isNotEmpty) word.trim(),
      ].join(' '),
    );
    // A message with no extraction and no subject — a chat, mostly. The
    // vector half answers on its own.
    if (query == null) return const [];
    return _context.keywordChunks(
      query,
      dirIds: dirIds,
      limit: SearchTuning.keywordFetch,
    );
  }

  /// The two rankings fused into one, PER PASSAGE.
  ///
  /// Per passage and not per file, which is the difference between this and
  /// [fuseDocuments]: a search names documents and this quotes paragraphs, so
  /// the thing being scored is the paragraph. The arithmetic is the mailbox
  /// search's own — half the vector's relevance plus half the words', with
  /// the same floor under it — because it was calibrated against a real
  /// corpus and a second formula here would be a second thing to re-measure.
  ///
  /// Four passes in this order and no other. The floor first, so a passage
  /// nothing is about never reaches the prompt; the consulted files next, so
  /// a file the user named is not trimmed out by a nearer one; then the
  /// per-file cap, so a fifty-chunk report is not the whole answer; then the
  /// take, which is the only step that knows how many passages were wanted.
  static List<ContextChunkHit> _rank({
    required List<ContextChunkHit> vectorHits,
    required List<ContextChunkHit> keywordHits,
    required Set<int> consultFirst,
    required int perFile,
    required int k,
  }) {
    // bm25 has no absolute scale, so relevance is measured against the best
    // score THIS query found — which is a number only the whole keyword page
    // knows.
    var best = 0.0;
    for (final hit in keywordHits) {
      final bm25 = hit.bm25;
      if (bm25 != null && bm25 > best) best = bm25;
    }

    final byVector = {for (final hit in vectorHits) hit.chunkId: hit};
    final byKeyword = {for (final hit in keywordHits) hit.chunkId: hit};
    final scored = <({ContextChunkHit hit, double score})>[];
    for (final chunkId in {...byVector.keys, ...byKeyword.keys}) {
      final vector = byVector[chunkId];
      final keyword = byKeyword[chunkId];
      final base = vector ?? keyword!;
      final distance = vector?.distance;
      final bm25 = keyword?.bm25;
      final score = SearchTuning.vectorWeight *
              (distance == null ? 0.0 : vectorRelevance(distance)) +
          SearchTuning.keywordWeight *
              (bm25 == null
                  ? 0.0
                  : keywordRelevance(
                      bm25: bm25,
                      best: best,
                      coverage: keyword?.coverage ?? 0,
                    ));
      // A file the user pointed at is exempt. They have said this is the one
      // to read, and a floor calibrated on "is this about the same thing"
      // has no standing against that.
      if (score < SearchTuning.minScore && !consultFirst.contains(base.fileId)) {
        continue;
      }
      scored.add((
        // Merged rather than picked: the fused row carries whichever signals
        // the two passes measured, and `withSignals` states the missing ones
        // as missing instead of carrying a stale number forward.
        hit: base.withSignals(
          distance: distance,
          bm25: bm25,
          coverage: keyword?.coverage,
        ),
        score: score,
      ));
    }

    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      // The chunk id breaks ties, so two passages of equal score come back in
      // the same order on every run — a prompt that reshuffled between two
      // identical drafts would be a difference nobody could account for.
      return byScore != 0 ? byScore : a.hit.chunkId.compareTo(b.hit.chunkId);
    });

    // Stable partition: the ranking survives inside each half, so "the user
    // named this file" reorders the list without re-scoring it.
    final ordered = <ContextChunkHit>[
      for (final entry in scored)
        if (consultFirst.contains(entry.hit.fileId)) entry.hit,
      for (final entry in scored)
        if (!consultFirst.contains(entry.hit.fileId)) entry.hit,
    ];

    final seen = <int, int>{};
    final kept = <ContextChunkHit>[];
    for (final hit in ordered) {
      final count = seen[hit.fileId] ?? 0;
      if (count >= perFile) continue;
      seen[hit.fileId] = count + 1;
      kept.add(hit);
      if (kept.length == k) break;
    }
    return kept;
  }

  /// The skills whose descriptions are nearest this message, and their bodies.
  ///
  /// Cosine against the SAME query vector the passages were searched with,
  /// computed here rather than in the vec0 index: there are a handful of
  /// skills in a project, the blobs are already in hand, and a second virtual
  /// table over a dozen rows would be a table to keep in step for nothing.
  Future<void> _addSkills(
    List<String> dirIds,
    Uint8List query,
    List<String> skills,
    List<ContextGuidance> guidance,
    Set<String> contributed,
  ) async {
    final rows = await _context.skillVectors(dirIds);
    if (rows.isEmpty) return;
    // Decoded once and reused: a project with thirty skills would otherwise
    // rebuild the same 768 doubles thirty times.
    final vector = decodeEmbedding(query);
    final matches = <({ContextFile file, double distance})>[];
    for (final row in rows) {
      final distance = 1 - cosine(vector, decodeEmbedding(row.embedding));
      if (!distance.isFinite || distance > ContextTuning.skillMaxDistance) {
        continue;
      }
      matches.add((file: row.file, distance: distance));
    }
    matches.sort((a, b) => a.distance.compareTo(b.distance));

    // The name is resolved BEFORE the two slots are spent, not after. A skill
    // filed at the root of a project has no folder above it to be called by,
    // and one that took a slot and then dropped out of it would cost the
    // second-nearest skill its place for a block nothing renders.
    for (final match in matches) {
      if (skills.length >= ContextTuning.maxSkills) break;
      final text = await _context.fileText(match.file.id) ?? '';
      // The FOLDER name, which is what a skill is invoked as — `skillOf`'s
      // own rule. The fallback is the same segment read directly, for a row
      // whose words the walk never stored.
      final name = skillOf(match.file.relPath, text)?.name ??
          _folderOf(match.file.relPath);
      if (name.isEmpty) continue;
      contributed.add(match.file.dirId);
      skills.add(name);
      final description = match.file.description?.trim() ?? '';
      final body = _clamp(
        parseFrontmatter(text).body.trim(),
        ContextTuning.skillBodyCap,
      );
      guidance.add(ContextGuidance(
        label: 'SKILL $name',
        // Description first: it is the author's own sentence saying when this
        // applies, and a model reading the body without it is reading steps
        // with no statement of what they are for.
        text: [
          if (description.isNotEmpty) description,
          if (body.isNotEmpty) body,
        ].join('\n'),
      ));
    }
  }

  /// The nested `CLAUDE.md` notes governing the subtrees the kept passages
  /// came out of.
  ///
  /// Claude Code's own on-demand rule: notes beside a file apply to that file,
  /// and are read when it is. The root entry is skipped because the brief —
  /// or the root block above — has already said what it says.
  Future<void> _addNestedNotes(
    List<ContextExcerpt> excerpts,
    Map<int, ContextFile> files,
    List<ContextGuidance> guidance,
    Set<String> contributed,
  ) async {
    final seen = <String>{};
    for (final excerpt in excerpts) {
      final file = files[excerpt.fileId];
      if (file == null) continue;
      for (final chainPath in file.claudeChain) {
        if (chainPath == 'CLAUDE.md') continue;
        // Keyed by directory too: two projects can both carry a
        // `docs/CLAUDE.md` saying different things.
        if (!seen.add('${file.dirId}|$chainPath')) continue;
        final note = await _context.fileByPath(file.dirId, chainPath);
        if (note == null) continue;
        final text = await _context.fileText(note.id);
        if (text == null || text.isEmpty) continue;
        final body = _clamp(
          parseFrontmatter(text).body.trim(),
          ContextTuning.nestedClaudeMdCap,
        );
        if (body.isEmpty) continue;
        contributed.add(file.dirId);
        guidance.add(ContextGuidance(label: chainPath, text: body));
      }
    }
  }

  /// The rules whose declared paths match a passage that was kept.
  ///
  /// Scoped to the rule's OWN directory: a rule is a statement about files in
  /// the project it lives in, and `docs/**` in one project has nothing to say
  /// about another project's `docs/`.
  Future<void> _addRules(
    List<ContextDir> dirs,
    List<ContextExcerpt> excerpts,
    List<ContextGuidance> guidance,
    Set<String> contributed,
  ) async {
    if (excerpts.isEmpty) return;
    for (final dir in dirs) {
      final paths = [
        for (final excerpt in excerpts)
          if (excerpt.dirId == dir.id) excerpt.relPath,
      ];
      if (paths.isEmpty) continue;
      // The rules only, asked for as rules. A project is tens of thousands of
      // files and a handful of them are rules, so reading every row of it on
      // every draft to throw all but four away is a table scan the index
      // already knows how to answer.
      for (final file in await _context.rulesFor(dir.id)) {
        if (!_ruleApplies(file.pathsJson, paths)) continue;
        final text = await _context.fileText(file.id);
        if (text == null || text.isEmpty) continue;
        final body = _clamp(
          parseFrontmatter(text).body.trim(),
          ContextTuning.ruleBodyCap,
        );
        if (body.isEmpty) continue;
        contributed.add(dir.id);
        guidance.add(ContextGuidance(
          label: 'rule ${p.posix.basename(file.relPath)}',
          text: body,
        ));
      }
    }
  }

  /// Whether any glob in [pathsJson] matches any of [relPaths].
  ///
  /// Tolerant at every step. The column is written by this app from a
  /// project's own frontmatter, which means a person can put anything in it:
  /// a malformed list, a glob syntax `package:glob` will not parse. Each of
  /// those means "this rule does not apply here", never a draft that failed.
  static bool _ruleApplies(String? pathsJson, List<String> relPaths) {
    if (pathsJson == null || pathsJson.isEmpty) return false;
    List<dynamic> decoded;
    try {
      final raw = jsonDecode(pathsJson);
      if (raw is! List) return false;
      decoded = raw;
    } on FormatException {
      return false;
    }
    for (final entry in decoded) {
      if (entry is! String || entry.isEmpty) continue;
      Glob glob;
      try {
        // Posix explicitly: rel paths always carry `/`, whatever platform the
        // app is running on.
        glob = Glob(entry, context: p.posix);
      } catch (_) {
        continue;
      }
      for (final relPath in relPaths) {
        try {
          if (glob.matches(relPath)) return true;
          if (relPath.startsWith('./') && glob.matches(relPath.substring(2))) {
            return true;
          }
        } catch (_) {
          continue;
        }
      }
    }
    return false;
  }

  /// The segment above `SKILL.md`, which is what the skill is called.
  static String _folderOf(String relPath) {
    final segments = relPath.split('/');
    return segments.length >= 2 ? segments[segments.length - 2] : '';
  }

  /// The passage without its `<relPath> · <locator>` header line. A passage
  /// with no newline at all is one line of text and keeps all of it.
  static String _withoutHeader(String text) {
    final newline = text.indexOf('\n');
    return newline < 0 ? text : text.substring(newline + 1);
  }

  /// The date part of an ISO stamp, without parsing one — the attachment
  /// retriever's rule, for its reason: every stamp this app stores is
  /// ISO-8601, and a `DateTime.parse` here would throw on the one malformed
  /// row in a project, in the middle of building a prompt.
  static String _day(String mtime) =>
      mtime.length >= 10 ? mtime.substring(0, 10) : '';

  static String _clamp(String value, int cap) =>
      value.length > cap ? value.substring(0, cap) : value;
}
