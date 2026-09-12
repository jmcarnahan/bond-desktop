import 'dart:convert';
import 'dart:io';

/// A real socket that answers llama-server's router endpoints.
///
/// A real [HttpServer] rather than a fake `http.Client`, for
/// `FakeLlamaServer`'s reason: the supervisor's readiness rule is a
/// conversation with two endpoints whose answers disagree on purpose —
/// `/health` is 503 for the whole time `/models` is reporting progress — and
/// a scripted client would let a supervisor that asked the wrong one pass.
class FakeRouterServer {
  FakeRouterServer._(this._server) {
    _server.listen(_handle);
  }

  final HttpServer _server;

  static Future<FakeRouterServer> start() async =>
      FakeRouterServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  int get port => _server.port;

  /// Model id to whether its weights are resident. The supervisor's loading
  /// progress is exactly this map.
  Map<String, bool> loaded = {};

  /// Whether `/health` answers 200. False is 503, which is what the real
  /// server sends while a model is still being mapped — and, once it has
  /// been ready, what a wedged server sends.
  bool healthy = true;

  /// How many requests have been served, for a test asserting that polling
  /// stopped.
  int requests = 0;

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    requests++;
    switch (request.uri.path) {
      case '/models':
        final body = utf8.encode(jsonEncode({
          'data': [
            for (final entry in loaded.entries)
              {
                'id': entry.key,
                'status': {'value': entry.value ? 'loaded' : 'unloaded'},
              },
          ],
        }));
        request.response.statusCode = HttpStatus.ok;
        request.response.headers
            .set(HttpHeaders.contentTypeHeader, 'application/json');
        request.response.headers.contentLength = body.length;
        request.response.add(body);
      case '/health':
        request.response.statusCode =
            healthy ? HttpStatus.ok : HttpStatus.serviceUnavailable;
        request.response.write(healthy ? '{"status":"ok"}' : 'loading');
      default:
        request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  }
}
