import 'dart:convert';

import 'package:bond_inbox/services/calendar/command/command_heads.dart';
import 'package:bond_inbox/services/calendar/command/command_types.dart';
import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/command_heads_fixture.dart';

/// The command head file: what `load` accepts and refuses, and the
/// arithmetic `apply` does, over a tiny hand-made head (dim 3, the ten
/// actions; axis 0 is create, 1 move, 2 cancel).
void main() {
  CommandHeads load(Map<String, Object?> json) =>
      CommandHeads.load(jsonEncode(json));

  Matcher refusedFor(String words) => throwsA(isA<CommandHeadsRefused>()
      .having((e) => e.reason, 'reason', contains(words)));

  group('load', () {
    test('reads a well-formed file', () {
      final h = load(commandHeadsJson());
      expect(h.options, [
        'create',
        'move',
        'cancel',
        'rsvp_yes',
        'rsvp_no',
        'rsvp_maybe',
        'find_time',
        'ask_free',
        'ask_agenda',
        'ask_person',
      ]);
      expect(h.dim, 3);
      expect(h.weight, hasLength(10));
      expect(h.temperature, 1.0);
      expect(h.nTrain, 400);
      expect(h.nHeldout, 100);
      expect(h.heldoutAcc, 0.93);
      expect(h.lexiconHeldoutAcc, isNull,
          reason: 'a fresh fit leaves the lexicon number to the Dart side');
      expect(load(commandHeadsJson(lexiconAcc: 0.81)).lexiconHeldoutAcc, 0.81);
    });

    test('refuses another format or input', () {
      expect(() => load(commandHeadsJson(format: 'bond-command-heads/2')),
          refusedFor('format'));
      expect(() => load(commandHeadsJson(input: 'bond-state/1')),
          refusedFor('input'));
      expect(() => CommandHeads.load('not json'), refusedFor('not JSON'));
      expect(() => CommandHeads.load('[]'), refusedFor('not a JSON object'));
    });

    test('refuses a head fitted on another question set', () {
      expect(() => load(commandHeadsJson(qhash: '0000000000000000')),
          refusedFor('question set'));
    });

    test('reads the encoder model, and refuses a file naming none', () {
      expect(load(commandHeadsJson()).encoderModel, 'bond-decide-synthetic');
      expect(
          load(commandHeadsJson(encoderModel: 'bond-decide-v3')).encoderModel,
          'bond-decide-v3');
      for (final bad in [null, '', '  ', 7]) {
        expect(() => load(commandHeadsJson(encoderModel: bad)),
            refusedFor('names no encoder model'),
            reason: 'encoder_model $bad');
      }
    });

    test('refuses options out of order, missing, or with unknown', () {
      final opts = [...CommandHeads.expectedOptions];
      final swapped = [...opts]
        ..[0] = opts[1]
        ..[1] = opts[0];
      expect(() => load(commandHeadsJson(options: swapped)),
          refusedFor('actions in order'));
      expect(() => load(commandHeadsJson(options: opts.sublist(1))),
          refusedFor('actions in order'));
      expect(() => load(commandHeadsJson(options: [...opts, 'unknown'])),
          refusedFor('actions in order'));
    });

    test('refuses ragged weights, a short bias, and a bad temperature', () {
      final ragged = [
        for (var o = 0; o < 10; o++) [0.0, 0.0, if (o != 4) 0.0],
      ];
      expect(() => load(commandHeadsJson(weight: ragged)), refusedFor('ragged'));
      expect(() => load(commandHeadsJson(weight: [[1.0, 0.0, 0.0]])),
          refusedFor('10 rows'));
      expect(() => load(commandHeadsJson(bias: [0.0, 0.0])),
          refusedFor('bias'));
      for (final t in [0, -1.0, 'hot', null]) {
        expect(() => load(commandHeadsJson(temperature: t)),
            refusedFor('temperature'),
            reason: 'temperature $t');
      }
    });
  });

  group('apply', () {
    final head = load(commandHeadsJson());

    test('softmax sums to 1, and the temperature flattens it', () {
      final p = head.probabilities([2.0, 0.5, -1.0]);
      expect(p, hasLength(10));
      expect(p.fold(0.0, (a, b) => a + b), closeTo(1.0, 1e-12));
      expect(p[0], greaterThan(p[1]));
      final hot = load(commandHeadsJson(temperature: 4.0))
          .probabilities([2.0, 0.5, -1.0]);
      expect(hot[0], lessThan(p[0]));
      expect(hot.fold(0.0, (a, b) => a + b), closeTo(1.0, 1e-12));
    });

    test('the argmax above the bar is the head\'s answer', () {
      final g = head.apply([0.0, 12.0, 0.0]);
      expect(g.action, CommandAction.move);
      expect(g.path, CommandPath.head);
      expect(g.confidence, greaterThan(0.99));
      expect(head.apply([0.0, 0.0, 12.0]).action, CommandAction.cancel);
    });

    test('below the bar it is unknown, carrying the probability', () {
      // Ten options, one logit a little up: the argmax is well under 0.8.
      final g = head.apply([0.0, 1.0, 0.0]);
      expect(g.action, CommandAction.unknown);
      expect(g.path, CommandPath.head);
      expect(g.confidence, lessThan(0.8));
      expect(g.confidence,
          closeTo(head.probabilities([0.0, 1.0, 0.0])[1], 1e-12));
      // The same vector clears a lower bar.
      expect(head.apply([0.0, 1.0, 0.0], bar: 0.2).action, CommandAction.move);
    });

    test('a vector of another width is refused', () {
      expect(() => head.apply([1.0, 2.0]), refusedFor('reads 3 numbers'));
    });
  });

  group('the asset', () {
    test('absent reads as no head', () async {
      expect(await loadCommandHeadsAsset(bundle: _Bundle(null)), isNull);
    });

    test('refused reads as no head', () async {
      final bad = jsonEncode(commandHeadsJson(qhash: 'ffffffffffffffff'));
      expect(await loadCommandHeadsAsset(bundle: _Bundle(bad)), isNull);
    });

    test('present and well-formed is loaded', () async {
      final h = await loadCommandHeadsAsset(bundle: _Bundle(commandHeadsText()));
      expect(h, isNotNull);
      expect(h!.dim, 3);
    });
  });
}

/// An asset bundle holding [text] at the command heads path, or nothing.
class _Bundle extends CachingAssetBundle {
  _Bundle(this.text);

  final String? text;

  @override
  Future<ByteData> load(String key) async {
    final t = text;
    if (key != commandHeadsAsset || t == null) {
      throw FlutterError('Unable to load asset: "$key".');
    }
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(t)));
  }
}
