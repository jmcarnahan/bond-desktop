import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A real socket that answers like llama-server, so `LlmClient` can be tested
/// as itself rather than subclassed away.
///
/// The alternative — a fake `http.Client` — cannot see the two things that
/// have actually broken here: the request body this app puts on the wire, and
/// the response encoding. llama-server sends `application/json` with NO
/// charset, which makes `http`'s `body` getter fall back to latin-1; this
/// server reproduces that exactly, so a regression away from `bodyBytes`
/// fails a test instead of mangling one sender's name in production.
class FakeLlamaServer {
  final HttpServer _server;

  /// Every decoded request body, in the order they arrived.
  final List<Map<String, dynamic>> requests = [];

  /// `json_schema.name` → the answers to give, in order. The last entry
  /// repeats once the script runs out, which is what lets a drain of twenty
  /// messages be scripted with one line.
  final Map<String, List<Object>> _scripts = {};

  /// Applied before every response. A drain that must observe latency sets
  /// this; everything else leaves it at zero and runs in milliseconds.
  Duration delay = Duration.zero;

  FakeLlamaServer._(this._server) {
    _server.listen(_handle);
  }

  static Future<FakeLlamaServer> start() async =>
      FakeLlamaServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  /// What an `LlmClient` should be pointed at.
  String get chatUrl => 'http://127.0.0.1:${_server.port}/v1/chat/completions';

  /// Scripts the answers for one schema name.
  ///
  /// A step is one of:
  /// - `Map<String, dynamic>` — a 200 whose message content is that map,
  ///   JSON-encoded into a string, which is what a `json_schema` completion
  ///   actually returns.
  /// - [ScriptedReply] — the same, plus a `reasoning_content` field, for the
  ///   thinking tripwire.
  /// - `int` — that HTTP status, with a plain-text body.
  /// - [drop] — the socket closes with no response at all.
  void scriptFor(String schemaName, List<Object> steps) {
    _scripts[schemaName] = [...steps];
  }

  /// The step that hangs up mid-request — an `http.ClientException` on the
  /// client side, which is how a crashed model server presents.
  static const Symbol drop = #drop;

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();

    if (request.method != 'POST' ||
        request.uri.path != '/v1/chat/completions') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    try {
      final decoded = jsonDecode(body);
      final payload =
          decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      requests.add(payload);

      if (delay > Duration.zero) await Future<void>.delayed(delay);

      final step = _nextStep(_schemaNameOf(payload));

      if (step == drop) {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.destroy();
        return;
      }
      if (step is int) {
        request.response.statusCode = step;
        request.response.write('scripted status $step');
        await request.response.close();
        return;
      }

      final reply = step is ScriptedReply
          ? step
          : ScriptedReply(step as Map<String, dynamic>);
      await _respond(request.response, reply);
    } catch (error) {
      // A scripting mistake — a step of the wrong type, a body that is not
      // JSON — answers loudly and NOW. An exception that escaped this handler
      // would leave the socket open with nothing written, and the client would
      // wait out its full 120-second timeout to report the wrong failure.
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('fake server error: $error');
      await request.response.close();
    }
  }

  /// The name this app asked its answer to be constrained to. `result` is
  /// `LlmClient`'s own default, for a call that passed no schema name.
  static String _schemaNameOf(Map<String, dynamic> payload) {
    final format = payload['response_format'];
    if (format is! Map) return 'result';
    final schema = format['json_schema'];
    if (schema is! Map) return 'result';
    return schema['name'] as String? ?? 'result';
  }

  /// Consumes one step, leaving the last one in place so it repeats. An
  /// unscripted schema answers 400 rather than something plausible: a test
  /// that forgot a script should say so, and a 400 is the one status the
  /// queue never retries.
  Object _nextStep(String schemaName) {
    final steps = _scripts[schemaName];
    if (steps == null || steps.isEmpty) {
      return HttpStatus.badRequest;
    }
    return steps.length > 1 ? steps.removeAt(0) : steps.first;
  }

  /// Byte-for-byte the shape `LlmClient._post` parses, including the header
  /// that omits the charset.
  Future<void> _respond(HttpResponse response, ScriptedReply reply) async {
    final message = <String, dynamic>{
      'role': 'assistant',
      'content': jsonEncode(reply.content),
      if (reply.reasoningContent != null)
        'reasoning_content': reply.reasoningContent,
    };
    final bytes = utf8.encode(jsonEncode({
      'choices': [
        {'index': 0, 'message': message, 'finish_reason': 'stop'},
      ],
    }));

    response.statusCode = HttpStatus.ok;
    // Set as a raw string, not a `ContentType` with a charset: the real
    // server sends none, and that absence is what this fixture is for.
    response.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    response.headers.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }
}

/// One scripted 200, with the optional `reasoning_content` a model that
/// ignored `enable_thinking` would send back alongside its answer.
class ScriptedReply {
  final Map<String, dynamic> content;
  final String? reasoningContent;

  const ScriptedReply(this.content, {this.reasoningContent});
}
