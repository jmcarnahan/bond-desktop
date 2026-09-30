/// The decision model's classification heads, applied in Dart: the nine
/// message fields and the three storyline questions.
///
/// The server returns the encoder's raw mean-pooled vector and nothing else;
/// the heads — one linear layer and one calibration temperature per
/// question — ride beside the model file as `decide-heads.json` (schema 2),
/// exported losslessly from the PyTorch checkpoint. Keeping them here rather than on the server is what
/// lets a stock llama-server serve the model at all.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show immutable;

import '../llm/llm_client.dart'
    show DecisionMisconfiguredException, LlmFormatException;
import 'decision_questions.dart';
import 'decision_state.dart' show decisionRendererVersion;

/// The fields in head order, which is `distill/questions.py` `FIELDS`.
const List<String> decisionFields = [
  'gate',
  'drop_reason',
  'category',
  'urgency',
  'needs_action',
  'reply_expected',
  'needs_you',
  'intent',
  'importance',
];

/// Each field's options in head-output order (`questions.OPTIONS`). A heads
/// file whose options differ in any way is refused: the index of a logit IS
/// its meaning, so a reordered list would silently swap answers.
const Map<String, List<String>> decisionOptions = {
  'gate': ['keep', 'drop'],
  'drop_reason': [
    'newsletter',
    'no_reply',
    'auto_generated',
    'monitoring',
    'ticket_system',
    'identity_service',
    'share_notification',
    'machine_sender',
    'digest',
    'cold_outreach',
    'outbound',
    'empty',
    'other',
  ],
  'category': ['work', 'personal', 'notification', 'other'],
  'urgency': ['low', 'normal', 'high', 'urgent'],
  'needs_action': ['yes', 'no'],
  'reply_expected': ['yes', 'no'],
  'needs_you': ['yes', 'no'],
  'intent': [
    'request',
    'question',
    'approval',
    'scheduling',
    'fyi',
    'transactional',
    'social',
  ],
  'importance': ['low', 'normal', 'high'],
};

/// One field's answer: the argmax option, its probability, and every option's.
@immutable
class ChoiceAnswer {
  final String choice;

  /// The chosen option's probability — the max of [probabilities].
  final double confidence;

  /// Every option's calibrated probability, in head order.
  final Map<String, double> probabilities;

  const ChoiceAnswer({
    required this.choice,
    required this.confidence,
    required this.probabilities,
  });

  /// The answer a set of calibrated probabilities makes: the most probable of
  /// [options], the first on a tie, as [DecisionHeads.apply] chooses. The
  /// probabilities are kept in [options] order. For a server that answers
  /// probabilities itself (the `systemone` kind), which calibrated them there.
  factory ChoiceAnswer.fromProbabilities(
    List<String> options,
    Map<String, double> probabilities,
  ) {
    var best = options.first;
    for (final option in options.skip(1)) {
      if ((probabilities[option] ?? 0) > (probabilities[best] ?? 0)) {
        best = option;
      }
    }
    return ChoiceAnswer(
      choice: best,
      confidence: probabilities[best] ?? 0,
      probabilities: {for (final o in options) o: probabilities[o] ?? 0},
    );
  }

  Map<String, Object?> toJson() => {
        'choice': choice,
        'confidence': confidence,
        'probabilities': probabilities,
      };

  factory ChoiceAnswer.fromJson(Map<String, Object?> json) => ChoiceAnswer(
        choice: json['choice'] as String? ?? '',
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
        probabilities: {
          for (final MapEntry(:key, :value)
              in ((json['probabilities'] as Map?) ?? const {}).entries)
            if (value is num) '$key': value.toDouble(),
        },
      );
}

/// All nine answers for one message.
@immutable
class DecisionAnswers {
  final Map<String, ChoiceAnswer> fields;

  const DecisionAnswers(this.fields);

