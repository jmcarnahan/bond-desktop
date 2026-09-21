import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' show IOClient;
import 'package:path/path.dart' as p;

import '../../data/message_store.dart' show MessageStore;
import 'download_state.dart';
import 'model_manifest.dart';

/// Where a file's bytes are asked for. Real builds answer
/// [ModelFile.resolveUri]; a test points it at a loopback server.
typedef ResolveUri = Uri Function(ModelFile file);

/// Where a SIDECAR's bytes are asked for. Real builds answer
/// [ModelFile.sidecarResolveUri]; a test points it at a loopback server.
///
/// A seam of its own rather than a widening of [ResolveUri], because the two
/// files differ in name and revision and a caller substituting a hub has to be
/// able to say so for both.
typedef ResolveSidecarUri = Uri Function(ModelFile file, ModelSidecar sidecar);

/// Injected so a backoff is a RECORDED duration in a test rather than a real
/// minute of wall clock.
typedef Sleep = Future<void> Function(Duration d);

/// How a `.part` is opened for writing. A seam, so the disk-full path can be
/// tested without filling a volume.
typedef OpenPart = Future<IOSink> Function(String path, {required bool append});

/// A failure that ends this file with a word from [DownloadError].
class _FileFailure implements Exception {
  _FileFailure(this.error);
  final String error;
}

/// A failure worth trying again — a socket, a 5xx, a rate limit. [after] is a
/// delay the server asked for; null means "use the backoff".
class _Retryable implements Exception {
  _Retryable([this.after]);
  final Duration? after;
}

/// What a resolve produced: either the CDN address, or the bytes themselves.
class _Resolved {
  _Resolved.redirect(this.cdnUri) : response = null;
  _Resolved.body(this.response) : cdnUri = null;
  final Uri? cdnUri;
  final http.StreamedResponse? response;
}

/// ONE file to fetch: a checkpoint's weights, or the sidecar that follows it.
///
/// A manifest ENTRY can cost two downloads and the run treats them as two
/// transfers with two ledger rows — they resume and verify separately, and a
/// single row could not say that one of them landed. It is still ONE row on
/// the screen: [progressId] is the entry's id for both legs, [priorBytes] is
/// what the legs before this one already account for, and [parentTotal] is
/// every byte the entry costs, so a bar counts from zero to one once.
class _Leg {
  _Leg({
    required this.parent,
    required this.ledgerId,
    required this.relativePath,
    required this.uri,
    required this.sha256,
    required this.sizeBytes,
    required this.priorBytes,
    required this.isLast,
  });

  final ModelFile parent;

  /// The ledger's key — the entry's id, or `<id>.draft` for a sidecar.
  final String ledgerId;

  final String relativePath;
  final Uri uri;
  final String sha256;
  final int sizeBytes;

  /// Bytes belonging to the legs BEFORE this one, so a progress event can
  /// speak for the whole entry.
  final int priorBytes;

  /// Whether a `done` here is the ENTRY's done. Only the last leg may emit a
  /// terminal success: a screen drawing one bar per model must not see it
  /// finish while the sidecar is still to come.
  final bool isLast;

  String get progressId => parent.id;

  int get parentTotal => parent.downloadBytes;
}

