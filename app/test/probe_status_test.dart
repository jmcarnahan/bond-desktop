import 'package:bond_inbox/services/llm/model_probe.dart';
import 'package:bond_inbox/widgets/inline_alert.dart';
import 'package:bond_inbox/widgets/probe_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the last look at a server renders as.
///
/// The cases moved here from `model_slot_editor_test.dart` when the line
/// became a widget of its own: three forms carry the three outcomes, and the
/// line naming where it actually looked is the one that resolves a "not
/// reachable" against a server that is demonstrably up.
///
/// One stateless widget over two props, so this file pumps it alone. The
/// guard that feeds it lives in the same library, so its two rules are pinned
/// here too: a probe that breaks its promise becomes one sentence rather than
/// a crash, and an empty access key is sent as no key at all.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    bool probing = false,
    ModelProbeResult? result,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ProbeStatus(probing: probing, result: result),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('a check in flight says so', (tester) async {
    await pump(tester, probing: true);

    expect(find.text('Checking…'), findsOneWidget);
  });

  testWidgets('nothing asked yet renders nothing at all', (tester) async {
    await pump(tester);

    expect(find.byType(Text), findsNothing);
    expect(find.byType(InlineAlert), findsNothing);
  });

  testWidgets('a server that did not answer is an alert, and names where it '
      'looked', (tester) async {
    await pump(
      tester,
      result: ModelProbeResult(
        reachable: false,
        probedUrl: Uri.parse('http://127.0.0.1:9000/v1/models'),
        error: 'Nothing is listening at 127.0.0.1:9000',
      ),
    );

    expect(find.byType(InlineAlert), findsOneWidget);
    expect(find.text('Nothing is listening at 127.0.0.1:9000'), findsOneWidget);
    expect(find.text('Asked http://127.0.0.1:9000/v1/models'), findsOneWidget);
  });

  testWidgets('a failure with no sentence still says it was not reachable',
      (tester) async {
    await pump(tester, result: const ModelProbeResult(reachable: false));

    expect(find.text('Not reachable'), findsOneWidget);
  });

  testWidgets('a live server with nothing loaded says that, not a count',
      (tester) async {
    await pump(tester, result: const ModelProbeResult(reachable: true));

    expect(find.text('Reachable · nothing loaded yet'), findsOneWidget);
    expect(find.byType(InlineAlert), findsNothing);
  });

  testWidgets('one model and several read differently', (tester) async {
    await pump(
      tester,
      result: const ModelProbeResult(reachable: true, modelIds: ['qwen3-4b']),
    );
    expect(find.text('Reachable · 1 model'), findsOneWidget);

    await pump(
      tester,
      result: ModelProbeResult(
        reachable: true,
        modelIds: const ['qwen3-4b', 'qwen3.8'],
        probedUrl: Uri.parse('https://box.example.com/prose/v1/models'),
      ),
    );
    expect(find.text('Reachable · 2 models'), findsOneWidget);
    expect(
      find.text('Asked https://box.example.com/prose/v1/models'),
      findsOneWidget,
    );
  });

  group('guardedProbe', () {
    test('a probe that throws is reported, not thrown', () async {
      final result = await guardedProbe(
        (url, {bearer}) async => throw StateError('boom'),
        'https://box.example.com/v1/chat/completions',
        null,
      );

      expect(result.reachable, isFalse);
      expect(result.error, 'Could not check the server');
    });

    test('an empty bearer is sent as none, and a real one rides', () async {
      final sent = <String?>[];
      Future<ModelProbeResult> probe(String url, {String? bearer}) async {
        sent.add(bearer);
        return const ModelProbeResult(reachable: true);
      }

      const url = 'https://box.example.com/v1/chat/completions';
      await guardedProbe(probe, url, '');
      await guardedProbe(probe, url, 'sk-fixture-bearer');
      await guardedProbe(probe, url, null);

      expect(sent, [null, 'sk-fixture-bearer', null]);
    });
  });
}