  /// All nine answers from each field's calibrated probabilities, keyed by
  /// field and then option: [ChoiceAnswer.fromProbabilities] over
  /// [decisionOptions], in [decisionFields] order.
  factory DecisionAnswers.fromProbabilities(
    Map<String, Map<String, double>> probabilities,
  ) =>
      DecisionAnswers({
        for (final field in decisionFields)
          field: ChoiceAnswer.fromProbabilities(
            decisionOptions[field]!,
            probabilities[field] ?? const {},
          ),
      });

  /// The answer for [field]. Throws [ArgumentError] for a field this model
  /// does not answer — a caller asking for one is a programming error.
  ChoiceAnswer operator [](String field) {
    final answer = fields[field];
    if (answer == null) {
      throw ArgumentError.value(field, 'field', 'not a decision field');
    }
    return answer;
  }

  /// The probability of [option] on [field], 0 for an option it does not have.
  double p(String field, String option) =>
      this[field].probabilities[option] ?? 0;

  /// `{field: {choice, confidence, probabilities: {option: p}}}`, the shape a
  /// stored `answers_json` takes.
  Map<String, Object?> toJson() => {
        for (final MapEntry(:key, :value) in fields.entries)
          key: value.toJson(),
      };

  /// Entries that are not a Map (a stored `owner_known` flag) are skipped.
  factory DecisionAnswers.fromJson(Map<String, Object?> json) =>
      DecisionAnswers({
        for (final MapEntry(:key, :value) in json.entries)
          if (value is Map) key: ChoiceAnswer.fromJson(value.cast()),
      });
}

/// One question's linear head.
class _Head {
  final String name;
  final List<String> options;

  /// One row per option, [DecisionHeads.hidden] wide.
  final List<Float64List> weight;
  final Float64List bias;
  final double temperature;

  _Head(this.name, this.options, this.weight, this.bias, this.temperature);
}

/// The heads file, validated, and the arithmetic that turns a vector into
/// [DecisionAnswers] or a storyline question's p(yes).
class DecisionHeads {
  /// The question hash the model was trained under ([decisionQhash]). A
  /// heads file from another question set answers different questions, so
  /// it is refused rather than trusted.
  static const String expectedQhash = decisionQhash;

  /// The width of the encoder's pooled vector: ModernBERT-large's hidden
  /// size. A file whose heads read another width is not this model's.
  static const int width = 1024;

  /// What a schema-1 file says: the nine-field heads of the first decision
  /// model, which cannot answer the storyline questions. It is the one
  /// refusal the owner meets after an upgrade, so it names the cause rather
  /// than a mismatch. It does not promise that today's `make decide-install`
  /// fixes it: that target installs the newer model only once it points at
  /// one.
  static const String olderModelText =
      'The installed decision model is the older version, which cannot '
      'answer the storyline questions. Install the newer decision model '
      '(make decide-install once it points at it).';

  /// The model's own name, from the file — what a stored decision records.
  final String model;
  final String qhash;

  /// The first 12 hex of the file's sha256, or empty for heads built in
  /// memory. Two installs that share a [model] name but differ in any weight
  /// differ here, which is what the sweep's pair cache keys on
  /// (`DecisionClient.modelIdentity`).
  final String fingerprint;

  /// The vector width every head reads: the file's weight rows', which is
  /// always [width].
  final int hidden;

  /// The encoder's context in tokens, specials included. The client truncates
  /// a long state to this.
  final int maxTokens;

  /// The nine message fields' heads, in [decisionFields] order.
  final List<_Head> _heads;

  /// The storyline questions' heads, one per [StorylineQuestion].
  final Map<StorylineQuestion, _Head> _storyline;

  DecisionHeads._(
    this.model,
    this.qhash,
    this.fingerprint,
    this.hidden,
    this.maxTokens,
    this._heads,
    this._storyline,
  );

  /// Reads and validates [file]. Throws [DecisionOlderModelException] for the
  /// older model's file, [LlmFormatException] when the file is otherwise not
  /// a heads file this build can use, [FileSystemException] when it cannot be
  /// read.
  static Future<DecisionHeads> load(File file) async {
    final Object? decoded;
    final String text;
    try {
      text = await file.readAsString();
      decoded = jsonDecode(text);
    } on FormatException {
      throw const LlmFormatException(
        'The decision heads file is not JSON.',
      );
    }
    if (decoded is! Map) {
      throw const LlmFormatException(
        'The decision heads file is not a JSON object.',
      );
    }
    return DecisionHeads.fromJson(
      decoded.cast<String, Object?>(),
      fingerprint: headsFingerprint(text),
    );
  }

