/// The four questions every golden loader asks of a decoded JSON tree, and
/// the one rule about how it decodes one.
///
/// One copy, because there were three: `golden_set.dart`,
/// `golden_registry.dart` and `golden_storyline.dart` each carried their own
/// private `_asMap` / `_asList` / `_asStrings` / `_asString`, written to the
/// same contract and free to drift apart the day one of them was edited. The
/// contract is worth stating once: a field of the wrong TYPE is "not
/// recorded", never a cast error halfway through loading a hundred items.
///
/// That tolerance is the whole point. The golden files are hand-maintained
/// and machine-local, so a field somebody typed as a number where a string
/// belongs must cost that one field and nothing else — a loader that threw
/// would take a ninety-minute run down over a typo in an item nobody is
/// scoring.
library;

/// [value] as a string-keyed map, or an empty one.
Map<String, dynamic> asMap(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : const <String, dynamic>{};

/// [value] as a list, or an empty one.
List<Object?> asList(Object? value) => value is List ? value : const <Object?>[];

/// [value] as a list of strings, nulls dropped and everything else rendered.
///
/// Rendered rather than dropped because these lists are names, slugs and
/// reasons a person typed: a number where a slug belongs is still the thing
/// the author meant, and dropping it would shrink a denominator silently.
List<String> asStrings(Object? value) =>
    [for (final entry in asList(value)) if (entry != null) '$entry'];

/// [value] as a string, or [fallback].
String asString(Object? value, [String fallback = '']) =>
    value is String ? value : fallback;

/// [load], with a malformed file named rather than thrown at.
///
/// `jsonDecode`'s own `FormatException` says "Unexpected character at 41231"
/// and nothing about WHICH file it gave up on, which is the difference between
/// a two-minute fix and an afternoon: a golden run reads a set, a registry and
/// a run file, and the loaders are handed their paths by a define nobody
/// reads twice.
///
/// The exception's text is not repeated beyond its message. A decode error can
/// carry the bytes it choked on, and these files are real correspondence.
///
/// One copy, for the reason at the top of this file: `LiveBench.decodeOrFail`
/// is this function under the name the benches already call it by.
Future<T> decodeJsonOrFail<T>(String path, Future<T> Function() load) async {
  try {
    return await load();
  } on FormatException catch (e) {
    throw StateError('could not read $path as JSON: ${e.message}');
  }
}
