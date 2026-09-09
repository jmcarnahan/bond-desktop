import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../models/attachment_models.dart';
import '../models/files_models.dart';
import '../services/message_search.dart';
import '../services/search_grammar.dart';
import 'app_providers.dart';

/// What the Files stop is looking at: one shelf of every document in the
/// mailbox, and — when somebody asks a question of it — the passages that
/// answer.
///
/// Paged rather than held whole, because unlike the drafts pane there is no
/// bound on how many files a mailbox has: a year of mail is thousands, and a
/// list that read them all to draw the first screen would spend a second doing
/// it.
///
/// The kind lives HERE rather than in the screen, because two controls change
/// it — the rows on the rail and the pills in the pane — and two places
/// holding one fact is how they come to disagree. The SOURCES do not: the
/// header's chips already scope every pane, so they are passed per call by the
/// screen that owns them.
///
/// The one rule it shares with every other list in the app: **stamp before the
/// first await**. A page-one read started before a kind change can land after
/// it, and an answer to a question that is no longer standing must write
/// nothing.

/// How a query is answered. The `sources` argument is the `in:` facet, honoured
/// in SQL — see [MessageSearch.search].
typedef FilesSearchRunner = Future<MessageSearchResult> Function(
  String query, {
  List<String> sources,
});

@immutable
class FilesState {
  /// The shelf, newest message first.
  final List<FileRow> rows;

  /// Whether a read has come back at all — success or failure. What separates
  /// "nothing has been read yet" from "there are no files", which are the same
  /// empty list and very different sentences.
  final bool loaded;

  /// Whether a further page is on its way, for a Load more that must not fire
  /// twice.
  final bool loadingMore;

  /// Whether the last page came back short, which is the only honest way to
  /// know a paged list has ended.
  final bool atEnd;

  /// Non-null when the newest read failed. Whatever rows are on screen stay
  /// there: a pane that blanked on a failed re-read would throw away a list
  /// that is still perfectly true.
  final String? error;

  final FilesKind kind;

  /// The passages that answered a query, or null while the live list is up.
  /// Only documents: a message hit is not a file, and the Files stop is about
  /// files.
  final List<AttachmentChunkHit>? search;

  /// The RAW query those results answer, facets and all — it is what the reader
  /// typed and what the box still shows.
  final String? searchQuery;

  final bool searching;

  /// Why a search did not answer — the index is down, or the query was nothing
  /// but filters. A notice ON the pane rather than a replacement for it.
  final String? searchNotice;

  const FilesState({
    this.rows = const [],
    this.loaded = false,
    this.loadingMore = false,
    this.atEnd = false,
    this.error,
    this.kind = FilesKind.all,
    this.search,
    this.searchQuery,
    this.searching = false,
    this.searchNotice,
  });

  /// Explicit `clear` flags rather than nullable-means-keep, on
  /// `DraftsInboxState`'s precedent: a banner that could only be set and never
  /// cleared would outlive the failure it described.
  FilesState copyWith({
    List<FileRow>? rows,
    bool? loaded,
    bool? loadingMore,
    bool? atEnd,
    String? error,
    bool clearError = false,
    FilesKind? kind,
    List<AttachmentChunkHit>? search,
    bool clearSearch = false,
    String? searchQuery,
    bool? searching,
    String? searchNotice,
    bool clearSearchNotice = false,
  }) =>
      FilesState(
        rows: rows ?? this.rows,
        loaded: loaded ?? this.loaded,
        loadingMore: loadingMore ?? this.loadingMore,
        atEnd: atEnd ?? this.atEnd,
        error: clearError ? null : (error ?? this.error),
        kind: kind ?? this.kind,
        search: clearSearch ? null : (search ?? this.search),
        searchQuery: clearSearch ? null : (searchQuery ?? this.searchQuery),
        searching: searching ?? this.searching,
        searchNotice:
            clearSearchNotice ? null : (searchNotice ?? this.searchNotice),
      );
}

/// Shown when a read failed but there is still a list to look at.
const String _staleMessage =
    "Couldn't read your files just now — showing what was already here.";

/// Shown for a query that is nothing but filters. Word for word the home feed's
/// sentence, because it is the same mistake and there is no second way to
/// explain it.
const String _facetsOnlyNotice =
    'Add a word or two to search for — the filters alone are not a question.';

class FilesNotifier extends StateNotifier<FilesState> {
  final MessageStore _store;

  /// How a query is answered. Null in a test that never searches, and nowhere
  /// else — [submitSearch] without one is a no-op rather than a crash.
  final FilesSearchRunner? _runSearch;

  /// Numbers every page-one read, so a slow one that lands after a newer one
  /// writes nothing. [loadMore] reads it without incrementing: an older page
  /// must never win over a newer first page, and it must never invalidate one
  /// either.
  int _seq = 0;

  /// The same guard for searches, and a separate number on purpose — a kind
  /// change under a set of results must not cancel them.
  int _searchSeq = 0;

  FilesNotifier(this._store, {required FilesSearchRunner? searchRunner})
      : _runSearch = searchRunner,
        super(const FilesState());

  /// A screenful and then some. Large because a file card is small and a day
  /// of mail can carry a dozen.
  static const int pageSize = 100;

