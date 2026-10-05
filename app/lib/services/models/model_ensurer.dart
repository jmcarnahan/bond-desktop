import 'dart:async';

import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, debugPrint, immutable, mapEquals,
        setEquals;

import 'download_state.dart';
import 'model_downloader.dart';
import 'model_manifest.dart';

/// Where one [ModelEnsurer] run stands.
enum EnsurePhase { idle, downloading, failed, done }

/// What the ensurer is doing, for the Models page and the rail.
///
/// It never holds a URL or a token: ids, fractions and error WORDS, the
/// things a status line needs and nothing a log should not carry.
@immutable
class EnsureState {
  final EnsurePhase phase;

  /// The manifest id being fetched, or the first one that failed.
  final String? modelId;

  /// 0..1 across the whole run while downloading; 1 once it has ended. Null
  /// while [waiting].
  final double? fraction;

  /// A download is running that is not this ensurer's (the wizard's run,
  /// still going after it was left): the ensurer waits its turn, and the
  /// surfaces say a download is running and offer no button.
  final bool waiting;

  /// Each entry of the run in flight, 0..1, by manifest id: a row shows ITS
  /// entry's percentage rather than the run's.
  final Map<String, double> fractions;

  /// The entries that landed in the run in flight or the last one, so a row
  /// can say `On disk` the moment its own entry is done.
  final Set<String> landedIds;

  /// The FIRST failed entry's [DownloadError] word, when [phase] is failed.
  final String? error;

  /// Every entry that failed in the last run.
  final Set<String> failedIds;

  /// Each failed entry's own error word, so a row can say why IT failed
  /// when it was not the first.
  final Map<String, String?> errors;

  const EnsureState({
    this.phase = EnsurePhase.idle,
    this.modelId,
    this.fraction,
    this.waiting = false,
    this.fractions = const {},
    this.landedIds = const {},
    this.error,
    this.failedIds = const {},
    this.errors = const {},
  });

  /// Why [id] failed in the last run, or null.
  String? errorFor(String id) => errors[id] ?? (id == modelId ? error : null);

  /// How far [id]'s own download is, or null when it is not in the run.
  double? fractionFor(String id) => fractions[id];

  @override
  bool operator ==(Object other) =>
      other is EnsureState &&
      other.phase == phase &&
      other.modelId == modelId &&
      other.fraction == fraction &&
      other.waiting == waiting &&
      mapEquals(other.fractions, fractions) &&
      setEquals(other.landedIds, landedIds) &&
      other.error == error &&
      setEquals(other.failedIds, failedIds) &&
      mapEquals(other.errors, errors);

  @override
  int get hashCode => Object.hash(
        phase,
        modelId,
        fraction,
        waiting,
        Object.hashAllUnordered(fractions.keys),
        Object.hashAllUnordered(landedIds),
        error,
        Object.hashAllUnordered(failedIds),
        Object.hashAllUnordered(errors.keys),
      );

  @override
  String toString() => 'EnsureState(${phase.name}'
      '${waiting ? ', waiting' : ''}'
      '${modelId == null ? '' : ', $modelId'}'
      '${fraction == null ? '' : ', ${(fraction! * 100).round()}%'}'
      '${error == null ? '' : ', $error'})';
}

