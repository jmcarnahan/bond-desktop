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
    routerEmbedId: 333590944,
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
    expect(find.text('318 MB'), findsOneWidget);
    expect(find.text('4.0 GB'), findsOneWidget);
    expect(find.text('17.7 GB'), findsOneWidget);
  });

  testWidgets('the footer totals what is about to be downloaded',
      (tester) async {
    await open(tester);

    expect(find.text('Total download: 22.0 GB'), findsOneWidget);
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

  testWidgets("the committed manifest's notice is shown verbatim",
      (tester) async {
    // Read off the real asset, not a fixture: the notice is what a licence
    // REQUIRES to be shown, and a test against invented text would prove
    // nothing about the thing that ships. `flutter test` runs from `app/`, so
    // the asset is a plain file here.
    final committed = ModelManifest.parse(
      File('assets/models/manifest.json').readAsStringSync(),
    );
    final notice = committed.byRole(ModelRole.embed).notice;
    expect(notice, isNotNull);

    await open(tester, which: committed, onOpenLicense: (_) {});

    expect(find.text(notice!), findsOneWidget);
    expect(
      notice,
      'Gemma is provided under and subject to the Gemma Terms of Use found '
      'at ai.google.dev/gemma/terms',
    );
  });

  testWidgets('Continue fires the host callback', (tester) async {
    var continues = 0;
    await open(tester, onContinue: () => continues++);

    await tester.tap(find.byKey(setupContinueKey));
    await tester.pump();

    expect(continues, 1);
  });
}
