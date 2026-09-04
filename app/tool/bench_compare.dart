import 'dart:convert';
import 'dart:io';

/// Two bench results, side by side.
///
/// A bakeoff is decided by a difference, and a difference needs two runs that
/// still exist — which is what `test/fixtures/bench_report.dart` writes and
/// this reads. Deliberately plain `dart:io`: it runs against a JSON file, has
/// no reason to load Flutter, and starting it should cost nothing.
///
///   `dart run tool/bench_compare.dart <a.json> <b.json>`
///
/// Multi-target files (the A/B benches write two) compare POSITIONALLY, first
/// target against first target. Comparing by label would be worse, not better:
/// the labels are what change between candidates, so matching on them would
/// silently compare nothing at all.

const int _usageExit = 2;

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: dart run tool/bench_compare.dart <a.json> <b.json>');
    exit(_usageExit);
  }

  final a = _read(args[0]);
  final b = _read(args[1]);

  if (a['bench'] != b['bench']) {
    stderr.writeln(
      'refusing: ${args[0]} is "${a['bench']}" and ${args[1]} is '
      '"${b['bench']}" — different benches measure different work, and a '
      'table putting them in one row would compare nothing.',
    );
    exit(_usageExit);
  }

  final aTarget = _firstTarget(a);
  final bTarget = _firstTarget(b);

  stdout.writeln('bench: ${a['bench']}');
  stdout.writeln();
  _writeTasks(aTarget, bTarget);
  stdout.writeln();
  _writeAccuracy(a, b);
  stdout.writeln();
  stdout.writeln('A: ${aTarget['label'] ?? '—'}  B: ${bTarget['label'] ?? '—'}');
}

Map<String, Object?> _read(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('no such file: $path');
    exit(_usageExit);
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on FormatException catch (e) {
    stderr.writeln('$path is not JSON: $e');
    exit(_usageExit);
  }
  if (decoded is! Map<String, Object?>) {
    stderr.writeln('$path is not a bench result document');
    exit(_usageExit);
  }
  return decoded;
}

Map<String, Object?> _firstTarget(Map<String, Object?> doc) {
  final targets = doc['targets'];
  if (targets is List && targets.isNotEmpty && targets.first is Map) {
    return Map<String, Object?>.from(targets.first as Map);
  }
  return const {};
}

/// Task name → its row, in the order the run produced them.
Map<String, Map<String, Object?>> _tasksOf(Map<String, Object?> target) {
  final out = <String, Map<String, Object?>>{};
  final tasks = target['tasks'];
  if (tasks is! List) return out;
  for (final t in tasks) {
    if (t is Map && t['task'] is String) {
      out[t['task'] as String] = Map<String, Object?>.from(t);
    }
  }
  return out;
}

void _writeTasks(Map<String, Object?> aTarget, Map<String, Object?> bTarget) {
  final aTasks = _tasksOf(aTarget);
  final bTasks = _tasksOf(bTarget);
  // A's order first, then anything only B ran — a task the candidate added is
  // worth seeing, and dropping it would hide it.
  final names = <String>[
    ...aTasks.keys,
    ...bTasks.keys.where((k) => !aTasks.containsKey(k)),
  ];

  stdout.writeln('| task | A p50 | B p50 | Δ ms | A gen t/s | B gen t/s | Δ% |');
  stdout.writeln('| --- | --- | --- | --- | --- | --- | --- |');
  for (final name in names) {
    final at = aTasks[name];
    final bt = bTasks[name];
    final ap50 = _int(at?['p50_ms']);
    final bp50 = _int(bt?['p50_ms']);
    final atps = _double(at?['gen_tps']);
    final btps = _double(bt?['gen_tps']);

    final deltaMs = (ap50 == null || bp50 == null) ? '—' : _signed(bp50 - ap50);
    final deltaPct = (atps == null || btps == null || atps == 0)
        ? '—'
        : '${_signedNum((btps - atps) / atps * 100)}%';

    stdout.writeln(
      '| $name | ${ap50 ?? '—'} | ${bp50 ?? '—'} | $deltaMs '
      '| ${_rate(atps)} | ${_rate(btps)} | $deltaPct |',
    );
  }
}

void _writeAccuracy(Map<String, Object?> a, Map<String, Object?> b) {
  final aCards = _cardsOf(a);
  final bCards = _cardsOf(b);
  if (aCards.isEmpty && bCards.isEmpty) {
    stdout.writeln('no accuracy scored on either side');
    return;
  }

  final names = <String>[
    ...aCards.keys,
    ...bCards.keys.where((k) => !aCards.containsKey(k)),
  ];

  stdout.writeln('| dimension | A | B |');
  stdout.writeln('| --- | --- | --- |');
  for (final name in names) {
    final ac = aCards[name];
    final bc = bCards[name];
    final aHits = _int(ac?['hits']);
    final bHits = _int(bc?['hits']);
    final aJudged = _int(ac?['judged']);
    final bJudged = _int(bc?['judged']);
    // Bold only when the comparison is honest: fewer hits out of the SAME
    // number judged is a regression, while fewer hits out of fewer questions
    // is a shorter run.
    final worse = aHits != null &&
        bHits != null &&
        aJudged != null &&
        aJudged == bJudged &&
        bHits < aHits;
    String bold(String cell) => worse ? '**$cell**' : cell;
    stdout.writeln('| ${bold(name)} | ${bold(_score(aHits, aJudged))} '
        '| ${bold(_score(bHits, bJudged))} |');
  }
}

Map<String, Map<String, Object?>> _cardsOf(Map<String, Object?> doc) {
  final out = <String, Map<String, Object?>>{};
  final accuracy = doc['accuracy'];
  if (accuracy is! List) return out;
  for (final c in accuracy) {
    if (c is Map && c['dimension'] is String) {
      out[c['dimension'] as String] = Map<String, Object?>.from(c);
    }
  }
  return out;
}

int? _int(Object? v) => v is num ? v.toInt() : null;

double? _double(Object? v) => v is num ? v.toDouble() : null;

String _rate(double? tps) => tps == null ? '—' : tps.toStringAsFixed(1);

String _score(int? hits, int? judged) =>
    (hits == null || judged == null) ? '—' : '$hits/$judged';

String _signed(int v) => v > 0 ? '+$v' : '$v';

String _signedNum(double v) {
  final text = v.toStringAsFixed(1);
  return v > 0 ? '+$text' : text;
}
