import 'dart:async';

import 'package:bond_inbox/services/llm/model_probe.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/widgets/model_servers_form.dart';
import 'package:bond_inbox/widgets/probe_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one form for servers a person names.
///
/// Prop-only, so this file pumps it alone: there is no `InboxScreen` and
/// therefore no sixty-second timer, which is what makes `pumpAndSettle` safe
/// here. What it pins is the contract both hosts depend on: an address is
/// refused before anything is asked, a name is DISCOVERED rather than typed,
/// a server that lists several waits for a pick, and the access key reaches
/// the two requests and the one call and nothing else.
///
/// The access key in these fixtures is `sk-fixture-…`, and several cases
/// assert that no rendered `Text` carries it. `find.text` reads an
/// `EditableText`'s controller rather than the bullets it draws, so the field
/// itself is the one match allowed anywhere.

const _bigUrl = 'https://box.example.com/prose/v1/chat/completions';
const _smallUrl = 'https://box.example.com/bulk/v1/chat/completions';
const _localUrl = 'http://localhost:8080/v1/chat/completions';

/// Somebody else's service, and the one place either name appears: the form
/// has to recognise a vendor's address and a Converse one.
const _openAiUrl = 'https://api.openai.com/v1/chat/completions';
const _bedrockUrl =
    'https://bedrock-runtime.us-east-1.amazonaws.com/model/example/converse';

typedef Connected = ({
  String bigUrl,
  String smallUrl,
  String bigModel,
  String smallModel,
  String? bigKey,
  String? smallKey,
});

