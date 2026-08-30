import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:mcp_dart/mcp_dart.dart';

/// The app's one door onto the MCP wire.
///
/// Every `mcp_dart` import in this app lives in this file, deliberately: the
/// package is young and its transport dialect has moved between minor
/// versions, so a churn there must cost one file's review and nothing more.
/// Callers see [BondMcpClient] — a single method over JSON maps — and never a
/// package type.
///
/// The server this talks to is STATELESS. Its `Mcp-Session-Id` is a
/// per-connection convenience, not a durable handle, so a session the peer no
/// longer knows is a normal event and not an error worth showing anyone: the
/// answer is to re-initialize and repeat the call, which [BondMcpHttpClient]
/// does exactly once.

/// The call did not complete: JSON-RPC, HTTP, or a malformed result.
///
/// Held apart from [McpToolException] because the two mean opposite things to
/// a caller. This one is transient — retry, or report a connection problem.
class McpTransportException implements Exception {
  final String message;

  /// The HTTP status when the failure carried one. 404 specifically means the
  /// peer has forgotten the session; [BondMcpHttpClient] reads it.
  final int? statusCode;

  const McpTransportException(this.message, {this.statusCode});

  @override
  String toString() => statusCode == null
      ? 'MCP transport error: $message'
      : 'MCP transport error (HTTP $statusCode): $message';
}

/// The tool RAN and reported failure (`isError: true`).
///
/// Nothing about the connection is wrong; retrying the same call gets the same
/// answer. [message] is the tool's own text.
class McpToolException implements Exception {
  final String message;

  const McpToolException(this.message);

  @override
  String toString() => 'MCP tool error: $message';
}

/// One tool call, in and out as plain JSON.
///
/// Deliberately a single method: a fake is three lines, so every test that
/// needs one writes its own rather than sharing a helper.
abstract class BondMcpClient {
  /// Runs [name] with [args] and returns the tool's JSON object.
  ///
  /// Throws [McpToolException] when the tool itself failed, and
  /// [McpTransportException] for everything else.
  Future<Map<String, dynamic>> callTool(String name, Map<String, Object?> args);

  Future<void> close();
}

/// One live MCP connection, reduced to what a tool call needs.
///
/// This seam exists so tests can count connections and script failures without
/// a server — and so nothing outside this file has to know a `mcp_dart` type.
/// [callRaw] returns the tool result as WIRE JSON; interpreting it is
/// [decodeToolResult]'s job, which keeps that logic testable on its own.
abstract class McpToolSession {
  /// The raw `CallToolResult` JSON. Throws [McpTransportException] — with
  /// `statusCode: 404` when the peer has forgotten the session.
  Future<Map<String, dynamic>> callRaw(String name, Map<String, Object?> args);

  Future<void> dispose();
}

/// Opens a connection to [url], carrying [bearer] when one was available.
typedef McpSessionFactory = Future<McpToolSession> Function(
  Uri url,
  String? bearer,
);

/// What this client announces itself as during `initialize`.
const Implementation _clientInfo = Implementation(
  name: 'bond-inbox',
  version: '1.0.0',
);

/// The handshake dialect to speak.
///
/// [McpProtocol.legacy], not the package default: the server is FastMCP 3.x,
/// which speaks the pre-2026 `initialize` → `notifications/initialized` flow.
/// The default (`stable`) would spend a round trip on a `server/discover`
/// probe this peer cannot answer, then fall back to this anyway.
@visibleForTesting
McpClientOptions buildClientOptions() =>
    const McpClientOptions(protocol: McpProtocol.legacy);

/// The per-request headers a connection is opened with.
///
/// `Accept` naming both types is mandatory — the server answers 406 without
/// it, and tool results genuinely do arrive as SSE frames rather than JSON.
/// A null [bearer] means the local dev server, which wants no `Authorization`
/// header at all: sending an empty one is worse than sending none.
@visibleForTesting
Map<String, dynamic> buildRequestInit(String? bearer) => {
      'headers': <String, dynamic>{
        'Accept': 'application/json, text/event-stream',
        if (bearer != null && bearer.isNotEmpty) 'Authorization': 'Bearer $bearer',
      },
    };

/// Reads a tool result's wire JSON into the object the caller wanted.
///
/// Split out as a top-level function so the parsing rules can be tested
/// against literal payloads, with no client, transport, or server involved.
///
/// `isError` is checked BEFORE the content, and deliberately: a failing tool
/// may still carry a structured payload, and returning it would hand the
/// caller an error dressed as an answer.
Map<String, dynamic> decodeToolResult(Map<String, dynamic> raw) {
  if (raw['isError'] == true) {
    throw McpToolException(_firstText(raw) ?? 'The tool reported an error.');
  }

  final structured = raw['structuredContent'];
  if (structured is Map<String, dynamic>) return structured;
  if (structured is Map) return Map<String, dynamic>.from(structured);

  final text = _firstText(raw);
  if (text == null) {
    throw const McpTransportException(
      'The tool returned no structured content and no text to read.',
    );
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw McpTransportException('The tool returned text that is not JSON: $text');
  }
  if (decoded is Map<String, dynamic>) return decoded;
  if (decoded is Map) return Map<String, dynamic>.from(decoded);
  throw McpTransportException(
    'The tool returned JSON that is not an object: $text',
  );
}