/// Downloads whatever the current placements need and the disk lacks,
/// OUTSIDE the wizard (decision D6).
///
/// The wizard downloads once, at setup. Everything after that — a model the
/// wizard could not fetch because the registry was unreachable, a launch
/// under `BOND_DEV_SKIP_SETUP` that never saw the wizard, a placement moved
/// to this Mac in Settings, a manifest bump — is this class's: it runs at
/// launch once the app is showing, on Settings' Check and Download, and
/// after a registry or placement change.
///
/// ONE ownership rule for the ONE [ModelDownloader] it shares with the
/// wizard, whose `run` refuses a second run:
/// - while [blocked] says the wizard is showing, nothing starts, at once;
/// - while somebody ELSE's run is in flight (the wizard's, still going after
///   Finish or Back to the inbox), it says so ([EnsureState.waiting]), waits
///   for `downloader.idle`, and then does its scan, so a kick is never
///   dropped and a file that run landed still reaches the router through
///   [afterRun];
/// - [standDown] cancels its OWN run when the wizard opens (parts are kept,
///   so the wizard resumes from the byte);
/// - a run somebody else left PAUSED is cancelled rather than waited for:
///   nothing could ever resume it (see [_ensure]).
/// Single-flight on its own account too, coalescing FORWARD: a call while a
/// pass is still waiting for somebody else's run joins that pass, whose scan
/// is still to come; a call once the pass has scanned gets ONE further pass,
/// shared by every call made meanwhile and started when the current one ends,
/// so a placement moved, a registry saved or a Download again pressed during
/// a pass is seen.
///
/// Plain Dart, no Riverpod: the provider hands it every collaborator as a
/// closure read at call time, so a placement or a folder moved between two
/// runs is what the next run sees.
class ModelEnsurer {
  ModelEnsurer({
    required this.downloader,
    required this.wanted,
    required this.modelsFolder,
    required this.readLedger,
    required this.beforeRun,
    required this.afterRun,
    this.blocked,
  });

  /// A LOOKUP, so building the ensurer (and reading its state) does not
  /// build the downloader and the manifest behind it.
  final ModelDownloader Function() downloader;

  /// The ensure set, computed fresh per call: what the placements need on
  /// this Mac. A FUTURE, because it waits on the machine tier the way the
  /// router's own manifest does.
  final Future<ModelManifest> Function() wanted;

  final String Function() modelsFolder;
  final Future<DownloadLedger> Function() readLedger;

  /// Awaited before a run starts: the prefs notifier's `ready`, so a STORED
  /// registry token is in the cache the downloader's lookup reads.
  final Future<void> Function() beforeRun;

  /// Awaited at the end of EVERY completed pass, the one that found nothing
  /// missing included, with the ids that landed in it: the provider restarts
  /// the router when one of them is served there, and otherwise asks for the
  /// preset, which restarts only when its hash moved (a file the wizard's
  /// lingering run landed).
  final Future<void> Function(Set<String> landedIds) afterRun;

  /// True while the wizard owns the downloader. Null is never blocked.
  final bool Function()? blocked;

  final ValueNotifier<EnsureState> _state =
      ValueNotifier(const EnsureState());
  Future<EnsureState>? _inFlight;
  bool _disposed = false;

  /// The pass in flight has begun its scan: a call now needs a pass of its
  /// own rather than this one.
  bool _scanned = false;

  /// What the pass in flight re-verifies, merged into by a call that arrives
  /// before its scan.
  Set<String> _reverify = {};

  /// The one further pass owed to the calls made after the scan, and what it
  /// re-verifies.
  Completer<EnsureState>? _again;
  Set<String> _againReverify = {};

  /// [standDown] was called: a further pass owed is skipped.
  bool _skipAgain = false;

  /// This ensurer's own run is in flight.
  bool _owns = false;

  /// [standDown] cancelled the run in flight.
  bool _stoodDown = false;

  ValueListenable<EnsureState> get state => _state;

  bool get _blocked => _disposed || (blocked?.call() ?? false);

  ModelDownloader get _shared => downloader();

  /// Downloads what is missing. Never throws: every outcome is a state.
  ///
  /// [reverify] names entries to treat as missing even when the ledger says
  /// they are current, whose files the downloader HASHES again: a good file
  /// is kept, a wrong or damaged one replaced (Settings' Download again).
  ///
  /// A call during a pass that has not scanned yet joins it; a call after
  /// the scan completes with the ONE further pass every such call shares.
  Future<EnsureState> ensure({Set<String> reverify = const {}}) {
    final running = _inFlight;
    if (running != null) {
      if (!_scanned) {
        _reverify.addAll(reverify);
        return running;
      }
      _againReverify.addAll(reverify);
      return (_again ??= Completer<EnsureState>()).future;
    }
    if (_blocked) return Future.value(_state.value);
    _skipAgain = false;
    return _start(reverify);
  }

