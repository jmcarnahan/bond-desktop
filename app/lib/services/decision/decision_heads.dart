/// The nine classification heads the decision model ends in, applied in Dart.
///
/// The server returns the encoder's raw mean-pooled vector and nothing else;
/// the heads — one linear layer and one calibration temperature per field —
/// ride beside the model file as `decide-heads.json`, exported losslessly from
/// the PyTorch checkpoint. Keeping them here rather than on the server is what
/// lets a stock llama-server serve the model at all.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable;

import '../llm/llm_client.dart' show LlmFormatException;

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

  factory DecisionAnswers.fromJson(Map<String, Object?> json) =>
      DecisionAnswers({
        for (final MapEntry(:key, :value) in json.entries)
          if (value is Map) key: ChoiceAnswer.fromJson(value.cast()),
      });
}

/// One field's linear head.
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
/// [DecisionAnswers].
class DecisionHeads {
  /// The question hash the model was trained under
  /// (`questions.question_hash()`). A heads file from another question set
  /// answers different questions, so it is refused rather than trusted.
  static const String expectedQhash = '6eba387492208260';

  /// The model's own name, from the file — what a stored decision records.
  final String model;
  final String qhash;

  /// The vector width every head reads.
  final int hidden;

  /// The encoder's context in tokens, specials included. The client truncates
  /// a long state to this.
  final int maxTokens;

  final List<_Head> _heads;

  DecisionHeads._(
    this.model,
    this.qhash,
    this.hidden,
    this.maxTokens,
    this._heads,
  );

  /// Reads and validates [file]. Throws [LlmFormatException] when the file is
  /// not a heads file this build can use, [FileSystemException] when it cannot
  /// be read.
  static Future<DecisionHeads> load(File file) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
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
    return DecisionHeads.fromJson(decoded.cast<String, Object?>());
  }

  /// Validates everything [apply] relies on, so a bad file fails once, here,
  /// with a sentence, rather than as a wrong answer on every message.
  factory DecisionHeads.fromJson(Map<String, Object?> json) {
    Never refuse(String why) =>
        throw LlmFormatException('The decision heads file $why.');

    if (json['schema'] != 1) refuse('has schema ${json['schema']}, not 1');
    final qhash = json['qhash'];
    if (qhash != expectedQhash) {
      refuse('was trained on question set $qhash, not $expectedQhash');
    }
    if (json['pooling'] != 'mean') {
      refuse('pools by ${json['pooling']}, not mean');
    }
    final model = json['model'];
    if (model is! String || model.isEmpty) refuse('names no model');
    final hidden = json['hidden'];
    if (hidden is! int || hidden <= 0) refuse('has no hidden width');
    final maxTokens = json['max_tokens'];
    // Room for the two specials and at least one token of text.
    if (maxTokens is! int || maxTokens < 3) refuse('has no max_tokens');

    final fields = json['fields'];
    if (fields is! List || fields.length != decisionFields.length) {
      refuse('does not carry the ${decisionFields.length} decision fields');
    }
    final heads = <_Head>[];
    for (var i = 0; i < decisionFields.length; i++) {
      final name = decisionFields[i];
      final field = fields[i];
      if (field is! Map || field['name'] != name) {
        refuse('has its fields out of order (expected $name at $i)');
      }
      final expected = decisionOptions[name]!;
      final options = field['options'];
      if (options is! List ||
          options.length != expected.length ||
          [for (var j = 0; j < expected.length; j++) options[j] == expected[j]]
              .contains(false)) {
        refuse('has different options for $name');
      }
      final n = expected.length;

      final weight = field['weight'];
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

      final bias = field['bias'];
      if (bias is! List || bias.length != n) {
        refuse('has a $name bias that is not $n long');
      }

      final temperature = field['temperature'];
      if (temperature is! num ||
          !temperature.isFinite ||
          temperature <= 0) {
        refuse('has a $name temperature that is not a positive number');
      }

      heads.add(_Head(
        name,
        expected,
        rows,
        _numbers(bias, () => refuse('has a non-number in $name')),
        temperature.toDouble(),
      ));
    }
    return DecisionHeads._(model, qhash as String, hidden, maxTokens, heads);
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

  /// Every field's answer for one raw (UNnormalised) pooled vector:
  /// `softmax((W·v + b) / T)`, the argmax (the first on a tie) and its
  /// probability.
  DecisionAnswers apply(List<double> vector) {
    if (vector.length != hidden) {
      throw LlmFormatException(
        'The decision model returned a vector of ${vector.length} numbers, '
        'not $hidden.',
      );
    }
    final answers = <String, ChoiceAnswer>{};
    for (final head in _heads) {
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
      // Max-subtracted, so a large logit cannot overflow `exp`.
      var best = 0;
      for (var o = 1; o < n; o++) {
        if (logits[o] > logits[best]) best = o;
      }
      final top = logits[best];
      var sum = 0.0;
      final exps = Float64List(n);
      for (var o = 0; o < n; o++) {
        exps[o] = math.exp(logits[o] - top);
        sum += exps[o];
      }
      final probabilities = {
        for (var o = 0; o < n; o++) head.options[o]: exps[o] / sum,
      };
      answers[head.name] = ChoiceAnswer(
        choice: head.options[best],
        confidence: exps[best] / sum,
        probabilities: probabilities,
      );
    }
    return DecisionAnswers(answers);
  }
}