/// The first text block's text, or null when there is none.
String? _firstText(Map<String, dynamic> raw) {
  final content = raw['content'];
  if (content is! List) return null;
  for (final block in content) {
    if (block is Map && block['type'] == 'text') {
      final text = block['text'];
      if (text is String) return text;
    }
  }
  return null;
}

/// Talks to an MCP server over streamable HTTP.
///
/// Connects lazily — nothing happens until the first [callTool] — because the
/// app builds one of these long before it knows whether the user is signed in.
class BondMcpHttpClient implements BondMcpClient {
  /// The `/mcp` endpoint, used verbatim apart from one trailing slash.
  ///
  /// The slash is stripped because FastMCP historically answered the trailing
  /// form with a 307, and a 307 through a proxy can arrive at the destination
  /// with the POST body gone.
  final Uri baseUrl;

  /// Asked for a token at every (re)connect, not once at construction: the
  /// JWT rotates, and a connection opened an hour later must carry the
  /// current one. Null — or no callback — means "send no Authorization",
  /// which is what the local dev server wants.
  final Future<String?> Function()? _getBearer;

  final McpSessionFactory _sessionFactory;

  McpToolSession? _session;

  /// Single-flight guard: two calls racing on a cold client must share one
  /// handshake, not open two connections.
  Future<McpToolSession>? _connecting;

  BondMcpHttpClient(
    Uri baseUrl, {
    Future<String?> Function()? getBearer,
    @visibleForTesting McpSessionFactory? sessionFactory,
  })  : baseUrl = _stripTrailingSlash(baseUrl),
        _getBearer = getBearer,
        _sessionFactory = sessionFactory ?? _openStreamableHttpSession;

  static Uri _stripTrailingSlash(Uri url) {
    final text = url.toString();
    return text.endsWith('/') ? Uri.parse(text.substring(0, text.length - 1)) : url;
  }

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, Object?> args,
  ) async {
    try {
      return decodeToolResult(await (await _liveSession()).callRaw(name, args));
    } on McpTransportException catch (e) {
      // A 404 is the stateless server saying it has never heard of this
      // session — expected after it restarts or load-balances elsewhere. Drop
      // the connection and run the call once more on a fresh handshake. A
      // second 404 is a real fault, not a stale session.
      if (e.statusCode != 404) rethrow;
      await _dropSession();
      return decodeToolResult(await (await _liveSession()).callRaw(name, args));
    }
  }

  /// The live session, connecting if there is none.
  Future<McpToolSession> _liveSession() {
    final existing = _session;
    if (existing != null) return Future.value(existing);
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<McpToolSession> _connect() async {
    final bearer = await _getBearer?.call();
    final session = await _sessionFactory(baseUrl, bearer);
    _session = session;
    return session;
  }

  Future<void> _dropSession() async {
    final session = _session;
    _session = null;
    // A dead session's close can itself fail; that must not mask the retry.
    try {
      await session?.dispose();
    } on Object {
      // Nothing to do — the connection is being abandoned either way.
    }
  }

  @override
  Future<void> close() => _dropSession();
}

/// The production session: a real `mcp_dart` client over streamable HTTP.
Future<McpToolSession> _openStreamableHttpSession(Uri url, String? bearer) async {
  final transport = StreamableHttpClientTransport(
    url,
    opts: StreamableHttpClientTransportOptions(
      requestInit: buildRequestInit(bearer),
    ),
  );
  final client = McpClient(_clientInfo, options: buildClientOptions());
  try {
    await client.connect(transport);
  } on Object catch (e) {
    throw _asTransportException(e);
  }
  return _McpDartSession(client);
}

class _McpDartSession implements McpToolSession {
  final McpClient _client;

  _McpDartSession(this._client);

  @override
  Future<Map<String, dynamic>> callRaw(
    String name,
    Map<String, Object?> args,
  ) async {
    try {
      final result = await _client.callTool(
        CallToolRequest(name: name, arguments: Map<String, dynamic>.from(args)),
      );
      return result.toJson();
    } on Object catch (e) {
      throw _asTransportException(e);
    }
  }

  @override
  Future<void> dispose() => _client.close();
}

/// Translates every `mcp_dart` failure into this file's own vocabulary, so no
/// package type escapes past [BondMcpClient].
///
/// The status code matters in exactly one case — a stale session arrives as
/// 404 and is the caller's cue to reconnect — so it is carried through rather
/// than flattened into the message.
McpTransportException _asTransportException(Object error) {
  if (error is McpTransportException) return error;
  if (error is StaleSessionError) {
    return McpTransportException(error.message, statusCode: error.code ?? 404);
  }
  if (error is StreamableHttpError) {
    return McpTransportException(error.message, statusCode: error.code);
  }
  if (error is McpError) return McpTransportException(error.message);
  return McpTransportException(error.toString());
}
