import 'package:bond_inbox/screens/setup/setup_controls.dart';
import 'package:bond_inbox/screens/setup/setup_device_body.dart';
import 'package:bond_inbox/services/system/system_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The first-run step that can say no.
///
/// Prop-only, so there is no provider, no channel and no supervisor here —
/// which is what makes `pumpAndSettle` safe. What is pinned is the shape of
/// each verdict: a refusal has NO way forward, a warning has one, and a
/// machine that has not answered yet says so rather than showing zeroes.
void main() {
  Future<void> open(
    WidgetTester tester, {
    HardwareInfo? hardware,
    bool blocked = false,
    bool lowMemory = false,
    VoidCallback? onContinue,
    bool settle = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(760, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SetupDeviceBody(
            hardware: hardware,
            blocked: blocked,
            lowMemory: lowMemory,
            proseName: 'Qwen3.8 27B',
            proseMinRamBytes: 34359738368,
            onContinue: onContinue ?? () {},
          ),
        ),
      ),
    ));
    // A spinner never settles, so the "still checking" case pumps once
    // instead — the same reason every screen with an indeterminate indicator
    // in this suite does.
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  /// A machine the platform answered about only partly — no memory figure and
  /// no OS string, which is what a `flutter test` binary really gets.
  const unreported = HardwareInfo(
    chip: 'Apple M1',
    memoryBytes: 0,
    appleSilicon: true,
    rosetta: false,
    osVersion: '',
  );

  const apple = HardwareInfo(
    chip: 'Apple M3 Max',
    memoryBytes: 68719476736,
    appleSilicon: true,
    rosetta: false,
    osVersion: '15.6',
  );

  testWidgets('a machine that has not answered yet says it is checking',
      (tester) async {
    await open(tester, hardware: null, settle: false);

    expect(find.text('Checking this Mac…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(setupContinueKey), findsNothing);
  });

  testWidgets('a supported Mac reads back its chip, memory and macOS',
      (tester) async {
    await open(tester, hardware: apple);

    expect(find.text('Apple M3 Max'), findsOneWidget);
    expect(find.text('64.0 GB'), findsOneWidget);
    expect(find.text('15.6'), findsOneWidget);
    expect(find.byKey(setupContinueKey), findsOneWidget);
  });

  testWidgets('memory the platform could not report reads as unknown',
      (tester) async {
    // Zero bytes is what `HardwareInfo.unknown` carries, and what a build with
    // no channel behind it answers. "0 B" would be a claim about a machine;
    // "unknown" is the fact.
    await open(tester, hardware: unreported);

    expect(find.text('unknown'), findsOneWidget);
    expect(find.text('0 B'), findsNothing);
  });

  testWidgets('an empty macOS version drops its row rather than showing blank',
      (tester) async {
    await open(tester, hardware: unreported);

    expect(find.text('macOS'), findsNothing);
  });

  testWidgets('an Intel Mac is refused, with no way forward', (tester) async {
    await open(
      tester,
      hardware: const HardwareInfo(
        chip: 'Intel Core i9',
        memoryBytes: 34359738368,
        appleSilicon: false,
        rosetta: false,
        osVersion: '13.6',
      ),
      blocked: true,
    );

    expect(
      find.text('Intel-based Macs are currently not supported.'),
      findsOneWidget,
    );
    expect(find.text("Bond's models need Apple silicon."), findsOneWidget);
    // The whole point of the refusal: a disabled Continue would invite
    // pressing it.
    expect(find.byKey(setupContinueKey), findsNothing);
  });

  testWidgets('Rosetta adds the sentence that names the fix', (tester) async {
    await open(
      tester,
      hardware: const HardwareInfo(
        chip: 'Apple M2',
        memoryBytes: 17179869184,
        appleSilicon: true,
        rosetta: true,
        osVersion: '15.6',
      ),
      blocked: true,
    );

    expect(
      find.text('This copy of Bond is running under Rosetta. Download the '
          'Apple silicon build.'),
      findsOneWidget,
    );
    expect(find.byKey(setupContinueKey), findsNothing);
  });

  testWidgets('too little memory for the writing model warns and continues',
      (tester) async {
    await open(
      tester,
      hardware: const HardwareInfo(
        chip: 'Apple M2',
        memoryBytes: 17179869184,
        appleSilicon: true,
        rosetta: false,
        osVersion: '15.6',
      ),
      lowMemory: true,
    );

    expect(
      find.text('This Mac has 16.0 GB of memory. The writing model '
          '(Qwen3.8 27B) is built for 32.0 GB or more and may run slowly '
          'here. The models the inbox itself needs fit comfortably.'),
      findsOneWidget,
    );
    // A warning, not a refusal: triage, extraction and search all run on the
    // two small models and those fit anywhere.
    expect(find.byKey(setupContinueKey), findsOneWidget);
  });

  testWidgets('Continue fires the host callback', (tester) async {
    var continues = 0;
    await open(tester, hardware: apple, onContinue: () => continues++);

    await tester.tap(find.byKey(setupContinueKey));
    await tester.pump();

    expect(continues, 1);
  });
}