  Future<EnsureState> _start(Set<String> reverify) {
    _reverify = {...reverify};
    _scanned = false;
    final run = _ensure().whenComplete(_passEnded);
    _inFlight = run;
    return run;
  }

  /// Starts the further pass owed, unless the wizard opened, the ensurer was
  /// disposed or stood down meanwhile: then the calls waiting on it complete
  /// with the state as it stands.
  void _passEnded() {
    _inFlight = null;
    final again = _again;
    if (again == null) return;
    _again = null;
    final reverify = _againReverify;
    _againReverify = {};
    if (_skipAgain || _blocked) {
      _skipAgain = false;
      again.complete(_state.value);
      return;
    }
    again.complete(_start(reverify));
  }

  /// Cancels this ensurer's OWN run, keeping its parts, and completes once
  /// that run has ended. Nothing when the run in flight is somebody else's
  /// or there is none. A further pass owed is skipped either way.
  Future<void> standDown() async {
    if (_again != null) _skipAgain = true;
    if (!_owns) return;
    final ModelDownloader shared;
    try {
      shared = _shared;
    } on Object catch (e) {
      debugPrint('model ensure: could not stand down: $e');
      return;
    }
    _stoodDown = true;
    try {
      await shared.cancel();
    } on Object catch (e) {
      debugPrint('model ensure: could not stand down: $e');
    }
    await shared.idle;
  }

