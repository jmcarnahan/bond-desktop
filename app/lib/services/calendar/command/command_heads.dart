import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import '../../decision/decision_heads.dart' show DecisionHeads;
import 'command_types.dart';

/// Why a command heads file was not used. The sentence is for a debug line;
/// nobody is shown it, since the bar simply reads commands without a head.
class CommandHeadsRefused implements Exception {
  final String reason;

  const CommandHeadsRefused(this.reason);

  @override
  String toString() => 'CommandHeadsRefused: $reason';
}

/// The decision model's command head: one linear layer and a calibration
/// temperature that name a Day-bar command's action from the decision
/// encoder's raw pooled vector (plan §1.1 "The command head",
/// docs/pipeline/14-calendar.md "Commands").
///
/// It is a SECOND head on the same encoder, fitted by
/// `tools/calendar_heads/fit.py` (`make calendar-heads`) on the fictional
/// labelled commands in `test/fixtures/calendar_commands/`, and shipped as
/// `assets/calendar/command_heads.json`. Kept apart from [DecisionHeads]
/// (pinned: the nine message heads, their file and their refusals) because
/// it answers a different question over a different input — the typed
/// command itself, not a rendered message state.
///
/// **Tied to the encoder.** A head reads the vector space of the encoder it
/// was fitted on and nothing else, so the file names that encoder twice: by
/// its question set (`encoder_qhash`, which must be
/// [DecisionHeads.expectedQhash] — refused here, at load) and by the model's
/// own name (`encoder_model`, copied by the fit from the installed
/// `decide-heads.json`'s `model` — compared with the installed heads at every
/// call, by `DecisionCommandClassifier`, because the installed model can
/// change under a running app). Either one off, and the bar reads commands
/// with the lexicon alone. The same for a file whose options are not the ten
/// actions in [CommandAction] order: the index of a logit IS its meaning.
///
/// **Ten options, not eleven.** The head predicts the ten real actions;
/// `unknown` is what a guess below the bar becomes ([apply]), so the router
/// falls through to the lexicon rather than trusting an unsure head.
class CommandHeads {
  /// The file's own format word; any other is refused.
  static const String format = 'bond-command-heads/1';

  /// What the vector was taken of: the command text as typed, sent to the
  /// server as text (`DecisionClient.embedRaw`), never a rendered state.
  static const String input = 'raw-text/1';

  /// The question set of the encoder the head was fitted on, which must be
  /// [DecisionHeads.expectedQhash]. A question hash names the questions the
  /// encoder was trained under, not the encoder: two trainings on one
  /// question set share it, which is what [encoderModel] is for.
  final String encoderQhash;

  /// The decision model the head was fitted on: the `model` of the
  /// `decide-heads.json` installed when `fit.py` ran. The classifier refuses
  /// the head when the installed heads name another model.
  final String encoderModel;

  /// The ten wire words, in [CommandAction] order ([expectedOptions]).
  final List<String> options;

  /// options × dim.
  final List<List<double>> weight;
  final List<double> bias;
  final double temperature;

  /// The fit's own record ([fitted] in the file): how many commands it was
  /// fitted and held out on, and its held-out accuracy. The lexicon's
  /// held-out accuracy is the Dart side's number
  /// (`test/calendar_command_heldout_test.dart`), so a freshly fitted file
  /// carries null there.
  final int nTrain, nHeldout;
  final double heldoutAcc;
  final double? lexiconHeldoutAcc;

  final List<Float64List> _rows;
  final Float64List _bias;

  CommandHeads._({
    required this.encoderQhash,
    required this.encoderModel,
    required this.options,
    required this.weight,
    required this.bias,
    required this.temperature,
    required this.nTrain,
    required this.nHeldout,
    required this.heldoutAcc,
    required this.lexiconHeldoutAcc,
  })  : _rows = [for (final r in weight) Float64List.fromList(r)],
        _bias = Float64List.fromList(bias);

  /// The options a file must carry: every action's wire word, in enum
  /// order, without `unknown`.
  static final List<String> expectedOptions = [
    for (final a in CommandAction.values)
      if (a != CommandAction.unknown) a.wire,
  ];

  /// The vector width every row reads.
  int get dim => _rows.first.length;

  /// Reads and validates [json]: `{format, encoder_qhash, encoder_model,
  /// input, fields:
  /// {action: {options, weight, bias, temperature}}, fitted: {n_train,
  /// n_heldout, heldout_acc, lexicon_heldout_acc}}`. Throws
  /// [CommandHeadsRefused] with the reason for anything [apply] could not
  /// trust.
  static CommandHeads load(String json) {
    Never refuse(String why) =>
        throw CommandHeadsRefused('The command heads file $why.');

    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      refuse('is not JSON');
    }
    if (decoded is! Map) refuse('is not a JSON object');
    if (decoded['format'] != format) {
      refuse('has format ${decoded['format']}, not $format');
    }
    if (decoded['input'] != input) {
      refuse('reads input ${decoded['input']}, not $input');
    }
    final qhash = decoded['encoder_qhash'];
    if (qhash != DecisionHeads.expectedQhash) {
      refuse('was fitted on question set $qhash, not '
          '${DecisionHeads.expectedQhash}');
    }
    final encoderModel = decoded['encoder_model'];
    if (encoderModel is! String || encoderModel.trim().isEmpty) {
      refuse('names no encoder model');
    }

