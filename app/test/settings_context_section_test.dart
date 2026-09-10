import 'dart:async';

import 'package:bond_inbox/models/context_models.dart';
import 'package:bond_inbox/providers/context_provider.dart' show ContextDirRow;
import 'package:bond_inbox/widgets/settings_context_section.dart';
import 'package:bond_inbox/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Context directories section on its own: the collapsed summary, what
/// each row says about where its directory stands, and that every control
/// reaches the host with the right id and the right boolean.
///
/// Prop-only, so there is no `InboxScreen` and no sixty-second timer — which
/// is what makes bounded pumps enough here. `settings_context_host_test.dart`
/// is the other half: the same section wired to a real store through the
/// screen.

const _now = '2026-09-09T12:00:00Z';

ContextDir _dir({
  String id = 'd1',
  String path = '/Users/pat/projects/acme',
  String displayName = 'acme',
  String status = 'ready',
  String? error,
  String? walkedAt = '2026-09-09T11:57:00Z',
  int filesCount = 12,
  bool digests = true,
  bool honorGitignore = false,
  String? briefJson,
}) =>
    ContextDir(
      id: id,
      path: path,
      displayName: displayName,
      status: status,
      error: error,
      walkedAt: walkedAt,
      filesCount: filesCount,
      textBytes: 4096,
      briefJson: briefJson,
      digests: digests,
      honorGitignore: honorGitignore,
      createdAt: _now,
      updatedAt: _now,
    );

ContextDirRow _row(
  ContextDir dir, {
  int links = 0,
  int chunks = 30,
  int embedded = 30,
  String? about,
  int digestsDone = 0,
  int digestsEligible = 0,
}) =>
    (
      dir: dir,
      links: links,
      chunks: chunks,
      embedded: embedded,
      about: about,
      digestsDone: digestsDone,
      digestsEligible: digestsEligible,
    );

