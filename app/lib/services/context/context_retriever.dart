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
import '../llm/context_select_task.dart';
import '../llm/embeddings_client.dart';
import '../llm/json_task.dart' show runTask;
import '../llm/llm_client.dart';
import '../search_fusion.dart';
import 'claude_conventions.dart';
import 'context_chunker.dart'
    show contextSection, expandedSectionLines, parseLineLocator;

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

  /// How much of ONE section the selector asked for reaches the prompt.
  ///
  /// Three thousand characters is a long `##` section of a design note or a
  /// whole short file, and it is three times what a ranked passage gets — the
  /// point of asking to read something whole is that a thousand characters of
  /// it was not enough. Past this the model is being handed a document to
  /// summarise instead of a section to quote.
  static const int expandedSectionCap = 3000;

  /// How many of them. The select task's own `maxRead`, restated here because
  /// this is the number the excerpt fence was widened to hold — a test pins
  /// the two together.
  static const int maxExpanded = 2;

  /// How many ranked passages there must be before a pack with no pointers is
  /// worth a call.
  ///
  /// Under this the ranking has already shown the model nearly everything the
  /// directory had to say, and a selector choosing two of five passages it
  /// can see in full is spending a model call to reorder a short list. A pack
  /// WITH pointers qualifies however short its ranking is — a pointer names a
  /// file the ranking may never have reached — once the directory has
  /// anything indexed at all. Before that there is nothing to read: the text
  /// and the passages are written by the same pass, so a directory with no
  /// passages has no section to hand back either.
  static const int selectMinCandidates = 8;
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

  /// This passage is a whole section the selector asked to read, not a chunk
  /// the ranking kept. The render says so, because the difference matters to
  /// a model deciding whether the absence of a number means the number is not
  /// there: a ranked passage is an extract and a section is the section.
  final bool expanded;

  const ContextExcerpt({
    required this.dirName,
    required this.relPath,
    required this.locator,
    required this.modified,
    required this.text,
    required this.fileId,
    required this.dirId,
    this.truncated = false,
    this.expanded = false,
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

  /// The sections the selector asked to read in full, as
  /// `<rel path> § <locator>` — or just the path when it asked for a whole
  /// file. What the activity row counts and the handback names; the passages
  /// themselves are in [excerpts], at the front, flagged.
  final List<String> expanded;

  /// Why the section pick did not happen, or null. Read by the activity row
  /// only: the pack it belongs to is the pack that would have been built
  /// anyway, so this explains a missing improvement rather than a failure.
  final String? selectError;

  const ContextPack({
    required this.directories,
    required this.briefs,
    required this.guidance,
    required this.excerpts,
    required this.skills,
    this.expanded = const [],
    this.selectError,
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

  /// The fast slot, for the one call this class makes. Nullable because a
  /// build without one is a legal build — every test that is about the
  /// ranking wants a retriever with no model behind it, and the step below
  /// simply does not run.
  final LlmClient? _fastClient;

  /// Whether the owner has left the section pick on. A closure and not a
  /// value, on the house rule that `services/` never reaches into
  /// `providers/`: the preference is READ at the moment a pack is built, so
  /// flipping the switch does not have to rebuild this object or the worker
  /// above it.
  final bool Function() _selectExpand;

  ContextRetriever(
    this._store,
    this._context,
    this._embeddings, {
    LlmClient? fastClient,
    bool Function()? selectExpand,
  })  :
        // ignore: prefer_initializing_formals
        _fastClient = fastClient,
        _selectExpand = selectExpand ?? _alwaysOn;

  static bool _alwaysOn() => true;

  /// Everything worth putting in front of the model about this message.
  ///
  /// [consultFirst] is the "look at this file" path: file ids the person
  /// named. Those files are READ, not merely ranked — the neighbour page is a
  /// dozen passages wide and a file somebody pointed at is usually not on it,
  /// which is precisely why they pointed. Each named file is asked for its own
  /// nearest passages, and a file the vector index cannot answer for is read
  /// from the top instead. What comes back bypasses the score floor and sits
  /// in front of the ranking. Empty is the ordinary case.
  ///
  /// [queryVector] is [AttachmentRetriever.excerptsFor]'s parameter and its
  /// contract: a caller searching both corpora with the same question passes
  /// one memoised closure and the message's card is embedded once. Null means
  /// "build it yourself". It is called only after the `LIMIT 1` guard below,
  /// so a room whose directories hold nothing indexed still costs no POST.
  ///
  /// **The last step may ask to read closer.** Once the directory has
  /// anything indexed, and with a fast client, the preference on, and either
  /// a brief that points at files or a page of ranked passages worth choosing
  /// between, one call names up to two sections to read WHOLE; they go to the
  /// front of the excerpts and the passages they already contain come out.
  /// That call needs no vector of its own — it reads the first words of what
  /// is already in hand — so a pack that got here on a named file alone, or
  /// on a pointer with no vector behind it at all, can still expand one. The
  /// nested notes and the matching rules are gathered AFTER it, so a section
  /// the ranking never surfaced still arrives with the `CLAUDE.md` beside it
  /// and the rule that governs its path. Any failure, or an empty answer,
  /// leaves the pack exactly as this comment's paragraphs above built it.
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
    // What every brief in scope says answers which kind of question, in scope
    // order. The half of the selector's input that can name a file the
    // ranking never reached.
    final pointers = <({String topic, String path})>[];
    final expanded = <String>[];
    String? selectError;
    // Every file row already read, by id, so the steps below share one read
    // each. Declared up here rather than beside the ranking loop that fills
    // it because the closer read runs on the path where that loop never ran
    // at all, and the nested notes are looked up through this map.
    final files = <int, ContextFile>{};

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
          expanded: List.unmodifiable(expanded),
          selectError: selectError,
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
        pointers.addAll(brief.pointers);
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

      // The named files, read before anything is ranked. A consulted file
      // that never reaches this list contributes nothing at all, and a person
      // who pointed at a file and got a draft that ignored it has been told
      // something untrue by the button they pressed.
      final consulted = <ContextChunkHit>[];
      if (consultFirst.isNotEmpty) {
        final nearest = query == null
            ? null
            : await _context.chunkKnn(
                query,
                embedModel: EmbeddingsClient.documentModelTag,
                dirIds: dirIds,
                fileIds: consultFirst,
                // A page per named file, which is what the per-file cap below
                // will keep of them anyway.
                k: perFile * consultFirst.length,
              );
        if (nearest != null) consulted.addAll(nearest);

        // Files the vector index could not answer for — no vector written
        // yet, the native index missing from this build, the embedder down —
        // are read from the top, in order. That is what "read this file
        // first" means when nothing knows which part of it is nearest.
        final answered = {for (final hit in consulted) hit.fileId};
        for (final id in consultFirst) {
          if (answered.contains(id)) continue;
          final file = await _context.fileById(id);
          // The scope again, on this path too: a named file outside every
          // directory linked to this room is a file this room may not read.
          if (file == null || !dirIds.contains(file.dirId)) continue;
          consulted.addAll(await _context.chunksForFile(id, limit: perFile));
        }
      }

      /// The tail of the pack: the closer read, and then the notes and rules
      /// that ride with whatever the excerpts ended up being.
      ///
      /// A closure because there are two ways into it. The ordinary one is
      /// the end of this method, with the ranked list behind it; the other is
      /// the exit just below, where there is no vector and so no ranking at
      /// all — and a pack whose brief POINTS at a file still qualifies for
      /// the closer read, because the selector needs no vector to choose a
      /// path somebody already wrote down. The notes and the rules run AFTER
      /// the select step in both, so a section pulled in from a pointer
      /// brings its nested `CLAUDE.md` and the rule whose glob matches it,
      /// exactly as a ranked passage does.
      Future<void> lookCloser(List<ContextChunkHit> ordered) async {
        // The one step that can ask for more, in a try of its OWN rather than
        // under the one below. Everything above is already built and correct;
        // a selector that fell over must cost this pack the closer read and
        // nothing else, and the outer catch would hand back a pack that had
        // never run the rules.
        try {
          await _selectAndExpand(
            source: source,
            replyToId: replyToId,
            dirs: dirs,
            dirIds: dirIds,
            pointers: pointers,
            ordered: ordered,
            files: files,
            excerpts: excerpts,
            skills: skills,
            skillGuidance: skillGuidance,
            contributed: contributed,
            expanded: expanded,
          );
        } catch (error) {
          selectError = error.toString();
        }
        await _addNestedNotes(excerpts, files, nestedGuidance, contributed);
        await _addRules(dirs, excerpts, ruleGuidance, contributed);
      }

      // The embedding server is down, or refused the card. Degraded, never
      // thrown — and the skills go with the passages, because they are
      // matched against this very vector. A file the person NAMED still
      // reaches the pack, because finding it never needed the question.
      // Not an exit before the closer read, though: the pointers are already
      // in hand and the selector reads them without a vector, so a brief that
      // names the right file can still have it read whole.
      if (query == null && consulted.isEmpty) {
        await lookCloser(const []);
        return built();
      }

      var vectorHits = query == null
          ? const <ContextChunkHit>[]
          : await _context.chunkKnn(
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

      if (consulted.isNotEmpty) {
        // Merged rather than appended: a consulted passage the neighbour page
        // already holds keeps its distance, and so keeps its score.
        final seen = {for (final hit in vectorHits) hit.chunkId};
        vectorHits = [
          ...vectorHits,
          for (final hit in consulted)
            if (seen.add(hit.chunkId)) hit,
        ];
      }

      final keywordHits = await _keywordHits(source, replyToId, dirIds);
      final ranking = _rank(
        vectorHits: vectorHits,
        keywordHits: keywordHits,
        consultFirst: consultFirst.toSet(),
        perFile: perFile,
        k: k,
      );

      var spent = 0;
      for (final hit in ranking.kept) {
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

      // Skills are matched against the question's vector and there is no
      // other way to pick one, so a pass that got here on a named file alone
      // adds none — the same degradation the early return used to make.
      if (query != null) {
        await _addSkills(dirIds, query, skills, skillGuidance, contributed);
      }
      await lookCloser(ranking.ordered);
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
  /// [kept] is what the prompt gets. [ordered] is the same ranking one step
  /// earlier — every passage that cleared the floor, after the consulted
  /// partition and BEFORE the per-file cap and the take — which is the page
  /// the section pick chooses from: a file whose three best passages the cap
  /// trimmed to one is exactly the file worth reading whole.
  static ({List<ContextChunkHit> kept, List<ContextChunkHit> ordered}) _rank({
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
    return (kept: kept, ordered: ordered);
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
      final block = await _skillBlock(match.file);
      if (block == null) continue;
      contributed.add(match.file.dirId);
      skills.add(block.name);
      guidance.add(block.guidance);
    }
  }

  /// One skill file as the guidance fence reads it, and the name it is
  /// invoked by.
  ///
  /// Shared by the two paths that can put a skill in a pack — the cosine
  /// match above and the selector's own pick — so that a skill chosen by the
  /// model and a skill chosen by the vector are rendered by the same code and
  /// carry the same label.
  ///
  /// Null when the skill has no name to be called by. The name is resolved
  /// BEFORE either caller spends one of its two slots, not after: a skill
  /// filed at the root of a project has no folder above it, and one that took
  /// a slot and then dropped out of it would cost the next skill its place
  /// for a block nothing renders.
  Future<({String name, ContextGuidance guidance})?> _skillBlock(
    ContextFile file,
  ) async {
    final text = await _context.fileText(file.id) ?? '';
    // The FOLDER name, which is what a skill is invoked as — `skillOf`'s own
    // rule. The fallback is the same segment read directly, for a row whose
    // words the walk never stored.
    final name = skillOf(file.relPath, text)?.name ?? _folderOf(file.relPath);
    if (name.isEmpty) return null;
    final description = file.description?.trim() ?? '';
    final body = _clamp(
      parseFrontmatter(text).body.trim(),
      ContextTuning.skillBodyCap,
    );
    return (
      name: name,
      guidance: ContextGuidance(
        label: 'SKILL $name',
        // Description first: it is the author's own sentence saying when this
        // applies, and a model reading the body without it is reading steps
        // with no statement of what they are for.
        text: [
          if (description.isNotEmpty) description,
          if (body.isNotEmpty) body,
        ].join('\n'),
      ),
    );
  }

  /// The look-closer step: one fast call that may name up to two sections to
  /// read WHOLE and up to two skills to read at all.
  ///
  /// Six passages of a thousand characters can miss the one section that
  /// carries the number, and nothing in the ranking can know that — a section
  /// is near a question because of what it is about, and the sentence with
  /// the figure in it is the one sentence in it that is not. So the model
  /// that is about to write the reply is shown what was found and asked
  /// whether it wants to read any of it properly.
  ///
  /// It needs NO vector. The message, the pointers, the skill descriptions
  /// and the first words of each passage are all in hand already, which is
  /// why this can run on a pack whose only signal was a file somebody named.
  ///
  /// Everything is built into local lists and committed at the end. A throw
  /// half way through — the model, the store, a file that went away — leaves
  /// [excerpts], [skills] and [skillGuidance] exactly as the ranking left
  /// them, and the caller notes the failure beside a pack that is still
  /// worth sending.
  Future<void> _selectAndExpand({
    required String source,
    required String replyToId,
    required List<ContextDir> dirs,
    required List<String> dirIds,
    required List<({String topic, String path})> pointers,
    required List<ContextChunkHit> ordered,
    required Map<int, ContextFile> files,
    required List<ContextExcerpt> excerpts,
    required List<String> skills,
    required List<ContextGuidance> skillGuidance,
    required Set<String> contributed,
    required List<String> expanded,
  }) async {
    final client = _fastClient;
    if (client == null) return;
    if (!_selectExpand()) return;
    // A pack with pointers always qualifies, however short the ranking is:
    // the pointer's file may hold what no passage could rank. Without them,
    // a page too short to be worth choosing between is not worth a call.
    if (pointers.isEmpty &&
        ordered.length < ContextTuning.selectMinCandidates) {
      return;
    }

    // Every skill in scope, by the name it is invoked as. Not the embedded
    // ones — this is the list the model chooses from by DESCRIPTION, and a
    // project whose vectors never landed still has its instructions.
    //
    // The name is [_folderOf] here and `skillOf` in [_skillBlock], and the
    // two agreeing is load-bearing rather than incidental: `skillOf` resolves
    // a skill to the segment above its `SKILL.md` whatever the frontmatter
    // says — Claude Code's own rule, because that is what a person types —
    // so both answer the same word. That is what makes the `skills.contains`
    // check below a real dedup: the name the model is SHOWN and the name the
    // block is LABELLED with have to be one name, or a skill the cosine
    // already offered would be offered again under a second spelling and
    // spend both slots on one file.
    final available = <({ContextFile file, String name})>[];
    for (final dir in dirs) {
      for (final file in await _context.skillsFor(dir.id)) {
        final name = _folderOf(file.relPath);
        if (name.isEmpty) continue;
        available.add((file: file, name: name));
      }
    }

    final row = await _store.getMessageRow(source, replyToId);
    // The row can be gone between the draft being queued and this read. An
    // empty question still lets the pointers answer.
    final message = row == null
        ? ''
        : '${stripReFw(row['subject'] as String?)}\n'
            '${row['body_text'] as String? ?? ''}';

    final candidates = <({String path, String locator, String preview})>[];
    for (final hit in ordered.take(ContextSelectTask.maxCandidates)) {
      final file = files[hit.fileId] ?? await _context.fileById(hit.fileId);
      if (file == null) continue;
      files[hit.fileId] = file;
      candidates.add((
        // The FILE row's path, never the passage's header line: a rename
        // keeps the chunks and refiles only the keyword rows, so the stored
        // header can name where the file used to be — and the selector has
        // to answer with a path this code can look up again.
        path: file.relPath,
        locator: hit.locator,
        preview: _withoutHeader(hit.text),
      ));
    }

    final answer = await runTask(
      client,
      const ContextSelectTask(),
      ContextSelectInput(
        message: message,
        pointers: pointers,
        skills: [
          for (final skill in available)
            (name: skill.name, description: skill.file.description ?? ''),
        ],
        candidates: candidates,
        now: DateTime.now(),
      ),
      // Deterministic: two identical drafts of the same message must read the
      // same sections, or the difference between them is one nobody can
      // account for.
      temperature: 0,
      // Two paths, two names and a sentence.
      maxTokens: 256,
    );
    if (answer.isEmpty) return;

    final sections = <ContextExcerpt>[];
    final labels = <String>[];
    final contributedNow = <String>{};
    for (final read in answer.read) {
      final path = read.path.trim();
      if (path.isEmpty) continue;
      ContextFile? file;
      ContextDir? from;
      for (final dir in dirs) {
        file = await _context.fileByPath(dir.id, path) ??
            (path.startsWith('./')
                ? await _context.fileByPath(dir.id, path.substring(2))
                : null);
        if (file != null) {
          from = dir;
          break;
        }
      }
      // Two projects in scope carrying the same path is decided by scope
      // order, which is the order the room linked them in.
      if (file == null || from == null) continue;
      // Belt and braces. The guard that actually holds today is the loop
      // above: every `fileByPath` was asked of a directory in scope, so a
      // path the model invented simply finds no row. This line is here for
      // the day a `fileByPath` resolves across directories — a path the model
      // spelled is a path the model could invent, and the scope is the one
      // property this class may never lose.
      if (!dirIds.contains(file.dirId)) continue;
      // The same section, asked for twice. A model that names `Pricing` and
      // then `Pricing > Q4 rates` has named one thing and part of it, and
      // expanding both puts the child's text in the fence twice — which is
      // the very duplication the drop rule below exists to prevent. The
      // LARGER of the two wins either way round: a read already held by a
      // section taken is skipped here, and a read that holds one taken
      // earlier replaces it, its label with it.
      if (sections.any((section) =>
          section.fileId == file!.id &&
          _contains(section.locator, read.locator))) {
        continue;
      }
      for (var taken = sections.length - 1; taken >= 0; taken--) {
        if (sections[taken].fileId != file.id) continue;
        if (!_contains(read.locator, sections[taken].locator)) continue;
        sections.removeAt(taken);
        labels.removeAt(taken);
      }
      final text = await _context.fileText(file.id);
      if (text == null || text.isEmpty) continue;
      final section = contextSection(file.relPath, text, read.locator);
      // A locator this file does not have. Nothing is expanded and nothing is
      // reported: the ranked passages are still there, which is what the pack
      // would have been anyway.
      if (section == null || section.trim().isEmpty) continue;
      sections.add(ContextExcerpt(
        dirName: from.displayName,
        relPath: file.relPath,
        locator: read.locator,
        modified: _day(file.mtime),
        text: _clamp(section, ContextTuning.expandedSectionCap),
        fileId: file.id,
        dirId: file.dirId,
        truncated: file.status == 'truncated',
        expanded: true,
      ));
      labels.add(read.locator.isEmpty
          ? file.relPath
          : '${file.relPath} § ${read.locator}');
      // The expanded file joins the map the nested notes are looked up
      // through. A section pulled in from a pointer is a file the ranking
      // never surfaced, so nothing else would have put it there — and a
      // `docs/CLAUDE.md` that governs it is exactly the note a reply quoting
      // it should have read.
      files[file.id] = file;
      contributedNow.add(file.dirId);
      if (sections.length == ContextTuning.maxExpanded) break;
    }

    // The passages the sections already contain come out. The model reading
    // the same paragraph twice is not the problem — spending the fence on it
    // is, and a passage quoted beside the section it was cut from reads as
    // two sources saying the same thing.
    final remaining = [
      for (final excerpt in excerpts)
        if (!sections.any((section) =>
            section.fileId == excerpt.fileId &&
            _contains(section.locator, excerpt.locator)))
          excerpt,
    ];

    // The sections go FIRST: they are what the model asked to read, and the
    // excerpt fence loses whole blocks off the END when it is over budget.
    // Their ceiling is their own — two times [ContextTuning.expandedSectionCap]
    // — and the ranked tail keeps the budget it was already trimmed to, so
    // nothing here re-budgets a list that was budgeted once already.
    final picked = <String>[];
    final pickedGuidance = <ContextGuidance>[];
    for (final name in answer.skills) {
      // Already offered by the cosine, so it is already in the pack.
      if (skills.contains(name) || picked.contains(name)) continue;
      ContextFile? file;
      for (final skill in available) {
        // Exact and case-sensitive: the name is one the model was HANDED, and
        // a near-miss is a name it made up.
        if (skill.name != name) continue;
        file = skill.file;
        break;
      }
      if (file == null) continue;
      final block = await _skillBlock(file);
      if (block == null) continue;
      picked.add(block.name);
      pickedGuidance.add(block.guidance);
      contributedNow.add(file.dirId);
    }

    // The model's picks DISPLACE the cosine's, they do not stack on top of
    // them: the ceiling is two for the reason [ContextTuning.maxSkills]
    // gives, and the pick is the better-informed of the two rankings because
    // it read the question rather than measuring it.
    final finalSkills = [...picked, ...skills].take(ContextTuning.maxSkills);
    final finalGuidance =
        [...pickedGuidance, ...skillGuidance].take(ContextTuning.maxSkills);

    excerpts
      ..clear()
      ..addAll(sections)
      ..addAll(remaining);
    skills
      ..clear()
      ..addAll(finalSkills);
    skillGuidance
      ..clear()
      ..addAll(finalGuidance);
    expanded.addAll(labels);
    contributed.addAll(contributedNow);
  }

  /// Whether the section located by [section] already holds the passage
  /// located by [passage], in the same file.
  ///
  /// Four ways it can. An empty section locator is the whole file, so it
  /// holds everything in it. A passage of the very same section is it. A
  /// DEEPER breadcrumb is nested inside — the whole of `Pricing` carries its
  /// `Pricing > Q4 rates` with it, parts and all — which is the same rule the
  /// section reader extends by.
  ///
  /// And two line windows OVERLAP, which is the one the breadcrumb rules
  /// cannot see. A code file is cut into sixty-line windows every fifty
  /// lines while the reader hands back [expandedSectionLines] of them, so an
  /// expanded `lines 61–120` is really lines 61 to 180 and the ranked
  /// `lines 101–160` sits entirely inside it. Entirely is the test: a window
  /// that only overlaps the span's tail still carries lines the section does
  /// not, and dropping it would lose them.
  static bool _contains(String section, String passage) {
    if (section.isEmpty) return true;
    if (passage == section) return true;
    if (passage.startsWith('$section > ')) return true;
    if (passage.startsWith('$section · part')) return true;
    final span = parseLineLocator(section);
    final window = parseLineLocator(passage);
    if (span != null && window != null) {
      return window.first >= span.first &&
          window.last <= span.first + expandedSectionLines - 1;
    }
    return false;
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