  /// [fingerprint] for a heads file's [text].
  static String headsFingerprint(String text) =>
      sha256.convert(utf8.encode(text)).toString().substring(0, 12);

  /// Validates everything [apply] and [pYes] rely on, so a bad file fails
  /// once, here, with a sentence, rather than as a wrong answer on every
  /// message.
  ///
  /// Schema 2 (question set v5): `questions` is the nine message fields in
  /// [decisionFields] order, renderer `message`, then `same_effort` (`pair`),
  /// `member_of` (`membership`) and `charter_specific` (`charter`), each
  /// `{id, renderer, options, weight, bias, temperature}`.
  factory DecisionHeads.fromJson(
    Map<String, Object?> json, {
    String fingerprint = '',
  }) {
    Never refuse(String why) =>
        throw LlmFormatException('The decision heads file $why.');

    if (json['schema'] == 1) throw const DecisionOlderModelException();
    if (json['schema'] != 2) refuse('has schema ${json['schema']}, not 2');
    final qhash = json['qhash'];
    if (qhash != expectedQhash) {
      refuse('was trained on question set $qhash, not $expectedQhash');
    }
    if (json['renderer'] != decisionRendererVersion) {
      refuse('reads renderer ${json['renderer']}, not '
          '$decisionRendererVersion');
    }
    if (json['pooling'] != 'mean') {
      refuse('pools by ${json['pooling']}, not mean');
    }
    final model = json['model'];
    if (model is! String || model.isEmpty) refuse('names no model');
    // The width is the first weight row's; every row of every question must
    // agree with it, and it must be [width]. `hidden` is optional in schema
    // 2, and a file that states one must state the same.
    final questions = json['questions'];
    final firstQuestion =
        questions is List && questions.isNotEmpty ? questions.first : null;
    final firstWeight = firstQuestion is Map ? firstQuestion['weight'] : null;
    final firstRow =
        firstWeight is List && firstWeight.isNotEmpty ? firstWeight.first : null;
    if (firstRow is! List) refuse('has no weight to read a width from');
    final hidden = firstRow.length;
    if (hidden != width) refuse('has heads $hidden wide, not $width');
    final stated = json['hidden'];
    if (stated != null && stated != hidden) {
      refuse('has a hidden width of $stated, but heads $hidden wide');
    }
    final maxTokens = json['max_tokens'];
    // Room for the two specials and at least one token of text.
    if (maxTokens is! int || maxTokens < 3) refuse('has no max_tokens');

    final expected = [
      for (final f in decisionFields) (f, 'message', decisionOptions[f]!),
      for (final q in StorylineQuestion.values)
        (q.id, q.renderer, StorylineQuestion.options),
    ];
    if (questions is! List || questions.length != expected.length) {
      refuse('does not carry the ${expected.length} decision questions');
    }
    final heads = <_Head>[];
    for (var i = 0; i < expected.length; i++) {
      final (name, renderer, options) = expected[i];
      final question = questions[i];
      if (question is! Map || question['id'] != name) {
        refuse('has its questions out of order (expected $name at $i)');
      }
      if (question['renderer'] != renderer) {
        refuse('has $name on renderer ${question['renderer']}, not '
            '$renderer');
      }
      final got = question['options'];
      if (got is! List ||
          got.length != options.length ||
          [for (var j = 0; j < options.length; j++) got[j] == options[j]]
              .contains(false)) {
        refuse('has different options for $name');
      }
      final n = options.length;

      final weight = question['weight'];
      if (weight is! List || weight.length != n) {
        refuse('has a $name weight that is not $n rows');
      }
      final rows = <Float64List>[];
      for (final row in weight) {
        if (row is! List || row.length != hidden) {
          refuse('has a $name weight row that is not $hidden wide');
        }
        rows.add(_numbers(row, () => refuse('has a non-number in $name')));
      }

      final bias = question['bias'];
      if (bias is! List || bias.length != n) {
        refuse('has a $name bias that is not $n long');
      }

      final temperature = question['temperature'];
      if (temperature is! num ||
          !temperature.isFinite ||
          temperature <= 0) {
        refuse('has a $name temperature that is not a positive number');
      }

      heads.add(_Head(
        name,
        options,
        rows,
        _numbers(bias, () => refuse('has a non-number in $name')),
        temperature.toDouble(),
      ));
    }
    final fields = decisionFields.length;
    return DecisionHeads._(
      model,
      qhash as String,
      fingerprint,
      hidden,
      maxTokens,
      heads.sublist(0, fields),
      {
        for (final (i, q) in StorylineQuestion.values.indexed)
          q: heads[fields + i],
      },
    );
  }

