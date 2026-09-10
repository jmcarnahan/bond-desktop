import 'package:flutter/foundation.dart' show debugPrint;

import '../data/context_store.dart';
import '../data/message_store.dart';
import '../models/attachment_models.dart';
import '../models/context_models.dart';
import '../models/home_models.dart';
import 'llm/embeddings_client.dart';
import 'search_fusion.dart';

/// What a search came back with — hits, or a reason there are none.
///
/// Sealed and two-cased rather than a list that is sometimes empty, because
/// "nothing in your mail is about that" and "the thing that answers questions
/// is not running" are the two sentences a search screen must never confuse.
/// One is an answer; the other is an instruction to go and start a server.
///
/// The unavailable case is narrow: BOTH passes have to have failed. A search
/// asks the meaning index and the word index, and the word index needs nothing
/// but the database — so a dead embedding server narrows the answer rather
/// than removing it, and says so in [MessageSearchHits.notice].
sealed class MessageSearchResult {
  const MessageSearchResult();
}

/// A search that ran. [hits] may still be empty — that is a real answer.
class MessageSearchHits extends MessageSearchResult {
  /// The query as it was searched, trimmed. Carried back so a screen can label
  /// a result set that arrived after the box was typed into again.
  final String query;

  /// One list, ranked once.
  ///
  /// The two passes are merged before they get here rather than shown one
  /// under the other. Two lists meant a reader saw their mailbox twice under
  /// two headings, with the message BOTH passes found leading one and buried
  /// in the other — and it meant a header count that had to add up two
  /// numbers. A row that only the words could reach (a gate-dropped message
  /// was never embedded) still appears, at the proportion of the score it was
  /// able to earn.
  final List<SearchHit> hits;

  /// The passages of attached documents that answer the same query, one per
  /// file.
  ///
  /// A separate list rather than more [hits], because a document hit is not a
  /// message: it is a fragment of a file, and it has to be shown with the file
  /// name and the place in it. Empty is the ordinary answer for a mailbox
  /// nobody has attached anything to, and for one whose passages are all
  /// further from the query than the floor allows.
  final List<AttachmentChunkHit> documents;

  /// The passages of the owner's own registered directories that answer the
  /// same query, one per file.
  ///
  /// A third list for [documents]'s reason and one more: a directory file is
  /// not a message and not an attachment. It belongs to no thread, it is the
  /// person's OWN work rather than something a stranger sent, and it is shown
  /// above both because a question about a project is usually answered better
  /// by the project than by a message mentioning it. Empty is the ordinary
  /// answer for a mailbox with no directory registered, which costs one
  /// `SELECT id FROM context_dirs` and nothing else.
  final List<ContextChunkHit> directories;

  /// Non-null when only ONE of the two passes contributed — the sentence to
  /// show over a set of results that is narrower than it looks.
  ///
  /// Never two sentences: both passes failing is the unavailable case, not a
  /// doubly-noticed one.
  ///
  /// A fact about THIS result set rather than a standing condition of the
  /// screen, which is why it travels with the rows.
  final String? notice;

  const MessageSearchHits(
    this.query,
    this.hits, {
    this.documents = const [],
    this.directories = const [],
    this.notice,
  });
}

/// A search that could not run, and the sentence to show for it.
class MessageSearchUnavailable extends MessageSearchResult {
  final String reason;

  const MessageSearchUnavailable(this.reason);
}

/// What a search of the archive came back with: rows, and a sentence when one
/// half of it could not run.
///
/// Plain rather than part of [MessageSearchResult]'s sealed pair, because the
/// archive's search still ANSWERS when the embedding server is down — the word
/// pass runs either way. So unavailability here is a notice ON a result, where
/// above it is a case INSTEAD of one.
class ArchiveSearchResult {
  /// The query as it was searched, trimmed.
  final String query;

  /// The fused ranking's rows, best first. Score order rather than date order:
  /// the archive asks the same question the home search does and deserves the
  /// same answer.
  final List<HomeFeedRow> rows;

  /// Non-null when only one pass contributed.
  final String? notice;

  const ArchiveSearchResult(this.query, this.rows, this.notice);
}