  Future<EnsureState> _ensure() async {
    // Somebody else's run: wait for it rather than drop the kick. Inside the
    // net, because the lookup builds a provider that can throw, or be read
    // after its container is gone.
    try {
      if (_shared.running) {
        final before = _state.value;
        _set(const EnsureState(phase: EnsurePhase.downloading, waiting: true));
        while (_shared.running) {
          // A PAUSED run is cancelled, never waited for: this ensurer runs
          // only while the wizard is not showing, so a paused run then has no
          // screen that could ever resume it. Its parts are kept, and the
          // scan below resumes them from the byte.
          if (_shared.paused && !_owns && !_blocked) {
            await _shared.cancel();
          }
          await _shared.idle;
        }
        if (_blocked) {
          _set(before);
          return _state.value;
        }
      }
    } on Object catch (e) {
      debugPrint('model ensure: could not read the downloader: $e');
      if (_state.value.waiting) _set(const EnsureState());
      return _state.value;
    }

    _scanned = true;
    final reverify = {..._reverify};
    final List<ModelFile> missing;
    try {
      final set = await wanted();
      final folder = modelsFolder();
      final ledger = await readLedger();
      missing = [
        for (final model in set.models)
          if (!model.isLocal &&
              (reverify.contains(model.id) ||
                  !(ledger.isCurrent(model) &&
                      ModelManifest.filesPresent(model, folder))))
            model,
      ];
    } on Object catch (e) {
      debugPrint('model ensure: could not read what is wanted: $e');
      if (_state.value.waiting) _set(const EnsureState());
      return _state.value;
    }
    if (missing.isEmpty) {
      _set(const EnsureState(phase: EnsurePhase.done, fraction: 1));
      await _nudge(const {});
      return _state.value;
    }
    try {
      await beforeRun();
    } on Object catch (e) {
      // A prefs load that failed costs a refused file the row explains,
      // never the run.
      debugPrint('model ensure: preferences not ready: $e');
    }
    // Asked again: the wizard may have opened, or another run started,
    // across the awaits above. No await between this and `run`.
    final ModelDownloader shared;
    try {
      shared = _shared;
    } on Object catch (e) {
      debugPrint('model ensure: could not read the downloader: $e');
      if (_state.value.waiting) _set(const EnsureState());
      return _state.value;
    }
    if (_blocked || shared.running) {
      if (_state.value.waiting) _set(const EnsureState());
      return _state.value;
    }
    final Stream<DownloadProgress> stream;
    try {
      stream = shared.run(missing, reverify);
    } on StateError catch (e) {
      debugPrint('model ensure: did not start: $e');
      return _state.value;
    }
    _owns = true;
    _stoodDown = false;

    final totals = {for (final m in missing) m.id: m.downloadBytes};
    final received = {for (final m in missing) m.id: 0};
    final failed = <String>[];
    final errors = <String, String?>{};
    final landed = <String>{};
    var fraction = 0.0;
    // The downloader's own order, smallest first.
    final first = ([...missing]
          ..sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes)))
        .first
        .id;
    String? current;

    Map<String, double> each() => {
          for (final id in totals.keys)
            id: totals[id]! <= 0
                ? (landed.contains(id) ? 1.0 : 0.0)
                : (received[id]! / totals[id]!).clamp(0.0, 1.0).toDouble(),
        };

    double whole() {
      var sum = 0;
      var got = 0;
      for (final id in totals.keys) {
        sum += totals[id]!;
        got += received[id]!;
      }
      if (sum <= 0) return 0;
      final value = got / sum;
      return value > 1 ? 1 : value;
    }

    _set(EnsureState(
      phase: EnsurePhase.downloading,
      modelId: first,
      fraction: 0,
      fractions: Map.unmodifiable(each()),
    ));

    try {
      await for (final progress in stream) {
        final id = progress.id;
        if (!totals.containsKey(id)) continue;
        switch (progress.status) {
          case DownloadStatus.done:
            landed.add(id);
            received[id] = totals[id]!;
          case DownloadStatus.failed:
            // Finished as far as the run's fraction goes: nothing more of it
            // is coming this run.
            received[id] = totals[id]!;
            if (!failed.contains(id)) failed.add(id);
            errors[id] = progress.error;
          case DownloadStatus.pending:
          case DownloadStatus.downloading:
          case DownloadStatus.paused:
          case DownloadStatus.verifying:
            received[id] =
                progress.receivedBytes.clamp(0, totals[id]!).toInt();
            current = id;
        }
        // Never backwards: a checksum retry starts its file again, and a
        // bar that slid back would read as the download undoing itself.
        final next = whole();
        if (next > fraction) fraction = next;
        _set(EnsureState(
          phase: EnsurePhase.downloading,
          modelId: current ?? id,
          fraction: fraction,
          fractions: Map.unmodifiable(each()),
          landedIds: Set.unmodifiable(landed),
          failedIds: Set.unmodifiable(failed),
          errors: Map.unmodifiable(errors),
        ));
      }
    } on Object catch (e) {
      debugPrint('model ensure: the run ended unexpectedly: $e');
    }
    _owns = false;

    if (_stoodDown) {
      // Cancelled for the wizard: nothing failed and not everything landed.
      _stoodDown = false;
      _set(EnsureState(landedIds: Set.unmodifiable(landed)));
    } else if (failed.isEmpty) {
      _set(EnsureState(
        phase: EnsurePhase.done,
        fraction: 1,
        landedIds: Set.unmodifiable(landed),
      ));
    } else {
      debugPrint('model ensure: ${failed.join(', ')} failed: '
          '${failed.map((id) => errors[id]).join(', ')}');
      _set(EnsureState(
        phase: EnsurePhase.failed,
        modelId: failed.first,
        fraction: 1,
        landedIds: Set.unmodifiable(landed),
        error: errors[failed.first],
        failedIds: Set.unmodifiable(failed),
        errors: Map.unmodifiable(errors),
      ));
    }
    await _nudge(landed);
    return _state.value;
  }

  Future<void> _nudge(Set<String> landed) async {
    if (_disposed) return;
    try {
      await afterRun(Set.unmodifiable(landed));
    } on Object catch (e) {
      debugPrint('model ensure: the server was not nudged: $e');
    }
  }

  void _set(EnsureState next) {
    if (_disposed) return;
    _state.value = next;
  }

  void dispose() {
    _disposed = true;
    _state.dispose();
  }
}