void main() {
  late List<String> rereads;
  late List<String> removes;
  late List<(String, bool)> digests;
  late List<(String, bool)> ignored;
  late List<bool> selectExpands;

  setUp(() {
    rereads = [];
    removes = [];
    digests = [];
    ignored = [];
    selectExpands = [];
  });

  Future<void> pumpSection(
    WidgetTester tester, {
    required List<ContextDirRow> rows,
    bool expanded = true,
    bool loading = false,
    String? error,
    Future<void> Function()? onAdd,
    bool selectExpand = true,
    bool wireSelectExpand = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ContextDirectoriesSection(
            rows: rows,
            expanded: expanded,
            loading: loading,
            error: error,
            onToggle: () {},
            onAdd: onAdd,
            onReread: rereads.add,
            onRemove: removes.add,
            onDigestsChanged: (id, on) => digests.add((id, on)),
            onHonorGitignoreChanged: (id, on) => ignored.add((id, on)),
            selectExpand: selectExpand,
            onSelectExpandChanged:
                wireSelectExpand ? selectExpands.add : null,
            now: () => DateTime.parse(_now),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  group('the section pick switch', () {
    testWidgets('shows what is stored rather than what was tapped',
        (tester) async {
      // Prop-driven with no local state: the host watches the preference and
      // rebuilds, so a switch that remembered its own tap could disagree with
      // the database it is meant to be showing.
      await pumpSection(tester, rows: [_row(_dir())], selectExpand: false);

      final control = tester.widget<SwitchListTile>(
        find.byKey(ContextDirectoriesSection.selectExpandKey),
      );
      expect(control.value, isFalse);
      expect(
        find.text('Let the model pick two sections to read in full before '
            'drafting'),
        findsOneWidget,
      );
      expect(
        find.text('One extra fast call per suggestion that reads a '
            'directory. Off, a reply sees only the nearest passages.'),
        findsOneWidget,
      );
    });

    testWidgets('a tap reaches the host with the new value', (tester) async {
      await pumpSection(tester, rows: [_row(_dir())], selectExpand: true);

      final control = find.byKey(ContextDirectoriesSection.selectExpandKey);
      await tester.ensureVisible(control);
      await tester.pump();
      await tester.tap(control);
      await tester.pump();

      expect(selectExpands, [false]);
    });

    testWidgets('a host that cannot write it is offered no switch',
        (tester) async {
      await pumpSection(
        tester,
        rows: [_row(_dir())],
        wireSelectExpand: false,
      );

      expect(
        find.byKey(ContextDirectoriesSection.selectExpandKey),
        findsNothing,
      );
      // And the rows are still there — the switch is not the section.
      expect(find.text('acme'), findsOneWidget);
    });
  });

  group('the collapsed summary', () {
    testWidgets('says there are none yet', (tester) async {
      await pumpSection(tester, rows: const [], expanded: false);
      expect(find.text('No directories yet'), findsOneWidget);
    });

    testWidgets('counts one directory in the singular', (tester) async {
      await pumpSection(
        tester,
        rows: [_row(_dir(filesCount: 12))],
        expanded: false,
      );
      expect(find.text('1 directory · 12 files'), findsOneWidget);
    });

    testWidgets('sums the files across directories', (tester) async {
      await pumpSection(
        tester,
        rows: [
          _row(_dir(filesCount: 12)),
          _row(_dir(id: 'd2', displayName: 'notes', filesCount: 3)),
        ],
        expanded: false,
      );
      expect(find.text('2 directories · 15 files'), findsOneWidget);
    });
  });

  group('the status line', () {
    testWidgets('a directory nobody has read yet says so', (tester) async {
      await pumpSection(
        tester,
        rows: [
          _row(
            _dir(status: 'pending', walkedAt: null, filesCount: 0),
            chunks: 0,
            embedded: 0,
          ),
        ],
      );
      expect(find.text('not read yet'), findsOneWidget);
    });

    testWidgets('a walk in flight says it is reading', (tester) async {
      await pumpSection(
        tester,
        rows: [
          _row(
            _dir(status: 'reading', walkedAt: null, filesCount: 0),
            chunks: 0,
            embedded: 0,
          ),
        ],
      );
      expect(find.text('reading…'), findsOneWidget);
    });

    testWidgets('a read directory counts files, passages and the age',
        (tester) async {
      await pumpSection(tester, rows: [_row(_dir())]);
      expect(find.text('12 files · 30 passages · read 3m ago'), findsOneWidget);
    });

    testWidgets('an embedding tail is named', (tester) async {
      await pumpSection(
        tester,
        rows: [_row(_dir(), chunks: 30, embedded: 8)],
      );
      expect(
        find.text('12 files · 30 passages · read 3m ago · embedding 8 of 30'),
        findsOneWidget,
      );
    });

    testWidgets('a summary tail is named while it is still behind',
        (tester) async {
      await pumpSection(
        tester,
        rows: [_row(_dir(), digestsDone: 3, digestsEligible: 12)],
      );
      expect(
        find.text('12 files · 30 passages · read 3m ago · summaries 3 of 12'),
        findsOneWidget,
      );
    });

    testWidgets('a directory level with its summaries says nothing about them',
        (tester) async {
      await pumpSection(
        tester,
        rows: [_row(_dir(), digestsDone: 12, digestsEligible: 12)],
      );
      expect(find.textContaining('summaries'), findsNothing);
    });

    testWidgets('summaries switched off hide the progress entirely',
        (tester) async {
      // A count towards a total nothing is working on would never move.
      await pumpSection(
        tester,
        rows: [
          _row(_dir(digests: false), digestsDone: 0, digestsEligible: 12),
        ],
      );
      expect(find.textContaining('summaries'), findsNothing);
    });

    testWidgets('an unavailable folder shows its own sentence', (tester) async {
      await pumpSection(
        tester,
        rows: [
          _row(
            _dir(
              status: 'unavailable',
              error: 'The folder could not be opened. Add it again.',
            ),
          ),
        ],
      );
      expect(
        find.text('The folder could not be opened. Add it again.'),
        findsOneWidget,
      );
      // The counts are gone from the row: they describe a walk from before
      // the folder went away. (The collapsed summary still totals the files,
      // which is a different question — how much is registered.)
      expect(find.textContaining('30 passages'), findsNothing);
    });

    testWidgets('a read that failed shows the sentence the handler stored',
        (tester) async {
      await pumpSection(
        tester,
        rows: [
          _row(
            _dir(
              status: 'error',
              error: 'Reading this folder failed: the passage write failed.',
            ),
          ),
        ],
      );

      // The handler writes this row when a reconcile throws part-way. Without
      // it the folder would sit at `reading…` for good, so the sentence has
      // to actually reach the section.
      expect(
        find.text('Reading this folder failed: the passage write failed.'),
        findsOneWidget,
      );
      expect(find.textContaining('30 passages'), findsNothing);
    });

    testWidgets('an unlinked directory says so, a linked one counts',
        (tester) async {
      await pumpSection(
        tester,
        rows: [
          _row(_dir()),
          _row(_dir(id: 'd2', displayName: 'notes'), links: 3),
        ],
      );
      expect(find.text('Not linked to any thread yet'), findsOneWidget);
      expect(find.text('Links: 3'), findsOneWidget);
    });
  });

  group('the brief', () {
    testWidgets('its opening sentence sits under the path', (tester) async {
      await pumpSection(
        tester,
        rows: [_row(_dir(), about: 'Atlas is the renewal analysis.')],
      );

      expect(
        find.byKey(ContextDirectoriesSection.aboutKeyFor('d1')),
        findsOneWidget,
      );
      expect(find.text('Atlas is the renewal analysis.'), findsOneWidget);
    });

    testWidgets('a directory with no brief yet shows no line at all',
        (tester) async {
      await pumpSection(tester, rows: [_row(_dir())]);

      expect(
        find.byKey(ContextDirectoriesSection.aboutKeyFor('d1')),
        findsNothing,
      );
    });

    testWidgets('an empty about is the same as none', (tester) async {
      await pumpSection(tester, rows: [_row(_dir(), about: '')]);

      expect(
        find.byKey(ContextDirectoriesSection.aboutKeyFor('d1')),
        findsNothing,
      );
    });
  });

  testWidgets('Re-read now calls back with the directory id', (tester) async {
    await pumpSection(
      tester,
      rows: [_row(_dir()), _row(_dir(id: 'd2', displayName: 'notes'))],
    );

    await tester.tap(find.byKey(ContextDirectoriesSection.rereadKeyFor('d2')));
    await tester.pump();

    expect(rereads, ['d2']);
  });

  group('Remove takes two taps', () {
    testWidgets('the first arms a different button in a different place',
        (tester) async {
      await pumpSection(tester, rows: [_row(_dir(), links: 2)]);

      await tester.tap(find.byKey(ContextDirectoriesSection.removeKeyFor('d1')));
      await tester.pump();

      expect(removes, isEmpty);
      expect(
        find.byKey(ContextDirectoriesSection.confirmRemoveKeyFor('d1')),
        findsOneWidget,
      );
      expect(
        find.text('Removes its index and 2 links; the folder itself is '
            'untouched.'),
        findsOneWidget,
      );
    });

    testWidgets('Keep puts it back and removes nothing', (tester) async {
      await pumpSection(tester, rows: [_row(_dir())]);

      await tester.tap(find.byKey(ContextDirectoriesSection.removeKeyFor('d1')));
      await tester.pump();
      await tester.tap(find.byKey(ContextDirectoriesSection.keepKeyFor('d1')));
      await tester.pump();

      expect(removes, isEmpty);
      expect(
        find.byKey(ContextDirectoriesSection.removeKeyFor('d1')),
        findsOneWidget,
      );
      expect(
        find.byKey(ContextDirectoriesSection.confirmRemoveKeyFor('d1')),
        findsNothing,
      );
    });

    testWidgets('the second calls back', (tester) async {
      await pumpSection(tester, rows: [_row(_dir())]);

      await tester.tap(find.byKey(ContextDirectoriesSection.removeKeyFor('d1')));
      await tester.pump();
      await tester
          .tap(find.byKey(ContextDirectoriesSection.confirmRemoveKeyFor('d1')));
      await tester.pump();

      expect(removes, ['d1']);
    });

    testWidgets('a row that goes and comes back is not still armed',
        (tester) async {
      // The safety net in `didUpdateWidget`. A re-read that drops the armed
      // row — or a Remove that lands — must not leave the section holding a
      // confirmation for an id nothing renders, because the next Remove on
      // that id would then arrive already confirmed and delete on one tap.
      await pumpSection(tester, rows: [_row(_dir())]);
      await tester.tap(find.byKey(ContextDirectoriesSection.removeKeyFor('d1')));
      await tester.pump();
      expect(
        find.byKey(ContextDirectoriesSection.confirmRemoveKeyFor('d1')),
        findsOneWidget,
      );

      // Gone: the library came back without it.
      await pumpSection(
        tester,
        rows: [_row(_dir(id: 'd2', displayName: 'notes'))],
      );
      // And back: the same directory registered again, or a read that had
      // simply missed it.
      await pumpSection(tester, rows: [_row(_dir())]);

      expect(
        find.byKey(ContextDirectoriesSection.removeKeyFor('d1')),
        findsOneWidget,
      );
      expect(
        find.byKey(ContextDirectoriesSection.confirmRemoveKeyFor('d1')),
        findsNothing,
      );
      expect(removes, isEmpty);
    });

    testWidgets('arming one row leaves the other alone', (tester) async {
      await pumpSection(
        tester,
        rows: [_row(_dir()), _row(_dir(id: 'd2', displayName: 'notes'))],
      );

      await tester.tap(find.byKey(ContextDirectoriesSection.removeKeyFor('d1')));
      await tester.pump();

      expect(
        find.byKey(ContextDirectoriesSection.removeKeyFor('d2')),
        findsOneWidget,
      );
      expect(
        find.byKey(ContextDirectoriesSection.confirmRemoveKeyFor('d2')),
        findsNothing,
      );
    });
  });

  group('the two switches', () {
    testWidgets('Summaries carries the value straight through',
        (tester) async {
      await pumpSection(tester, rows: [_row(_dir(digests: true))]);

      await tester.tap(find.byKey(ContextDirectoriesSection.digestsKeyFor('d1')));
      await tester.pump();

      expect(digests, [('d1', false)]);
    });

    testWidgets('Read ignored files is the stored column inverted',
        (tester) async {
      // honor_gitignore off is the default, so the switch reads ON: the app
      // IS reading the ignored files.
      await pumpSection(tester, rows: [_row(_dir(honorGitignore: false))]);
      expect(
        tester
            .widget<Switch>(
                find.byKey(ContextDirectoriesSection.ignoredKeyFor('d1')))
            .value,
        isTrue,
      );

      // Turning it off means "honour .gitignore", which is the column set.
      await tester.tap(find.byKey(ContextDirectoriesSection.ignoredKeyFor('d1')));
      await tester.pump();

      expect(ignored, [('d1', true)]);
    });
  });

  group('Add directory…', () {
    testWidgets('reads Adding… and goes inert while the panel is out',
        (tester) async {
      final panel = Completer<void>();
      var calls = 0;
      await pumpSection(
        tester,
        rows: const [],
        onAdd: () {
          calls++;
          return panel.future;
        },
      );

      await tester.tap(find.byKey(ContextDirectoriesSection.addKey));
      await tester.pump();

      expect(calls, 1);
      expect(find.text('Adding…'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
                find.byKey(ContextDirectoriesSection.addKey))
            .onPressed,
        isNull,
      );

      panel.complete();
      await tester.pump();
      await tester.pump();

      expect(find.text('Add directory…'), findsOneWidget);
    });

    testWidgets('no Add is offered when the host wired none', (tester) async {
      await pumpSection(tester, rows: const []);
      expect(find.byKey(ContextDirectoriesSection.addKey), findsNothing);
    });
  });

  testWidgets('a library still loading says so and keeps its rows',
      (tester) async {
    await pumpSection(tester, rows: [_row(_dir())], loading: true);

    expect(find.text('Loading…'), findsOneWidget);
    expect(find.text('acme'), findsOneWidget);
  });

  testWidgets('a library that could not be read shows the sentence',
      (tester) async {
    await pumpSection(
      tester,
      rows: const [],
      error: 'The directories could not be read.',
    );
    expect(find.text('The directories could not be read.'), findsOneWidget);
  });

  testWidgets('collapsed, the body is gone and the summary stays',
      (tester) async {
    await pumpSection(tester, rows: [_row(_dir())], expanded: false);

    expect(find.text('1 directory · 12 files'), findsOneWidget);
    expect(find.byKey(ContextDirectoriesSection.rereadKeyFor('d1')), findsNothing);
    expect(
      find.byKey(SettingsSection.toggleKey(ContextDirectoriesSection.title)),
      findsOneWidget,
    );
  });
}
