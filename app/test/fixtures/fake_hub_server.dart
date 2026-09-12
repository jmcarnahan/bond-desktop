import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:crypto/crypto.dart' as crypto;

/// Deterministic bytes that are not compressible into nothing — a fake GGUF.
List<int> fakeWeights(int length, {int seed = 7}) {
  final random = Random(seed);
  return List<int>.generate(length, (_) => random.nextInt(256));
}

String sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

/// A real loopback server playing Hugging Face and its CDN.
///
/// A real [HttpServer] rather than a scripted `http.Client`, for
/// `FakeRouterServer`'s reason: the behaviour under test is a CONVERSATION —
/// a resolve that redirects, a ranged GET against a signed URL that can
/// expire mid-transfer, a socket that dies with the body half sent — and a
/// scripted client would happily let a downloader that never sent a `Range`
/// header pass.
///
/// Two routes:
/// * `/<repo>/resolve/<revision>/<file>` — the hub. Redirects to the CDN.
/// * `/cdn/<token>/<repo>/<file>` — the signed copy. Supports Range.
class FakeHubServer {
  FakeHubServer._(this._server) {
    _server.listen(_handle);
  }

  final HttpServer _server;

  static Future<FakeHubServer> start() async =>
      FakeHubServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  int get port => _server.port;

  Future<void> close() => _server.close(force: true);

  /// `'<repo>/<file>'` to the bytes the CDN serves.
  final Map<String, List<int>> contents = {};

  // ── resolve knobs ──────────────────────────────────────────────────

  /// 401 with `X-Error-Code: GatedRepo`, which is a licence nobody accepted.
  bool gated = false;

  /// The NEXT resolve answers 429 with `RateLimit: "api";r=0;t=1`, then this
  /// clears itself.
  bool rateLimitOnce = false;

  /// The next resolve answers 429 whose only header is `Retry-After: 3` —
  /// what a hub without the `RateLimit` extension sends.
  bool rateLimitRetryAfterOnce = false;

  /// The next resolve answers 429 with NOTHING to read a delay out of.
  bool rateLimitBareOnce = false;

  /// One-shot status for the next resolve — a 5xx or a 404.
  int? resolveStatusOverride;

  /// What `X-Linked-Size` / `X-Linked-Etag` say, when a test wants them to
  /// disagree with the manifest.
  int? linkedSizeOverride;
  String? linkedEtagOverride;

  /// Answer the resolve with the body itself instead of a redirect — the hub
  /// does this for small files and for some mirrors.
  bool resolveDirect = false;

  // ── CDN knobs ──────────────────────────────────────────────────────

  /// Ignore `Range` and always answer 200 from byte zero.
  bool ignoreRange = false;

  /// Tokens below this answer 403 — a signature that aged out.
  int expireTokensBelow = 0;

  /// EVERY token answers 403, however fresh — a CDN that will never hand
  /// these bytes over, whatever the signature says.
  bool expireAll = false;

  /// The next CDN request answers 429 with `RateLimit: "api";r=0;t=1`.
  bool cdnRateLimitOnce = false;

  /// Serve at most this many bytes of the range that was asked for, then end
  /// the response PROPERLY — a legitimate short answer, not a dropped socket.
  /// `Content-Length` and `Content-Range` describe what is actually sent.
  int? shortBodyBytes;

  /// Close the socket after this many bytes of body, once.
  int? dropAfterBytes;

  /// Close the socket after [dropAfterBytes] EVERY time (default 0 bytes).
  bool dropAlways = false;

  /// Restrict the drop knobs to these `'<repo>/<file>'` keys, so one file in
  /// a run can be made to fail while its neighbours finish.
  Set<String>? dropOnly;

  /// Flip one byte of the first CDN body, then clear.
  bool corruptFirst = false;

  /// Flip one byte of every CDN body.
  bool corruptAlways = false;

  /// Sleep between 64 KiB chunks, so a test can pause mid-stream.
  Duration? chunkDelay;

  /// One-shot status for the next CDN request.
  int? cdnStatusOverride;

  // ── records ────────────────────────────────────────────────────────

  int resolveCount = 0;
  int cdnCount = 0;
  final List<String?> resolveRanges = [];
  final List<String?> cdnRanges = [];
  final List<Uri> requests = [];

  int _token = 1;

  Uri resolveUriFor(ModelFile file) => Uri.parse(
        'http://127.0.0.1:$port/${file.repo}/resolve/${file.revision}/'
        '${file.file}',
      );

