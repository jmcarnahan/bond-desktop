import 'package:bond_inbox/services/llm/model_probe.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/widgets/settings_target_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The add and edit pane: what has to be filled in before a Save is possible,
/// what a Save hands the host, and the three ways a bearer can end up.
///
/// The bearer is the reason half of this file exists. It is never read back
/// onto the screen, so "unchanged" has to be a state the empty field can be
/// in, and the two flags that carry it — `hasBearer` on the spec and the
/// `bearer` argument beside it — have to disagree in exactly one direction.

/// One Save, as the host received it.
typedef _Saved = ({
  LlmTargetSpec spec,
  String? bearer,
  bool prose,
  bool confirm,
  bool bulk,
});

const _stored = LlmTargetSpec(
  id: 't-1a2b3c4d',
  name: 'Studio box',
  url: 'http://localhost:18100/v1/chat/completions',
  model: 'qwen3-27b-fp8',
  hasBearer: true,
  parallel: 4,
);

void main() {
  late List<_Saved> saved;
  late int cancels;

  setUp(() {
    saved = [];
    cancels = 0;
  });

  Future<void> open(
    WidgetTester tester, {
    LlmTargetSpec? initial,
    Future<ModelProbeResult> Function(String url)? probe,
    // A Save that throws, for the failure test; the default records.
    Object? saveThrows,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LlmTargetEditor(
          initial: initial,
          probe: probe,
          onSave: (spec, {bearer, prose = false, confirm = false, bulk = false}) async {
            if (saveThrows != null) throw saveThrows;
            saved.add((
              spec: spec,
              bearer: bearer,
              prose: prose,
              confirm: confirm,
              bulk: bulk,
            ));
          },
          onCancel: () => cancels++,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, Key key, String text) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(key), text);
    await tester.pumpAndSettle();
  }

  Future<void> fillIn(WidgetTester tester) async {
    await type(tester, LlmTargetEditor.nameKey, 'Studio box');
    await type(
      tester,
      LlmTargetEditor.urlKey,
      'http://localhost:18100/v1/chat/completions',
    );
    await type(tester, LlmTargetEditor.modelKey, 'qwen3-27b-fp8');
  }

  bool saveEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byKey(LlmTargetEditor.saveKey)).onPressed !=
      null;

  bool checked(WidgetTester tester, Key key) =>
      tester.widget<CheckboxListTile>(find.byKey(key)).value ?? false;

  testWidgets('Save waits for a name, a URL and a model', (tester) async {
    await open(tester);
    expect(saveEnabled(tester), isFalse);
    expect(
      find.text('A name, a server URL and a model name are all needed before '
          'this can be saved.'),
      findsOneWidget,
    );

    await type(tester, LlmTargetEditor.nameKey, 'Studio box');
    await type(tester, LlmTargetEditor.modelKey, 'qwen3-27b-fp8');
    expect(saveEnabled(tester), isFalse);

    // A URL with no host is not a URL a request can be made to.
    await type(tester, LlmTargetEditor.urlKey, 'not-a-url');
    expect(saveEnabled(tester), isFalse);
    expect(
      find.text('The server URL needs a host, such as '
          'http://localhost:18100/v1/chat/completions'),
      findsOneWidget,
    );

    await type(
      tester,
      LlmTargetEditor.urlKey,
      'http://localhost:18100/v1/chat/completions',
    );
    expect(saveEnabled(tester), isTrue);
  });

  testWidgets('a Save that throws stays on the pane with one sentence, and '
      'nothing escapes the zone', (tester) async {
    await open(tester, saveThrows: StateError('the settings store is gone'));
    await fillIn(tester);

    await press(tester, find.byKey(LlmTargetEditor.saveKey));

    // Every other writing control on this screen fails inline; a Save that
    // vanished into the zone left the pane open and said nothing.
    expect(tester.takeException(), isNull);
    expect(find.byKey(LlmTargetEditor.saveErrorKey), findsOneWidget);
    expect(find.text(LlmTargetEditor.saveFailedText), findsOneWidget);
    expect(saved, isEmpty);
    // The typed values are intact and Save is offered again.
    expect(find.text('Studio box'), findsOneWidget);
    expect(saveEnabled(tester), isTrue);
  });

  testWidgets('a Save carries the spec, the token and the three presets',
      (tester) async {
    await open(tester);
    await fillIn(tester);

    await press(
      tester,
      find.descendant(
        of: find.byType(SegmentedButton<LlmWire>),
        matching: find.text('Bedrock Converse'),
      ),
    );
    await press(
      tester,
      find.descendant(
        of: find.byType(SegmentedButton<int>),
        matching: find.text('8'),
      ),
    );
    await press(tester, find.byKey(LlmTargetEditor.streamsKey));
    await type(tester, LlmTargetEditor.bearerKey, 'fictional-token');
    await press(tester, find.byKey(LlmTargetEditor.presetBulkKey));

    await press(tester, find.byKey(LlmTargetEditor.saveKey));

    expect(saved, hasLength(1));
    final call = saved.single;
    expect(call.spec.name, 'Studio box');
    expect(call.spec.url, 'http://localhost:18100/v1/chat/completions');
    expect(call.spec.model, 'qwen3-27b-fp8');
    expect(call.spec.wire, LlmWire.bedrockConverse);
    expect(call.spec.parallel, 8);
    expect(call.spec.streams, isFalse);
    expect(call.spec.hasBearer, isTrue);
    expect(call.bearer, 'fictional-token');
    expect((call.prose, call.confirm, call.bulk), (true, true, true));
    // Generated, never derived from the name.
    expect(call.spec.id, matches(RegExp(r'^t-[0-9a-f]{8}$')));
  });

  testWidgets('on ADD the two model presets are ticked and bulk is not',
      (tester) async {
    await open(tester);

    expect(checked(tester, LlmTargetEditor.presetProseKey), isTrue);
    expect(checked(tester, LlmTargetEditor.presetConfirmKey), isTrue);
    expect(checked(tester, LlmTargetEditor.presetBulkKey), isFalse);

    await fillIn(tester);
    await press(tester, find.byKey(LlmTargetEditor.presetProseKey));
    await press(tester, find.byKey(LlmTargetEditor.saveKey));

    final call = saved.single;
    expect((call.prose, call.confirm, call.bulk), (false, true, false));
  });

  testWidgets('an edit keeps the id, offers no presets and keeps the token',
      (tester) async {
    await open(tester, initial: _stored);

    for (final key in [
      LlmTargetEditor.presetProseKey,
      LlmTargetEditor.presetConfirmKey,
      LlmTargetEditor.presetBulkKey,
    ]) {
      expect(find.byKey(key), findsNothing);
    }
    // The field is empty and the hint is what says a token is there.
    expect(find.text('Stored. Type to replace'), findsOneWidget);

    await type(tester, LlmTargetEditor.nameKey, 'Studio box two');
    await press(tester, find.byKey(LlmTargetEditor.saveKey));

    final call = saved.single;
    expect(call.spec.id, _stored.id);
    expect(call.spec.name, 'Studio box two');
    expect(call.spec.parallel, 4);
    // Null with hasBearer true means "keep the one in the keychain".
    expect(call.bearer, isNull);
    expect(call.spec.hasBearer, isTrue);
    expect((call.prose, call.confirm, call.bulk), (false, false, false));
  });

  /// A width of 3 cannot be DRAWN — the segments are 1 / 2 / 4 / 8 — so it
  /// snaps to 2 to appear. Writing the snapped number back would let a Save
  /// that only changed the name quietly narrow the target's lane.
  group('a width the segments cannot draw', () {
    const odd = LlmTargetSpec(
      id: 't-1a2b3c4d',
      name: 'Studio box',
      url: 'http://localhost:18100/v1/chat/completions',
      model: 'qwen3-27b-fp8',
      parallel: 3,
    );

    testWidgets('survives a Save that never touched it', (tester) async {
      await open(tester, initial: odd);

      // Drawn as the nearest segment it has.
      expect(
        tester.widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>)).selected,
        {2},
      );

      await type(tester, LlmTargetEditor.nameKey, 'Studio box two');
      await press(tester, find.byKey(LlmTargetEditor.saveKey));

      expect(saved.single.spec.parallel, 3);
    });

    testWidgets('is replaced by the number somebody pressed', (tester) async {
      await open(tester, initial: odd);

      await press(
        tester,
        find.descendant(
          of: find.byType(SegmentedButton<int>),
          matching: find.text('4'),
        ),
      );
      await press(tester, find.byKey(LlmTargetEditor.saveKey));

      expect(saved.single.spec.parallel, 4);
    });
  });

  testWidgets('Remove bearer saves the target without one', (tester) async {
    await open(tester, initial: _stored);

    await press(tester, find.byKey(LlmTargetEditor.bearerClearKey));
    // The offer goes with the token it was about.
    expect(find.text('Stored. Type to replace'), findsNothing);
    expect(find.byKey(LlmTargetEditor.bearerClearKey), findsNothing);

    await press(tester, find.byKey(LlmTargetEditor.saveKey));

    final call = saved.single;
    expect(call.bearer, isNull);
    expect(call.spec.hasBearer, isFalse);
  });

  testWidgets('typing a new token replaces the stored one', (tester) async {
    await open(tester, initial: _stored);

    await type(tester, LlmTargetEditor.bearerKey, 'second-fictional-token');
    await press(tester, find.byKey(LlmTargetEditor.saveKey));

    final call = saved.single;
    expect(call.bearer, 'second-fictional-token');
    expect(call.spec.hasBearer, isTrue);
  });

  testWidgets('a checked server offers its own models to pick between',
      (tester) async {
    final asked = <String>[];
    await open(tester, probe: (url) async {
      asked.add(url);
      return const ModelProbeResult(
        reachable: true,
        modelIds: ['qwen3-27b-fp8', 'qwen3-4b'],
      );
    });
    await fillIn(tester);

    await press(tester, find.byKey(LlmTargetEditor.checkKey));

    expect(asked, ['http://localhost:18100/v1/chat/completions']);
    expect(find.text('Reachable · 2 models'), findsOneWidget);
    expect(find.byKey(LlmTargetEditor.modelPickerKey), findsOneWidget);
    // A probe never blocks a Save.
    expect(saveEnabled(tester), isTrue);
  });

  testWidgets('Cancel reaches the host and writes nothing', (tester) async {
    await open(tester);
    await fillIn(tester);

    await press(tester, find.byKey(LlmTargetEditor.cancelKey));

    expect(cancels, 1);
    expect(saved, isEmpty);
  });

  testWidgets('the pane survives a doubled text scale', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await open(tester, probe: (_) async => const ModelProbeResult(reachable: true));
    await fillIn(tester);

    expect(tester.takeException(), isNull);
  });
}
