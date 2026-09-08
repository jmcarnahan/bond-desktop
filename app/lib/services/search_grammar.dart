import 'package:flutter/foundation.dart' show immutable;

import '../models/home_models.dart';

/// The facets a search box understands, and what is left of the query once
/// they have been lifted out of it.
///
/// A facet is a FILTER and never a ranker. The words the reader typed are what
/// the index is asked about; `from:` and the rest only decide which of the
/// answers survive. That split is why this file is pure and knows nothing
/// about the store: the one facet the database can honour cheaply — the
/// connector — travels down as [sources], and everything else runs here over
/// rows that have already come back.
@immutable
class SearchQuery {
  /// What is left to embed, trimmed. Empty is a legitimate parse — the reader
  /// typed only filters — and the caller is expected to refuse to search on
  /// it rather than embed the empty string.
  final String text;

  /// A sender needle, already lowercased, matched against the name OR the
  /// address. One field would be the wrong one about half the time: a reader
  /// types "dana" for a name they have seen and "@example.com" for a domain
  /// they have not.
  final String? from;

  /// `'email'`, `'teams'`, or null for both.
  final String? source;

  final bool hasFile;

  /// UTC midnight of the day the reader named. [before] keeps hits STRICTLY
  /// earlier than it; [after] keeps hits at or later than it. The asymmetry is
  /// what makes `after:2026-09-07` include the seventh, which is what anyone
  /// typing it means.
  final DateTime? before;
  final DateTime? after;

  const SearchQuery({
    this.text = '',
    this.from,
    this.source,
    this.hasFile = false,
    this.before,
    this.after,
  });

  /// Whether the reader narrowed anything at all. What tells a bare sentence
  /// apart from one carrying filters, for a caller deciding whether the empty
  /// [text] is a mistake or simply an empty box.
  bool get hasFacets =>
      from != null || source != null || hasFile || before != null || after != null;

  /// The connectors the store should be asked about. The ONE facet that runs
  /// in SQL: the source is a column on every row the search reads, so
  /// narrowing there costs nothing and narrowing here would throw away hits
  /// the index had already spent its budget on.
  List<String> get sources =>
      source == null ? const ['email', 'teams'] : [source!];
}

/// `YYYY-MM-DD` and nothing else. A date facet is only useful if the reader
/// can predict what it accepts, and `DateTime.tryParse` alone accepts a dozen
/// spellings including bare years — so `before:2026` would silently become the
/// first of January rather than staying the word the reader meant.
final RegExp _dayOnly = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// Splits on whitespace, keeping anything inside double quotes together.
///
/// The quotes are dropped as they are read, so `from:"Dana Whitfield"` arrives
/// as one token spelled `from:Dana Whitfield` and a bare `"two words"` arrives
/// as the two words with nothing around them. That is deliberate: quoting is a
/// grouping gesture, not something the reader wants searched for.
List<String> _tokenise(String raw) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  var quoted = false;

  void flush() {
    final token = buffer.toString();
    buffer.clear();
    if (token.isNotEmpty) tokens.add(token);
  }

  for (var i = 0; i < raw.length; i++) {
    final ch = raw[i];
    if (ch == '"') {
      quoted = !quoted;
      continue;
    }
    if (!quoted && (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r')) {
      flush();
      continue;
    }
    buffer.write(ch);
  }
  flush();
  return tokens;
}

/// Reads a typed query into its facets and the sentence underneath them.
///
/// Every unrecognised `word:` token STAYS TEXT — an unknown facet, a value the
/// facet does not take, an empty one. A search box that swallowed
/// `re:` or a URL because it looked like a facet would be a box the reader
/// cannot trust with an ordinary sentence, and there is no error channel here
/// to tell them what happened.
SearchQuery parseSearchQuery(String raw) {
  String? from;
  String? source;
  var hasFile = false;
  DateTime? before;
  DateTime? after;
  final words = <String>[];

  DateTime? day(String value) {
    if (!_dayOnly.hasMatch(value)) return null;
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return null;
    // Re-minted in UTC rather than used as parsed: a bare date parses as LOCAL
    // midnight, and comparing that against the stored UTC stamps would move
    // the boundary by the reader's offset.
    return DateTime.utc(parsed.year, parsed.month, parsed.day);
  }

  for (final token in _tokenise(raw)) {
    final colon = token.indexOf(':');
    // A colon at the very start is not a facet name, and one at the very end
    // is a facet with nothing in it — both are text.
    if (colon > 0 && colon < token.length - 1) {
      final name = token.substring(0, colon).toLowerCase();
      final value = token.substring(colon + 1);
      switch (name) {
        case 'from':
          from = value.toLowerCase();
          continue;
        case 'in':
          final resolved = switch (value.toLowerCase()) {
            'mail' || 'email' || 'outlook' => 'email',
            'teams' || 'chat' => 'teams',
            _ => null,
          };
          if (resolved != null) {
            source = resolved;
            continue;
          }
        case 'has':
          if (const {'file', 'files', 'attachment', 'attachments'}
              .contains(value.toLowerCase())) {
            hasFile = true;
            continue;
          }
        case 'before':
          final bound = day(value);
          if (bound != null) {
            before = bound;
            continue;
          }
        case 'after':
          final bound = day(value);
          if (bound != null) {
            after = bound;
            continue;
          }
      }
    }
    words.add(token);
  }

  return SearchQuery(
    text: words.join(' ').trim(),
    from: from,
    source: source,
    hasFile: hasFile,
    before: before,
    after: after,
  );
}

/// Drops the hits the facets exclude, keeping the index's ranking order.
///
/// The source facet is NOT applied here: it went down to the store as
/// [SearchQuery.sources] and the rows that came back already honour it.
/// Filtering it a second time would be harmless and misleading — a reader of
/// this function would think the narrowing happened late.
///
/// Both date comparisons are string comparisons of ISO UTC stamps, which is
/// exact rather than lucky: `HomeFeedRow.receivedAt` is written by the store as
/// an ISO-8601 UTC string and the bound is minted as one, so the two sort
/// lexicographically in the same order they sort chronologically. A row with
/// no stamp at all fails any date facet — a message that cannot say when it
/// arrived cannot be shown to have arrived inside a window.
List<SearchHit> filterHits(SearchQuery query, List<SearchHit> hits) {
  if (query.from == null &&
      !query.hasFile &&
      query.before == null &&
      query.after == null) {
    return hits;
  }

  final needle = query.from;
  final before = query.before?.toIso8601String();
  final after = query.after?.toIso8601String();

  bool keep(HomeFeedRow row) {
    if (needle != null) {
      final name = row.fromName?.toLowerCase() ?? '';
      final address = row.fromAddress?.toLowerCase() ?? '';
      if (!name.contains(needle) && !address.contains(needle)) return false;
    }
    if (query.hasFile && !row.hasAttachments) return false;
    if (before != null || after != null) {
      final at = row.receivedAt;
      if (at.isEmpty) return false;
      if (before != null && at.compareTo(before) >= 0) return false;
      if (after != null && at.compareTo(after) < 0) return false;
    }
    return true;
  }

  return [
    for (final hit in hits)
      if (keep(hit.row)) hit,
  ];
}
