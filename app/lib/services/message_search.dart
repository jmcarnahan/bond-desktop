import 'package:flutter/foundation.dart' show debugPrint;

import '../data/message_store.dart';
import '../models/attachment_models.dart';
import '../models/home_models.dart';
import 'llm/embeddings_client.dart';

/// What a search came back with — hits, or a reason there are none.
///
/// Sealed and two-cased rather than a list that is sometimes empty, because
/// "nothing in your mail is about that" and "the thing that answers questions
/// is not running" are the two sentences a search screen must never confuse.
/// One is an answer; the other is an instruction to go and start a server.
///
/// The unavailable case is narrow, and narrower than it once was: BOTH passes
/// have to have failed. A search runs the index and a text scan, and the scan
/// needs nothing but the database — so a dead embedding server narrows the
/// answer rather than removing it, and says so in [MessageSearchHits.notice].
sealed class MessageSearchResult {
  const MessageSearchResult();
}

/// A search that ran. [hits] may still be empty — that is a real answer.
class MessageSearchHits extends MessageSearchResult {
  /// The query as it was searched, trimmed. Carried back so a screen can label
  /// a result set that arrived after the box was typed into again.
  final String query;

  final List<SemanticHit> hits;

  /// The passages of attached documents that answer the same query, nearest
  /// one per document.
  ///
  /// A separate list rather than more [hits], because a document hit is not a
  /// message: it is a fragment of a file, and it has to be shown with the file
  /// name and the place in it. Empty is the ordinary answer for a mailbox
  /// nobody has attached anything to, and for one whose chunk index is not
  /// built on this platform — neither is worth a third case here, because the
  /// message hits are an answer either way.
  final List<AttachmentChunkHit> documents;

  /// Messages the words match that the index did not already return, in date
  /// order behind the ranked [hits].
  ///
  /// The text pass runs on EVERY search and not only as a rescue, the same way
  /// the archive's does. A gate-dropped message never reached the embedder, so
  /// no vector was ever written for it and no amount of a healthy embedding
  /// server will make it findable by meaning — and it is exactly the pile a
  /// person comes to a search box looking for. Separate from [hits] because
  /// only those carry a distance: a shape that insisted on one would have to
  /// invent it.
  final List<HomeFeedRow> textRows;

  /// Non-null when ONLY the text pass contributed — the sentence to show over
  /// a set of results that is narrower than it looks.
  ///
  /// A fact about THIS result set rather than a standing condition of the
  /// screen, which is why it travels with the rows.
  final String? notice;

  const MessageSearchHits(
    this.query,
    this.hits, {
    this.documents = const [],
    this.textRows = const [],
    this.notice,
  });
}

/// A search that could not run, and the sentence to show for it.
class MessageSearchUnavailable extends MessageSearchResult {
  final String reason;

  const MessageSearchUnavailable(this.reason);
}

/// What a search of the archive came back with: rows, and a sentence when the
/// semantic half of it could not run.
///
/// Plain rather than part of [MessageSearchResult]'s sealed pair, because the
/// archive's search still ANSWERS when the embedding server is down — the text
/// pass runs either way. So unavailability here is a notice ON a result, where
/// above it is a case INSTEAD of one.
class ArchiveSearchResult {
  /// The query as it was searched, trimmed.
  final String query;

  /// Semantic matches first in rank order, then the text matches the index did
  /// not already return.
  final List<HomeFeedRow> rows;

  /// Non-null when only the text pass contributed.
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
  final List<AttachmentChunkHit> documents;
  final String? notice;
  final String? reason;

