import 'dart:async';
import 'dart:io' show HttpHeaders, HttpStatus;

import 'package:http/http.dart' as http;

/// What Settings' **Check** under Model registry found.
enum RegistryCheck {
  /// The registry answered the file asked for with its bytes: 200 or 206,
  /// and not a web page. Said of the registry only once every model's file
  /// answered so.
  reachable,

  /// The registry answered with a redirect, which the probe does not follow
  /// (the token goes nowhere else): a download will follow it, hop by hop.
  redirected,

  /// A 200 or 206 carrying `text/html`: a sign-in or proxy page, never the
  /// model. The download fails the same answer as `registry_not_a_model`.
  notAModel,

  /// 401 or 403: no token, or one the registry refused.
  unauthorized,

  /// 404: the address is a registry, but not the one holding this model.
  notFound,

  /// Nothing listening, a timeout, or any other answer.
  unreachable,

  /// No registry address anywhere, so nothing was asked.
  notConfigured,
}

/// One look at the model registry: a `GET` of [url] (one model's file: the
/// embedding model's GGUF, the decision model's small heads file) for its
/// FIRST byte, with the bearer when there is one.
///
/// Never throws: this is a settings screen's status line. Redirects are not
/// followed, so the token rides to [url]'s own origin and nowhere else; a
/// redirect is said as one, because the probe cannot know whether it leads to
/// object storage or to a sign-in page. [token] is a SECRET: it goes into the header and nowhere else,
/// never into a result, a log line or an exception.
Future<RegistryCheck> probeRegistry({
  required Uri url,
  String? token,
  required http.Client client,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final request = http.Request('GET', url)..followRedirects = false;
  request.headers[HttpHeaders.rangeHeader] = 'bytes=0-0';
  if (token != null && token.isNotEmpty) {
    request.headers[HttpHeaders.authorizationHeader] = 'Bearer $token';
  }
  final http.StreamedResponse response;
  try {
    response = await client.send(request).timeout(timeout);
  } on Object {
    return RegistryCheck.unreachable;
  }
  // The body is a byte at most, or a page nobody reads: let it go.
  unawaited(response.stream.listen((_) {}, onError: (Object _) {}).cancel());
  final code = response.statusCode;
  if (code == HttpStatus.ok || code == HttpStatus.partialContent) {
    final type =
        (response.headers[HttpHeaders.contentTypeHeader] ?? '').trim();
    return type.toLowerCase().startsWith('text/html')
        ? RegistryCheck.notAModel
        : RegistryCheck.reachable;
  }
  if (code >= 300 && code < 400) return RegistryCheck.redirected;
  if (code == HttpStatus.unauthorized || code == HttpStatus.forbidden) {
    return RegistryCheck.unauthorized;
  }
  if (code == HttpStatus.notFound) return RegistryCheck.notFound;
  return RegistryCheck.unreachable;
}
