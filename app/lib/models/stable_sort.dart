/// [items] in [compare]'s order, with ties left in the order they arrived.
///
/// Dart's own `List.sort` is not stable, and every list in this app that
/// wants a stable order — the Needs You pile, the People directory, a
/// person's threads — used to carry the input position through by hand and
/// use it as the final tie-break. Written once, here, so those sorts differ
/// only in their comparator, which is the only thing that actually differs.
///
/// A comparator that returns 0 for everything hands the input back
/// unchanged, which is what "the input untouched" orders rely on.
List<T> stableSorted<T>(List<T> items, int Function(T a, T b) compare) {
  final indexed = <(int, T)>[];
  var index = 0;
  for (final item in items) {
    indexed.add((index++, item));
  }
  indexed.sort((a, b) {
    final by = compare(a.$2, b.$2);
    if (by != 0) return by;
    return a.$1.compareTo(b.$1);
  });
  return [for (final (_, item) in indexed) item];
}