  const _SemanticPass(
    this.hits, {
    this.documents = const [],
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
/// Every search is two passes, and both public methods run them through the
/// same two private helpers. That is deliberate rather than tidy: the two used
/// to spell the pair out separately, and a corpus rule added to one and not
/// the other is a search that answers a different question depending on which
/// screen asked it.
class MessageSearch {
  final MessageStore _store;
  final EmbeddingsClient _embeddings;

  MessageSearch(this._store, this._embeddings);

  /// How many documents a search names. Small on purpose: they sit under the
  /// message hits, and a page of passages would bury the thing most people are
  /// actually looking for.
  static const int _documentLimit = 6;

  /// The home screen's search: ranked by meaning, filled in by words.
  ///
  /// [MessageSearchUnavailable] is what comes back only when BOTH passes
  /// failed, which in practice means the database itself is unreadable — an
  /// embedding server that is off leaves the text pass standing, and a text
  /// pass that throws under a healthy index leaves the ranking standing.
  Future<MessageSearchResult> search(
    String query, {
    int limit = 50,
    bool includeDropped = false,
  }) async {
    final text = query.trim();
    final pass = await _semantic(
      text,
      limit: limit,
      includeDropped: includeDropped,
    );

    List<HomeFeedRow> textRows;
    try {
      textRows = await _textBehind(
        text,
        pass.hits ?? const [],
        limit: limit,
        includeDropped: includeDropped,
      );
    } catch (e) {
      // Nothing left to show, so the sealed case earns itself: the reader is
      // owed the instruction rather than an empty list that reads as an answer
      // about their mailbox.
      if (pass.hits == null) {
        return MessageSearchUnavailable(
          pass.reason ?? 'the search could not run',
        );
      }
      // Ranked hits survive a text pass that fell over, and a reader looking
      // at them is not owed a sentence about the half that was only ever going
      // to widen the list.
      debugPrint('search: text pass failed: $e');
      textRows = const [];
    }

    return MessageSearchHits(
      text,
      pass.hits ?? const [],
      documents: pass.documents,
      textRows: textRows,
      notice: pass.notice,
    );
  }

  /// The same question asked of the whole history, both ways at once.
  ///
  /// Scope is ALL of it, dropped rows included, because the archive's selling
  /// point is "I know I got that email" — a search that quietly skipped the
  /// pile the gate threw out would answer that sentence with silence.
  ///
  /// The one difference from [search]: the two lists arrive flattened into one
  /// set of rows, because the archive ranks by date under the hits anyway and
  /// has no use for the seam.
  Future<ArchiveSearchResult> searchArchive(
    String query, {
    int limit = 50,
  }) async {
    final text = query.trim();
    final pass = await _semantic(text, limit: limit, includeDropped: true);
    final semantic = pass.hits ?? const <SemanticHit>[];

    return ArchiveSearchResult(
      text,
      [
        for (final hit in semantic) hit.row,
        ...await _textBehind(
          text,
          semantic,
          limit: limit,
          includeDropped: true,
        ),
      ],
      pass.notice,
    );
  }

  /// Embeds the query and ranks both corpora with it, or explains why it could
  /// not.
  Future<_SemanticPass> _semantic(
    String text, {
    required int limit,
    required bool includeDropped,
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
        notice: 'Text matches only — $subject.',
        reason: subject,
      );
    }

    final hits = await _store.semanticSearch(
      encodeEmbedding(vector),
      embedModel: EmbeddingsClient.documentModelTag,
      limit: limit,
      includeDropped: includeDropped,
    );
    // Null and not empty: the native index is missing on this build, which is
    // a different sentence from "no message matches".
    if (hits == null) {
      return const _SemanticPass(
        null,
        notice: 'Text matches only — the semantic index is unavailable.',
        reason: 'the semantic index is unavailable',
      );
    }
    // The same query vector against the second corpus. It runs only after the
    // message search has an answer, so a document search can never be the
    // reason a search reports itself unavailable.
    final chunks = await _store.searchAttachmentChunks(
      encodeEmbedding(vector),
      embedModel: EmbeddingsClient.documentModelTag,
      limit: _documentLimit,
      includeDropped: includeDropped,
    );
    return _SemanticPass(hits, documents: chunks ?? const []);
  }

  /// The word pass, minus whatever the index already ranked.
  ///
  /// Deduplicated on [HomeFeedRow.feedKey] rather than on the message id: an
  /// id is only unique within its connector, and a set keyed on half of a key
  /// would drop a Teams message because an email happened to share its id.
  Future<List<HomeFeedRow>> _textBehind(
    String text,
    List<SemanticHit> semantic, {
    required int limit,
    required bool includeDropped,
  }) async {
    final seen = {for (final hit in semantic) hit.row.feedKey};
    return [
      for (final row in await _store.textSearchMessages(
        text,
        limit: limit,
        includeDropped: includeDropped,
      ))
        if (seen.add(row.feedKey)) row,
    ];
  }
}
