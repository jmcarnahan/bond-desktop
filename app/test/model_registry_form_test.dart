import 'dart:async';

import 'package:bond_inbox/services/llm/model_slots.dart' show accessKeyCharsText;
import 'package:bond_inbox/services/models/registry_probe.dart';
import 'package:bond_inbox/widgets/model_registry_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const String _fakeToken = 'test-token-123';
const String _registry =
    'https://artifactory.example.com/artifactory/bond-models';

/// One Save, as the host received it.
typedef Saved = ({String url, String? token, bool clearToken});

/// The Model registry block: an address, a token, Save, Remove token, Check.
///
/// Prop-only, so it is pumped alone and `pumpAndSettle` is safe. The token
/// is a SECRET: asserted obscured, emptied after a Save, and on no rendered
/// `Text`; never asserted absent from the tree, because `find.text` reads an
/// `EditableText`'s controller rather than the bullets it draws.
void main() {
  late List<Saved> saves;
  late int removes;

  setUp(() {
    saves = [];
    removes = 0;
  });

  Future<void> open(
    WidgetTester tester, {
    String url = _registry,
    bool tokenStored = false,
    bool tokenFromBuild = false,
    String? refusal,
    Future<RegistryCheck> Function()? onCheck,
    bool wireRemove = true,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ModelRegistryForm(
            url: url,
            tokenStored: tokenStored,
            tokenFromBuild: tokenFromBuild,
            onSave: ({required url, token, required clearToken}) async {
              saves.add((url: url, token: token, clearToken: clearToken));
              return refusal;
            },
            onRemoveToken: wireRemove ? () async => removes++ : null,
            onCheck: onCheck,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, Key key, String text) async {
    await tester.enterText(find.byKey(key), text);
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, Key key) async {
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }

  TextField field(WidgetTester tester, Key key) =>
      tester.widget<TextField>(find.byKey(key));

  List<String> rendered(WidgetTester tester) => [
        for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? '',
      ];

  testWidgets('opens on the address, with the token empty and obscured',
      (tester) async {
    await open(tester, tokenStored: true);

    expect(find.text(ModelRegistryForm.title), findsOneWidget);
    expect(
      find.text('Where Bond downloads the decision and embedding models from.'),
      findsOneWidget,
    );
    expect(field(tester, ModelRegistryForm.urlKey).controller!.text, _registry);
    final token = field(tester, ModelRegistryForm.tokenKey);
    expect(token.obscureText, isTrue);
    expect(token.controller!.text, isEmpty);
  });

  testWidgets('the three hints: stored, from the build, and a new address',
      (tester) async {
    await open(tester, tokenStored: true);
    expect(find.text('Stored. Type to replace'), findsOneWidget);

    await open(tester, url: '', tokenFromBuild: false);
    expect(find.text('Stored. Type to replace'), findsNothing);
    expect(find.text(ModelRegistryForm.buildTokenHint), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await open(tester, tokenFromBuild: true);
    expect(find.text('Using the token from this build. Type to replace'),
        findsOneWidget);

    await type(tester, ModelRegistryForm.urlKey,
        'https://registry.example.com/artifactory/bond-models');
    expect(find.text('A new address needs its own token'), findsOneWidget);
    expect(find.text(ModelRegistryForm.buildTokenHint), findsNothing);
  });

  testWidgets('a Save writes the typed token, then empties the field and '
      'never renders it', (tester) async {
    await open(tester);

    await type(tester, ModelRegistryForm.tokenKey, _fakeToken);
    await press(tester, ModelRegistryForm.saveKey);

    expect(saves, hasLength(1));
    expect(saves.single.url, _registry);
    expect(saves.single.token, _fakeToken);
    expect(saves.single.clearToken, isFalse);
    expect(field(tester, ModelRegistryForm.tokenKey).controller!.text, isEmpty);
    expect(find.text(ModelRegistryForm.savedText), findsOneWidget);
    expect(rendered(tester), everyElement(isNot(contains(_fakeToken))));
  });

  testWidgets('a blank token keeps the stored one', (tester) async {
    await open(tester, tokenStored: true);

    await press(tester, ModelRegistryForm.saveKey);

    expect(saves.single.token, isNull);
    expect(saves.single.clearToken, isFalse);
  });

  testWidgets('another origin with no token typed asks to forget the stored '
      'one; with a token typed it does not', (tester) async {
    await open(tester, tokenStored: true);
    const other = 'https://registry.example.com/artifactory/bond-models';

    await type(tester, ModelRegistryForm.urlKey, other);
    await press(tester, ModelRegistryForm.saveKey);
    expect(saves.last, (url: other, token: null, clearToken: true));

    await tester.pumpWidget(const SizedBox());
    await open(tester, tokenStored: true);
    await type(tester, ModelRegistryForm.urlKey, other);
    await type(tester, ModelRegistryForm.tokenKey, _fakeToken);
    await press(tester, ModelRegistryForm.saveKey);
    expect(saves.last.clearToken, isFalse);
    expect(saves.last.token, _fakeToken);
  });

  testWidgets('Remove token shows only when one is stored, and only with its '
      'wiring', (tester) async {
    await open(tester);
    expect(find.byKey(ModelRegistryForm.removeTokenKey), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await open(tester, tokenFromBuild: true);
    expect(find.byKey(ModelRegistryForm.removeTokenKey), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await open(tester, tokenStored: true, wireRemove: false);
    expect(find.byKey(ModelRegistryForm.removeTokenKey), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await open(tester, tokenStored: true);
    await press(tester, ModelRegistryForm.removeTokenKey);
    expect(removes, 1);
  });

  testWidgets('an address that is not one is refused under the field, and '
      'nothing is written', (tester) async {
    await open(tester);

    await type(tester, ModelRegistryForm.urlKey, 'artifactory.example.com');
    await press(tester, ModelRegistryForm.saveKey);

    expect(saves, isEmpty);
    expect(find.byKey(ModelRegistryForm.refusalKey), findsOneWidget);
    expect(
        find.text('The address needs to start with http:// or https:// and '
            'name a server.'),
        findsOneWidget);
  });

  testWidgets("the host's refusal lands under the field and keeps the token",
      (tester) async {
    await open(tester, refusal: 'The registry address was refused.');

    await type(tester, ModelRegistryForm.tokenKey, _fakeToken);
    await press(tester, ModelRegistryForm.saveKey);

    expect(find.text('The registry address was refused.'), findsOneWidget);
    expect(field(tester, ModelRegistryForm.tokenKey).controller!.text,
        _fakeToken);
    expect(rendered(tester), everyElement(isNot(contains(_fakeToken))));
  });

  testWidgets('a token no header can carry is refused, without quoting it',
      (tester) async {
    await open(tester);

    await type(tester, ModelRegistryForm.tokenKey, 'bad token\nline');
    await press(tester, ModelRegistryForm.saveKey);

    expect(saves, isEmpty);
    expect(find.text(accessKeyCharsText), findsOneWidget);
  });

  testWidgets('an http address on another machine hints at https; loopback '
      'does not', (tester) async {
    await open(tester, url: 'http://registry.example.com/artifactory/x');
    expect(find.text('Use the https address when your registry has one.'),
        findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await open(tester, url: 'http://localhost:18082/artifactory/bond-models');
    expect(find.text(ModelRegistryForm.httpsHint), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await open(tester);
    expect(find.text(ModelRegistryForm.httpsHint), findsNothing);
  });

  testWidgets('Check says what the registry answered', (tester) async {
    for (final entry in {
      RegistryCheck.reachable: 'Registry reachable.',
      RegistryCheck.unauthorized:
          'The model registry refused the access token.',
      RegistryCheck.notFound:
          'The model registry does not have this model. Check its address.',
      RegistryCheck.unreachable: 'Registry unreachable.',
      RegistryCheck.notAModel: 'The model registry answered with a web page, '
          'not a model. Check its address.',
      RegistryCheck.redirected:
          'The registry answered with a redirect. A download will follow it.',
    }.entries) {
      await tester.pumpWidget(const SizedBox());
      await open(tester, onCheck: () async => entry.key);
      await press(tester, ModelRegistryForm.checkKey);
      expect(
        tester.widget<Text>(find.byKey(ModelRegistryForm.statusKey)).data,
        entry.value,
      );
    }
  });

  testWidgets('Check is off while the typed address is not the saved one, '
      'and says why', (tester) async {
    var checks = 0;
    await open(tester, onCheck: () async {
      checks++;
      return RegistryCheck.reachable;
    });
    expect(find.text(ModelRegistryForm.saveFirstText), findsNothing);

    await type(tester, ModelRegistryForm.urlKey,
        'https://registry.example.com/artifactory/bond-models');
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(ModelRegistryForm.checkKey))
          .onPressed,
      isNull,
    );
    expect(find.text('Save the address first to check it.'), findsOneWidget);
    await tester.tap(find.byKey(ModelRegistryForm.checkKey));
    await tester.pumpAndSettle();
    expect(checks, 0);

    // The saved address again, with a trailing slash: the same address.
    await type(tester, ModelRegistryForm.urlKey, '$_registry/');
    expect(find.text(ModelRegistryForm.saveFirstText), findsNothing);
    await press(tester, ModelRegistryForm.checkKey);
    expect(checks, 1);
  });

  testWidgets('a BLANK address saved follows the build, and Check is on for '
      'the build\'s address', (tester) async {
    const typed = 'https://registry.example.com/artifactory/bond-models';
    var checks = 0;
    var hostUrl = typed;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SingleChildScrollView(
            child: ModelRegistryForm(
              url: hostUrl,
              onSave: ({required url, token, required clearToken}) async {
                saves.add((url: url, token: token, clearToken: clearToken));
                // Blank means follow the build: the host re-resolves to it.
                setState(() => hostUrl = url.isEmpty ? _registry : url);
                return null;
              },
              onCheck: () async {
                checks++;
                return RegistryCheck.reachable;
              },
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await type(tester, ModelRegistryForm.urlKey, '');
    expect(find.text(ModelRegistryForm.saveFirstText), findsOneWidget,
        reason: 'blank is not saved yet; Check would ask the typed host');

    await press(tester, ModelRegistryForm.saveKey);
    expect(saves.single.url, '');
    expect(field(tester, ModelRegistryForm.urlKey).controller!.text, isEmpty);
    expect(find.text(ModelRegistryForm.saveFirstText), findsNothing);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(ModelRegistryForm.checkKey))
          .onPressed,
      isNotNull,
    );
    await press(tester, ModelRegistryForm.checkKey);
    expect(checks, 1);
  });

  testWidgets('both fields are held while a Save is out, and the token is '
      'emptied when it lands', (tester) async {
    final landed = Completer<String?>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ModelRegistryForm(
          url: _registry,
          onSave: ({required url, token, required clearToken}) =>
              landed.future,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await type(tester, ModelRegistryForm.tokenKey, _fakeToken);
    await tester.tap(find.byKey(ModelRegistryForm.saveKey));
    await tester.pump();

    expect(field(tester, ModelRegistryForm.urlKey).enabled, isFalse);
    expect(field(tester, ModelRegistryForm.tokenKey).enabled, isFalse);

    landed.complete(null);
    await tester.pumpAndSettle();
    expect(field(tester, ModelRegistryForm.urlKey).enabled, isTrue);
    expect(field(tester, ModelRegistryForm.tokenKey).controller!.text, isEmpty);
  });

  testWidgets('no Check without its wiring', (tester) async {
    await open(tester);
    expect(find.byKey(ModelRegistryForm.checkKey), findsNothing);
  });

  test('no user-facing sentence carries an em-dash or a parenthesis', () {
    for (final text in [
      ModelRegistryForm.title,
      ModelRegistryForm.caption,
      ModelRegistryForm.urlLabel,
      ModelRegistryForm.tokenLabel,
      ModelRegistryForm.storedHint,
      ModelRegistryForm.buildTokenHint,
      ModelRegistryForm.otherOriginHint,
      ModelRegistryForm.httpsHint,
      ModelRegistryForm.addressRefusalText,
      ModelRegistryForm.savedText,
      ModelRegistryForm.saveFirstText,
      for (final check in RegistryCheck.values)
        ModelRegistryForm.checkText(check),
    ]) {
      expect(text, isNot(contains('—')), reason: text);
      expect(text, isNot(contains('(')), reason: text);
    }
  });
}