/// Fetches the manifest's GGUF files, resumably.
///
/// ONE stream at a time, smallest first. One stream because the bottleneck is
/// the link rather than the server, and four concurrent 4 GB transfers only
/// make every one of them finish later; smallest first because the embedding
/// and bulk models are what the inbox actually needs to start working — a
/// user is triaging mail while the twenty-three-gigabyte prose model is still
/// arriving, instead of waiting for the whole set.
///
/// A FAILURE MOVES ON. A prose model that 404s must not hide an embedding
/// model that finished, so a file's failure is an event on the stream and the
/// run continues to the next file. The stream itself never carries an error.
///
/// Nothing here persists a URL. Hugging Face answers a resolve with a
/// redirect to a SIGNED CDN address that expires in about an hour, so a
/// stored one would turn into a mysterious 403 on the next launch. The app
/// re-resolves every time, and treats a 403 mid-transfer as "the signature
/// aged out" rather than as a refusal.
///
/// The RESUME OFFSET is the `.part` file's own length, never the ledger's.
/// The ledger is written at most every couple of seconds and a crash can lose
/// the last write; the file on disk cannot lie about how many bytes it holds.
///
/// Hashing is asked of the platform ([SystemInfo.sha256], CryptoKit) because
/// a pure-Dart sha256 over twenty-three gigabytes takes minutes on the
/// isolate that draws the UI. The Dart fallback is real code and not a
/// courtesy: it is what runs under `flutter test`, where there is no channel
/// behind the method call.
class ModelDownloader {
  ModelDownloader({
    required this.manifest,
    required this.modelsFolder,
    required this.readLedger,
    required this.writeLedger,
    this.sha256,
    this.beginActivity,
    this.endActivity,
    http.Client? httpClient,
    ResolveUri? resolveUri,
    ResolveSidecarUri? resolveSidecarUri,
    Sleep? sleep,
    OpenPart? openPart,
    this.maxAttempts = 10,
    this.minBackoff = const Duration(seconds: 2),
    this.maxBackoff = const Duration(seconds: 60),
    this.progressInterval = const Duration(milliseconds: 250),
    this.ledgerInterval = const Duration(seconds: 2),
    this.headersTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 60),
  })  : _ownsClient = httpClient == null,
        _client = httpClient ?? _defaultClient(headersTimeout),
        _resolveUri = resolveUri ?? _defaultResolveUri,
        _resolveSidecarUri = resolveSidecarUri ?? _defaultResolveSidecarUri,
        _sleep = sleep ?? _defaultSleep,
        _openPart = openPart ?? _defaultOpenPart;

  static Uri _defaultResolveUri(ModelFile file) => file.resolveUri;

  static Uri _defaultResolveSidecarUri(ModelFile file, ModelSidecar sidecar) =>
      file.sidecarResolveUri!;
  static Future<void> _defaultSleep(Duration d) => Future<void>.delayed(d);

  static Future<IOSink> _defaultOpenPart(
    String path, {
    required bool append,
  }) async =>
      File(path)
          .openWrite(mode: append ? FileMode.append : FileMode.writeOnly);

  /// package:http cannot abort a request once it is in flight, so the connect
  /// timeout is set on the socket layer, which is the one place that can
  /// actually close the thing. A stall AFTER the connect is bounded by the
  /// server, by [idleTimeout] on the body, or by [dispose].
  static http.Client _defaultClient(Duration connectTimeout) =>
      IOClient(HttpClient()..connectionTimeout = connectTimeout);

  /// What the App Nap activity is called, so a user reading Activity Monitor
  /// sees why this app is keeping the machine awake.
  static const String activityReason = 'Downloading models';

  /// Beside the destination rather than in a temp directory: a resume has to
  /// find it on the same volume, and a rename onto the finished name must not
  /// be a cross-device copy of twenty-three gigabytes.
  static const String partSuffix = '.part';

  final ModelManifest manifest;
  final int maxAttempts;
  final Duration minBackoff;
  final Duration maxBackoff;
  final Duration progressInterval;
  final Duration ledgerInterval;
  final Duration headersTimeout;
  final Duration idleTimeout;

  /// LATE-BOUND, on `ModelServerSupervisor`'s rule: the folder is read at the
  /// top of a run, so moving it in Settings between two runs is picked up
  /// without rebuilding anything that is mid-transfer.
  final String Function() modelsFolder;

  final Future<DownloadLedger> Function() readLedger;
  final Future<void> Function(DownloadLedger) writeLedger;

  /// The platform's hash, when there is one. A null ANSWER — not a null
  /// callback — is what sends a verify to the Dart fallback.
  final Future<String?> Function(String path)? sha256;

  final Future<int?> Function(String reason)? beginActivity;
  final Future<void> Function(int token)? endActivity;

  final http.Client _client;
  final bool _ownsClient;
  final ResolveUri _resolveUri;
  final ResolveSidecarUri _resolveSidecarUri;
  final Sleep _sleep;
  final OpenPart _openPart;

  DownloadLedger _ledger = DownloadLedger.empty;
  StreamController<DownloadProgress>? _controller;
  bool _running = false;
  bool _pauseRequested = false;
  bool _cancelRequested = false;
  bool _disposed = false;
  Completer<void>? _resumeGate;
  StreamIterator<List<int>>? _bytes;
  DateTime? _lastLedgerWrite;

  bool get running => _running;

  /// The latest in-memory ledger — current from the moment [run] has read it.
  DownloadLedger get ledger => _ledger;

  /// Downloads what is not already on disk, smallest first, one at a time.
  ///
  /// The stream carries one [DownloadProgress] per state change plus throttled
  /// progress while bytes move, and completes when every file has finished,
  /// failed, or been cancelled. It never carries an error.
  Stream<DownloadProgress> run([Iterable<ModelFile>? files]) {
    if (_running) {
      throw StateError('ModelDownloader.run: a run is already in progress');
    }
    if (_disposed) {
      throw StateError('ModelDownloader.run: this downloader was disposed');
    }
    _running = true;
    _pauseRequested = false;
    _cancelRequested = false;
    final controller = StreamController<DownloadProgress>();
    _controller = controller;
    scheduleMicrotask(() => _drive(files));
    return controller.stream;
  }

  /// Stops the transfer and RETURNS. The part stays where it is; the `paused`
  /// ledger row and the `paused` event follow on the RUN's own turn, once the
  /// cancelled stream has unwound, and [resume] carries the same file on from
  /// the byte it stopped at.
  Future<void> pause() async {
    if (!_running) return;
    _pauseRequested = true;
    await _abortInFlight();
  }

  Future<void> resume() async {
    _pauseRequested = false;
    final gate = _resumeGate;
    _resumeGate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  /// Like [pause], but the run ends. Parts are kept — a cancel is a "not
  /// now", and throwing away four gigabytes for it would be a cruel reading.
  Future<void> cancel() async {
    if (!_running) return;
    _cancelRequested = true;
    _pauseRequested = false;
    await _abortInFlight();
    final gate = _resumeGate;
    _resumeGate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  /// Whether the FINISHED files at [file]'s destinations hash to what the
  /// manifest says — the weights, and the sidecar when there is one.
  ///
  /// Both, because the question a caller is asking is whether this checkpoint
  /// can be served, and a prose model whose draft head is the previous
  /// build's cannot. The parent is hashed first and a mismatch answers at
  /// once, so the cheap half never pays for the expensive one.
  Future<bool> verify(ModelFile file) async {
    final folder = modelsFolder();
    if (!await _digestMatches(
      p.join(folder, file.relativePath),
      file.sha256,
    )) {
      return false;
    }
    final head = file.sidecar;
    if (head == null) return true;
    return _digestMatches(
      p.join(folder, file.sidecarRelativePath!),
      head.sha256,
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    await cancel();
    if (_ownsClient) _client.close();
    final controller = _controller;
    _controller = null;
    // NOT awaited. A single-subscription controller's `close()` completes only
    // once a listener has taken what is queued, so awaiting it here would hang
    // a dispose that is tidying up after a caller who walked away.
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
    }
  }

  // ───────────────────────────── the run ─────────────────────────────

  Future<void> _drive(Iterable<ModelFile>? files) async {
    final controller = _controller;
    int? token;
    try {
      _ledger = await readLedger();
      final ordered = [...(files ?? manifest.bySize)]
        ..sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));

      // The whole list before the first byte, so a screen draws every row at
      // once rather than growing one line at a time.
      final folder = modelsFolder();
      for (final file in ordered) {
        // Summed across the legs, because the row is the ENTRY's: a prose
        // model whose weights are here and whose sidecar is half here draws
        // one bar that says so.
        var received = 0;
        for (final leg in _legsFor(file)) {
          received += _lengthOf('${p.join(folder, leg.relativePath)}$partSuffix');
        }
        _emit(DownloadProgress(
          id: file.id,
          status: DownloadStatus.pending,
          receivedBytes: received,
          totalBytes: file.downloadBytes,
        ));
      }

      token = await beginActivity?.call(activityReason);
      for (final file in ordered) {
        if (_cancelRequested) break;
        try {
          await _runFile(file, folder);
        } on Object catch (e, stack) {
          // The LEGS look after themselves — see `_runFile`, which fails the
          // leg that threw. What is left for this net is a throw from
          // BUILDING the legs, where there is no leg to fail and no row to
          // write: the entry is said to have failed on the stream and the run
          // walks on to the next one, because a bug reached through one file
          // must not take the rest of the set down with it.
          debugPrint('model download: ${file.id} failed unexpectedly: '
              '$e\n$stack');
          _emit(DownloadProgress(
            id: file.id,
            status: DownloadStatus.failed,
            receivedBytes: 0,
            totalBytes: file.downloadBytes,
            error: DownloadError.network,
          ));
        }
      }
    } on Object catch (e, stack) {
      // Never onto the stream: a caller draws rows, and a thrown object has
      // no row to belong to. It is a bug if it happens, so it is said once.
      debugPrint('model download: unexpected failure: $e\n$stack');
    } finally {
      if (token != null) {
        try {
          await endActivity?.call(token);
        } on Object catch (e) {
          debugPrint('model download: endActivity failed: $e');
        }
      }
      _running = false;
      _bytes = null;
      _resumeGate = null;
      // NOT awaited: a single-subscription controller's `close()` waits for a
      // listener, and a caller who dropped the stream would otherwise hold
      // this run open — and its App Nap activity with it — forever.
      if (controller != null && !controller.isClosed) {
        unawaited(controller.close());
      }
      if (identical(_controller, controller)) _controller = null;
    }
  }

  /// The files one manifest entry costs, in the order they are fetched: the
  /// weights, then the sidecar. The sidecar goes SECOND because a draft head
  /// without the model it drafts for is of no use to anybody, and a run that
  /// stops between them leaves the more valuable file on disk.
  List<_Leg> _legsFor(ModelFile file) {
    final head = file.sidecar;
    return [
      _Leg(
        parent: file,
        ledgerId: file.id,
        relativePath: file.relativePath,
        uri: _resolveUri(file),
        sha256: file.sha256,
        sizeBytes: file.sizeBytes,
        priorBytes: 0,
        isLast: head == null,
      ),
      if (head != null)
        _Leg(
          parent: file,
          ledgerId: DownloadLedger.draftId(file.id),
          relativePath: file.sidecarRelativePath!,
          uri: _resolveSidecarUri(file, head),
          sha256: head.sha256,
          sizeBytes: head.sizeBytes,
          priorBytes: file.sizeBytes,
          isLast: true,
        ),
    ];
  }

  /// One entry, leg by leg. A leg that fails or is cancelled ends the ENTRY:
  /// the sidecar is worth nothing without its parent, and a failure is already
  /// on the stream as this entry's terminal event.
  ///
  /// The UNEXPECTED throw is caught per leg, and the leg that threw is the one
  /// failed. Failing the first leg instead would write `failed` at zero bytes
  /// over the parent's `done` row when it was the SIDECAR that threw — a
  /// finished eighteen-gigabyte file the next launch would fetch again.
  Future<void> _runFile(ModelFile file, String folder) async {
    for (final leg in _legsFor(file)) {
      final bool landed;
      try {
        landed = await _runLeg(leg, folder);
      } on Object catch (e, stack) {
        debugPrint('model download: ${leg.ledgerId} failed unexpectedly: '
            '$e\n$stack');
        try {
          final part = '${p.join(folder, leg.relativePath)}$partSuffix';
          await _finish(leg, DownloadStatus.failed, _lengthOf(part),
              leg.sizeBytes,
              error: DownloadError.network);
        } on Object catch (second) {
          debugPrint(
              'model download: ${leg.ledgerId} could not be failed: $second');
        }
        return;
      }
      if (!landed) return;
    }
  }

  /// True when this leg's file is on disk under its finished name at the
  /// digest asked for; false when it failed, paused into a cancel, or was
  /// abandoned.
  Future<bool> _runLeg(_Leg leg, String folder) async {
    final dest = p.join(folder, leg.relativePath);
    final part = '$dest$partSuffix';
    final total = leg.sizeBytes;

    // 1 — the folder. A models folder the user pointed at a volume that is no
    // longer mounted fails here, and says so, instead of failing per byte.
    try {
      Directory(p.dirname(dest)).createSync(recursive: true);
    } on FileSystemException {
      await _finish(leg, DownloadStatus.failed, 0, total,
          error: DownloadError.missingFolder);
      return false;
    }

    // 2 — a part written for a different checkpoint. Resuming into it would
    // spend the whole download to fail a checksum at the very end.
    //
    // A part with NO row at all is kept and resumed. The ledger is written at
    // most every couple of seconds and a crash can lose it entirely, so a
    // missing row says nothing about the bytes; being wrong here costs one
    // checksum at the end, and deleting on it would throw away gigabytes
    // every time the app died mid-download.
    final existing = _ledger[leg.ledgerId];
    if (existing != null && existing.sha256 != leg.sha256 && _exists(part)) {
      _deleteQuietly(part);
      _ledger = _ledger.without(leg.ledgerId);
      await _persistLedger(force: true);
    }

    // 3 — a finished file already there.
    if (_exists(dest)) {
      if (existing != null &&
          existing.status == DownloadStatus.done &&
          existing.sha256 == leg.sha256) {
        // Skipped, but SAID. On a top-up run — the weights already here, the
        // head still to fetch — a silent skip would leave the entry's bar
        // reading zero until the head's first bytes landed, which on a
        // 1.6 GB file over a slow link is a screen that looks stuck.
        _emitLeg(
          leg,
          leg.isLast ? DownloadStatus.done : DownloadStatus.downloading,
          total,
        );
        return true;
      }
      _emitLeg(leg, DownloadStatus.verifying, total);
      if (await _digestMatches(dest, leg.sha256)) {
        await _finish(leg, DownloadStatus.done, total, total);
        return true;
      }
      _deleteQuietly(dest);
    }

    var attempts = 0;
    var backoff = minBackoff;
    var progressMark = _lengthOf(part);
    var checksumRetried = false;
    var immediateUsed = false;
    final rate = _RateWindow();

    while (true) {
      if (await _stopHere(leg, _lengthOf(part), total)) return false;

      // 4 — where the part left off. Longer than the manifest says means the
      // file behind the manifest changed size without changing its name.
      var offset = _lengthOf(part);
      if (offset > total) {
        _deleteQuietly(part);
        offset = 0;
      }
      if (offset < total) {
        try {
          await _transfer(leg, part, offset, total, rate);
        } on _FileFailure catch (failure) {
          await _finish(leg, DownloadStatus.failed, _lengthOf(part), total,
              error: failure.error);
          return false;
        } on _Retryable catch (retry) {
          if (_pauseRequested || _cancelRequested) continue;
          final now = _lengthOf(part);
          if (now > progressMark) {
            // Bytes landed since the last failure, so this is a flaky link
            // rather than a wall: the budget starts over.
            progressMark = now;
            attempts = 0;
            backoff = minBackoff;
            immediateUsed = false;
          }
          attempts++;
          if (attempts >= maxAttempts) {
            await _finish(leg, DownloadStatus.failed, now, total,
                error: DownloadError.network);
            return false;
          }
          if (retry.after != null) {
            await _sleep(retry.after!);
          } else if (_isImmediate(retry) && !immediateUsed) {
            immediateUsed = true;
          } else {
            // A SECOND expired signature with no byte in between is not a
            // signature that aged out, it is a wall — and a wall waits like
            // any other.
            await _sleep(backoff);
            backoff = _doubled(backoff);
          }
          continue;
        }
        if (_pauseRequested || _cancelRequested) continue;
      }

      // 8 — verify, then rename. The rename is what makes the finished name
      // appear atomically: nothing ever sees a half file under it.
      _emitLeg(leg, DownloadStatus.verifying, _lengthOf(part));
      await _record(leg, DownloadStatus.verifying, _lengthOf(part), total,
          force: true);
      if (await _digestMatches(part, leg.sha256)) {
        try {
          File(part).renameSync(dest);
        } on FileSystemException catch (e) {
          await _finish(leg, DownloadStatus.failed, _lengthOf(part), total,
              error: _isDiskFull(e)
                  ? DownloadError.diskFull
                  : DownloadError.missingFolder);
          return false;
        }
        await _finish(leg, DownloadStatus.done, total, total);
        return true;
      }
      _deleteQuietly(part);
      if (checksumRetried) {
        // Twice is not a flipped bit in flight; it is the wrong file. Nothing
        // is left behind, so the next run starts clean rather than resuming
        // into bytes that are already known to be wrong.
        await _finish(leg, DownloadStatus.failed, 0, total,
            error: DownloadError.checksum);
        return false;
      }
      checksumRetried = true;
      progressMark = 0;
      attempts = 0;
      backoff = minBackoff;
      immediateUsed = false;
    }
  }

  /// Resolves and streams one attempt's worth of bytes into the part.
  ///
  /// Returns when the part holds every byte the manifest asked for; anything
  /// less — a dropped socket, a body that ended early — leaves by way of
  /// [_Retryable] or [_FileFailure], so the caller has one place to decide
  /// what a shortfall costs.
  Future<void> _transfer(
    _Leg leg,
    String part,
    int offset,
    int total,
    _RateWindow rate,
  ) async {
    final resolved = await _resolve(leg, offset);
    var response = resolved.response;
    if (response == null) {
      response = await _fetch(resolved.cdnUri!, offset);
      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        await _drain(response);
        // The part already holds everything the CDN would send.
        return;
      }
    }
    return _consume(leg, part, offset, total, response, rate);
  }

  /// Step 5. The hub's own answer: a redirect to the CDN, or the bytes.
  Future<_Resolved> _resolve(_Leg leg, int offset) async {
    final request = http.Request('GET', leg.uri)..followRedirects = false;
    // The Range rides on the RESOLVE as well, because a hub that answers the
    // body directly rather than redirecting has to resume too.
    if (offset > 0) {
      request.headers[HttpHeaders.rangeHeader] = 'bytes=$offset-';
    }
    final response = await _send(request);
    final code = response.statusCode;

    if (code == 301 ||
        code == 302 ||
        code == 303 ||
        code == 307 ||
        code == 308) {
      final location = response.headers[HttpHeaders.locationHeader];
      await _drain(response);
      _checkLinked(leg, response.headers);
      if (location == null || location.isEmpty) throw _Retryable();
      return _Resolved.redirect(leg.uri.resolve(location));
    }
    if (code == HttpStatus.ok || code == HttpStatus.partialContent) {
      try {
        _checkLinked(leg, response.headers);
      } on _FileFailure {
        await _drain(response);
        rethrow;
      }
      return _Resolved.body(response);
    }
    await _drain(response);
    if (code == HttpStatus.unauthorized &&
        response.headers['x-error-code'] == 'GatedRepo') {
      throw _FileFailure(DownloadError.gated);
    }
    if (code == HttpStatus.tooManyRequests) {
      throw _Retryable(_retryAfter(response.headers));
    }
    if (code >= 500) throw _Retryable();
    throw _FileFailure(DownloadError.http(code));
  }

  /// Step 6. The CDN copy.
  Future<http.StreamedResponse> _fetch(Uri uri, int offset) async {
    final request = http.Request('GET', uri)..followRedirects = true;
    if (offset > 0) {
      request.headers[HttpHeaders.rangeHeader] = 'bytes=$offset-';
    }
    final response = await _send(request);
    final code = response.statusCode;
    if (code == HttpStatus.ok ||
        code == HttpStatus.partialContent ||
        code == HttpStatus.requestedRangeNotSatisfiable) {
      return response;
    }
    await _drain(response);
    if (code == HttpStatus.forbidden) {
      // The signed URL aged out mid-download. Not a refusal — go round again
      // and ask the hub for a fresh signature, without a backoff, because
      // nothing is wrong and waiting a minute would only be rude.
      throw _ImmediateRetry();
    }
    if (code == HttpStatus.tooManyRequests) {
      throw _Retryable(_retryAfter(response.headers));
    }
    if (code >= 500) throw _Retryable();
    throw _FileFailure(DownloadError.http(code));
  }

  Future<http.StreamedResponse> _send(http.Request request) async {
    try {
      return await _client.send(request).timeout(headersTimeout);
    } on TimeoutException {
      throw _Retryable();
    } on SocketException {
      throw _Retryable();
    } on http.ClientException {
      throw _Retryable();
    } on HttpException {
      throw _Retryable();
    }
  }

  /// Step 7. Bytes to disk, with progress and a rate.
  Future<void> _consume(
    _Leg leg,
    String part,
    int offset,
    int total,
    http.StreamedResponse response,
    _RateWindow rate,
  ) async {
    // A 200 to a ranged request means the server ignored the Range and is
    // sending from byte zero; keeping the old prefix would duplicate it.
    final fresh = response.statusCode == HttpStatus.ok;
    var received = fresh ? 0 : offset;
    final sink = await _openPart(part, append: !fresh);
    final iterator =
        StreamIterator<List<int>>(response.stream.timeout(idleTimeout));
    _bytes = iterator;
    rate.reset();

    var lastEmit = DateTime.now().subtract(progressInterval);
    Object? failure;
    var stopped = false;

    // The ESTIMATE is over the whole entry, not this leg: a bar that said
    // "seconds left" and then started again on the sidecar would be lying
    // about the thing the number is for.
    void emitNow(int bytes) {
      final speed = rate.bytesPerSecond;
      final done = leg.priorBytes + bytes;
      final whole = leg.parentTotal;
      _emit(DownloadProgress(
        id: leg.progressId,
        status: DownloadStatus.downloading,
        receivedBytes: done,
        totalBytes: whole,
        bytesPerSecond: speed,
        remaining: speed > 0 && whole > done
            ? Duration(
                milliseconds: ((whole - done) / speed * 1000).round(),
              )
            : null,
      ));
    }

    emitNow(received);
    await _record(leg, DownloadStatus.downloading, received, total,
        force: true);

    try {
      while (true) {
        final bool more;
        try {
          more = await iterator.moveNext();
        } on Object catch (e) {
          failure = e;
          break;
        }
        if (!more) break;
        if (_pauseRequested || _cancelRequested) {
          stopped = true;
          await iterator.cancel();
          break;
        }
        final chunk = iterator.current;
        // The WRITE side is caught as well as the read. A volume that fills
        // up throws ENOSPC out of `add` or out of `flush`, and an escape from
        // here would leave the run with no word for what went wrong and the
        // whole set abandoned over one full disk.
        try {
          sink.add(chunk);
          received += chunk.length;
          rate.add(chunk.length);
          final now = DateTime.now();
          if (now.difference(lastEmit) >= progressInterval) {
            lastEmit = now;
            emitNow(received);
            await _record(leg, DownloadStatus.downloading, received, total);
            // Flushed on the same beat, so a disk that has filled up is
            // discovered while the part is still small enough to be honest
            // about how far it got.
            await sink.flush();
          }
        } on Object catch (e) {
          failure = e;
          break;
        }
      }
    } finally {
      _bytes = null;
      // The body goes as well as the sink. A write that failed leaves a live
      // subscription with a socket behind it and nobody left to read it.
      try {
        await iterator.cancel();
      } on Object catch (e) {
        debugPrint('model download: dropping the body failed: $e');
      }
      try {
        await sink.flush();
      } on Object catch (e) {
        failure ??= e;
      }
      try {
        await sink.close();
      } on Object catch (e) {
        failure ??= e;
      }
    }

    if (failure != null) {
      if (failure is FileSystemException && _isDiskFull(failure)) {
        // The part is KEPT. A user who frees ten gigabytes and presses Retry
        // must not start the twenty-three-gigabyte download over.
        throw _FileFailure(DownloadError.diskFull);
      }
      if (failure is _FileFailure) throw failure;
      // The error alone, not its stack: a dropped socket is an expected part
      // of a long download, and a page of frames per retry buries the log.
      debugPrint('model download: ${leg.ledgerId} stream failed: $failure');
      throw _Retryable();
    }
    if (stopped) return;
    if (received < total) {
      // A body that ended cleanly, short of the length that was asked for.
      // Retryable rather than a short answer, so that the caller's progress
      // rule applies: bytes did land, so this attempt has not spent a life
      // out of the budget.
      throw _Retryable();
    }
  }

  // ─────────────────────────── bookkeeping ───────────────────────────

  /// Whether the run must stop or wait here. Emits the paused state and, for
  /// a pause, holds until [resume] or [cancel].
  Future<bool> _stopHere(_Leg leg, int received, int total) async {
    if (!_pauseRequested && !_cancelRequested) return false;
    await _record(leg, DownloadStatus.paused, received, total, force: true);
    _emitLeg(leg, DownloadStatus.paused, received);
    if (_cancelRequested) return true;
    // Re-checked after the await above: a resume that arrived while the
    // ledger was being written would otherwise leave a gate nobody completes.
    if (!_pauseRequested) return false;
    final gate = Completer<void>();
    _resumeGate = gate;
    await gate.future;
    return _cancelRequested;
  }

  Future<void> _finish(
    _Leg leg,
    DownloadStatus status,
    int received,
    int total, {
    String? error,
  }) async {
    await _record(leg, status, received, total, error: error, force: true);
    // A `done` that is not the LAST leg is not this entry's done. The row is
    // written either way — that is what a resume reads — but the stream stays
    // silent, so a screen drawing one bar per model does not see it finish
    // while the sidecar is still to come. A FAILURE is always said: it ends
    // the entry, whichever file it happened to.
    if (status == DownloadStatus.done && !leg.isLast) return;
    _emitLeg(leg, status, received, error: error);
  }

  /// One event, in the ENTRY's terms: its id, its total, and the legs before
  /// this one counted in.
  void _emitLeg(
    _Leg leg,
    DownloadStatus status,
    int received, {
    String? error,
  }) {
    _emit(DownloadProgress(
      id: leg.progressId,
      status: status,
      receivedBytes: leg.priorBytes + received,
      totalBytes: leg.parentTotal,
      error: error,
    ));
  }

  Future<void> _record(
    _Leg leg,
    DownloadStatus status,
    int received,
    int total, {
    String? error,
    bool force = false,
  }) async {
    // The ROW is the leg's own: its id, its bytes, its digest. Two files that
    // resume separately cannot share one row, and a `.draft` row at the wrong
    // digest is what tells the next launch the head was bumped.
    _ledger = _ledger.record(FileDownloadState(
      id: leg.ledgerId,
      status: status,
      receivedBytes: received,
      totalBytes: total,
      sha256: leg.sha256,
      error: error,
      updatedAt: MessageStore.isoStamp(DateTime.now()),
    ));
    await _persistLedger(force: force);
  }

  Future<void> _persistLedger({bool force = false}) async {
    final now = DateTime.now();
    final last = _lastLedgerWrite;
    if (!force && last != null && now.difference(last) < ledgerInterval) {
      return;
    }
    _lastLedgerWrite = now;
    try {
      await writeLedger(_ledger);
    } on Object catch (e) {
      // A ledger that cannot be written costs a re-verify next launch, which
      // is a far smaller thing than a download that gives up over it.
      debugPrint('model download: ledger not written: $e');
    }
  }

  void _emit(DownloadProgress progress) {
    final controller = _controller;
    if (controller != null && !controller.isClosed) controller.add(progress);
  }

  Future<void> _abortInFlight() async {
    final iterator = _bytes;
    _bytes = null;
    if (iterator == null) return;
    try {
      await iterator.cancel();
    } on Object catch (e) {
      debugPrint('model download: cancelling the stream failed: $e');
    }
  }

  // ───────────────────────────── helpers ─────────────────────────────

  /// The hub states the linked object's size and etag on the redirect. When
  /// either disagrees with the manifest, the manifest is wrong about these
  /// bytes — and finding that out now is worth a great deal more than finding
  /// it out after eighteen gigabytes.
  void _checkLinked(_Leg leg, Map<String, String> headers) {
    final size = headers['x-linked-size'];
    if (size != null) {
      final value = int.tryParse(size.trim());
      if (value != null && value != leg.sizeBytes) {
        throw _FileFailure(DownloadError.manifestMismatch);
      }
    }
    final etag = headers['x-linked-etag'];
    if (etag != null) {
      final value = etag.trim().replaceAll('"', '');
      if (value.isNotEmpty &&
          value.length == 64 &&
          value.toLowerCase() != leg.sha256) {
        throw _FileFailure(DownloadError.manifestMismatch);
      }
    }
  }

  /// `RateLimit: "api";r=0;t=17`, or a plain `Retry-After` in seconds.
  Duration? _retryAfter(Map<String, String> headers) {
    final rateLimit = headers['ratelimit'];
    if (rateLimit != null) {
      final match = RegExp(r't\s*=\s*(\d+)').firstMatch(rateLimit);
      final seconds = int.tryParse(match?.group(1) ?? '');
      if (seconds != null) return _capped(Duration(seconds: seconds));
    }
    final retryAfter = headers[HttpHeaders.retryAfterHeader];
    final seconds = int.tryParse((retryAfter ?? '').trim());
    if (seconds != null) return _capped(Duration(seconds: seconds));
    return maxBackoff;
  }

  Duration _capped(Duration d) => d > maxBackoff ? maxBackoff : d;

  Duration _doubled(Duration d) => _capped(d * 2);

  bool _isImmediate(_Retryable retry) => retry is _ImmediateRetry;

  Future<void> _drain(http.StreamedResponse response) async {
    try {
      await response.stream.drain<void>();
    } on Object catch (e) {
      debugPrint('model download: draining a response failed: $e');
    }
  }

  Future<bool> _digestMatches(String path, String expected) async {
    final platform = await _platformDigest(path);
    if (platform != null) return platform.trim().toLowerCase() == expected;
    return await _dartDigest(path) == expected;
  }

  Future<String?> _platformDigest(String path) async {
    final ask = sha256;
    if (ask == null) return null;
    try {
      final answer = await ask(path);
      if (answer == null) {
        // Said out loud, because the Dart fallback over twenty-three
        // gigabytes is minutes on the isolate that draws the UI, and a
        // channel that has quietly stopped answering looks exactly like a
        // slow machine otherwise.
        debugPrint('model download: platform sha256 unavailable for $path; '
            'hashing in Dart');
      }
      return answer;
    } on Object catch (e) {
      debugPrint('model download: platform sha256 failed: $e');
      return null;
    }
  }

  Future<String?> _dartDigest(String path) async {
    try {
      final digest = await crypto.sha256.bind(File(path).openRead()).first;
      return digest.toString();
    } on Object catch (e) {
      debugPrint('model download: hashing $path failed: $e');
      return null;
    }
  }

  static bool _isDiskFull(FileSystemException e) => e.osError?.errorCode == 28;

  static bool _exists(String path) {
    try {
      return File(path).existsSync();
    } on FileSystemException {
      return false;
    }
  }

  static int _lengthOf(String path) {
    try {
      final file = File(path);
      return file.existsSync() ? file.lengthSync() : 0;
    } on FileSystemException {
      return 0;
    }
  }

  static void _deleteQuietly(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException catch (e) {
      debugPrint('model download: could not delete $path: $e');
    }
  }
}

