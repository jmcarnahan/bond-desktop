import 'package:bond_inbox/screens/setup/setup_controls.dart';
import 'package:bond_inbox/screens/setup/setup_download_body.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/download_state.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
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
    routerEmbedId: 639150592,
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
    MachineTier tier = MachineTier.full,
    Map<String, DownloadProgress> progress = const {},
    bool running = false,
    bool paused = false,
    bool complete = false,
    bool? allDownloaded,
    List<ModelFile>? files,
    VoidCallback? onStart,
    VoidCallback? onPause,
    VoidCallback? onResume,
    VoidCallback? onCancel,
    VoidCallback? onContinue,
    Widget? registryFix,
  }) async {
    await tester.binding.setSurfaceSize(const Size(760, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SetupDownloadBody(
            files: files ?? manifest.forTier(tier).bySize,
            progress: progress,
            running: running,
            paused: paused,
            complete: complete,
            allDownloaded: allDownloaded,
            onStart: onStart ?? () {},
            onPause: onPause ?? () {},
            onResume: onResume ?? () {},
            onCancel: onCancel ?? () {},
            onContinue: onContinue ?? () {},
            registryFix: registryFix,
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
        SetupDownloadBody.describeDownloadError(
            DownloadError.registryNotConfigured),
        'The model registry has no address. Add one under Settings, Models.',
      );
      expect(
        SetupDownloadBody.describeDownloadError(DownloadError.unauthorized),
        'The model registry refused the access token. Check it under '
        'Settings, Models.',
      );
      expect(
        SetupDownloadBody.describeDownloadError(DownloadError.registryNotFound),
        'The model registry does not have this model. Check its address under '
        'Settings, Models.',
      );
      expect(
        SetupDownloadBody.describeDownloadError(
            DownloadError.registryNotAModel),
        'The model registry answered with a web page, not a model. Check its '
        'address under Settings, Models.',
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

  testWidgets('an inbox Mac gets a bar per file its tier wants, and no more',
      (tester) async {
    // The host hands down the RESOLVED manifest, so the writing model has no
    // row here at all: a bar for a file nothing is fetching would never
    // finish, and Continue waits for every bar on the screen.
    await open(tester, tier: MachineTier.inbox);

    expect(find.text('Waiting'), findsNWidgets(2));
    expect(find.text('Test Prose'), findsNothing);
    expect(canContinue(tester), isFalse);
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

  testWidgets('the caption is true of every set: smallest first, one at a '
      'time', (tester) async {
    await open(tester);
    expect(find.text(SetupDownloadBody.orderText), findsOneWidget);
    expect(find.text('The models arrive one at a time, smallest first.'),
        findsOneWidget);
    expect(find.textContaining('two models the inbox needs'), findsNothing);
  });

  testWidgets('a failed registry row says why and that Bond keeps trying, and '
      'does not hold Continue', (tester) async {
    final withDecide = testManifest(withDecide: true);
    await open(
      tester,
      files: withDecide.bySize,
      complete: true,
      allDownloaded: false,
      progress: {
        for (final model in withDecide.models)
          model.id: model.isRegistry
              ? entry(model.id,
                  status: DownloadStatus.failed,
                  error: DownloadError.unauthorized)
              : entry(model.id, status: DownloadStatus.done),
      },
    );

    expect(
      find.text(
          SetupDownloadBody.describeDownloadError(DownloadError.unauthorized)),
      findsOneWidget,
    );
    expect(find.text(SetupDownloadBody.registryLaterText), findsOneWidget);
    expect(
        find.text('Bond tries again after setup, and under Settings, Models. '
            'You can continue.'),
        findsOneWidget);
    expect(canContinue(tester), isTrue);
    // Not every model is here, so the step does not say so, and it offers
    // the retry.
    expect(find.text('All models are on this Mac.'), findsNothing);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('waiting for another owner\'s run reads as in progress, with '
      'no button to press', (tester) async {
    await tester.binding.setSurfaceSize(const Size(760, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SetupDownloadBody(
            files: manifest.bySize,
            progress: const {},
            running: true,
            paused: false,
            waiting: true,
            complete: false,
            onStart: () {},
            onPause: () {},
            onResume: () {},
            onCancel: () {},
            onContinue: () {},
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(find.text(SetupDownloadBody.waitingText), findsOneWidget);
    for (final key in [
      SetupDownloadBody.startKey,
      SetupDownloadBody.pauseKey,
      SetupDownloadBody.resumeKey,
      SetupDownloadBody.cancelKey,
    ]) {
      expect(find.byKey(key), findsNothing);
    }
  });

  testWidgets('a failed registry row for the embedding model says why but '
      'never that you can continue, because it holds Continue',
      (tester) async {
    final both = testManifest(embed: testEmbedFile(), withDecide: true);
    expect(both.byRole(ModelRole.embed).isRegistry, isTrue);
    expect(both.byRole(ModelRole.embed).gatesSetup, isTrue);
    await open(
      tester,
      files: both.bySize,
      complete: false,
      allDownloaded: false,
      progress: {
        for (final model in both.models)
          model.id: model.id == routerEmbedId
              ? entry(model.id,
                  status: DownloadStatus.failed,
                  error: DownloadError.unauthorized)
              : entry(model.id, status: DownloadStatus.done),
      },
    );

    expect(
      find.text(
          SetupDownloadBody.describeDownloadError(DownloadError.unauthorized)),
      findsOneWidget,
    );
    expect(find.text(SetupDownloadBody.registryLaterText), findsNothing);
    expect(canContinue(tester), isFalse);
  });

  testWidgets('with both registry rows failed, only the decision model\'s '
      'says Bond keeps trying', (tester) async {
    final both = testManifest(embed: testEmbedFile(), withDecide: true);
    await open(
      tester,
      files: both.bySize,
      complete: false,
      allDownloaded: false,
      progress: {
        for (final model in both.models)
          model.id: model.isRegistry
              ? entry(model.id,
                  status: DownloadStatus.failed,
                  error: DownloadError.registryNotConfigured)
              : entry(model.id, status: DownloadStatus.done),
      },
    );

    expect(find.text(SetupDownloadBody.registryLaterText), findsOneWidget);
    expect(canContinue(tester), isFalse);
  });

  testWidgets('a failed hub row gets no registry line', (tester) async {
    await open(tester, progress: {
      routerEmbedId: entry(routerEmbedId,
          status: DownloadStatus.failed, error: DownloadError.network),
    });
    expect(find.text(SetupDownloadBody.registryLaterText), findsNothing);
    expect(canContinue(tester), isFalse);
  });

  testWidgets('Continue fires the host callback once complete',
      (tester) async {
    var continues = 0;
    await open(tester, complete: true, onContinue: () => continues++);

    await tester.tap(find.byKey(setupContinueKey));
    await tester.pump();

    expect(continues, 1);
  });

  group('a registry problem fixed on this step', () {
    // A stand-in for the host's form: this body is prop-only, so what is
    // pinned here is WHEN the slot is drawn and what the rows say beside it.
    const fix = Text('FIX-FORM');
    final both = testManifest(embed: testEmbedFile(), withDecide: true);

    Map<String, DownloadProgress> failing(String id, String error) => {
          for (final model in both.models)
            model.id: model.id == id
                ? entry(model.id,
                    status: DownloadStatus.failed, error: error)
                : entry(model.id, status: DownloadStatus.done),
        };

    test('the here-sentences point below, and anything else falls back', () {
      expect(
        SetupDownloadBody.describeRegistryFixHere(
            DownloadError.registryNotConfigured),
        'The model registry has no address. Add it below.',
      );
      expect(
        SetupDownloadBody.describeRegistryFixHere(DownloadError.unauthorized),
        'The model registry refused the access token. Check it below.',
      );
      expect(
        SetupDownloadBody.describeRegistryFixHere(
            DownloadError.registryNotFound),
        'The model registry does not have this model. Check its address '
        'below.',
      );
      expect(
        SetupDownloadBody.describeRegistryFixHere(
            DownloadError.registryNotAModel),
        'The model registry answered with a web page, not a model. Check its '
        'address below.',
      );
      expect(
        SetupDownloadBody.describeRegistryFixHere(DownloadError.network),
        SetupDownloadBody.describeDownloadError(DownloadError.network),
      );
      expect(
        SetupDownloadBody.describeRegistryFixHere(null),
        SetupDownloadBody.describeDownloadError(null),
      );
    });

    for (final word in DownloadError.registryFixes) {
      testWidgets('a failed embedding row ($word) draws the form and the '
          'here-sentence, and still holds Continue', (tester) async {
        await open(
          tester,
          files: both.bySize,
          complete: false,
          allDownloaded: false,
          progress: failing(routerEmbedId, word),
          registryFix: fix,
        );

        expect(find.text('FIX-FORM'), findsOneWidget);
        expect(
          find.text(SetupDownloadBody.describeRegistryFixHere(word)),
          findsOneWidget,
        );
        expect(
          find.text(SetupDownloadBody.describeDownloadError(word)),
          findsNothing,
        );
        expect(find.text(SetupDownloadBody.registryLaterText), findsNothing);
        expect(canContinue(tester), isFalse);
      });

      testWidgets('with no form from the host, a failed embedding row '
          '($word) keeps today\'s sentence and draws nothing more',
          (tester) async {
        await open(
          tester,
          files: both.bySize,
          complete: false,
          allDownloaded: false,
          progress: failing(routerEmbedId, word),
        );

        expect(find.text('FIX-FORM'), findsNothing);
        expect(
          find.text(SetupDownloadBody.describeDownloadError(word)),
          findsOneWidget,
        );
        expect(
          find.text(SetupDownloadBody.describeRegistryFixHere(word)),
          findsNothing,
        );
      });
    }

    // A wrong address fails as a plain network error too (a mistyped host,
    // a closed port) and a proxy's 5xx likewise: the fields are drawn for
    // any failed registry row, and the row keeps its own sentence.
    for (final word in [DownloadError.network, DownloadError.http(503)]) {
      testWidgets('a registry row that failed for another reason ($word) '
          'still draws the form, with its own sentence', (tester) async {
        await open(
          tester,
          files: both.bySize,
          complete: false,
          allDownloaded: false,
          progress: failing(routerEmbedId, word),
          registryFix: fix,
        );

        expect(find.text('FIX-FORM'), findsOneWidget);
        expect(
          find.text(SetupDownloadBody.describeDownloadError(word)),
          findsOneWidget,
        );
        // Never a "below" sentence: only the four registry words point there.
        expect(find.textContaining('below'), findsNothing);
        expect(canContinue(tester), isFalse);
      });
    }

    testWidgets('a failed HUB row draws no form', (tester) async {
      await open(
        tester,
        complete: false,
        allDownloaded: false,
        progress: {
          routerEmbedId: entry(routerEmbedId,
              status: DownloadStatus.failed, error: DownloadError.network),
        },
        registryFix: fix,
      );

      expect(manifest.byRole(ModelRole.embed).isRegistry, isFalse);
      expect(find.text('FIX-FORM'), findsNothing);
      expect(
        find.text(
            SetupDownloadBody.describeDownloadError(DownloadError.network)),
        findsOneWidget,
      );
    });

    testWidgets('a failed decision row draws the form beside its "you can '
        'continue" line, and never holds Continue', (tester) async {
      await open(
        tester,
        files: both.bySize,
        complete: true,
        allDownloaded: false,
        progress: failing(routerDecideId, DownloadError.unauthorized),
        registryFix: fix,
      );

      expect(find.text('FIX-FORM'), findsOneWidget);
      expect(
        find.text(SetupDownloadBody.describeRegistryFixHere(
            DownloadError.unauthorized)),
        findsOneWidget,
      );
      expect(find.text(SetupDownloadBody.registryLaterText), findsOneWidget);
      expect(canContinue(tester), isTrue);
    });

    testWidgets('no failed row draws no form', (tester) async {
      await open(
        tester,
        files: both.bySize,
        complete: false,
        allDownloaded: false,
        progress: {
          for (final model in both.models)
            model.id: entry(model.id, status: DownloadStatus.downloading),
        },
        registryFix: fix,
      );

      expect(find.text('FIX-FORM'), findsNothing);
    });
  });
}
