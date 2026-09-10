import 'dart:convert';

import 'package:bond_inbox/models/context_models.dart';
import 'package:bond_inbox/providers/context_provider.dart' show ContextDirRow;
import 'package:bond_inbox/widgets/context_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The link panel on its own: what each row says, and that every switch and
/// button reaches the host with the right id and the right boolean.
///
/// Prop-only, so there is no `InboxScreen` and no sixty-second timer behind
/// it. `inbox_context_panel_test.dart` is the other half — the same body
/// wired to a real store through the screen.

const _now = '2026-09-09T12:00:00Z';

ContextDirRow _row({
  String id = 'd1',
  String displayName = 'acme',
  String? about,
  int filesCount = 12,
  String? walkedAt = '2026-09-09T11:57:00Z',
}) =>
    (
      dir: ContextDir(
        id: id,
        path: '/Users/pat/projects/$displayName',
        displayName: displayName,
        status: 'ready',
        walkedAt: walkedAt,
        filesCount: filesCount,
        textBytes: 4096,
        digests: true,
        honorGitignore: false,
        createdAt: _now,
        updatedAt: _now,
      ),
      links: 0,
      chunks: 30,
      embedded: 30,
      about: about,
      digestsDone: 0,
      digestsEligible: 0,
    );

void main() {
  late List<({String id, bool on})> toggles;
  late int added;
  late int managed;
  late List<String> filesToggled;
  late List<int> filesOpened;

  setUp(() {
    toggles = [];
    added = 0;
    managed = 0;
    filesToggled = [];
    filesOpened = [];
  });

  ContextFile file(int id, String relPath, {String? purpose}) => ContextFile(
        id: id,
        dirId: 'd1',
        relPath: relPath,
        size: 400,
        mtime: _now,
        sha256: 'sha-$id',
        kind: 'doc',
        claudeChain: const [],
        digestJson: purpose == null
            ? null
            : jsonEncode(ContextFileDigest(purpose: purpose).toJson()),
        digestStatus: purpose == null ? 'pending' : 'done',
        hasDescEmbedding: false,
        textChars: 400,
        status: 'ok',
        seenAt: _now,
        updatedAt: _now,
      );

  Future<void> pumpPanel(
    WidgetTester tester, {
    List<ContextDirRow> rows = const [],
    Set<String> linked = const {},
    List<({String storyline, String dirId, String dirName})> inherited =
        const [],
    Set<String> expanded = const {},
    Map<String, List<ContextFile>> files = const {},
    bool withFiles = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(500, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ContextPanelBody(
          rows: rows,
          linked: linked,
          inherited: inherited,
          onToggle: (id, on) => toggles.add((id: id, on: on)),
          onAddDirectory: () => added++,
          onManage: () => managed++,
          expanded: expanded,
          files: files,
          onToggleFiles: withFiles ? filesToggled.add : null,
          onOpenFile: withFiles ? filesOpened.add : null,
          now: DateTime.parse(_now),
        ),
      ),
    ));
    await tester.pump();
  }

  group('the library', () {
    test('the switch key names its directory', () {
      expect(
        ContextPanelBody.toggleKeyFor('d1'),
        const Key('context-toggle-d1'),
      );
    });

    testWidgets('every registered directory gets a row and a switch',
        (tester) async {
      await pumpPanel(
        tester,
        rows: [
          _row(about: 'A renewal pricing model.'),
          _row(id: 'd2', displayName: 'ridge'),
        ],
        linked: {'d1'},
      );

      expect(find.text(ContextPanelBody.caption), findsOneWidget);
      expect(find.text('acme'), findsOneWidget);
      expect(find.text('A renewal pricing model.'), findsOneWidget);
      expect(find.text('12 files · read 3m ago'), findsNWidgets(2));
      // The whole library, not only what is linked: the question a person
      // opens this to answer cannot be answered by a list of the answers.
      expect(find.text('ridge'), findsOneWidget);

      final acme = tester.widget<Switch>(
        find.byKey(ContextPanelBody.toggleKeyFor('d1')),
      );
      final ridge = tester.widget<Switch>(
        find.byKey(ContextPanelBody.toggleKeyFor('d2')),
      );
      expect(acme.value, isTrue);
      expect(ridge.value, isFalse);
    });

    testWidgets('a directory nobody has read yet says so without a stamp',
        (tester) async {
      await pumpPanel(tester, rows: [_row(walkedAt: null, filesCount: 1)]);

      expect(find.text('1 file'), findsOneWidget);
    });

    testWidgets('turning one on and another off reaches the host', (tester) async {
      await pumpPanel(
        tester,
        rows: [_row(), _row(id: 'd2', displayName: 'ridge')],
        linked: {'d1'},
      );

      await tester.tap(find.byKey(ContextPanelBody.toggleKeyFor('d2')));
      await tester.tap(find.byKey(ContextPanelBody.toggleKeyFor('d1')));
      await tester.pump();

      expect(toggles, [(id: 'd2', on: true), (id: 'd1', on: false)]);
    });
  });

  group('what a thread inherits', () {
    testWidgets('is listed in muted type, under its own heading', (tester) async {
      await pumpPanel(
        tester,
        rows: [_row()],
        inherited: const [
          (storyline: 'Marrowfield renewal', dirId: 'd9', dirName: 'ridge'),
        ],
      );

      expect(find.text('Also from storylines'), findsOneWidget);
      // The heading carries the "also from"; the line under it names the
      // storyline and the directory and nothing else.
      expect(
        find.text('«Marrowfield renewal»: ridge'),
        findsOneWidget,
      );
      // No switch of its own: it is not this thread's link to turn off, and a
      // switch here would unlink somebody else's storyline.
      expect(find.byType(Switch), findsOneWidget);
    });

    testWidgets('a storyline\'s own panel says nothing about inheritance',
        (tester) async {
      await pumpPanel(tester, rows: [_row()]);

      expect(find.text('Also from storylines'), findsNothing);
    });
  });

  group('an empty library', () {
    testWidgets('says what one directory would buy, and offers Add',
        (tester) async {
      await pumpPanel(tester);

      expect(find.text(ContextPanelBody.emptyLine), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      expect(find.byKey(ContextPanelBody.addKey), findsOneWidget);
    });
  });

  group('the footer', () {
    testWidgets('Add and Manage each reach the host once', (tester) async {
      await pumpPanel(tester, rows: [_row()]);

      await tester.tap(find.byKey(ContextPanelBody.addKey));
      await tester.pump();
      await tester.tap(find.byKey(ContextPanelBody.manageKey));
      await tester.pump();

      expect(added, 1);
      expect(managed, 1);
      expect(find.text('Manage directories in Settings ›'), findsOneWidget);
    });
  });

  group('Files ›', () {
    test('the keys name what they open', () {
      expect(
        ContextPanelBody.filesKeyFor('d1'),
        const Key('context-files-d1'),
      );
      expect(ContextPanelBody.fileKeyFor(7), const Key('context-file-7'));
    });

    testWidgets('a host that cannot fetch the files draws no button',
        (tester) async {
      await pumpPanel(tester, rows: [_row()]);

      expect(find.byKey(ContextPanelBody.filesKeyFor('d1')), findsNothing);
    });

    testWidgets('the button asks the host to open it', (tester) async {
      await pumpPanel(tester, rows: [_row()], withFiles: true);

      expect(find.text('Files ›'), findsOneWidget);
      await tester.tap(find.byKey(ContextPanelBody.filesKeyFor('d1')));
      await tester.pump();

      expect(filesToggled, ['d1']);
    });

    testWidgets('an open disclosure lists the files and what they are for',
        (tester) async {
      await pumpPanel(
        tester,
        rows: [_row()],
        withFiles: true,
        expanded: const {'d1'},
        files: {
          'd1': [
            file(7, 'docs/pricing.md', purpose: 'The renewal pricing model.'),
            file(8, 'notes.md'),
          ],
        },
      );

      expect(find.text('Files ⌄'), findsOneWidget);
      expect(find.text('docs/pricing.md'), findsOneWidget);
      expect(find.text('doc · The renewal pricing model.'), findsOneWidget);
      // No digest yet: the kind alone, rather than a trailing separator.
      expect(find.text('doc'), findsOneWidget);

      await tester.tap(find.byKey(ContextPanelBody.fileKeyFor(7)));
      await tester.pump();

      expect(filesOpened, [7]);
    });

    testWidgets('past the cap it stops listing and says where to look',
        (tester) async {
      await pumpPanel(
        tester,
        rows: [_row()],
        withFiles: true,
        expanded: const {'d1'},
        files: {
          'd1': [
            for (var i = 0; i < ContextPanelBody.maxFilesShown + 1; i++)
              file(i + 1, 'docs/f$i.md'),
          ],
        },
      );

      // A panel is not a file browser. Search is.
      expect(find.text('+1 more — search finds them'), findsOneWidget);
      expect(
        find.byKey(ContextPanelBody.fileKeyFor(
          ContextPanelBody.maxFilesShown + 1,
        )),
        findsNothing,
      );
    });
  });
}
