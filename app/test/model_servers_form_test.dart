import 'dart:async';

import 'package:bond_inbox/services/llm/model_probe.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/widgets/model_servers_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one form for a server a person names, one address per instance.
///
/// Prop-only, so this file pumps it alone: there is no `InboxScreen` and
/// therefore no sixty-second timer, which is what makes `pumpAndSettle` safe
/// here. What it pins is the contract every host depends on: an address is
/// refused before anything is asked (a decision address must be an
/// embeddings endpoint), a name is DISCOVERED rather than typed, a server
/// that lists several waits for a pick, a vendor never reaches a role, and a
/// stored key rides only to the host it was typed for.
///
/// The access key in these fixtures is `sk-fixture-…`, and several cases
/// assert that no rendered `Text` carries it. `find.text` reads an
/// `EditableText`'s controller rather than the bullets it draws, so the field
/// itself is the one match allowed anywhere.

const _generativeUrl = 'https://box.example.com/prose/v1/chat/completions';
const _decisionUrl = 'https://box.example.com/decide/v1/embeddings';
const _otherUrl = 'https://other.example.com/prose/v1/chat/completions';
const _localUrl = 'http://localhost:8080/v1/chat/completions';
const _key = 'sk-fixture-not-a-real-token';
const _stored = 'sk-fixture-not-a-real-stored-token';

/// Somebody else's service, and the one place either name appears.
const _openAiUrl = 'https://api.openai.com/v1/chat/completions';
const _bedrockUrl =
    'https://bedrock-runtime.us-east-1.amazonaws.com/model/example/converse';

