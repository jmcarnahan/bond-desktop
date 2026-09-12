import 'package:bond_inbox/screens/setup/setup_controls.dart';
import 'package:bond_inbox/screens/setup/setup_storage_body.dart';
import 'package:bond_inbox/services/models/disk_preflight.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where the weights go, and the one screen that can refuse to go on.
///
/// Prop-only. What is pinned: free space that CANNOT be asked is not a
/// refusal (the download hits ENOSPC and keeps its part, and refusing on
/// ignorance would block a volume that simply cannot answer), a genuine
/// shortfall IS, and the number in the refusal is the one the volume would
/// have to give up — weights plus the 10 GiB of headroom the models need to
/// load, which is why the caption says so.
void main() {
  const gib = 1024 * 1024 * 1024;
  const folder = '/Users/x/Library/Application Support/com.bondinbox.app/models';

  DiskPreflight preflight({
    int needed = 20 * gib,
    int? free = 100 * gib,
    bool writable = true,
  }) =>
      DiskPreflight(
        folder: folder,
        neededBytes: needed,
        headroomBytes: downloadHeadroomBytes,
        freeBytes: free,
        writable: writable,
      );

  Future<void> open(
    WidgetTester tester, {
    DiskPreflight? disk,
    VoidCallback? onChooseFolder,
    VoidCallback? onContinue,
    bool wireFolder = true,
    bool settle = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(760, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SetupStorageBody(
            folder: folder,
            disk: disk,
            onChooseFolder:
                wireFolder ? (onChooseFolder ?? () {}) : null,
            onContinue: onContinue ?? () {},
          ),
        ),
      ),
    ));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  bool canContinue(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byKey(setupContinueKey)).onPressed !=
      null;

  testWidgets('the folder is shown before anything is asked about it',
      (tester) async {
    await open(tester, disk: null);

    expect(find.text(folder), findsOneWidget);
    expect(find.text('Checking free space…'), findsOneWidget);
    // Nobody starts a twenty-three gigabyte download before the volume has
    // been asked about.
    expect(canContinue(tester), isFalse);
  });

  testWidgets('room to spare says how much is left afterwards',
      (tester) async {
    await open(tester, disk: preflight());

    expect(find.text('Free after download: 80.0 GB'), findsOneWidget);
    expect(canContinue(tester), isTrue);
  });

  testWidgets('a folder that already holds every model says so',
      (tester) async {
    await open(tester, disk: preflight(needed: 0));

    expect(find.text('All models are already in this folder.'), findsOneWidget);
    expect(find.textContaining('Free after download'), findsNothing);
    expect(canContinue(tester), isTrue);
  });

  testWidgets('free space that could not be checked is not a refusal',
      (tester) async {
    await open(tester, disk: preflight(free: null));

    expect(
      find.text('Free space could not be checked. If the download runs out '
          'of room it stops and keeps what it has.'),
      findsOneWidget,
    );
    expect(canContinue(tester), isTrue);
  });

  testWidgets('a shortfall names the three numbers and stops the step',
      (tester) async {
    await open(tester, disk: preflight(needed: 20 * gib, free: 5 * gib));

    expect(
      find.text('Not enough space: the download needs 30.0 GB and 5.0 GB is '
          'free. Free up 25.0 GB or choose another folder.'),
      findsOneWidget,
    );
    // Said out loud because the required number is bigger than the manifest
    // total, and a reader doing the arithmetic would otherwise conclude the
    // app cannot add up.
    expect(
      find.text('That includes 10 GB of headroom the models need to load.'),
      findsOneWidget,
    );
    expect(canContinue(tester), isFalse);
  });

  testWidgets('a volume with nothing left on it still reads as a number',
      (tester) async {
    // `formatBytes` answers the empty string for zero, and a full disk is
    // exactly the case this sentence is for — the refusal must not read
    // "and  is free".
    await open(tester, disk: preflight(needed: 20 * gib, free: 0));

    expect(
      find.text('Not enough space: the download needs 30.0 GB and 0 B is '
          'free. Free up 30.0 GB or choose another folder.'),
      findsOneWidget,
    );
    expect(canContinue(tester), isFalse);
  });

  testWidgets('a folder Bond cannot write to says so and stops the step',
      (tester) async {
    // Free space is not permission, and the number beside it is beside the
    // point: a folder that refuses the first byte fails every file.
    await open(tester, disk: preflight(writable: false));

    expect(
      find.text("Bond can't write to this folder. Choose another one."),
      findsOneWidget,
    );
    expect(find.textContaining('Free after download'), findsNothing);
    expect(canContinue(tester), isFalse);
  });

  testWidgets('an unwritable folder that holds every model is still a refusal',
      (tester) async {
    // Nothing left to download is the one case that passes on a full volume;
    // it must not pass on a folder the run cannot rename a part in.
    await open(tester, disk: preflight(needed: 0, writable: false));

    expect(find.text('All models are already in this folder.'), findsNothing);
    expect(canContinue(tester), isFalse);
  });

  testWidgets('Change folder… fires the host, and hides when unwired',
      (tester) async {
    var chooses = 0;
    await open(
      tester,
      disk: preflight(),
      onChooseFolder: () => chooses++,
    );

    await tester.tap(find.byKey(SetupStorageBody.changeFolderKey));
    await tester.pump();
    expect(chooses, 1);

    await open(tester, disk: preflight(), wireFolder: false);
    expect(find.byKey(SetupStorageBody.changeFolderKey), findsNothing);
  });

  testWidgets('Continue fires the host callback', (tester) async {
    var continues = 0;
    await open(tester, disk: preflight(), onContinue: () => continues++);

    await tester.tap(find.byKey(setupContinueKey));
    await tester.pump();

    expect(continues, 1);
  });
}