/// One semantic pass, and what to say when it could not run.
///
/// [hits] is null rather than empty when the pass never happened at all —
/// exactly the distinction `MessageStore.semanticSearch` keeps — and the two
/// sentences beside it are the same fact worded for two places: [notice] rides
/// on a result that still has rows, [reason] fills the sealed unavailable case
/// on the one path where nothing is left to show.
class _SemanticPass {
  final List<SemanticHit>? hits;
  final List<AttachmentChunkHit>? documents;
  final List<ContextChunkHit>? directories;
  final String? notice;
  final String? reason;

  const _SemanticPass(
    this.hits, {
    this.documents,
    this.directories,
    this.notice,
    this.reason,
  });
}

/// One keyword pass, in [_SemanticPass]'s shape and for its reasons.
///
/// The two are separate classes rather than one because their failures are
/// separate facts — a mailbox can lose either index without losing the other —
/// and the whole point of the pair is that the caller can tell which.
class _KeywordPass {
  final List<KeywordHit>? hits;
  final List<AttachmentChunkHit>? documents;
  final List<ContextChunkHit>? directories;
  final String? notice;
  final String? reason;

  const _KeywordPass(
    this.hits, {
    this.documents,
    this.directories,
    this.notice,
    this.reason,
  });
}

/// Turns a sentence a person typed into ranked messages.
///
/// The search screen's ONLY door: it never reaches [EmbeddingsClient] or
/// [MessageStore] itself. Both halves of a search have to agree about the
/// corpus — the query is embedded under
/// [EmbeddingsClient.searchQueryPrefix] and matched against vectors written
/// under [EmbeddingsClient.documentPrefix] — and that pairing is the kind of
/// fact that survives exactly as long as it lives in one place.
///
/// Every search is two passes fused into one ranking, and both public methods
/// run them through the same two private helpers. That is deliberate rather
/// than tidy: the two used to spell the pair out separately, and a corpus rule
/// added to one and not the other is a search that answers a different
/// question depending on which screen asked it.
class MessageSearch {
  final MessageStore _store;
  final EmbeddingsClient _embeddings;

  /// The library of registered directories, or null on a build that has none
  /// wired up. Optional rather than required because every test and every
  /// caller that predates the third corpus asks the same two questions of the
  /// mailbox and must keep getting the same two answers.
  final ContextStore? _contextStore;

  MessageSearch(this._store, this._embeddings, {ContextStore? context})
      : _contextStore = context;

  /// The home screen's search: meaning and words, scored together.
  ///
  /// [MessageSearchUnavailable] is what comes back only when BOTH passes
  /// failed — an embedding server that is off leaves the word index standing,
  /// and a SQLite without FTS5 leaves the ranking standing.
  ///
  /// [sources] narrows BOTH corpora to a set of connectors — the `in:` facet,
  /// honoured in SQL because the source is a column on every row either read
  /// touches. Filtering it after the fact would spend each index's whole
  /// budget on hits from the connector the reader excluded.
  Future<MessageSearchResult> search(
    String query, {
    int limit = 50,
    bool includeDropped = false,
    List<String> sources = const ['email', 'teams'],
  }) async {
    final text = query.trim();
    final semantic = await _semanticOrNotice(
      text,
      limit: limit,
      includeDropped: includeDropped,
      sources: sources,
    );
    final keywords = await _keywordsOrNotice(
      text,
      includeDropped: includeDropped,
      sources: sources,
    );

    // Nothing left to show, so the sealed case earns itself: the reader is
    // owed the instruction rather than an empty list that reads as an answer
    // about their mailbox.
    if (semantic.hits == null && keywords.hits == null) {
      return MessageSearchUnavailable(
        semantic.reason ?? keywords.reason ?? 'the search could not run',
      );
    }

    return MessageSearchHits(
      text,
      fuseMessages(
        semantic: semantic.hits,
        keywords: keywords.hits,
        limit: limit,
      ),
      documents: fuseDocuments(
        semantic: semantic.documents,
        keywords: keywords.documents,
      ),
      directories: fuseDirectories(
        semantic: semantic.directories,
        keywords: keywords.directories,
      ),
      // At most one of the two is set here — the both-failed case returned
      // above — so whichever is non-null is the sentence.
      notice: semantic.notice ?? keywords.notice,
    );
  }