  /// Page one of the current kind.
  Future<void> load({required List<String> sources}) async {
    final seq = ++_seq;
    try {
      final rows = await _store.recentAttachments(
        sources: sources,
        kind: state.kind,
        limit: pageSize,
      );
      if (seq != _seq || !mounted) return;
      state = state.copyWith(
        rows: rows,
        loaded: true,
        loadingMore: false,
        atEnd: rows.length < pageSize,
        clearError: true,
      );
    } catch (e) {
      if (seq != _seq || !mounted) return;
      debugPrint('files read failed: $e');
      state = state.copyWith(
        loaded: true,
        loadingMore: false,
        error: _staleMessage,
      );
    }
  }

  /// The next page, appended.
  ///
  /// The offset is what is already on screen rather than a page counter: a
  /// reload can change the length of the list under it, and counting pages
  /// would then skip or repeat one.
  Future<void> loadMore({required List<String> sources}) async {
    if (state.loadingMore || state.atEnd || !state.loaded) return;
    final seq = _seq;
    final offset = state.rows.length;
    state = state.copyWith(loadingMore: true);
    try {
      final more = await _store.recentAttachments(
        sources: sources,
        kind: state.kind,
        limit: pageSize,
        offset: offset,
      );
      if (seq != _seq || !mounted) return;
      // A page is only the NEXT page of the list it was asked against. A kind
      // change that was already in flight when this started shares its
      // sequence number and shortens the list under it; appending rows 200
      // onward to a list that now ends at 100 would leave a hole nobody could
      // see.
      if (state.rows.length != offset) {
        state = state.copyWith(loadingMore: false);
        return;
      }
      state = state.copyWith(
        rows: [...state.rows, ...more],
        loadingMore: false,
        // A short page is the end. Asking for one more and getting nothing
        // would cost a query to learn what this already knows.
        atEnd: more.length < pageSize,
        clearError: true,
      );
    } catch (e) {
      if (seq != _seq || !mounted) return;
      debugPrint('files page read failed: $e');
      state = state.copyWith(loadingMore: false, error: _staleMessage);
    }
  }

  /// Narrows the shelf and re-reads it from the top.
  ///
  /// The kind runs in SQL, so a change is a new question rather than a filter
  /// over what is in hand — see [MessageStore.recentAttachments].
  Future<void> setKind(FilesKind kind, {required List<String> sources}) async {
    state = state.copyWith(kind: kind, atEnd: false);
    await load(sources: sources);
  }

  /// Asks the index a sentence and shows the documents that answer it.
  ///
  /// Submission is the whole gate, [HomeFeedNotifier.submitSearch]'s rule: a
  /// query costs an embedding call, so this runs on Enter and never on a
  /// keystroke.
  ///
  /// The live rows are KEPT underneath. Leaving search is then instant, and a
  /// search that fails costs the reader nothing they were already looking at.
  Future<void> submitSearch(
    String query, {
    required List<String> sources,
  }) async {
    final text = query.trim();
    if (text.isEmpty) return;
    final runner = _runSearch;
    if (runner == null) return;

    // The facets come off first, and what is left is the question. A query of
    // nothing but filters is not one: there is no sentence to embed, and
    // embedding the empty string would rank the whole shelf by its distance
    // from nothing at all.
    final parsed = parseSearchQuery(text);
    if (parsed.text.isEmpty) {
      state = state.copyWith(
        searching: false,
        searchNotice: _facetsOnlyNotice,
      );
      return;
    }

    final seq = ++_searchSeq;
    state = state.copyWith(searching: true, clearSearchNotice: true);

    final MessageSearchResult result;
    try {
      result = await runner(
        parsed.text,
        // `in:` beats the header's chips: the reader typed it into this query,
        // and a facet that was quietly ignored is worse than one that does not
        // exist.
        sources: parsed.source == null ? sources : parsed.sources,
      );
    } catch (e) {
      // [MessageSearch] answers rather than throws, by contract — but the
      // runner crosses the database on its way there, and a pane left
      // searching forever is the one outcome this must not have.
      if (seq != _searchSeq || !mounted) return;
      debugPrint('files search failed: $e');
      state = state.copyWith(
        searching: false,
        searchNotice: "Search failed — couldn't read the index.",
      );
      return;
    }
    if (seq != _searchSeq || !mounted) return;

    switch (result) {
      case MessageSearchHits():
        state = state.copyWith(
          // Documents only. A message that mentions a contract is a fine
          // answer somewhere else; the Files stop was asked about files.
          search: result.documents,
          // The RAW query, facets and all — it is what the reader typed and
          // what the box still shows.
          searchQuery: text,
          searching: false,
        );
      case MessageSearchUnavailable():
        state = state.copyWith(
          searching: false,
          searchNotice: 'Search is unavailable — ${result.reason}',
        );
    }
  }

  /// Back to the live shelf.
  ///
  /// Instant, because the rows under the results were never unloaded. The stamp
  /// moves first: an answer still in flight belongs to a search that no longer
  /// exists.
  void exitSearch() {
    _searchSeq++;
    state = state.copyWith(
      clearSearch: true,
      searching: false,
      clearSearchNotice: true,
    );
  }
}

/// NOT autoDispose, on `draftsInboxProvider`'s precedent: the shelf belongs to
/// the session rather than to the frame, so leaving for a file and coming back
/// lands on the page that was there. The screen re-reads it on arrival and on
/// every refresh, which is what keeps it honest.
final filesProvider =
    StateNotifierProvider<FilesNotifier, FilesState>((ref) {
  return FilesNotifier(
    ref.watch(messageStoreProvider),
    searchRunner: (query, {sources = const ['email', 'teams']}) =>
        ref.read(messageSearchProvider).search(query, sources: sources),
  );
});
