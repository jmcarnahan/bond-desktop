import '../data/message_store.dart';
import '../models/home_models.dart';
import 'llm/embeddings_client.dart';

/// What a search came back with — hits, or a reason there are none.
///
/// Sealed and two-cased rather than a list that is sometimes empty, because
/// "nothing in your mail is about that" and "the thing that answers questions
/// is not running" are the two sentences a search screen must never confuse.
/// One is an answer; the other is an instruction to go and start a server.
sealed class MessageSearchResult {
  const MessageSearchResult();
}

/// A search that ran. [hits] may still be empty — that is a real answer.
class MessageSearchHits extends MessageSearchResult {
  /// The query as it was searched, trimmed. Carried back so a screen can label
  /// a result set that arrived after the box was typed into again.
  final String query;

  final List<SemanticHit> hits;

  const MessageSearchHits(this.query, this.hits);
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

/// Turns a sentence a person typed into ranked messages.
///
/// The search screen's ONLY door: it never reaches [EmbeddingsClient] or
/// [MessageStore] itself. Both halves of a search have to agree about the
/// corpus — the query is embedded under
/// [EmbeddingsClient.searchQueryPrefix] and matched against vectors written
/// under [EmbeddingsClient.documentPrefix] — and that pairing is the kind of
/// fact that survives exactly as long as it lives in one place.
class MessageSearch {
  final MessageStore _store;
  final EmbeddingsClient _embeddings;

  MessageSearch(this._store, this._embeddings);

  Future<MessageSearchResult> search(
    String query, {
    int limit = 50,
    bool includeDropped = false,
  }) async {
    final text = query.trim();

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
      return MessageSearchUnavailable(
        'the embedding server ${result.reason ?? 'did not answer'}',
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
      return const MessageSearchUnavailable(
        'the semantic index is unavailable',
      );
    }
    return MessageSearchHits(text, hits);
  }

  /// The same question asked of the whole history, both ways at once.
  ///
  /// Scope is ALL of it, dropped rows included, because the archive's selling
  /// point is "I know I got that email" — a search that quietly skipped the
  /// pile the gate threw out would answer that sentence with silence.
  ///
  /// The text pass runs EVERY time and not only as a rescue: gate-dropped
  /// messages have no vectors at all, so they are unreachable by meaning no
  /// matter how well the embedding server is running. Semantic ranking goes
  /// first because when it works it is the better answer; text fills in behind
  /// it with whatever it never had a chance to see.
  Future<ArchiveSearchResult> searchArchive(
    String query, {
    int limit = 50,
  }) async {
    final text = query.trim();

    String? notice;
    var semantic = const <SemanticHit>[];

    final result = await _embeddings.embedResult(
      text,
      prefix: EmbeddingsClient.searchQueryPrefix,
    );
    final vector = result.vector;
    if (vector == null) {
      notice = 'Text matches only — the embedding server '
          '${result.reason ?? 'did not answer'}.';
    } else {
      final hits = await _store.semanticSearch(
        encodeEmbedding(vector),
        embedModel: EmbeddingsClient.documentModelTag,
        limit: limit,
        includeDropped: true,
      );
      if (hits == null) {
        notice = 'Text matches only — the semantic index is unavailable.';
      } else {
        semantic = hits;
      }
    }

    final rows = [for (final hit in semantic) hit.row];
    final seen = {for (final row in rows) row.feedKey};
    for (final row in await _store.textSearchMessages(text, limit: limit)) {
      if (seen.add(row.feedKey)) rows.add(row);
    }
    return ArchiveSearchResult(text, rows, notice);
  }
}