    final fields = decoded['fields'];
    final action = fields is Map ? fields['action'] : null;
    if (action is! Map) refuse('has no action head');

    final options = action['options'];
    final expected = expectedOptions;
    if (options is! List ||
        options.length != expected.length ||
        [for (var i = 0; i < expected.length; i++) options[i] == expected[i]]
            .contains(false)) {
      refuse('does not carry the ${expected.length} actions in order');
    }
    final n = expected.length;

    final weight = action['weight'];
    if (weight is! List || weight.length != n) {
      refuse('has a weight that is not $n rows');
    }
    final rows = <List<double>>[];
    int? width;
    for (final row in weight) {
      if (row is! List || row.isEmpty) refuse('has an empty weight row');
      width ??= row.length;
      if (row.length != width) refuse('has ragged weight rows');
      rows.add(_numbers(row, () => refuse('has a non-number in its weight')));
    }

    final bias = action['bias'];
    if (bias is! List || bias.length != n) {
      refuse('has a bias that is not $n long');
    }
    final temperature = action['temperature'];
    if (temperature is! num || !temperature.isFinite || temperature <= 0) {
      refuse('has a temperature that is not a positive number');
    }

    final fitted = decoded['fitted'];
    if (fitted is! Map) refuse('has no fitted record');
    final nTrain = fitted['n_train'];
    final nHeldout = fitted['n_heldout'];
    final acc = fitted['heldout_acc'];
    final lexicon = fitted['lexicon_heldout_acc'];
    if (nTrain is! int || nHeldout is! int || acc is! num) {
      refuse('has an incomplete fitted record');
    }
    if (lexicon != null && lexicon is! num) {
      refuse('has a lexicon accuracy that is not a number');
    }

    return CommandHeads._(
      encoderQhash: qhash as String,
      encoderModel: encoderModel,
      options: List.unmodifiable(expected),
      weight: List.unmodifiable(rows),
      bias: List.unmodifiable(
          _numbers(bias, () => refuse('has a non-number in its bias'))),
      temperature: temperature.toDouble(),
      nTrain: nTrain,
      nHeldout: nHeldout,
      heldoutAcc: acc.toDouble(),
      lexiconHeldoutAcc: (lexicon as num?)?.toDouble(),
    );
  }

  static List<double> _numbers(List<Object?> values, Never Function() bad) => [
        for (final v in values) v is num && v.isFinite ? v.toDouble() : bad(),
      ];

  /// Every option's calibrated probability for one raw pooled vector, in
  /// [options] order: `softmax((W·x + b) / T)`, max-subtracted so a large
  /// logit cannot overflow `exp`. Throws [CommandHeadsRefused] for a vector
  /// of another width — a server whose encoder is not the one the file was
  /// fitted on.
  List<double> probabilities(List<double> vector) {
    if (vector.length != dim) {
      throw CommandHeadsRefused(
          'The command head reads $dim numbers, not ${vector.length}.');
    }
    final n = _rows.length;
    final logits = Float64List(n);
    for (var o = 0; o < n; o++) {
      final row = _rows[o];
      var dot = _bias[o];
      for (var k = 0; k < row.length; k++) {
        dot += row[k] * vector[k];
      }
      logits[o] = dot / temperature;
    }
    final top = logits.reduce(math.max);
    final exps = [for (final l in logits) math.exp(l - top)];
    final sum = exps.fold(0.0, (a, b) => a + b);
    return [for (final e in exps) e / sum];
  }

  /// The head's guess: the argmax (the first on a tie) when its probability
  /// is at least [bar], otherwise `unknown` carrying that probability — the
  /// head answers only above its bar, and the router falls through to the
  /// lexicon on an `unknown`.
  CommandGuess apply(List<double> vector, {double bar = 0.80}) {
    final p = probabilities(vector);
    var best = 0;
    for (var o = 1; o < p.length; o++) {
      if (p[o] > p[best]) best = o;
    }
    final action = p[best] >= bar
        ? CommandActionWire.parse(options[best])
        : CommandAction.unknown;
    return CommandGuess(action, p[best], CommandPath.head);
  }
}

/// Where the fitted head ships. The DIRECTORY is what `pubspec.yaml`
/// registers, so a build with no fitted file (none yet, or a fit that did
/// not clear the adoption bar) still builds.
const String commandHeadsAsset = 'assets/calendar/command_heads.json';

/// The shipped head, or null when there is none or it was refused — either
/// way the bar reads commands with the lexicon alone.
Future<CommandHeads?> loadCommandHeadsAsset({AssetBundle? bundle}) async {
  final String json;
  try {
    // The bytes, decoded here: `loadString` hands a file over 50 KB (this
    // one is) to a `compute` isolate, a real isolate that a widget test's
    // fake clock never sees finish. One decode of a small file, once.
    final bytes = await (bundle ?? rootBundle).load(commandHeadsAsset);
    json = utf8.decode(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
  } catch (_) {
    // A missing asset throws; not having a head is the ordinary case.
    return null;
  }
  try {
    return CommandHeads.load(json);
  } on CommandHeadsRefused catch (e) {
    debugPrint('calendar command: ${e.reason}');
    return null;
  }
}