  /// The same question asked of the whole history.
  ///
  /// Scope is ALL of it, dropped rows included, because the archive's selling
  /// point is "I know I got that email" — a search that quietly skipped the
  /// pile the gate threw out would answer that sentence with silence.
  ///
  /// The one difference from [search]: the hits arrive flattened into rows,
  /// because the archive renders feed rows and has no place to put a score.
  Future<ArchiveSearchResult> searchArchive(
    String query, {
    int limit = 50,
  }) async {
    final text = query.trim();
    const sources = ['email', 'teams'];
    // No passages: the archive renders feed rows, and a document read whose
    // answer has nowhere to go is two queries and a chunk backfill spent on
    // nothing.
    final semantic = await _semanticOrNotice(
      text,
      limit: limit,
      includeDropped: true,
      sources: sources,
      withDocuments: false,
    );
    final keywords = await _keywordsOrNotice(
      text,
      includeDropped: true,
      sources: sources,
      withDocuments: false,
    );

    return ArchiveSearchResult(
      text,
      [
        for (final hit in fuseMessages(
          semantic: semantic.hits,
          keywords: keywords.hits,
          limit: limit,
        ))
          hit.row,
      ],
      semantic.notice ?? keywords.notice,
    );
  }

  /// [_semantic], with a THROW turned into the same narrowed answer a dead
  /// embedding server gets.
  ///
  /// The index lives in a native extension over its own connection, and a read
  /// of it can fail outright rather than answer null — the vec0 table missing
  /// on this build, a connection that lost the extension. The word pass needs
  /// nothing but the database, so it still has an answer, and a search box
  /// that threw would leave a reader with no result at all over a half of the
  /// search they never asked for by name.
  ///
  /// [withDocuments] off is the archive's shape: [ArchiveSearchResult] has
  /// nowhere to put a passage, so asking for one is two reads whose answers
  /// are thrown away.
  Future<_SemanticPass> _semanticOrNotice(
    String text, {
    required int limit,
    required bool includeDropped,
    required List<String> sources,
    bool withDocuments = true,
  }) async {
    try {
      return await _semantic(
        text,
        limit: limit,
        includeDropped: includeDropped,
        sources: sources,
        withDocuments: withDocuments,
      );
    } catch (e) {
      debugPrint('search: semantic pass failed: $e');
      return const _SemanticPass(
        null,
        notice: 'Words only — the semantic index could not be read.',
        reason: 'the semantic index could not be read',
      );
    }
  }

  /// Embeds the query and ranks both corpora with it, or explains why it could
  /// not.
  Future<_SemanticPass> _semantic(
    String text, {
    required int limit,
    required bool includeDropped,
    required List<String> sources,
    bool withDocuments = true,
  }) async {
    final result = await _embeddings.embedResult(
      text,
      prefix: EmbeddingsClient.searchQueryPrefix,
    );
    final vector = result.vector;
    if (vector == null) {
      // Unavailable and rejected collapse here, where everywhere else in the
      // app they diverge. The difference decides whether to retry LATER, and
      // there is no later in a search: the person is waiting, and the only
      // thing they can do about either is start the server the message names.
      //
      // The subject is composed on rather than assumed: every
      // [EmbeddingsClient] reason is written as a PREDICATE of the embedding
      // server ('is not reachable — run: make embed'), so naming it here is
      // what turns the fragment into a clause a screen can print whole.
      final subject =
          'the embedding server ${result.reason ?? 'did not answer'}';
      return _SemanticPass(
        null,
        notice: 'Words only — $subject.',
        reason: subject,
      );
    }

    final hits = await _store.semanticSearch(
      encodeEmbedding(vector),
      embedModel: EmbeddingsClient.documentModelTag,
      limit: limit,
      includeDropped: includeDropped,
      sources: sources,
    );
    // Null and not empty: the native index is missing on this build, which is
    // a different sentence from "no message matches".
    if (hits == null) {
      return const _SemanticPass(
        null,
        notice: 'Words only — the semantic index is unavailable.',
        reason: 'the semantic index is unavailable',
      );
    }
    // The same query vector against the second corpus. It runs only after the
    // message search has an answer, so a document search can never be the
    // reason a search reports itself unavailable.
    //
    // Four times the page: the fusion collapses passages to one per FILE, and
    // a single long spreadsheet can occupy a whole page of neighbours on its
    // own and still be one answer.
    if (!withDocuments) return _SemanticPass(hits);
    final chunks = await _store.searchAttachmentChunks(
      encodeEmbedding(vector),
      embedModel: EmbeddingsClient.documentModelTag,
      limit: SearchTuning.documentLimit * 4,
      includeDropped: includeDropped,
      sources: sources,
    );
    return _SemanticPass(
      hits,
      documents: chunks,
      directories: await _directoryNeighbours(vector),
    );
  }

