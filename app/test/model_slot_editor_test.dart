import 'dart:async';

import 'package:bond_inbox/services/llm/model_probe.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/widgets/inline_alert.dart';
import 'package:bond_inbox/widgets/model_slot_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One slot's editor, driven with nothing but closures.
///
/// It is prop-only and holds no providers, so this file pumps it alone: there
/// is no `InboxScreen` and therefore no sixty-second timer, which is what makes
/// `pumpAndSettle` safe here and nowhere near `settings_models_host_test.dart`.
///
/// The subject is the contract the screen above it depends on: Save is the only
/// commit, a value equal to the compiled default is stored as "follow the
/// build", a probe never blocks a save, and the three outcomes a probe can have
/// render as three different things.

const LlmTarget _default = LlmTarget(
  baseUrl: 'http://localhost:8082/v1/chat/completions',
  model: 'qwen3.8',
);

void main() {
  Future<void> pump(
    WidgetTester tester, {
    LlmTarget current = _default,
    LlmTarget compiledDefault = _default,
    bool isDefault = true,
    Future<ModelProbeResult> Function(String)? probe,
    void Function({required String url, required String model})? onSave,
    VoidCallback? onReset,
    bool wireProbe = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ModelSlotEditor(
            slot: ModelSlot.fast,
            title: 'Fast · bulk work',
            blurb: 'Triage and the rest of the bulk work.',
            current: current,
            compiledDefault: compiledDefault,
            isDefault: isDefault,
            probe: !wireProbe
                ? null
                : probe ??
                    (_) async => const ModelProbeResult(reachable: true),
            onSave: onSave ?? ({required url, required model}) {},
            onReset: onReset ?? () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  String urlText(WidgetTester tester) => tester
      .widget<TextField>(
        find.byKey(ModelSlotEditor.urlFieldKey(ModelSlot.fast)),
      )
      .controller!
      .text;

  String modelText(WidgetTester tester) => tester
      .widget<TextField>(
        find.byKey(ModelSlotEditor.modelFieldKey(ModelSlot.fast)),
      )
      .controller!
      .text;

  bool saveEnabled(WidgetTester tester) =>
      tester
          .widget<FilledButton>(
            find.byKey(ModelSlotEditor.saveKey(ModelSlot.fast)),
          )
          .onPressed !=
      null;

  Future<void> check(WidgetTester tester) async {
    await tester.tap(find.byKey(ModelSlotEditor.checkKey(ModelSlot.fast)));
    await tester.pumpAndSettle();
  }

  testWidgets('opens on the target it was handed', (tester) async {
    await pump(
      tester,
      current: const LlmTarget(
        baseUrl: 'http://127.0.0.1:9000/v1/chat/completions',
        model: 'mlx-4b',
      ),
    );

    expect(urlText(tester), 'http://127.0.0.1:9000/v1/chat/completions');
    expect(modelText(tester), 'mlx-4b');
  });

  testWidgets('the chip says whether the slot follows the build',
      (tester) async {
    await pump(tester);
    expect(find.text('Default'), findsOneWidget);
    expect(find.text('Custom'), findsNothing);

    await pump(tester, isDefault: false);
    expect(find.text('Custom'), findsOneWidget);
    expect(find.text('Default'), findsNothing);
  });

  testWidgets('Check server asks about the URL in the FIELD, and lists what it '
      'finds', (tester) async {
    final asked = <String>[];
    await pump(tester, probe: (url) async {
      asked.add(url);
      return ModelProbeResult(
        reachable: true,
        modelIds: const ['qwen3-4b', 'qwen3.8'],
        probedUrl: Uri.parse('http://127.0.0.1:9000/v1/models'),
      );
    });

    await tester.enterText(
      find.byKey(ModelSlotEditor.urlFieldKey(ModelSlot.fast)),
      ' http://127.0.0.1:9000/v1/chat/completions ',
    );
    await tester.pumpAndSettle();
    await check(tester);

    // Trimmed, and the field's value rather than the saved one: the whole
    // point of the button is to check what is about to be saved.
    expect(asked, ['http://127.0.0.1:9000/v1/chat/completions']);
    expect(find.text('Reachable · 2 models'), findsOneWidget);
    expect(find.text('Asked http://127.0.0.1:9000/v1/models'), findsOneWidget);
    expect(
      find.byKey(ModelSlotEditor.modelPickerKey(ModelSlot.fast)),
      findsOneWidget,
    );
    // The free field is GONE — with a listing, the name is picked, not typed.
    expect(
      find.byKey(ModelSlotEditor.modelFieldKey(ModelSlot.fast)),
      findsNothing,
    );
  });

  testWidgets('picking a listed model makes the editor dirty', (tester) async {
    await pump(
      tester,
      probe: (_) async => const ModelProbeResult(
        reachable: true,
        modelIds: ['qwen3-4b', 'qwen3.8'],
      ),
    );
    await check(tester);
    expect(saveEnabled(tester), isFalse);

    await tester.tap(find.byKey(ModelSlotEditor.modelPickerKey(ModelSlot.fast)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('qwen3-4b').last);
    await tester.pumpAndSettle();

    expect(saveEnabled(tester), isTrue);
  });

  testWidgets('Save hands both halves over and leaves the editor clean',
      (tester) async {
    final saves = <(String, String)>[];
    await pump(
      tester,
      onSave: ({required url, required model}) => saves.add((url, model)),
    );

    await tester.enterText(
      find.byKey(ModelSlotEditor.urlFieldKey(ModelSlot.fast)),
      'http://127.0.0.1:9000/v1/chat/completions',
    );
    await tester.enterText(
      find.byKey(ModelSlotEditor.modelFieldKey(ModelSlot.fast)),
      'mlx-4b',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ModelSlotEditor.saveKey(ModelSlot.fast)));
    await tester.pumpAndSettle();

    expect(saves, [('http://127.0.0.1:9000/v1/chat/completions', 'mlx-4b')]);
    expect(saveEnabled(tester), isFalse,
        reason: 'the save became the new baseline');
  });

  testWidgets('typing the build defaults back stores "follow the build"',
      (tester) async {
    final saves = <(String, String)>[];
    await pump(
      tester,
      current: const LlmTarget(
        baseUrl: 'http://127.0.0.1:9000/v1/chat/completions',
        model: 'other',
      ),
      isDefault: false,
      onSave: ({required url, required model}) => saves.add((url, model)),
    );

    await tester.enterText(
      find.byKey(ModelSlotEditor.urlFieldKey(ModelSlot.fast)),
      _default.baseUrl,
    );
    await tester.enterText(
      find.byKey(ModelSlotEditor.modelFieldKey(ModelSlot.fast)),
      _default.model,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ModelSlotEditor.saveKey(ModelSlot.fast)));
    await tester.pumpAndSettle();

    // Empty, not the literal default: a dart-define frozen into the database
    // would make a changed build invisible.
    expect(saves, [('', '')]);
  });

  testWidgets('Use build defaults resets both fields, and is inert when the '
      'slot is already default', (tester) async {
    var resets = 0;
    await pump(
      tester,
      current: const LlmTarget(
        baseUrl: 'http://127.0.0.1:9000/v1/chat/completions',
        model: 'mlx-4b',
      ),
      isDefault: false,
      onReset: () => resets++,
    );

    await tester.tap(find.byKey(ModelSlotEditor.resetKey(ModelSlot.fast)));
    await tester.pumpAndSettle();

    expect(resets, 1);
    expect(urlText(tester), _default.baseUrl);
    expect(modelText(tester), _default.model);

    await pump(tester);
    expect(
      tester
          .widget<TextButton>(find.byKey(ModelSlotEditor.resetKey(ModelSlot.fast)))
          .onPressed,
      isNull,
    );
  });

  testWidgets('Cancel puts the last saved values back, and is disabled while '
      'clean', (tester) async {
    await pump(tester);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(ModelSlotEditor.cancelKey(ModelSlot.fast)),
          )
          .onPressed,
      isNull,
    );

    await tester.enterText(
      find.byKey(ModelSlotEditor.urlFieldKey(ModelSlot.fast)),
      'http://elsewhere:1/v1/chat/completions',
    );
    await tester.enterText(
      find.byKey(ModelSlotEditor.modelFieldKey(ModelSlot.fast)),
      'nonsense',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ModelSlotEditor.cancelKey(ModelSlot.fast)));
    await tester.pumpAndSettle();

    expect(urlText(tester), _default.baseUrl);
    expect(modelText(tester), _default.model);
  });

  testWidgets('a server that did not answer is an alert, and Save still works',
      (tester) async {
    final saves = <(String, String)>[];
    await pump(
      tester,
      current: const LlmTarget(
        baseUrl: 'http://127.0.0.1:9000/v1/chat/completions',
        model: 'qwen3.8',
      ),
      isDefault: false,
      probe: (_) async => ModelProbeResult(
        reachable: false,
        probedUrl: Uri.parse('http://127.0.0.1:9000/v1/models'),
        error: 'Nothing is listening at 127.0.0.1:9000',
      ),
      onSave: ({required url, required model}) => saves.add((url, model)),
    );
    await check(tester);

    expect(find.byType(InlineAlert), findsOneWidget);
    expect(find.text('Nothing is listening at 127.0.0.1:9000'), findsOneWidget);
    expect(find.text('Asked http://127.0.0.1:9000/v1/models'), findsOneWidget);

    // A probe is diagnostics; it is never a gate. Somebody starting a server
    // in a minute must still be able to point the app at it now.
    await tester.enterText(
      find.byKey(ModelSlotEditor.modelFieldKey(ModelSlot.fast)),
      'mlx-4b',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ModelSlotEditor.saveKey(ModelSlot.fast)));
    await tester.pumpAndSettle();

    expect(saves, [('http://127.0.0.1:9000/v1/chat/completions', 'mlx-4b')]);
  });

  testWidgets('a model this server does not serve is kept, and flagged',
      (tester) async {
    await pump(
      tester,
      current: const LlmTarget(baseUrl: _defaultUrl, model: 'mystery'),
      probe: (_) async =>
          const ModelProbeResult(reachable: true, modelIds: ['qwen3-4b']),
    );
    await check(tester);

    expect(find.text('mystery (not listed)'), findsOneWidget);
    expect(
      find.text('This server did not list that name. llama.cpp will ignore '
          'it; an MLX runtime will refuse the request.'),
      findsOneWidget,
    );
  });

  testWidgets('a URL the probe refuses is shown beside the field, not as '
      'server status', (tester) async {
    await pump(
      tester,
      probe: (_) async => const ModelProbeResult(
        reachable: false,
        error: 'Not a model server URL — expected something ending in /v1/…',
      ),
    );
    await check(tester);

    final field = tester.widget<TextField>(
      find.byKey(ModelSlotEditor.urlFieldKey(ModelSlot.fast)),
    );
    expect(
      field.decoration!.errorText,
      'Not a model server URL — expected something ending in /v1/…',
    );
    // No request was made, so there is nothing to report ABOUT a server.
    expect(find.byType(InlineAlert), findsNothing);
  });

  testWidgets('a live server with nothing loaded keeps the typed name',
      (tester) async {
    await pump(
      tester,
      probe: (_) async => const ModelProbeResult(reachable: true),
    );
    await check(tester);

    expect(find.text('Reachable · nothing loaded yet'), findsOneWidget);
    expect(
      find.byKey(ModelSlotEditor.modelFieldKey(ModelSlot.fast)),
      findsOneWidget,
    );
    expect(
      find.byKey(ModelSlotEditor.modelPickerKey(ModelSlot.fast)),
      findsNothing,
    );
  });

  testWidgets('editing the URL drops the listing it no longer belongs to',
      (tester) async {
    await pump(
      tester,
      probe: (_) async =>
          const ModelProbeResult(reachable: true, modelIds: ['qwen3-4b']),
    );
    await check(tester);
    expect(
      find.byKey(ModelSlotEditor.modelPickerKey(ModelSlot.fast)),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(ModelSlotEditor.urlFieldKey(ModelSlot.fast)),
      'http://elsewhere:1/v1/chat/completions',
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(ModelSlotEditor.modelPickerKey(ModelSlot.fast)),
      findsNothing,
    );
    expect(
      find.byKey(ModelSlotEditor.modelFieldKey(ModelSlot.fast)),
      findsOneWidget,
    );
  });

  testWidgets('an empty field cannot be saved', (tester) async {
    await pump(tester);

    await tester.enterText(
      find.byKey(ModelSlotEditor.modelFieldKey(ModelSlot.fast)),
      '',
    );
    await tester.pumpAndSettle();
    expect(saveEnabled(tester), isFalse);

    await tester.enterText(
      find.byKey(ModelSlotEditor.modelFieldKey(ModelSlot.fast)),
      'mlx-4b',
    );
    await tester.enterText(
      find.byKey(ModelSlotEditor.urlFieldKey(ModelSlot.fast)),
      '   ',
    );
    await tester.pumpAndSettle();
    expect(saveEnabled(tester), isFalse);
  });

  testWidgets('a new target from the host is adopted by a clean editor and '
      'ignored by a dirty one', (tester) async {
    // The identity-wipe path: a sign-in underneath the pane replaces what the
    // host says the slot is. An unsaved edit is the user's and survives it.
    await pump(tester);
    await pump(
      tester,
      current: const LlmTarget(baseUrl: 'http://new:1/v1/chat/completions',
          model: 'adopted'),
    );
    expect(urlText(tester), 'http://new:1/v1/chat/completions');
    expect(modelText(tester), 'adopted');

    await tester.enterText(
      find.byKey(ModelSlotEditor.modelFieldKey(ModelSlot.fast)),
      'mine',
    );
    await tester.pumpAndSettle();
    await pump(
      tester,
      current: const LlmTarget(baseUrl: 'http://other:2/v1/chat/completions',
          model: 'theirs'),
    );

    expect(modelText(tester), 'mine');
    expect(urlText(tester), 'http://new:1/v1/chat/completions');
  });

  testWidgets('a probe landing after the editor is gone does nothing',
      (tester) async {
    final pending = Completer<ModelProbeResult>();
    await pump(tester, probe: (_) => pending.future);

    await tester.tap(find.byKey(ModelSlotEditor.checkKey(ModelSlot.fast)));
    await tester.pump();

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.complete(const ModelProbeResult(reachable: true));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('a probe that throws is reported, not thrown', (tester) async {
    // The probe's own contract is never to throw; this is the editor keeping
    // that promise on the probe's behalf, because a settings screen must not
    // crash on diagnostics.
    await pump(tester, probe: (_) async => throw StateError('socket'));
    await check(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(InlineAlert), findsOneWidget);
    expect(find.text('Could not check the server'), findsOneWidget);
  });

  testWidgets('an answer for a URL that was edited away is dropped',
      (tester) async {
    final pending = Completer<ModelProbeResult>();
    await pump(tester, probe: (_) => pending.future);
    await tester.tap(find.byKey(ModelSlotEditor.checkKey(ModelSlot.fast)));
    await tester.pump();
    expect(find.text('Checking…'), findsOneWidget);

    // The user moves on while the answer is out.
    await tester.enterText(
      find.byKey(ModelSlotEditor.urlFieldKey(ModelSlot.fast)),
      'http://elsewhere:1/v1/chat/completions',
    );
    await tester.pump();
    pending.complete(const ModelProbeResult(
      reachable: true,
      modelIds: ['stale-model'],
    ));
    await tester.pumpAndSettle();

    // No listing from the old server under the new server's URL, and the
    // editor is not stuck saying it is still checking.
    expect(find.text('Checking…'), findsNothing);
    expect(
      find.byKey(ModelSlotEditor.modelPickerKey(ModelSlot.fast)),
      findsNothing,
    );
    expect(find.textContaining('Reachable'), findsNothing);
  });

  testWidgets('without a probe there is no Check server, and the model stays '
      'a typed name', (tester) async {
    await pump(tester, wireProbe: false);

    expect(find.byKey(ModelSlotEditor.checkKey(ModelSlot.fast)), findsNothing);
    expect(
      find.byKey(ModelSlotEditor.modelFieldKey(ModelSlot.fast)),
      findsOneWidget,
    );
    // Everything else still works: this is an editor with one control fewer,
    // not a disabled one.
    await tester.enterText(
      find.byKey(ModelSlotEditor.modelFieldKey(ModelSlot.fast)),
      'mlx-4b',
    );
    await tester.pumpAndSettle();
    expect(saveEnabled(tester), isTrue);
  });
}

const String _defaultUrl = 'http://localhost:8082/v1/chat/completions';
