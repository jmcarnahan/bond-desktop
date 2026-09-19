import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/screens/setup/setup_controls.dart';
import 'package:bond_inbox/screens/setup/setup_models_body.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_manifest.dart';

/// The licence-and-sizes step, driven by props alone.
///
/// It renders the MANIFEST rather than a list of its own, so the sizes here
/// are the real committed ones: what is pinned is that the numbers a person
/// reads before agreeing to a twenty-three gigabyte download are the numbers
/// in `assets/models/manifest.json`, formatted the way the rest of the app
/// formats bytes.
void main() {
  /// The real sizes, so the rows below say what a real first run says.
  final manifest = testManifest(sizes: {
    routerEmbedId: 639150592,
    routerBulkId: 4280403520,
    routerProseId: 18973870432,
  });

  Future<void> open(
    WidgetTester tester, {
    ModelManifest? which,
    void Function(ModelFile)? onOpenLicense,
    VoidCallback? onContinue,
  }) async {
    await tester.binding.setSurfaceSize(const Size(760, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SetupModelsBody(
            manifest: which ?? manifest,
            onOpenLicense: onOpenLicense,
            onContinue: onContinue ?? () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('each model reads its name, its job and its size',
      (tester) async {
    await open(tester, onOpenLicense: (_) {});

    expect(find.text('Finds related messages'), findsOneWidget);
    expect(find.text('Reads and sorts your mail'), findsOneWidget);
    expect(find.text('Writes drafts and replies'), findsOneWidget);
    expect(find.text('610 MB'), findsOneWidget);
    expect(find.text('4.0 GB'), findsOneWidget);
    expect(find.text('17.7 GB'), findsOneWidget);
  });

  testWidgets('the footer totals what is about to be downloaded',
      (tester) async {
    await open(tester);

    expect(find.text('Total download: 22.3 GB'), findsOneWidget);
  });

  testWidgets('the licence opens through the host, and hides when unwired',
      (tester) async {
    final opened = <String>[];
    await open(tester, onOpenLicense: (file) => opened.add(file.id));

    await tester.tap(find.byKey(SetupModelsBody.licenseKey(routerProseId)));
    await tester.pump();
    expect(opened, [routerProseId]);

    // A host that cannot open a URL never offers one — the discipline every
    // optional control in this app keeps.
    await open(tester, onOpenLicense: null);
    expect(find.byKey(SetupModelsBody.licenseKey(routerProseId)), findsNothing);
    expect(find.byKey(SetupModelsBody.licenseKey(routerEmbedId)), findsNothing);
  });

  /// The real asset, not a fixture. `flutter test` runs from `app/`, so it is
  /// a plain file here.
  String committedJson() => File('assets/models/manifest.json').readAsStringSync();

  testWidgets('the committed manifest needs no notice, and shows none',
      (tester) async {
    // All three checkpoints have been Apache-2.0 since the embedding model
    // left EmbeddingGemma on 2026-09-19, and the Gemma Terms of Use went with
    // it. Null and not an empty string is what lets this screen skip the line
    // rather than render a blank one, so the absence is worth asserting.
    final committed = ModelManifest.parse(committedJson());
    for (final model in committed.models) {
      expect(model.notice, isNull, reason: model.id);
    }

    await open(tester, which: committed, onOpenLicense: (_) {});

    expect(find.byType(SetupModelsBody), findsOneWidget);
  });

  testWidgets('a notice is shown verbatim when a checkpoint carries one',
      (tester) async {
    // The property the screen exists to hold, kept alive against the day a
    // non-permissive model comes back: a notice is what a licence REQUIRES to
    // be shown, and paraphrasing or abbreviating it would be this app
    // deciding what a licence meant. Injected into the real manifest rather
    // than invented whole, so the rest of the screen is the shipping one.
    const notice = 'Shown exactly as the licence demands, every word of it.';
    final decoded = jsonDecode(committedJson()) as Map<String, Object?>;
    (((decoded['models'] as List).first) as Map<String, Object?>)['notice'] =
        notice;

    await open(
      tester,
      which: ModelManifest.parse(jsonEncode(decoded)),
      onOpenLicense: (_) {},
    );

    expect(find.text(notice), findsOneWidget);
  });

  testWidgets('Continue fires the host callback', (tester) async {
    var continues = 0;
    await open(tester, onContinue: () => continues++);

    await tester.tap(find.byKey(setupContinueKey));
    await tester.pump();

    expect(continues, 1);
  });
}
