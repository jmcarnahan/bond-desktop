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
}