typedef Connected = ({String url, String model, String? key, bool clearKey});

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
    ServerFormRole role = ServerFormRole.generative,
    String url = _generativeUrl,
    String model = '',
    bool keyStored = false,
    Future<ModelProbeResult> Function(String, {String? bearer})? probe,
    String? Function(String)? storedBearer,
    ServerConnect? onConnect,
    Future<void> Function()? onRemoveKey,
    Future<void> Function(LlmTargetSpec, Future<void> Function())? onThirdParty,
    String? thirdPartyRefusal,
    String connectLabel = 'Connect',
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ModelServersForm(
            role: role,
            url: url,
            model: model,
            keyStored: keyStored,
            probe: probe ?? fake(const {}),
            storedBearer: storedBearer,
            onConnect: onConnect ??
                ({required url, required model, key, required clearKey}) async =>
                    connected.add(
                      (url: url, model: model, key: key, clearKey: clearKey),
                    ),
            onRemoveKey: onRemoveKey,
            onThirdParty: onThirdParty,
            thirdPartyRefusal: thirdPartyRefusal,
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

  Future<void> connect(
    WidgetTester tester, [
    ServerFormRole role = ServerFormRole.generative,
  ]) =>
      press(tester, find.byKey(ModelServersForm.connectKey(role)));

  Future<void> type(WidgetTester tester, Key key, String text) async {
    await tester.enterText(find.byKey(key), text);
    await tester.pumpAndSettle();
  }

  String fieldText(WidgetTester tester, Key key) =>
      tester.widget<TextField>(find.byKey(key)).controller!.text;

  List<String> rendered(WidgetTester tester) => [
        for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? '',
      ];

  const gen = ServerFormRole.generative;
  const dec = ServerFormRole.decision;
  const cloud = ServerFormRole.cloudDrafts;

  group('the keys', () {
    test('are built on each role\'s prefix', () {
      expect(ModelServersForm.urlKey(dec), const ValueKey('servers-decision-url'));
      expect(ModelServersForm.keyKey(gen),
          const ValueKey('servers-generative-key'));
      expect(ModelServersForm.modelKey(gen),
          const ValueKey('servers-generative-model'));
      expect(ModelServersForm.connectKey(dec),
          const ValueKey('servers-decision-connect'));
      expect(ModelServersForm.errorKey(gen),
          const ValueKey('servers-generative-error'));
      expect(ModelServersForm.removeKeyKey(dec),
          const ValueKey('servers-decision-remove-key'));
      expect(ModelServersForm.urlKey(cloud), const ValueKey('cloud-drafts-url'));
      expect(ModelServersForm.connectKey(cloud),
          const ValueKey('cloud-drafts-connect'));
    });
  });

  group('the fields', () {
    testWidgets('open on the values the host resolved, one address, and the '
        'key opens empty and obscured', (tester) async {
      await open(tester, role: dec, url: _decisionUrl, keyStored: true);

      expect(fieldText(tester, ModelServersForm.urlKey(dec)), _decisionUrl);
      expect(find.text(ModelServersForm.urlLabel(dec)), findsOneWidget);
      // One address per form: no second field for any other role.
      expect(find.byKey(ModelServersForm.urlKey(gen)), findsNothing);
      final key = tester.widget<TextField>(
        find.byKey(ModelServersForm.keyKey(dec)),
      );
      expect(key.obscureText, isTrue);
      expect(key.controller!.text, isEmpty);
    });

    testWidgets('a stored key hints that typing replaces it', (tester) async {
      await open(tester, keyStored: true);
      expect(find.text(ModelServersForm.storedHint), findsOneWidget);

      await open(tester, keyStored: false);
      expect(find.text(ModelServersForm.storedHint), findsNothing);
    });

    testWidgets('a new host says the stored key is for another server',
        (tester) async {
      await open(tester, keyStored: true);

      await type(tester, ModelServersForm.urlKey(gen), _otherUrl);

      expect(find.text(ModelServersForm.otherHostHint), findsOneWidget);
      expect(find.text(ModelServersForm.storedHint), findsNothing);
    });

    testWidgets('Remove key is offered only with a key stored and a host that '
        'can forget it', (tester) async {
      var removed = 0;
      await open(tester, keyStored: true, onRemoveKey: () async => removed++);
      await press(tester, find.byKey(ModelServersForm.removeKeyKey(gen)));
      expect(removed, 1);

      await open(tester, keyStored: false, onRemoveKey: () async => removed++);
      expect(find.byKey(ModelServersForm.removeKeyKey(gen)), findsNothing);

      await open(tester, keyStored: true);
      expect(find.byKey(ModelServersForm.removeKeyKey(gen)), findsNothing);
    });
  });

  group('an address the form refuses', () {
    testWidgets('one with no scheme is refused under its field and nothing is '
        'asked', (tester) async {
      await open(tester);
      await type(tester, ModelServersForm.urlKey(gen), 'box.example.com');
      await connect(tester);

      expect(find.text(ModelServersForm.addressRefusalText), findsOneWidget);
      expect(asked, isEmpty);
      expect(connected, isEmpty);
    });

    testWidgets('a generative origin where an endpoint belongs says which',
        (tester) async {
      await open(tester);
      await type(tester, ModelServersForm.urlKey(gen), 'https://box.example.com');
      await connect(tester);

      expect(find.text(ModelServersForm.endpointRefusalText), findsOneWidget);
      expect(asked, isEmpty);
    });

    testWidgets('a decision address must be an embeddings endpoint',
        (tester) async {
      await open(tester, role: dec, url: _generativeUrl);
      await connect(tester, dec);

      expect(
        find.text(ModelServersForm.decisionEndpointRefusalText),
        findsOneWidget,
      );
      expect(asked, isEmpty);

      await type(tester, ModelServersForm.urlKey(dec), _decisionUrl);
      await connect(tester, dec);
      expect(find.text(ModelServersForm.decisionEndpointRefusalText),
          findsNothing);
      expect(asked.single.$1, _decisionUrl);
      expect(connected.single.url, _decisionUrl);
    });

    testWidgets('typing again clears the sentence', (tester) async {
      await open(tester);
      await type(tester, ModelServersForm.urlKey(gen), 'box.example.com');
      await connect(tester);
      expect(find.text(ModelServersForm.addressRefusalText), findsOneWidget);

      await type(tester, ModelServersForm.urlKey(gen), _generativeUrl);
      expect(find.text(ModelServersForm.addressRefusalText), findsNothing);
    });
  });

  group('Connect', () {
    testWidgets('asks the server with the typed key and writes what it listed',
        (tester) async {
      await open(
        tester,
        probe: fake(const {
          _generativeUrl:
              ModelProbeResult(reachable: true, modelIds: ['qwen3.8-27b']),
        }),
      );
      await type(tester, ModelServersForm.keyKey(gen), _key);
      await connect(tester);

      expect(asked, [(_generativeUrl, _key)]);
      expect(connected, [
        (url: _generativeUrl, model: 'qwen3.8-27b', key: _key, clearKey: false),
      ]);
      // The key left the field the moment it reached the host.
      expect(fieldText(tester, ModelServersForm.keyKey(gen)), isEmpty);
      expect(rendered(tester), isNot(contains(_key)));
    });

    testWidgets('a key no header can carry is refused under its field, and '
        'nothing is asked or written', (tester) async {
      await open(tester);
      await type(tester, ModelServersForm.keyKey(gen), 'sk-fixture\u00e9key');
      await connect(tester);

      expect(find.text(accessKeyCharsText), findsOneWidget);
      expect(asked, isEmpty);
      expect(connected, isEmpty);

      // Typing again clears the sentence.
      await type(tester, ModelServersForm.keyKey(gen), _key);
      expect(find.text(accessKeyCharsText), findsNothing);
    });

    testWidgets('a server that lists several waits for a pick, and the second '
        'press takes it', (tester) async {
      await open(
        tester,
        probe: fake(const {
          _generativeUrl:
              ModelProbeResult(reachable: true, modelIds: ['first', 'second']),
        }),
      );
      await connect(tester);
      expect(connected, isEmpty);
      expect(find.byKey(ModelServersForm.modelKey(gen)), findsOneWidget);
      expect(
        find.text('${ModelServersForm.chooseModelText}Connect again.'),
        findsOneWidget,
      );

      await press(tester, find.byKey(ModelServersForm.modelKey(gen)));
      await tester.tap(find.text('second').last);
      await tester.pumpAndSettle();
      await connect(tester);

      expect(connected.single.model, 'second');
    });

    testWidgets('a server that still lists the stored name connects on the '
        'first press', (tester) async {
      await open(
        tester,
        model: 'second',
        probe: fake(const {
          _generativeUrl:
              ModelProbeResult(reachable: true, modelIds: ['first', 'second']),
        }),
      );
      await connect(tester);

      expect(connected.single.model, 'second');
    });

    testWidgets('a decision server that lists several is taken at its first',
        (tester) async {
      await open(
        tester,
        role: dec,
        url: _decisionUrl,
        probe: fake(const {
          _decisionUrl:
              ModelProbeResult(reachable: true, modelIds: ['decide-a', 'b']),
        }),
      );
      await connect(tester, dec);

      expect(find.byKey(ModelServersForm.modelKey(dec)), findsNothing);
      expect(connected.single.model, 'decide-a');
    });

    testWidgets("a router's list is searched for the decision model, "
        'wherever it sits', (tester) async {
      await open(
        tester,
        role: dec,
        url: _decisionUrl,
        probe: fake(const {
          _decisionUrl: ModelProbeResult(
            reachable: true,
            modelIds: ['bond-embed', 'bond-decide', 'bond-prose'],
          ),
        }),
      );
      await connect(tester, dec);

      expect(find.byKey(ModelServersForm.modelKey(dec)), findsNothing);
      expect(connected.single.model, 'bond-decide');
    });

    testWidgets('the name this install already uses counts too',
        (tester) async {
      await open(
        tester,
        role: dec,
        url: _decisionUrl,
        model: 'decide-mine',
        probe: fake(const {
          _decisionUrl: ModelProbeResult(
            reachable: true,
            modelIds: ['bond-embed', 'decide-mine'],
          ),
        }),
      );
      await connect(tester, dec);
      expect(connected.single.model, 'decide-mine');
    });

    testWidgets('a server that did not answer connects nothing',
        (tester) async {
      await open(
        tester,
        probe: fake(const {
          _generativeUrl:
              ModelProbeResult(reachable: false, error: 'Connection refused'),
        }),
      );
      await connect(tester);

      expect(asked, hasLength(1));
      expect(connected, isEmpty);
    });

    testWidgets('a blank key with one stored sends the stored one to the same '
        'host, and never renders it', (tester) async {
      final looked = <String>[];
      await open(
        tester,
        role: dec,
        url: _decisionUrl,
        keyStored: true,
        storedBearer: (id) {
          looked.add(id);
          return _stored;
        },
      );
      await connect(tester, dec);

      expect(looked, [boxDecideId]);
      expect(asked, [(_decisionUrl, _stored)]);
      // Null keeps the stored key, and the host is the same: nothing to forget.
      expect(connected.single.key, isNull);
      expect(connected.single.clearKey, isFalse);
      expect(rendered(tester), isNot(contains(_stored)));
    });

    testWidgets('a NEW host with the key field blank sends no stored key and '
        'asks the host to forget it', (tester) async {
      await open(
        tester,
        keyStored: true,
        storedBearer: (_) => _stored,
      );
      await type(tester, ModelServersForm.urlKey(gen), _otherUrl);
      await connect(tester);

      expect(asked, [(_otherUrl, null)]);
      expect(connected.single.url, _otherUrl);
      expect(connected.single.key, isNull);
      expect(connected.single.clearKey, isTrue);
    });

    for (final (label, moved) in [
      ('https to http on the same host', 'http://box.example.com/prose/v1/chat/completions'),
      ('a port change on the same host', 'https://box.example.com:8443/prose/v1/chat/completions'),
    ]) {
      testWidgets('$label counts as another server', (tester) async {
        await open(tester, keyStored: true, storedBearer: (_) => _stored);
        await type(tester, ModelServersForm.urlKey(gen), moved);
        expect(find.text(ModelServersForm.otherHostHint), findsOneWidget);
        await connect(tester);

        expect(asked, [(moved, null)]);
        expect(connected.single.clearKey, isTrue);
      });
    }

    testWidgets('the default port spelled out is the same server',
        (tester) async {
      const spelled = 'https://box.example.com:443/prose/v1/chat/completions';
      await open(tester, keyStored: true, storedBearer: (_) => _stored);
      await type(tester, ModelServersForm.urlKey(gen), spelled);
      await connect(tester);

      expect(asked, [(spelled, _stored)]);
      expect(connected.single.clearKey, isFalse);
    });

    testWidgets('a new host with a typed key sends that key and forgets '
        'nothing', (tester) async {
      await open(tester, keyStored: true, storedBearer: (_) => _stored);
      await type(tester, ModelServersForm.urlKey(gen), _otherUrl);
      await type(tester, ModelServersForm.keyKey(gen), _key);
      await connect(tester);

      expect(asked, [(_otherUrl, _key)]);
      expect(connected.single.key, _key);
      expect(connected.single.clearKey, isFalse);
    });

    testWidgets('a server on this machine connects with no key at all',
        (tester) async {
      await open(tester, url: _localUrl);
      await connect(tester);

      expect(asked, [(_localUrl, null)]);
      expect(connected.single.url, _localUrl);
    });

    testWidgets('a refusal from the host is shown under the form',
        (tester) async {
      await open(
        tester,
        onConnect: ({required url, required model, key, required clearKey}) =>
            throw ArgumentError.value(url, 'url', 'not this one'),
      );
      await type(tester, ModelServersForm.keyKey(gen), _key);
      await connect(tester);

      expect(find.byKey(ModelServersForm.errorKey(gen)), findsOneWidget);
      expect(find.text('not this one'), findsOneWidget);
      // The key stays for another try, and is still never rendered.
      expect(fieldText(tester, ModelServersForm.keyKey(gen)), _key);
      expect(rendered(tester), isNot(contains(_key)));
    });

    testWidgets('a write that fails for a reason nobody typed still says so',
        (tester) async {
      await open(
        tester,
        onConnect: ({required url, required model, key, required clearKey}) =>
            throw StateError('keychain locked'),
      );
      await connect(tester);

      expect(find.text(ModelServersForm.saveFailedText), findsOneWidget);
      expect(find.textContaining('keychain'), findsNothing);
    });

    testWidgets('a press outlived by an edit writes nothing', (tester) async {
      final hold = Completer<ModelProbeResult>();
      await open(tester, probe: (url, {bearer}) => hold.future);

      await tester.tap(find.byKey(ModelServersForm.connectKey(gen)));
      await tester.pump();
      await tester.enterText(find.byKey(ModelServersForm.urlKey(gen)), _otherUrl);
      await tester.pump();
      hold.complete(
        const ModelProbeResult(reachable: true, modelIds: ['qwen3.8']),
      );
      await tester.pumpAndSettle();

      expect(connected, isEmpty);
    });

    testWidgets('a probe landing after the form is gone does nothing',
        (tester) async {
      final hold = Completer<ModelProbeResult>();
      await open(tester, probe: (url, {bearer}) => hold.future);

      await tester.tap(find.byKey(ModelServersForm.connectKey(gen)));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      hold.complete(
        const ModelProbeResult(reachable: true, modelIds: ['qwen3.8']),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(connected, isEmpty);
    });

    testWidgets('no probe, no Connect', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ModelServersForm(
            role: gen,
            onConnect: ({required url, required model, key, required clearKey})
                async {},
          ),
        ),
      ));
      final button = tester.widget<FilledButton>(
        find.byKey(ModelServersForm.connectKey(gen)),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('somebody else’s service', () {
    testWidgets('a vendor on the generative field is refused with the host\'s '
        'sentence, and nothing is sent to it', (tester) async {
      await open(
        tester,
        keyStored: true,
        storedBearer: (_) => _stored,
        thirdPartyRefusal: ModelServersForm.generativeThirdPartyRefusalText,
      );
      await type(tester, ModelServersForm.urlKey(gen), _openAiUrl);
      await connect(tester);

      expect(
        find.text(ModelServersForm.generativeThirdPartyRefusalText),
        findsOneWidget,
      );
      expect(asked, isEmpty);
      expect(connected, isEmpty);
    });

    testWidgets('a vendor on the decision field is refused with the decision '
        'sentence', (tester) async {
      await open(
        tester,
        role: dec,
        url: 'https://api.openai.com/v1/embeddings',
        thirdPartyRefusal: ModelServersForm.decisionThirdPartyRefusalText,
      );
      await connect(tester, dec);

      expect(
        find.text(ModelServersForm.decisionThirdPartyRefusalText),
        findsOneWidget,
      );
      expect(asked, isEmpty);
    });

    testWidgets('the wizard\'s sentence is the default', (tester) async {
      await open(tester, url: _openAiUrl, connectLabel: 'Continue');
      await connect(tester);

      expect(find.text(ModelServersForm.thirdPartyRefusalText), findsOneWidget);
      expect(connected, isEmpty);
    });

    testWidgets('cloud drafts asks the host first, and the resume writes',
        (tester) async {
      LlmTargetSpec? askedAbout;
      Future<void> Function()? resume;
      await open(
        tester,
        role: cloud,
        url: _openAiUrl,
        probe: fake(const {
          _openAiUrl: ModelProbeResult(reachable: true, modelIds: ['gpt-x']),
        }),
        onThirdParty: (spec, go) async {
          askedAbout = spec;
          resume = go;
        },
      );
      await type(tester, ModelServersForm.keyKey(cloud), _key);
      await connect(tester, cloud);

      expect(askedAbout!.id, cloudDraftsId);
      expect(askedAbout!.model, 'gpt-x');
      expect(askedAbout!.hasBearer, isTrue);
      expect(connected, isEmpty);

      await resume!();
      await tester.pumpAndSettle();
      expect(connected.single,
          (url: _openAiUrl, model: 'gpt-x', key: _key, clearKey: false));
    });

    testWidgets('a Converse service is typed into rather than asked',
        (tester) async {
      await open(
        tester,
        role: cloud,
        url: _bedrockUrl,
        onThirdParty: (spec, go) => go(),
      );
      await connect(tester, cloud);
      expect(find.text(ModelServersForm.modelNeededText), findsOneWidget);
      expect(asked, isEmpty);

      await type(
        tester,
        ModelServersForm.modelTextKey(cloud),
        'us.example.big-model',
      );
      await connect(tester, cloud);
      expect(asked, isEmpty);
      expect(connected.single.model, 'us.example.big-model');
    });
  });
}