  /// The third corpus's nearest passages, or null when it could not be read.
  ///
  /// Its OWN try/catch, and that is the whole reason it is a method. A
  /// directory index that will not open — a vec0 table this build never got,
  /// a project half-way through a rebuild — must never make a search of the
  /// MAILBOX report itself unavailable or narrowed. The mailbox already has
  /// its answer by the time this runs, and the worst a failure here can cost
  /// is the third list.
  ///
  /// Every registered directory, named INSIDE the query rather than matched
  /// corpus-wide and filtered after — [ContextStore.chunkKnn]'s rule, kept
  /// even by the one caller entitled to ask for all of them.
  ///
  /// Four times the page, on the documents' reasoning: the fusion collapses
  /// passages to one per file, and a single long analysis can fill a page of
  /// neighbours on its own and still be one answer.
  Future<List<ContextChunkHit>?> _directoryNeighbours(
    List<double> vector,
  ) async {
    final context = _contextStore;
    if (context == null) return null;
    try {
      final ids = await context.allDirIds();
      if (ids.isEmpty) return const [];
      // Null means the vector index is off, which here is the same answer as
      // "nothing near": the words half still ran.
      return await context.chunkKnn(
            encodeEmbedding(vector),
            embedModel: EmbeddingsClient.documentModelTag,
            dirIds: ids,
            k: SearchTuning.documentLimit * 4,
            excludeDigests: true,
          ) ??
          const [];
    } catch (e) {
      debugPrint('search: directory semantic pass failed: $e');
      return null;
    }
  }

  /// The words half of the third corpus, with [_directoryNeighbours]'s
  /// isolation and for its reasons.
  ///
  /// Digests are excluded at READ time, the rule the attachment search keeps:
  /// a digest is a model's summary, and someone searching for the words they
  /// typed is owed the file that contains them.
  Future<List<ContextChunkHit>?> _directoryWords(String text) async {
    final context = _contextStore;
    if (context == null) return null;
    try {
      final query = buildFtsQuery(text);
      if (query == null) return const [];
      final ids = await context.allDirIds();
      if (ids.isEmpty) return const [];
      return await context.keywordChunks(
        query,
        dirIds: ids,
        excludeDigests: true,
      );
    } catch (e) {
      debugPrint('search: directory keyword pass failed: $e');
      return null;
    }
  }

  /// The word pass over both corpora, with a missing index and a throw
  /// answering the same way.
  ///
  /// Null hits rather than empty when the index could not be built, on
  /// [_semanticOrNotice]'s distinction: "there is nothing to search with" is
  /// not "nothing matched", and only the first is worth a sentence.
  ///
  /// [withDocuments] carries [_semanticOrNotice]'s meaning: the archive does
  /// not show passages, so it does not pay for them.
  Future<_KeywordPass> _keywordsOrNotice(
    String text, {
    required bool includeDropped,
    required List<String> sources,
    bool withDocuments = true,
  }) async {
    try {
      final hits = await _store.keywordSearchMessages(
        text,
        includeDropped: includeDropped,
        sources: sources,
      );
      if (hits == null) {
        return const _KeywordPass(
          null,
          notice: _noWords,
          reason: _noWordsReason,
        );
      }
      if (!withDocuments) return _KeywordPass(hits);
      final documents = await _store.keywordSearchChunks(
        text,
        includeDropped: includeDropped,
        sources: sources,
      );
      return _KeywordPass(
        hits,
        documents: documents,
        directories: await _directoryWords(text),
      );
    } catch (e) {
      debugPrint('search: keyword pass failed: $e');
      return const _KeywordPass(
        null,
        notice: _noWords,
        reason: _noWordsReason,
      );
    }
  }

  /// The sentence for a mailbox whose word index could not be built — a
  /// SQLite compiled without FTS5, or a database that cannot be written to.
  static const String _noWords =
      'Meaning only — the keyword index could not be built.';

  static const String _noWordsReason = 'the keyword index could not be built';
}
