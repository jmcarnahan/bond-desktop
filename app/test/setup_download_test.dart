import 'package:bond_inbox/screens/setup/setup_controls.dart';
import 'package:bond_inbox/screens/setup/setup_download_body.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/download_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_manifest.dart';

/// The twenty-three gigabytes, drawn.
///
/// Prop-only, so the downloader itself is nowhere near this file — what is
/// pinned is the reading: which controls a state offers, that Continue waits
/// for EVERY file rather than the usable pair, and that every word in the
/// closed failure vocabulary comes out as a sentence with a next step in it.
void main() {
  final manifest = testManifest(sizes: {
    routerEmbedId: 333590944,
    routerBulkId: 4280403520,
    routerProseId: 18973870432,
  });

  DownloadProgress entry(
    String id, {
    DownloadStatus status = DownloadStatus.pending,
    int received = 0,
    int total = 1024,
    double rate = 0,
    Duration? remaining,
    String? error,
  }) =>
      DownloadProgress(
        id: id,
        status: status,
        receivedBytes: received,
        totalBytes: total,
        bytesPerSecond: rate,
        remaining: remaining,
        error: error,
      );

  Future<void> open(
    WidgetTester tester, {
    Map<String, DownloadProgress> progress = const {},
    bool running = false,
    bool paused = false,
    bool complete = false,
    VoidCallback? onStart,
    VoidCallback? onPause,
    VoidCallback? onResume,
    VoidCallback? onCancel,
    VoidCallback? onContinue,
  }) async {
    await tester.binding.setSurfaceSize(const Size(760, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SetupDownloadBody(
            files: manifest.bySize,
            progress: progress,
            running: running,
            paused: paused,
            complete: complete,
            onStart: onStart ?? () {},
            onPause: onPause ?? () {},
            onResume: onResume ?? () {},
            onCancel: onCancel ?? () {},
            onContinue: onContinue ?? () {},
          ),
        ),
      ),
    ));
    // One bare pump, the flow's idiom: the bars here are determinate, and
    // this suite keeps the house rule rather than settling around a wizard.
    await tester.pump();
  }

  bool canContinue(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byKey(setupContinueKey)).onPressed !=
      null;

  group('describeRemaining', () {
    test('is vague at every scale, on purpose', () {
      // The rate is measured over the last few seconds of a transfer that
      // runs for an hour: a figure to the second would be precise about a
      // number that is not.
      expect(
        SetupDownloadBody.describeRemaining(const Duration(seconds: 5)),
        'less than a minute left',
      );
      expect(
        SetupDownloadBody.describeRemaining(const Duration(seconds: 59)),
        'less than a minute left',
      );
      expect(
        SetupDownloadBody.describeRemaining(const Duration(seconds: 61)),
        'about 2 min left',
      );
      expect(
        SetupDownloadBody.describeRemaining(const Duration(minutes: 40)),
        'about 40 min left',
      );
      expect(
        SetupDownloadBody.describeRemaining(const Duration(hours: 2)),
        'about 2 h left',
      );
      expect(
        SetupDownloadBody.describeRemaining(
          const Duration(hours: 1, minutes: 25),
        ),
        'about 1 h 25 min left',
      );
    });
  });

  group('describeDownloadError', () {
    test('every word in the closed vocabulary has a next step in it', () {
      expect(
        SetupDownloadBody.describeDownloadError(DownloadError.diskFull),
        'Not enough disk space. Free some space, then try again.',
      );
      expect(
        SetupDownloadBody.describeDownloadError(DownloadError.checksum),
        'The file did not verify after two attempts. Check the connection '
        'and try again.',
      );
      expect(
        SetupDownloadBody.describeDownloadError(DownloadError.network),
        'The connection dropped too many times. Check the network and try '
        'again.',
      );
      expect(
        SetupDownloadBody.describeDownloadError(DownloadError.gated),
        'This model needs a Hugging Face login and cannot be downloaded '
        'automatically.',
      );
      expect(
        SetupDownloadBody.describeDownloadError(DownloadError.manifestMismatch),
        'The file on the server no longer matches this version of Bond. '
        'Update Bond and try again.',
      );
      expect(
        SetupDownloadBody.describeDownloadError(DownloadError.missingFolder),
        'The models folder could not be created. Go back and choose another '
        'folder.',
      );
      expect(
        SetupDownloadBody.describeDownloadError(DownloadError.http(503)),
        'The server answered HTTP 503.',
      );
    });

    test('a word this build does not know still reads as a sentence', () {
      // The ledger is read by builds older and newer than the one that wrote
      // it, and a machine word rendered at somebody is worse than a vague
      // sentence.
      expect(
        SetupDownloadBody.describeDownloadError('quantum_flux'),
        'The download failed.',
      );
      // `http_` with something that is not a status code behind it: a later
      // build's `http_timeout` must not be read back at somebody as an HTTP
      // code that does not exist.
      expect(
        SetupDownloadBody.describeDownloadError('http_abc'),
        'The download failed.',
      );
      expect(
        SetupDownloadBody.describeDownloadError('http_'),
        'The download failed.',
      );
      expect(
        SetupDownloadBody.describeDownloadError(null),
        'The download failed.',
      );
    });
  });

  testWidgets('nothing started offers Start download and no Continue',
      (tester) async {
    await open(tester);

    expect(find.text('Start download'), findsOneWidget);
    expect(find.byKey(SetupDownloadBody.pauseKey), findsNothing);
    expect(find.byKey(SetupDownloadBody.cancelKey), findsNothing);
    expect(canContinue(tester), isFalse);
    // Waiting, three times over — one per file, before any of them is looked
    // at.
    expect(find.text('Waiting'), findsNWidgets(3));
  });

  testWidgets('a file that failed turns Start into Try again', (tester) async {
    await open(tester, progress: {
      routerEmbedId: entry(
        routerEmbedId,
        status: DownloadStatus.failed,
        error: DownloadError.network,
      ),
    });

    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Start download'), findsNothing);
    expect(
      find.text('The connection dropped too many times. Check the network '
          'and try again.'),
      findsOneWidget,
    );
  });

  testWidgets('a running download offers Pause and Cancel', (tester) async {
    var pauses = 0;
    var cancels = 0;
    await open(
      tester,
      running: true,
      progress: {
        routerEmbedId: entry(
          routerEmbedId,
          status: DownloadStatus.downloading,
          received: 100 * 1024 * 1024,
          total: 333590944,
          rate: 12 * 1024 * 1024,
          remaining: const Duration(minutes: 3),
        ),
      },
      onPause: () => pauses++,
      onCancel: () => cancels++,
    );

    expect(find.byKey(SetupDownloadBody.startKey), findsNothing);
    expect(find.byKey(SetupDownloadBody.resumeKey), findsNothing);
    expect(find.text('Downloading'), findsOneWidget);
    // The detail line carries the rate and the estimate only while bytes are
    // actually moving.
    expect(
      find.text('100 MB of 318 MB · 12 MB/s · about 3 min left'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(SetupDownloadBody.pauseKey));
    await tester.tap(find.byKey(SetupDownloadBody.cancelKey));
    await tester.pump();
    expect(pauses, 1);
    expect(cancels, 1);
  });

  testWidgets('a paused run offers Resume rather than Start', (tester) async {
    var resumes = 0;
    await open(
      tester,
      running: true,
      paused: true,
      progress: {
        routerEmbedId: entry(routerEmbedId, status: DownloadStatus.paused),
      },
      onResume: () => resumes++,
    );

    // Still a run: starting a second one over a paused one is not something
    // the downloader allows.
    expect(find.byKey(SetupDownloadBody.startKey), findsNothing);
    expect(find.text('Paused'), findsOneWidget);
    expect(find.byKey(SetupDownloadBody.cancelKey), findsOneWidget);

    await tester.tap(find.byKey(SetupDownloadBody.resumeKey));
    await tester.pump();
    expect(resumes, 1);
  });

  testWidgets('the quit line is there in every state', (tester) async {
    const line = 'You can quit — the download resumes next launch.';
    await open(tester);
    expect(find.text(line), findsOneWidget);

    await open(tester, running: true);
    expect(find.text(line), findsOneWidget);

    await open(tester, complete: true);
    expect(find.text(line), findsOneWidget);
  });

  testWidgets('Continue waits for every file, not the usable pair',
      (tester) async {
    // The embed and bulk models are enough for triage and search, and NOT
    // enough here: the supervisor refuses to start while any file the preset
    // names is missing, so a partial set could not serve the inbox at all.
    await open(tester, progress: {
      routerEmbedId: entry(routerEmbedId, status: DownloadStatus.done),
      routerBulkId: entry(routerBulkId, status: DownloadStatus.done),
    });
    expect(find.text('Ready'), findsNWidgets(2));
    expect(canContinue(tester), isFalse);
    expect(find.text('All models are on this Mac.'), findsNothing);

    await open(tester, complete: true, progress: {
      for (final model in manifest.models)
        model.id: entry(model.id, status: DownloadStatus.done),
    });
    expect(find.text('All models are on this Mac.'), findsOneWidget);
    expect(canContinue(tester), isTrue);
    // Nothing left to start, so nothing offering to.
    expect(find.byKey(SetupDownloadBody.startKey), findsNothing);
  });

  testWidgets('Continue fires the host callback once complete',
      (tester) async {
    var continues = 0;
    await open(tester, complete: true, onContinue: () => continues++);

    await tester.tap(find.byKey(setupContinueKey));
    await tester.pump();

    expect(continues, 1);
  });
}