/// A retry with nothing to wait for — an expired signature, which is fixed by
/// asking again rather than by waiting.
class _ImmediateRetry extends _Retryable {
  _ImmediateRetry() : super();
}

/// Bytes over the last few seconds, which is what a person reads as "speed".
///
/// A whole-transfer average would tell somebody who has been downloading for
/// an hour how fast their link was an hour ago; the window is what makes the
/// estimate move when the network does.
class _RateWindow {
  static const Duration _window = Duration(seconds: 5);

  final Queue<({DateTime at, int bytes})> _samples = Queue();

  void reset() => _samples.clear();

  void add(int bytes) {
    final now = DateTime.now();
    _samples.add((at: now, bytes: bytes));
    while (_samples.isNotEmpty && now.difference(_samples.first.at) > _window) {
      _samples.removeFirst();
    }
  }

  /// The span is measured from the OLDEST sample, so the bytes that arrived at
  /// that instant are excluded: they were already on the wire when the window
  /// opened, and counting them against a span they did not take reads as a
  /// burst that never happened.
  double get bytesPerSecond {
    if (_samples.length < 2) return 0;
    final span = _samples.last.at.difference(_samples.first.at).inMicroseconds;
    if (span <= 0) return 0;
    var total = 0;
    var first = true;
    for (final sample in _samples) {
      if (first) {
        first = false;
        continue;
      }
      total += sample.bytes;
    }
    return total * 1000000 / span;
  }
}
