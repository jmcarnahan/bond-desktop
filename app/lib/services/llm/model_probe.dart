import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart' show immutable;
import 'package:http/http.dart' as http;

/// What one look at a model server found.
@immutable
class ModelProbeResult {
  /// The server answered 200 with a model list this could read. False for
  /// every other outcome — nothing listening, a wrong status, a body that is
  /// not JSON, a URL with no `/v1/` in it to derive a listing endpoint from.
  final bool reachable;

  /// The ids the server offered, in the order it offered them. llama-server
  /// answers with the single model it loaded; an MLX-style runtime lists
  /// several, and those are the names the model field has to pick between.
  final List<String> modelIds;

  /// One sentence, safe to put on a settings screen. Null exactly when
  /// [reachable].
  final String? error;

  /// Where it actually looked, for the screen's small print. Null when no
  /// listing URL could be derived.
  final Uri? probedUrl;

  const ModelProbeResult({
    required this.reachable,
    this.modelIds = const [],
    this.error,
    this.probedUrl,
  });
}

/// Asks a server what it is serving.
///
/// Never throws — this is a settings screen's live status line, and a probe
/// that could fail a build would be worse than one that says "not reachable".
/// Five seconds, not the client's 120: a person is watching this one.
class ModelServerProbe {
  final http.Client _http;
  final Duration timeout;

  ModelServerProbe({
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 5),
  }) : _http = httpClient ?? http.Client();

  /// `…/v1/chat/completions` and `…/v1/embeddings` both list at `…/v1/models`.
  ///
  /// Static and pure so the derivation is pinned by tests without a socket:
  /// this is the part a hand-typed URL breaks on, and the failure it produces
  /// otherwise is an unexplained "not reachable" against a server that is up.
  static Uri? modelsUrlFor(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;

    final segments = [
      for (final segment in uri.pathSegments)
        if (segment.isNotEmpty) segment,
    ];

    // Everything after the LAST `/v1/` is the endpoint's own name; replace it.
    final versionAt = segments.lastIndexOf('v1');
    if (versionAt >= 0) {
      return _at(uri, [...segments.take(versionAt + 1), 'models']);
    }

    // A bare origin is a server someone has typed the host of and no more.
    if (segments.isEmpty) {
      return _at(uri, const ['v1', 'models']);
    }

    // A path this cannot read — an Ollama-native `/api/generate`, a typo.
    // Failing here is the honest answer; guessing would probe a stranger.
    return null;
  }

  /// [origin]'s authority with a new path, and nothing else.
  ///
  /// Built rather than `replace`d because `Uri.replace(query: null)` KEEPS the
  /// query it was given — null there means "unchanged", not "drop it" — and a
  /// completions URL's own query string and fragment belong to that endpoint,
  /// not to the listing derived from it.
  static Uri _at(Uri origin, List<String> pathSegments) => Uri(
        scheme: origin.scheme,
        userInfo: origin.userInfo.isEmpty ? null : origin.userInfo,
        host: origin.host,
        port: origin.hasPort ? origin.port : null,
        pathSegments: pathSegments,
      );

  Future<ModelProbeResult> probe(String completionsUrl) async {
    final url = modelsUrlFor(completionsUrl);
    if (url == null) {
      return const ModelProbeResult(
        reachable: false,
        error: 'Not a model server URL — expected something ending in /v1/…',
      );
    }

    final http.Response response;
    try {
      response = await _http
          .get(url, headers: const {'Accept': 'application/json'})
          .timeout(timeout);
    } on SocketException {
      return ModelProbeResult(
        reachable: false,
        probedUrl: url,
        error: 'Nothing is listening at ${url.host}:${url.port}',
      );
    } on http.ClientException {
      return ModelProbeResult(
        reachable: false,
        probedUrl: url,
        error: 'The connection to ${url.host}:${url.port} was dropped',
      );
    } on TimeoutException {
      return ModelProbeResult(
        reachable: false,
        probedUrl: url,
        error: 'No answer within ${timeout.inSeconds} seconds',
      );
    } catch (error) {
      // The whole point of "never throws". A probe is diagnostics; an
      // unexpected exception here must read as a bad answer, not crash a
      // settings screen.
      return ModelProbeResult(
        reachable: false,
        probedUrl: url,
        error: 'Could not read $url',
      );
    }

    if (response.statusCode != 200) {
      return ModelProbeResult(
        reachable: false,
        probedUrl: url,
        error: 'The server answered HTTP ${response.statusCode}',
      );
    }

    final Object? decoded;
    try {
      // utf8 on bodyBytes for `LlmClient._text`'s reason: llama-server sends
      // `application/json` with no charset and `body` falls back to latin-1.
      decoded =
          jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
    } on FormatException {
      return ModelProbeResult(
        reachable: false,
        probedUrl: url,
        error: 'The server answered with something that is not JSON',
      );
    }

    // `data` is the OpenAI shape every runtime here speaks; `models` is the
    // alias a couple of MLX-side servers use. Anything else is a 200 from
    // something that is not a model server.
    final list = decoded is Map
        ? (decoded['data'] is List
            ? decoded['data'] as List
            : (decoded['models'] is List ? decoded['models'] as List : null))
        : null;
    if (list == null) {
      return ModelProbeResult(
        reachable: false,
        probedUrl: url,
        error: 'The server listed no models',
      );
    }

    // An empty list is still a live server — it is reachable with nothing
    // loaded, which is a different thing from unreachable and the screen has
    // to be able to say so.
    return ModelProbeResult(
      reachable: true,
      probedUrl: url,
      modelIds: [
        for (final entry in list)
          if (entry is Map && entry['id'] is String)
            entry['id'] as String
          else if (entry is String)
            entry,
      ],
    );
  }

  void close() => _http.close();
}