void main() {
  late List<(String, String?)> asked;
  late List<Connected> connected;

  setUp(() {
    asked = [];
    connected = [];
  });

  /// A probe that answers per URL and records what rode with each request.
  Future<ModelProbeResult> Function(String, {String? bearer}) fake(
    Map<String, ModelProbeResult> answers,
  ) =>
      (url, {bearer}) async {
        asked.add((url, bearer));
        return answers[url] ??
            const ModelProbeResult(reachable: true, modelIds: ['a-model']);
      };

  Future<void> open(
    WidgetTester tester, {
    String bigUrl = _bigUrl,
    String smallUrl = _smallUrl,
    String bigModel = '',
    String smallModel = '',
    bool keyStored = false,
    bool bigKeyStored = false,
    bool smallKeyStored = false,
    Future<ModelProbeResult> Function(String, {String? bearer})? probe,
    String? Function(String)? storedBearer,
    Future<void> Function({
      required String bigUrl,
      required String smallUrl,
      required String bigModel,
      required String smallModel,
      String? bigKey,
      String? smallKey,
    })? onConnect,
    Future<void> Function()? onRemoveKey,
    Future<void> Function(LlmTargetSpec, Future<void> Function())? onThirdParty,
    bool wireThirdParty = true,
    String connectLabel = 'Connect',
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ModelServersForm(
            bigUrl: bigUrl,
            smallUrl: smallUrl,
            bigModel: bigModel,
            smallModel: smallModel,
            keyStored: keyStored,
            bigKeyStored: bigKeyStored,
            smallKeyStored: smallKeyStored,
            probe: probe ?? fake(const {}),
            storedBearer: storedBearer,
            onConnect: onConnect ??
                ({
                  required bigUrl,
                  required smallUrl,
                  required bigModel,
                  required smallModel,
                  bigKey,
                  smallKey,
                }) async =>
                    connected.add((
                      bigUrl: bigUrl,
                      smallUrl: smallUrl,
                      bigModel: bigModel,
                      smallModel: smallModel,
                      bigKey: bigKey,
                      smallKey: smallKey,
                    )),
            onRemoveKey: onRemoveKey,
            onThirdParty: wireThirdParty
                ? (onThirdParty ?? (spec, resume) async => resume())
                : null,
            connectLabel: connectLabel,
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

  Future<void> connect(WidgetTester tester) =>
      press(tester, find.byKey(ModelServersForm.connectKey));

  Future<void> type(WidgetTester tester, Key key, String text) async {
    await tester.enterText(find.byKey(key), text);
    await tester.pumpAndSettle();
  }

  String fieldText(WidgetTester tester, Key key) =>
      tester.widget<TextField>(find.byKey(key)).controller!.text;

  List<String> rendered(WidgetTester tester) => [
        for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? '',
      ];

  group('the fields', () {
    testWidgets('open on the values the host resolved, and the key opens '
        'empty', (tester) async {
      await open(tester);

      expect(fieldText(tester, ModelServersForm.bigUrlKey), _bigUrl);
      expect(fieldText(tester, ModelServersForm.smallUrlKey), _smallUrl);
      expect(fieldText(tester, ModelServersForm.keyKey), '');
      expect(
        tester
            .widget<TextField>(find.byKey(ModelServersForm.keyKey))
            .obscureText,
        isTrue,
      );
      // One host is one operator and one key.
      expect(find.byKey(ModelServersForm.smallKeyKey), findsNothing);
    });

    testWidgets('a stored key hints that typing replaces it', (tester) async {
      await open(tester, keyStored: true, bigKeyStored: true);

      expect(
        tester
            .widget<TextField>(find.byKey(ModelServersForm.keyKey))
            .decoration!
            .hintText,
        ModelServersForm.storedHint,
      );
    });

    testWidgets('the second key field follows the two hosts as they are typed',
        (tester) async {
      await open(tester);
      expect(find.byKey(ModelServersForm.smallKeyKey), findsNothing);

      await type(tester, ModelServersForm.smallUrlKey, _localUrl);
      expect(find.byKey(ModelServersForm.smallKeyKey), findsOneWidget);

      await type(tester, ModelServersForm.smallUrlKey, _smallUrl);
      expect(find.byKey(ModelServersForm.smallKeyKey), findsNothing);
    });

    testWidgets('Remove key is offered only with a key stored and a host that '
        'can forget one', (tester) async {
      var removed = 0;
      await open(tester);
      expect(find.byKey(ModelServersForm.removeKeyKey), findsNothing);

      await open(tester, keyStored: true);
      expect(find.byKey(ModelServersForm.removeKeyKey), findsNothing);

      await open(
        tester,
        keyStored: true,
        onRemoveKey: () async => removed++,
      );
      await press(tester, find.byKey(ModelServersForm.removeKeyKey));

      expect(removed, 1);
    });
  });

  group('an address the form refuses', () {
    testWidgets('one with no scheme is refused under its field and nothing is '
        'asked', (tester) async {
      await open(tester);
      await type(tester, ModelServersForm.bigUrlKey, 'box.example.com');
      await connect(tester);

      expect(find.text(ModelServersForm.addressRefusalText), findsOneWidget);
      expect(asked, isEmpty);
      expect(connected, isEmpty);
    });

    testWidgets('an origin where an endpoint belongs says which endpoint',
        (tester) async {
      await open(tester);
      await type(tester, ModelServersForm.bigUrlKey, 'https://box.example.com');
      await connect(tester);

      expect(find.text(ModelServersForm.endpointRefusalText), findsOneWidget);
      expect(asked, isEmpty);
    });

    testWidgets('typing again clears the sentence', (tester) async {
      await open(tester);
      await type(tester, ModelServersForm.bigUrlKey, 'box.example.com');
      await connect(tester);
      expect(find.text(ModelServersForm.addressRefusalText), findsOneWidget);

      await type(tester, ModelServersForm.bigUrlKey, _bigUrl);

      expect(find.text(ModelServersForm.addressRefusalText), findsNothing);
    });
  });

  group('Connect', () {
    testWidgets('asks both servers with the typed key and reports each',
        (tester) async {
      await open(
        tester,
        probe: fake(const {
          _bigUrl: ModelProbeResult(reachable: true, modelIds: ['qwen3.8']),
          _smallUrl: ModelProbeResult(reachable: true, modelIds: ['qwen3-4b']),
        }),
      );
      await type(
        tester,
        ModelServersForm.keyKey,
        'sk-fixture-not-a-real-key',
      );
      await connect(tester);

      expect(asked, [
        (_bigUrl, 'sk-fixture-not-a-real-key'),
        (_smallUrl, 'sk-fixture-not-a-real-key'),
      ]);
      expect(find.byType(ProbeStatus), findsNWidgets(2));
      expect(find.text('Reachable · 1 model'), findsNWidgets(2));
      expect(rendered(tester), everyElement(isNot(contains('sk-fixture'))));
    });

    testWidgets('one id per server is used with nobody picking anything',
        (tester) async {
      await open(
        tester,
        probe: fake(const {
          _bigUrl: ModelProbeResult(reachable: true, modelIds: ['qwen3.8']),
          _smallUrl: ModelProbeResult(reachable: true, modelIds: ['qwen3-4b']),
        }),
      );
      await type(
        tester,
        ModelServersForm.keyKey,
        'sk-fixture-not-a-real-key',
      );
      await connect(tester);

      expect(connected, [
        (
          bigUrl: _bigUrl,
          smallUrl: _smallUrl,
          bigModel: 'qwen3.8',
          smallModel: 'qwen3-4b',
          bigKey: 'sk-fixture-not-a-real-key',
          smallKey: 'sk-fixture-not-a-real-key',
        ),
      ]);
      expect(find.byKey(ModelServersForm.bigModelKey), findsNothing);
      // The field is emptied the moment the key has reached the keychain.
      expect(fieldText(tester, ModelServersForm.keyKey), '');
      expect(rendered(tester), everyElement(isNot(contains('sk-fixture'))));
    });

    testWidgets('a server that lists several waits for a pick, and the second '
        'press takes it', (tester) async {
      await open(
        tester,
        probe: fake(const {
          _bigUrl: ModelProbeResult(
            reachable: true,
            modelIds: ['qwen3.8', 'qwen3-27b-fp8'],
          ),
          _smallUrl: ModelProbeResult(reachable: true, modelIds: ['qwen3-4b']),
        }),
      );
      await connect(tester);

      // The picker is up with the first id filled in, and nothing was written.
      final picker = find.byKey(ModelServersForm.bigModelKey);
      expect(picker, findsOneWidget);
      expect(
        tester.widget<DropdownButton<String>>(picker).value,
        'qwen3.8',
      );
      expect(
        find.textContaining(ModelServersForm.chooseModelText),
        findsOneWidget,
      );
      expect(connected, isEmpty);

      await press(tester, picker);
      await press(tester, find.text('qwen3-27b-fp8').last);
      await connect(tester);

      expect(connected.single.bigModel, 'qwen3-27b-fp8');
      expect(connected.single.smallModel, 'qwen3-4b');
    });

    testWidgets('a server that did not answer connects nothing',
        (tester) async {
      await open(
        tester,
        probe: fake(const {
          _bigUrl: ModelProbeResult(reachable: true, modelIds: ['qwen3.8']),
          _smallUrl: ModelProbeResult(
            reachable: false,
            error: 'Connection refused',
          ),
        }),
      );
      await connect(tester);

      expect(find.text('Connection refused'), findsOneWidget);
      expect(connected, isEmpty);
    });

    testWidgets('two hosts send two keys, each to its own server',
        (tester) async {
      await open(tester);
      await type(tester, ModelServersForm.smallUrlKey, _localUrl);
      await type(
        tester,
        ModelServersForm.keyKey,
        'sk-fixture-big-key',
      );
      await type(
        tester,
        ModelServersForm.smallKeyKey,
        'sk-fixture-small-key',
      );
      await connect(tester);

      expect(asked, [
        (_bigUrl, 'sk-fixture-big-key'),
        (_localUrl, 'sk-fixture-small-key'),
      ]);
      expect(connected.single.bigKey, 'sk-fixture-big-key');
      expect(connected.single.smallKey, 'sk-fixture-small-key');
      expect(rendered(tester), everyElement(isNot(contains('sk-fixture'))));
    });

    testWidgets('a key field left blank with one stored sends the stored one '
        'and writes no key at all', (tester) async {
      await open(
        tester,
        keyStored: true,
        bigKeyStored: true,
        smallKeyStored: true,
        storedBearer: (id) => 'sk-fixture-stored-$id',
      );
      await connect(tester);

      expect(asked, [
        (_bigUrl, 'sk-fixture-stored-$boxProseId'),
        (_smallUrl, 'sk-fixture-stored-$boxBulkId'),
      ]);
      // Null, not the empty string: the host reads that as "keep what is
      // stored" and writes no keychain entry.
      expect(connected.single.bigKey, isNull);
      expect(connected.single.smallKey, isNull);
      expect(rendered(tester), everyElement(isNot(contains('sk-fixture'))));
    });

    testWidgets('a refusal from the host is shown under the form',
        (tester) async {
      await open(
        tester,
        onConnect: ({
          required bigUrl,
          required smallUrl,
          required bigModel,
          required smallModel,
          bigKey,
          smallKey,
        }) async =>
            throw ArgumentError.value(
              bigUrl,
              'bigUrl',
              'a third-party server needs cloud drafts consent first',
            ),
      );
      await connect(tester);

      expect(find.byKey(ModelServersForm.errorKey), findsOneWidget);
      expect(
        find.text('a third-party server needs cloud drafts consent first'),
        findsOneWidget,
      );
    });

    testWidgets('a write that fails for a reason nobody typed still says so',
        (tester) async {
      // `useBox` ends in a keychain write, which answers with a
      // `PlatformException` on a locked keychain or a denied prompt. Caught
      // as nothing, that left the key field full and the screen silent.
      await open(
        tester,
        onConnect: ({
          required bigUrl,
          required smallUrl,
          required bigModel,
          required smallModel,
          bigKey,
          smallKey,
        }) async =>
            throw StateError('keychain locked'),
      );
      await connect(tester);

      expect(find.byKey(ModelServersForm.errorKey), findsOneWidget);
      expect(find.text(ModelServersForm.saveFailedText), findsOneWidget);
      // Nothing about the failure names the machinery that failed.
      expect(find.textContaining('StateError'), findsNothing);
    });

    testWidgets('a write outlived by an edit clears no key and says nothing',
        (tester) async {
      final hold = Completer<void>();
      await open(
        tester,
        onConnect: ({
          required bigUrl,
          required smallUrl,
          required bigModel,
          required smallModel,
          bigKey,
          smallKey,
        }) =>
            hold.future,
      );
      await type(tester, ModelServersForm.keyKey, 'sk-fixture-first-key');
      await tester.tap(find.byKey(ModelServersForm.connectKey));
      await tester.pumpAndSettle();

      // The person gave up waiting and started typing a replacement.
      await type(tester, ModelServersForm.keyKey, 'sk-fixture-second-key');

      hold.complete();
      await tester.pumpAndSettle();

      // The typing survives the old press landing: the clear belongs to the
      // press that was current, and no sentence about the old one lands
      // either.
      expect(
        fieldText(tester, ModelServersForm.keyKey),
        'sk-fixture-second-key',
      );
      expect(find.byKey(ModelServersForm.errorKey), findsNothing);
      expect(rendered(tester), everyElement(isNot(contains('sk-fixture'))));
    });

    testWidgets('a press outlived by an edit writes nothing', (tester) async {
      final hold = Completer<ModelProbeResult>();
      await open(tester, probe: (url, {bearer}) {
        asked.add((url, bearer));
        return hold.future;
      });

      await tester.tap(find.byKey(ModelServersForm.connectKey));
      await tester.pump();
      expect(find.text('Checking…'), findsNWidgets(2));

      await type(tester, ModelServersForm.bigUrlKey, _localUrl);
      // The busy lines come off with the edit.
      expect(find.text('Checking…'), findsNothing);

      hold.complete(
        const ModelProbeResult(reachable: true, modelIds: ['qwen3.8']),
      );
      await tester.pumpAndSettle();

      expect(connected, isEmpty);
      expect(find.textContaining('Reachable'), findsNothing);
    });
  });

  group('somebody else’s service', () {
    testWidgets('a vendor on the big address asks the host first, and the '
        'connect is its callback', (tester) async {
      final asks = <LlmTargetSpec>[];
      Future<void> Function()? resumed;
      await open(
        tester,
        bigUrl: _openAiUrl,
        probe: fake(const {
          _openAiUrl: ModelProbeResult(reachable: true, modelIds: ['gpt-x']),
          _smallUrl: ModelProbeResult(reachable: true, modelIds: ['qwen3-4b']),
        }),
        onThirdParty: (spec, resume) async {
          asks.add(spec);
          resumed = resume;
        },
      );
      await type(tester, ModelServersForm.keyKey, 'sk-fixture-not-a-real-key');
      await connect(tester);

      expect(asks.single.isThirdParty, isTrue);
      expect(asks.single.id, boxProseId);
      expect(asks.single.url, _openAiUrl);
      expect(asks.single.model, 'gpt-x');
      expect(asks.single.hasBearer, isTrue);
      expect(asks.single.parallel, 1);
      // Nothing is written until the person has read the pane and said yes.
      expect(connected, isEmpty);

      await resumed!();
      await tester.pumpAndSettle();

      expect(connected.single.bigUrl, _openAiUrl);
      expect(connected.single.bigModel, 'gpt-x');
    });

    testWidgets('a host with no pane to open refuses the address instead',
        (tester) async {
      await open(
        tester,
        bigUrl: _openAiUrl,
        wireThirdParty: false,
        probe: fake(const {
          _openAiUrl: ModelProbeResult(reachable: true, modelIds: ['gpt-x']),
        }),
      );
      await connect(tester);

      expect(find.text(ModelServersForm.thirdPartyRefusalText), findsOneWidget);
      expect(connected, isEmpty);
    });

    testWidgets('a Converse service is typed into rather than asked',
        (tester) async {
      await open(tester, bigUrl: _bedrockUrl);

      // Nothing to list, so nothing to probe and no picker: a Model field.
      expect(find.byKey(ModelServersForm.bigModelTextKey), findsOneWidget);
      expect(find.byKey(ModelServersForm.smallModelTextKey), findsNothing);

      await connect(tester);

      expect(find.text(ModelServersForm.modelNeededText), findsOneWidget);
      expect(asked, [(_smallUrl, null)]);
      expect(connected, isEmpty);

      await type(
        tester,
        ModelServersForm.bigModelTextKey,
        'us.example.big-model',
      );
      await connect(tester);

      expect(connected.single.bigModel, 'us.example.big-model');
      expect(connected.single.smallModel, 'a-model');
    });

    testWidgets('a Converse address prefills the model it was handed',
        (tester) async {
      await open(
        tester,
        bigUrl: _bedrockUrl,
        bigModel: 'us.example.big-model',
      );

      expect(
        fieldText(tester, ModelServersForm.bigModelTextKey),
        'us.example.big-model',
      );
    });
  });
}