  Future<void> _handle(HttpRequest request) async {
    requests.add(request.uri);
    final segments = request.uri.pathSegments;
    try {
      if (segments.length > 1 && segments.first == 'cdn') {
        await _cdn(request, segments);
      } else if (segments.length >= 5 && segments[2] == 'resolve') {
        await _resolve(request, segments);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    } on Object {
      // A socket the test deliberately killed is not a failure of this fake.
    }
  }

  /// `/<owner>/<name>/resolve/<revision>/<file>`
  Future<void> _resolve(HttpRequest request, List<String> segments) async {
    resolveCount++;
    resolveRanges.add(request.headers.value(HttpHeaders.rangeHeader));
    final repo = '${segments[0]}/${segments[1]}';
    final revision = segments[3];
    final name = segments.sublist(4).join('/');
    final key = '$repo/$name';
    final body = contents[key];

    if (gated) {
      request.response.statusCode = HttpStatus.unauthorized;
      request.response.headers.set('X-Error-Code', 'GatedRepo');
      await request.response.close();
      return;
    }
    if (rateLimitOnce) {
      rateLimitOnce = false;
      request.response.statusCode = HttpStatus.tooManyRequests;
      request.response.headers.set('RateLimit', '"api";r=0;t=1');
      await request.response.close();
      return;
    }
    if (rateLimitRetryAfterOnce) {
      rateLimitRetryAfterOnce = false;
      request.response.statusCode = HttpStatus.tooManyRequests;
      request.response.headers.set(HttpHeaders.retryAfterHeader, '3');
      await request.response.close();
      return;
    }
    if (rateLimitBareOnce) {
      rateLimitBareOnce = false;
      request.response.statusCode = HttpStatus.tooManyRequests;
      await request.response.close();
      return;
    }
    final override = resolveStatusOverride;
    if (override != null) {
      resolveStatusOverride = null;
      request.response.statusCode = override;
      await request.response.close();
      return;
    }
    if (body == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    request.response.headers.set('X-Repo-Commit', revision);
    request.response.headers
        .set('X-Linked-Size', '${linkedSizeOverride ?? body.length}');
    request.response.headers
        .set('X-Linked-ETag', '"${linkedEtagOverride ?? sha256Hex(body)}"');

    if (resolveDirect) {
      await _serve(request, body, isCdn: false, key: key);
      return;
    }

    final token = _token++;
    request.response.statusCode = HttpStatus.found;
    request.response.headers
        .set(HttpHeaders.locationHeader, '/cdn/$token/$repo/$name');
    request.response.write('redirecting');
    await request.response.close();
  }

  /// `/cdn/<token>/<owner>/<name>/<file>`
  Future<void> _cdn(HttpRequest request, List<String> segments) async {
    cdnCount++;
    cdnRanges.add(request.headers.value(HttpHeaders.rangeHeader));
    final token = int.tryParse(segments[1]) ?? 0;
    final key = segments.sublist(2).join('/');
    final body = contents[key];

    if (expireAll || token < expireTokensBelow) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    if (cdnRateLimitOnce) {
      cdnRateLimitOnce = false;
      request.response.statusCode = HttpStatus.tooManyRequests;
      request.response.headers.set('RateLimit', '"api";r=0;t=1');
      await request.response.close();
      return;
    }
    final override = cdnStatusOverride;
    if (override != null) {
      cdnStatusOverride = null;
      request.response.statusCode = override;
      await request.response.close();
      return;
    }
    if (body == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    await _serve(request, body, isCdn: true, key: key);
  }

  Future<void> _serve(
    HttpRequest request,
    List<int> body, {
    required bool isCdn,
    required String key,
  }) async {
    var bytes = body;
    if (isCdn && (corruptAlways || corruptFirst)) {
      corruptFirst = false;
      bytes = [...body];
      bytes[0] = bytes[0] ^ 0xff;
    }

    var start = 0;
    var ranged = false;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (!ignoreRange && range != null) {
      final match = RegExp(r'bytes=(\d+)-').firstMatch(range);
      start = int.tryParse(match?.group(1) ?? '0') ?? 0;
      if (start >= bytes.length) {
        request.response.statusCode =
            HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes */${bytes.length}');
        await request.response.close();
        return;
      }
      ranged = true;
      request.response.statusCode = HttpStatus.partialContent;
    } else {
      start = 0;
      request.response.statusCode = HttpStatus.ok;
    }

    // A server may legitimately answer with less of the range than was asked
    // for, as long as it says so — which is a CLEAN end short of the file,
    // and nothing like a socket that died.
    var end = bytes.length;
    final short = shortBodyBytes;
    if (short != null && end - start > short) end = start + short;
    if (ranged) {
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${end - 1}/${bytes.length}',
      );
    }

    final payload = bytes.sublist(start, end);
    final only = dropOnly;
    final mayDrop = only == null || only.contains(key);
    final drop = !mayDrop
        ? null
        : (dropAlways ? (dropAfterBytes ?? 0) : dropAfterBytes);
    if (drop != null) {
      if (!dropAlways) dropAfterBytes = null;
      // Written RAW, down a detached socket. `HttpResponse` refuses to send a
      // body shorter than its own `Content-Length` and throws away what was
      // buffered, so a client would see zero bytes and never exercise a
      // resume; a hand-written head followed by a socket that goes away with
      // the body half sent is what a link dying mid-transfer looks like. The
      // close is orderly rather than a `destroy()`, and the client still
      // reads it as the error it is — the head promised more bytes than
      // arrived. [shortBodyBytes] is the other half of this: a body that ends
      // early and says so, which is not an error at all.
      final status = request.response.statusCode;
      final reason =
          status == HttpStatus.partialContent ? 'Partial Content' : 'OK';
      final contentRange =
          request.response.headers.value(HttpHeaders.contentRangeHeader);
      final head = StringBuffer('HTTP/1.1 $status $reason\r\n')
        ..write('Content-Length: ${payload.length}\r\n');
      if (contentRange != null) {
        head.write('Content-Range: $contentRange\r\n');
      }
      head.write('\r\n');
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.write(head.toString());
      if (drop > 0) {
        socket.add(payload.sublist(0, min(drop, payload.length)));
      }
      await socket.flush();
      await socket.close();
      return;
    }

    request.response.headers.contentLength = payload.length;
    final delay = chunkDelay;
    if (delay == null) {
      request.response.add(payload);
      await request.response.close();
      return;
    }
    const chunk = 64 * 1024;
    for (var i = 0; i < payload.length; i += chunk) {
      request.response.add(
        payload.sublist(i, min(i + chunk, payload.length)),
      );
      await request.response.flush();
      await Future<void>.delayed(delay);
    }
    await request.response.close();
  }
}

/// The JSON a test writes into a temp asset, when it wants a manifest on
/// disk rather than in Dart.
String manifestJson(ModelManifest manifest) =>
    const JsonEncoder.withIndent('  ').convert(manifest.toJson());
