import 'package:bond_inbox/services/llm/model_probe.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/widgets/chips.dart';
import 'package:bond_inbox/widgets/settings_targets_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Targets list: what one row says about a server, which rows may be
/// edited or removed, and the two clicks a removal takes.
///
/// Prop-only, so there is no host, no prefs and no keychain here — the list is
/// driven with four closures and a list of specs.

const _fast = LlmTargetSpec(
  id: builtInFastId,
  name: builtInFastName,
  url: 'http://localhost:8082/v1/chat/completions',
  model: 'qwen3-4b',
);

const _prose = LlmTargetSpec(
  id: builtInProseId,
  name: builtInProseName,
  url: 'http://localhost:8080/v1/chat/completions',
  model: 'qwen3-27b',
);

/// The GPU box as it actually arrives: an ssh tunnel on loopback, with a
/// token, four slots wide.
const _box = LlmTargetSpec(
  id: 't-1a2b3c4d',
  name: 'Studio box',
  url: 'http://localhost:18100/v1/chat/completions',
  model: 'qwen3-27b-fp8',
  hasBearer: true,
  parallel: 4,
);

const _bedrock = LlmTargetSpec(
  id: 't-99887766',
  name: 'Bedrock Opus',
  url: 'https://bedrock-runtime.us-east-2.amazonaws.com/',
  model: 'us.example.opus',
  wire: LlmWire.bedrockConverse,
);

void main() {
  Future<void> open(
    WidgetTester tester, {
    List<LlmTargetSpec> targets = const [_fast, _prose, _box],
    Future<ModelProbeResult> Function(String url)? probe,
    VoidCallback? onAdd,
    void Function(LlmTargetSpec spec)? onEdit,
    Future<void> Function(String id)? onRemove,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SettingsTargetsBody(
            targets: targets,
            probe: probe,
            onAdd: onAdd ?? () {},
            onEdit: onEdit ?? (_) {},
            onRemove: onRemove ?? (_) async {},
          ),
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

  bool chipSaying(WidgetTester tester, String label) => tester
      .widgetList(
        find.descendant(of: find.byType(BondChip), matching: find.text(label)),
      )
      .isNotEmpty;

  testWidgets('a row says what the target is and what is known about it',
      (tester) async {
    await open(tester);

    expect(find.text('Studio box'), findsOneWidget);
    expect(find.text('localhost:18100'), findsOneWidget);
    expect(find.text('qwen3-27b-fp8'), findsOneWidget);
    expect(chipSaying(tester, 'OpenAI'), isTrue);
    expect(chipSaying(tester, 'Bearer set'), isTrue);
    expect(chipSaying(tester, 'Parallel 4'), isTrue);
  });

  testWidgets('the Converse wire and a missing token both say so',
      (tester) async {
    await open(tester, targets: const [_fast, _prose, _bedrock]);

    expect(chipSaying(tester, 'Converse'), isTrue);
    expect(chipSaying(tester, 'No bearer'), isTrue);
    // A row with one request in flight says nothing about width: the number is
    // only news when it is not one.
    expect(chipSaying(tester, 'Parallel 1'), isFalse);
  });

  testWidgets('the built-ins come first and are edited elsewhere',
      (tester) async {
    await open(tester);

    expect(
      tester.getTopLeft(find.text(builtInFastName)).dy,
      lessThan(tester.getTopLeft(find.text('Studio box')).dy),
    );
    for (final id in [builtInFastId, builtInProseId]) {
      expect(find.byKey(SettingsTargetsBody.editKey(id)), findsNothing);
      expect(find.byKey(SettingsTargetsBody.removeKey(id)), findsNothing);
    }
    expect(
      find.text('Edited above, under Fast and Prose'),
      findsNWidgets(2),
    );
    // The user's own target keeps both.
    expect(find.byKey(SettingsTargetsBody.editKey(_box.id)), findsOneWidget);
    expect(find.byKey(SettingsTargetsBody.removeKey(_box.id)), findsOneWidget);
  });

  testWidgets('Edit hands the host the spec it was pressed on', (tester) async {
    final edited = <String>[];
    await open(tester, onEdit: (spec) => edited.add(spec.id));

    await press(tester, find.byKey(SettingsTargetsBody.editKey(_box.id)));

    expect(edited, [_box.id]);
  });

  testWidgets('Remove takes two clicks and Keep stands it down',
      (tester) async {
    final removed = <String>[];
    await open(tester, onRemove: (id) async => removed.add(id));

    await press(tester, find.byKey(SettingsTargetsBody.removeKey(_box.id)));
    // Armed, and nothing has been written.
    expect(removed, isEmpty);
    expect(
      find.byKey(SettingsTargetsBody.removeConfirmKey(_box.id)),
      findsOneWidget,
    );

    await press(tester, find.byKey(SettingsTargetsBody.removeKeepKey(_box.id)));
    expect(removed, isEmpty);
    expect(find.byKey(SettingsTargetsBody.removeKey(_box.id)), findsOneWidget);

    await press(tester, find.byKey(SettingsTargetsBody.removeKey(_box.id)));
    await press(
      tester,
      find.byKey(SettingsTargetsBody.removeConfirmKey(_box.id)),
    );

    expect(removed, [_box.id]);
  });

  testWidgets('a host that cannot ask a server offers no Check server',
      (tester) async {
    await open(tester);

    for (final spec in const [_fast, _prose, _box]) {
      expect(find.byKey(SettingsTargetsBody.checkKey(spec.id)), findsNothing);
    }
    // The rest of the row is untouched — one control fewer, not disabled.
    expect(find.byKey(SettingsTargetsBody.editKey(_box.id)), findsOneWidget);
  });

  testWidgets('Check server asks that row\'s own URL and reports the answer',
      (tester) async {
    final asked = <String>[];
    await open(tester, probe: (url) async {
      asked.add(url);
      return const ModelProbeResult(
        reachable: true,
        modelIds: ['qwen3-27b-fp8'],
      );
    });

    await press(tester, find.byKey(SettingsTargetsBody.checkKey(_box.id)));

    expect(asked, [_box.url]);
    expect(find.text('Reachable · 1 model'), findsOneWidget);
  });

  testWidgets('Add target reaches the host', (tester) async {
    var added = 0;
    await open(tester, onAdd: () => added++);

    await press(tester, find.byKey(SettingsTargetsBody.addKey));

    expect(added, 1);
  });

  testWidgets('the list survives a doubled text scale', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await open(tester, probe: (_) async => const ModelProbeResult(reachable: true));

    expect(tester.takeException(), isNull);
  });
}