  static Float64List _numbers(List<Object?> values, Never Function() bad) {
    final out = Float64List(values.length);
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v is! num) bad();
      out[i] = v.toDouble();
    }
    return out;
  }

  /// Every message field's answer for one raw (UNnormalised) pooled
  /// vector: `softmax((W·v + b) / T)`, the argmax (the first on a tie) and
  /// its probability.
  DecisionAnswers apply(List<double> vector) {
    _checkWidth(vector);
    final answers = <String, ChoiceAnswer>{};
    for (final head in _heads) {
      final logits = _logits(head, vector);
      // The argmax of the LOGITS, the first on a tie: two probabilities that
      // round to the same double must not change which option is chosen.
      var best = 0;
      for (var o = 1; o < logits.length; o++) {
        if (logits[o] > logits[best]) best = o;
      }
      final probabilities = _softmaxOf(logits);
      answers[head.name] = ChoiceAnswer(
        choice: head.options[best],
        confidence: probabilities[best],
        probabilities: {
          for (var o = 0; o < probabilities.length; o++)
            head.options[o]: probabilities[o],
        },
      );
    }
    return DecisionAnswers(answers);
  }

  /// [question]'s calibrated p(yes) for one raw pooled vector of its
  /// rendered state: `softmax((W·v + b) / T)` at `yes`.
  double pYes(StorylineQuestion question, List<double> vector) {
    _checkWidth(vector);
    final head = _storyline[question]!;
    return _softmaxOf(_logits(head, vector))[head.options.indexOf('yes')];
  }

  void _checkWidth(List<double> vector) {
    if (vector.length != hidden) {
      throw LlmFormatException(
        'The decision model returned a vector of ${vector.length} numbers, '
        'not $hidden.',
      );
    }
  }

  /// One head's `(W·v + b) / T`, in option order.
  Float64List _logits(_Head head, List<double> vector) {
    final n = head.options.length;
    final logits = Float64List(n);
    for (var o = 0; o < n; o++) {
      final row = head.weight[o];
      var dot = head.bias[o];
      for (var k = 0; k < hidden; k++) {
        dot += row[k] * vector[k];
      }
      logits[o] = dot / head.temperature;
    }
    return logits;
  }

  /// [logits]' probabilities, in the same order.
  static Float64List _softmaxOf(Float64List logits) {
    final n = logits.length;
    // Max-subtracted, so a large logit cannot overflow `exp`.
    var top = logits[0];
    for (var o = 1; o < n; o++) {
      if (logits[o] > top) top = logits[o];
    }
    var sum = 0.0;
    final out = Float64List(n);
    for (var o = 0; o < n; o++) {
      out[o] = math.exp(logits[o] - top);
      sum += out[o];
    }
    for (var o = 0; o < n; o++) {
      out[o] /= sum;
    }
    return out;
  }
}

/// The heads file is the first decision model's (schema 1), which cannot
/// answer the storyline questions. A misconfiguration like any refused heads
/// file, so it parks under `decision_misconfigured`, with its own sentence.
class DecisionOlderModelException extends DecisionMisconfiguredException {
  const DecisionOlderModelException() : super(DecisionHeads.olderModelText);
}
