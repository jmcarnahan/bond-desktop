import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart'
    show debugPrint, immutable, visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../backend/auth_session.dart';
import '../backend/backend_types.dart';
import '../pkce.dart';
import '../token_store.dart';
import 'bond_mcp_client.dart';

/// Sign-in against the bond-mcps platform: OAuth 2.1 + PKCE against whichever
/// authorization server the MCP endpoint names, with the resulting JWT
/// presented to the MCP server as a bearer token.
///
/// Two shapes of server are supported by the SAME code path, decided by asking
/// rather than by configuration. The deployed platform answers an
/// unauthenticated request with 401 and a pointer to its metadata; the local
/// `make dev` server answers normally and wants no token at all. So sign-in
/// PROBES first and only runs OAuth when it is actually challenged — a
/// developer running locally is never sent to a browser.
///
/// Nothing here is Microsoft-specific. Connecting a Microsoft account is a
/// separate step the platform owns, surfaced through [needsReconsent] and
/// [microsoftConnectUrl]; a user can be legitimately signed IN here while
/// having connected nothing yet.
///
/// This app is pre-registered nowhere. When the authorization server's
/// metadata advertises an RFC 7591 `registration_endpoint` — every bond-mcps
/// one does — each interactive sign-in registers a fresh public client naming
/// the loopback URI the browser will come back to, and the id that comes back
/// carries the authorize round, the code exchange and every later refresh.
/// Only a server advertising no registration endpoint falls back to the
/// pre-registered [McpAuthSession.staticClientId] on its fixed port. That
/// fallback is the whole of what an operator ever has to seed, and no
/// bond-mcps deployment needs it.
///
/// The JWT lives in memory only. Only the rotating refresh token, the client
/// id it was issued to, the account summary, and the local-mode flag are
/// persisted — and they are persisted PER SERVER, under keys derived from the
/// canonical MCP URL (see [slotFor]). A session belongs to the endpoint it was
/// obtained from: pointing the app at another server switches to that server's
/// own slot, which either holds a session or does not, and destroys neither.
/// Switching between this backend and the direct-Graph one is likewise
/// lossless — those keys are the SDK session's and are never touched here.
///
/// Three rules keep a session from being lost to plumbing rather than to the
/// server's judgement. Every write to a slot's keychain pair is serialized
/// through one lock (see `_withSlot`), so a sign-in, a sign-out and a refresh
/// racing each other cannot leave the pair mismatched. A refresh whose request
/// failed on the wire or timed out is retried exactly once, because the
/// authorization server honours a rotation whose response was lost while the
/// successor is unused — so the retry is what makes an interrupted refresh
/// invisible. And every HTTP call this file makes carries a timeout, because a
/// hung refresh used to pin the single-flight guard until the app was
/// relaunched.

/// A request that never reached a server, or never came back: a dropped
/// connection, an unresolvable host, a timeout.
///
/// An [AuthException] to every caller — the message is the same one the
/// transport failure always produced — and private on purpose. Only the
/// refresh path tells it apart from a server's own answer, because only a
/// failure of this shape is worth retrying: a request that may never have
/// arrived. An HTTP status is the server's judgement and is never retried.
class _TransportFailure extends AuthException {
  const _TransportFailure(super.message);
}

/// One token exchange's outcome. `invalid_grant` has to be told apart from
/// every other non-200: the first means the session is over, the rest are
/// transient and must leave the stored refresh token alone.
@immutable
class _TokenResponse {
  final int statusCode;
  final Map<String, dynamic> json;

  const _TokenResponse(this.statusCode, this.json);
}

/// The authorization-server endpoints this flow uses, discovered together.
@immutable
class _AuthServerEndpoints {
  final Uri authorize;
  final Uri token;

  /// RFC 7591 dynamic client registration, when the server publishes one.
  ///
  /// Null means it offers no registration at all, and the pre-registered
  /// static client is then the only way in.
  final Uri? register;

  const _AuthServerEndpoints(this.authorize, this.token, this.register);
}

/// Pulls the RFC 9728 protected-resource-metadata URL out of a
/// `WWW-Authenticate` challenge.
///
/// The URL is READ, never constructed: this deployment serves it at
/// `/.well-known/oauth-protected-resource/mcp`, with the resource path as a
/// SUFFIX, which is not what a naive `<origin>/.well-known/...` guess would
/// build. Other challenge parameters may sit either side of it and either
/// quote style is tolerated.
@visibleForTesting
Uri? resourceMetadataUrlFrom(String? header) {
  if (header == null || header.isEmpty) return null;
  final match = RegExp(
    r'''resource_metadata\s*=\s*(?:"([^"]*)"|'([^']*)'|([^,\s]+))''',
    caseSensitive: false,
  ).firstMatch(header);
  if (match == null) return null;
  final value = match.group(1) ?? match.group(2) ?? match.group(3);
  if (value == null || value.isEmpty) return null;
  return Uri.tryParse(value);
}

class McpAuthSession implements AuthSession {
  /// The pre-registered public client, and the FALLBACK: presented only
  /// against an authorization server whose metadata advertises no RFC 7591
  /// `registration_endpoint`. Every bond-mcps server advertises one, so the
  /// everyday path registers this app itself, per sign-in, and this id is
  /// never sent. There is no secret and there never will be one — the
  /// authorization server advertises
  /// `token_endpoint_auth_methods_supported: ["none"]`.
  ///
  /// Also what a refresh presents when the slot holds no client id: a session
  /// signed in before ids were stored was issued to this client, and must keep
  /// refreshing as it rather than be pushed through a sign-in it does not
  /// need. That is the upgrade path.
  static const String staticClientId = 'bond-desktop';

  /// Registered byte for byte with whichever server knows [staticClientId]; it
  /// must match in BOTH the authorize and the token request. A registering
  /// sign-in names the port it actually bound instead.
  static const String staticRedirectUri = 'http://127.0.0.1:8766/callback';

  /// Fixed by the redirect above — on the fallback path there is no other port
  /// to move to. A registering sign-in binds an ephemeral one (RFC 8252 §7.3)
  /// and tells the server which one it got.
  static const int staticRedirectPort = 8766;

  /// The `client_name` a registration carries: what an operator reading the
  /// authorization server's clients table sees.
  static const String clientName = 'Bond Desktop';

  /// Where the browser is sent back to, on whichever loopback port is in use.
  static const String callbackPath = '/callback';

  /// The pre-slot global keys. Read by no code path any more — kept only so
  /// [_retireLegacyKeys] can name them.
  ///
  /// Deliberately NOT migrated into a slot. Whichever server they came from is
  /// exactly what they do not record, and a local-mode flag adopted into a
  /// deployed server's slot recreates the half-state this scheme exists to
  /// kill. One sign-in per server after this update is the entire migration
  /// cost.
  static const List<String> _legacyKeys = [
    'mcp_refresh_token',
    'mcp_account_json',
    'mcp_local_mode',
  ];

  /// A token this close to expiry is treated as already expired, so a request
  /// started now cannot arrive after it dies.
  static const Duration _expiryMargin = Duration(minutes: 5);

  /// A browser round trip that has not come back by now is abandoned.
  static const Duration _callbackTimeout = Duration(minutes: 5);

  /// How long a `connection_status` answer is trusted.
  ///
  /// Short on purpose: the status is a PROBE, not an authority. The platform
  /// can report a connection down for a moment, and a long cache would leave
  /// the UI insisting on a reconnect the user has already done.
  static const Duration _statusCacheTtl = Duration(seconds: 30);

  /// Which granted scope stands in for a scope this app wants.
  ///
  /// Pairs from Microsoft's own consent hierarchy — `Mail.ReadWrite` includes
  /// `Mail.Read`, `Chat.ReadWrite` includes `Chat.Read`, and both
  /// `User.Read.All` and `Directory.Read.All` include `User.ReadBasic.All` —
  /// and nothing else; deliberately not a general lattice. The chat pair
  /// matters because the platform's admin grant is `Chat.ReadWrite`, while
  /// this app asks the read-only question. The directory pair matters for the
  /// same reason one step further out: an admin usually grants the wider read,
  /// and without it the app would hide a directory the server would serve.
  /// Duplicated from `GraphAuth` rather than shared: the copy there is
  /// private, and two sessions agreeing by coincidence is cheaper than a
  /// shared constant that invites unrelated entries.
  static const Map<String, Set<String>> _subsumedBy = {
    'mail.read': {'mail.readwrite'},
    'chat.read': {'chat.readwrite'},
    'user.readbasic.all': {'user.read.all', 'directory.read.all'},
  };

  /// The `/mcp` endpoint. Also the RFC 8707 `resource` value: the JWT's `aud`
  /// must equal this exact string or every MCP call comes back 401.
  final Uri mcpUrl;

  final BondMcpClient _mcp;
  final http.Client _http;
  final TokenStore _store;
  final Future<bool> Function(Uri url) _openBrowser;

  /// How long any single HTTP call here waits before it is abandoned. A hung
  /// request must not pin the refresh guard until the app is relaunched.
  final Duration _requestTimeout;

  /// How long the refresh waits before its one retry. Zero in tests.
  final Duration _refreshRetryDelay;

  /// In memory only, deliberately: a leaked JWT is short-lived, while a leaked
  /// refresh token is not.
  String? _jwt;
  DateTime? _jwtExpiry;

  /// Discovered at sign-in and kept for the process's life, so a refresh does
  /// not re-walk the discovery chain on every token. Empty after a relaunch,
  /// which is why the refresh path can re-discover on demand.
  Uri? _tokenEndpoint;

  /// Single-flight guard for [validJwt]. Refresh tokens ROTATE here, so a
  /// second concurrent exchange would race on an already-consumed one.
  Future<String?>? _refreshInFlight;

  /// The tail of the chain of everything queued on this slot's lock. See
  /// [_withSlot].
  Future<void> _slotLock = Future<void>.value();

  Map<String, dynamic>? _statusCache;
  DateTime? _statusCachedAt;

  McpAuthSession({
    required Uri mcpUrl,
    required BondMcpClient mcpClient,
    http.Client? httpClient,
    TokenStore? store,
    Future<bool> Function(Uri url)? openBrowser,
    // Null rather than a defaulted parameter, like [httpClient] and [store]
    // above: the fields behind them are private, so an initializing formal —
    // which is what the analyzer asks for when a parameter is copied straight
    // into a field — is not spellable for a named parameter.
    Duration? requestTimeout,
    Duration? refreshRetryDelay,
  })  : mcpUrl = _canonical(mcpUrl),
        _mcp = mcpClient,
        _http = httpClient ?? http.Client(),
        _store = store ?? const SecureTokenStore(),
        _openBrowser = openBrowser ?? _launchInSystemBrowser,
        _requestTimeout = requestTimeout ?? const Duration(seconds: 30),
        _refreshRetryDelay = refreshRetryDelay ?? const Duration(seconds: 1) {
    // Fire-and-forget: nothing waits on the old keys going away, and a
    // keychain that refuses the write leaves three dead entries behind rather
    // than failing a session that is otherwise fine.
    unawaited(_retireLegacyKeys());
  }

  /// Which keychain slot this server's session lives in.
  ///
  /// A digest rather than the URL itself: keychain items are named, not
  /// escaped, and a URL carries characters and a length no key format should
  /// have to promise to survive. Sixteen hex chars is 64 bits — collisions
  /// between the two or three endpoints one install ever sees are not a
  /// concern, and a collision would cost a sign-in, not correctness.
  ///
  /// Takes the CANONICAL url ([mcpUrl]), so `…/mcp` and `…/mcp/` are one
  /// server with one session rather than two.
  @visibleForTesting
  static String slotFor(Uri canonicalUrl) => sha256
      .convert(utf8.encode(canonicalUrl.toString()))
      .toString()
      .substring(0, 16);

  late final String _slot = slotFor(mcpUrl);

  String get _keyRefreshToken => 'mcp_rt_$_slot';
  String get _keyAccountJson => 'mcp_account_$_slot';
  String get _keyLocalMode => 'mcp_local_$_slot';

  /// The client this slot's refresh token was issued to. Lives and dies with
  /// that token: the authorization server binds the two, and presenting the
  /// wrong client is `invalid_grant`.
  String get _keyClientId => 'mcp_client_$_slot';

  @visibleForTesting
  String get refreshTokenKey => _keyRefreshToken;

  @visibleForTesting
  String get accountJsonKey => _keyAccountJson;

  @visibleForTesting
  String get localModeKey => _keyLocalMode;

  @visibleForTesting
  String get clientIdKey => _keyClientId;

  /// Deletes the pre-slot global keys, once per session construction.
  ///
  /// They are retired rather than migrated because they do not say which
  /// server they belong to — see [_legacyKeys].
  ///
  /// Swallows everything, because nobody is awaiting it: this is housekeeping
  /// running unwatched off a constructor, and a store that cannot be written
  /// (a locked keychain, a test with no platform channel) must leave three
  /// dead entries behind rather than raise an unhandled error into whatever
  /// happened to be running.
  Future<void> _retireLegacyKeys() async {
    try {
      for (final key in _legacyKeys) {
        await _store.write(key, null);
      }
    } on Object {
      // Nothing reads these keys any more; failing to delete them costs
      // nothing but the bytes.
    }
  }

  /// The canonical resource string: one trailing slash removed, nothing else
  /// touched. `aud` is compared byte for byte, so this must be stable between
  /// the authorize request, the token request, and the MCP calls themselves.
  static Uri _canonical(Uri url) {
    final text = url.toString();
    return text.endsWith('/') ? Uri.parse(text.substring(0, text.length - 1)) : url;
  }

  /// The system browser, not a webview: it already holds whatever session the
  /// identity provider needs.
  static Future<bool> _launchInSystemBrowser(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  /// Runs [body] with exclusive use of this slot's keychain pair.
  ///
  /// Serializes every write to the pair — the client id and the refresh token
  /// — across all four writers: a refresh, the tail of a sign-in, a local
  /// sign-in, and a clear. Refresh tokens ROTATE, so two interleaved writers
  /// can leave the slot holding a pair the server has already retired: a
  /// sign-in that stored its new pair a moment before a refresh in flight
  /// stored the old session's rotated one costs the user the session they just
  /// signed in to. Correctness here must not depend on which buttons the UI
  /// happens to render at once.
  ///
  /// The browser round is deliberately OUTSIDE this: it is an unbounded user
  /// action, and holding the lock across it would block every [validJwt] for
  /// as long as someone leaves the sign-in page open.
  ///
  /// The chain future is completed by `whenComplete` and so always completes
  /// NORMALLY: a body that throws hands its error to its own caller and never
  /// poisons the next waiter.
  Future<T> _withSlot<T>(Future<T> Function() body) {
    final previous = _slotLock;
    final released = Completer<void>();
    _slotLock = released.future;
    return previous.then((_) => body()).whenComplete(released.complete);
  }

  // ── State ─────────────────────────────────────────────────────────────

  /// Signed in either way: a refresh token from the deployed platform, or the
  /// local-mode flag from a dev server that asked for nothing.
  ///
  /// Never throws — a keychain that refuses a read reports "not signed in",
  /// which is recoverable, rather than taking down whatever asked.
  @override
  Future<bool> get isSignedIn async {
    final refreshToken = await _store.read(_keyRefreshToken);
    if (refreshToken != null && refreshToken.isNotEmpty) return true;
    return await _store.read(_keyLocalMode) == '1';
  }

  /// True when the platform says no Microsoft account is connected — the one
  /// thing an interactive step can fix.
  ///
  /// A probe that FAILS answers false. A dropped network or a restarting
  /// server must not read as "you need to reconnect", which would push a
  /// perfectly good session into a reconnect loop.
  @override
  Future<bool> get needsReconsent async {
    final status = await _connectionStatus();
    if (status == null) return false;
    if (status['error'] == 'not_connected') return true;
    return status['connected'] == false;
  }

  /// Whether the connected account carries [bareScope].
  ///
  /// Reads the GRANT the platform reports, never a requested list.
  @override
  Future<bool> hasScope(String bareScope) async {
    final status = await _connectionStatus();
    if (status == null) return false;
    if (status['error'] == 'not_connected') return false;
    if (status['connected'] != true) return false;

    final raw = status['scopes'];
    final granted = <String>{
      for (final scope in raw is List ? raw : const [])
        if (scope is String && scope.isNotEmpty) scope.toLowerCase(),
    };

    // A connected account with no scopes recorded is a row that predates the
    // platform storing them. Those grants were all mail-only, so mail scopes
    // are answered true and everything else false — the same answer the app
    // would get if it asked the real grant.
    if (granted.isEmpty) return bareScope.toLowerCase().startsWith('mail.');

    final wanted = bareScope.toLowerCase();
    return granted.contains(wanted) ||
        (_subsumedBy[wanted]?.any(granted.contains) ?? false);
  }

  /// The stored account summary, falling back to whatever the JWT itself says.
  ///
  /// The fallback matters: a user who has signed in but not yet connected
  /// Microsoft has no profile to store, and the header still has to name them.
  @override
  Future<AccountInfo?> get storedAccount async {
    final raw = await _store.read(_keyAccountJson);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return AccountInfo.fromJson(decoded);
      } on FormatException {
        // Unreadable storage is not fatal — fall through to the JWT claims.
      }
    }
    final jwt = _jwt;
    return jwt == null ? null : _accountFromClaims(decodeJwtPayload(jwt));
  }

  /// Ends the session.
  ///
  /// Clears THIS server's four keys one by one rather than wiping the store:
  /// a `deleteAll` here would take the direct-Graph session and every other
  /// server's slot with it.
  /// Wiping the local mail database is not done here either — that belongs to
  /// the sign-out call site, which runs it for whichever session is active.
  @override
  Future<void> signOut() => _clear();

  /// Drops the cached `connection_status`, so the next question hits the
  /// server. Called after a connect flow, where the 30-second cache would
  /// otherwise keep reporting the pre-connect answer.
  void invalidateStatusCache() {
    _statusCache = null;
    _statusCachedAt = null;
  }

  /// Where to send the user to connect a Microsoft account, when the platform
  /// offers one. Always a fresh read — this is asked at the moment the user
  /// clicks, and a stale URL is worse than a slow one.
  Future<String?> microsoftConnectUrl() async {
    final status = await _connectionStatus(bypassCache: true);
    final url = status?['connect_url'];
    return url is String && url.isNotEmpty ? url : null;
  }

  // ── Sign-in ───────────────────────────────────────────────────────────

  @override
  Future<AccountInfo> signIn() async {
    final resourceMetadataUrl = await _probeAuthChallenge();
    return resourceMetadataUrl == null
        ? _signInLocal()
        : _signInWithAuthServer(resourceMetadataUrl);
  }

  /// Asks the MCP endpoint whether it wants a token, by making the request a
  /// real client would make.
  ///
  /// A bare GET is the wrong instrument, and the reason is specific: FastMCP
  /// refuses a GET at `/mcp` with 405 BEFORE its authentication layer ever
  /// runs, so the deployed platform — which challenges every real request —
  /// answers a GET exactly as an unprotected server would. Read as "no auth
  /// wall", that 405 stamped a live deployment as a local dev box and left the
  /// app "signed in" with no bearer and a 401 behind every call. The probe is
  /// therefore the initialize POST itself, which every MCP server has to route
  /// through whatever guards it.
  ///
  /// Fail closed. Local mode is entered ONLY on a definitive 2xx, and a 401
  /// carrying a challenge is the other definitive answer; every other status
  /// is an error, because a server that neither granted access nor asked for a
  /// sign-in has told us nothing, and guessing is what produced the bug above.
  /// Ambiguity is an error here, never an answer.
  Future<Uri?> _probeAuthChallenge() async {
    final http.Response response;
    try {
      response = await _http.post(
        mcpUrl,
        headers: const {
          'Content-Type': 'application/json',
          'Accept': 'application/json, text/event-stream',
        },
        body: jsonEncode(const {
          'jsonrpc': '2.0',
          'id': 0,
          'method': 'initialize',
          'params': {
            'protocolVersion': '2025-03-26',
            'capabilities': <String, Object?>{},
            'clientInfo': {'name': 'bond-inbox-probe', 'version': '1.0.0'},
          },
        }),
      ).timeout(_requestTimeout);
    } on http.ClientException catch (e) {
      throw _TransportFailure('Could not reach the MCP server: ${e.message}');
    } on SocketException catch (e) {
      throw _TransportFailure('Could not reach the MCP server: ${e.message}');
    } on TimeoutException {
      throw _TransportFailure(
        'Could not reach the MCP server: timed out after '
        '${_describeDuration(_requestTimeout)}',
      );
    }

    if (response.statusCode == HttpStatus.unauthorized) {
      final url = resourceMetadataUrlFrom(response.headers['www-authenticate']);
      if (url == null) {
        throw const AuthException(
          'The MCP server asked for a sign-in but did not say where to get one.',
        );
      }
      return url;
    }

    if (response.statusCode >= 200 && response.statusCode < 300) return null;

    throw AuthException(
      'The Bond server at $mcpUrl answered HTTP ${response.statusCode} to the '
      'sign-in probe — it neither granted access nor asked for a sign-in. '
      'Check the server URL.',
    );
  }

  /// The dev-server path: nothing to authorize, so record that and try to name
  /// the user from whatever the server already knows.
  ///
  /// The writes run under the slot lock like every other writer's: this path
  /// DELETES the pair a refresh in flight is about to rewrite, and the two
  /// orders are not the same session. The profile fetch runs OUTSIDE it, on
  /// purpose: it goes through the MCP client, whose bearer hook calls back
  /// into [validJwt], and a lock held across a call that can re-enter it is a
  /// deadlock waiting for the one day the early return does not fire.
  Future<AccountInfo> _signInLocal() async {
    await _withSlot(() async {
      await _store.write(_keyLocalMode, '1');
      // The two markers are mutually exclusive states of ONE session within
      // this server's slot — and one server can change nature between
      // restarts, a local dev box rebooted with auth on being the everyday
      // case. A refresh token left over from an earlier deployed-shaped
      // sign-in AT THIS SAME URL would win over the local-mode flag in
      // [validJwt] and send a refresh at a server with no token endpoint to
      // discover — breaking every call until a sign-out.
      _jwt = null;
      _jwtExpiry = null;
      await _store.write(_keyRefreshToken, null);
      // The client id goes with it: it is only ever the one that refresh
      // token was issued to, and a local session has no token to refresh.
      await _store.write(_keyClientId, null);
    });
    final account = await _profileAccount();
    if (account == null) return const AccountInfo(displayName: 'Local session');
    await _store.write(_keyAccountJson, jsonEncode(account.toJson()));
    return account;
  }

  Future<AccountInfo> _signInWithAuthServer(Uri resourceMetadataUrl) async {
    final endpoints = await _discoverEndpoints(resourceMetadataUrl);
    _tokenEndpoint = endpoints.token;
    final registerAt = endpoints.register;

    // Bound BEFORE registering: the registration must name the exact loopback
    // URI the browser will come back to, and on that path the port is whatever
    // the OS hands out. Without registration the port is the static client's.
    final server =
        await _bindCallbackListener(registerAt == null ? staticRedirectPort : 0);
    final String clientId;
    final String redirectUri;
    final String code;
    final verifier = randomUrlSafe(64);
    try {
      // One decision, made once: which client this sign-in is and where the
      // browser comes back to. Both go into the authorize request AND the
      // token request, and the two requests have to agree byte for byte.
      if (registerAt == null) {
        clientId = staticClientId;
        redirectUri = staticRedirectUri;
      } else {
        redirectUri = 'http://127.0.0.1:${server.port}$callbackPath';
        clientId = await _registerClient(registerAt, redirectUri);
      }
      code = await _authorizeRound(
        server: server,
        authorizeEndpoint: endpoints.authorize,
        clientId: clientId,
        redirectUri: redirectUri,
        challenge: pkceChallengeFor(verifier),
        state: randomUrlSafe(32),
      );
    } finally {
      // Unconditional: an abandoned sign-in must not hold the port for the
      // rest of the process's life.
      await server.close(force: true);
    }

    // Everything from here that TOUCHES the slot runs under its lock, and the
    // browser round above deliberately did not: a refresh that started before
    // this sign-in must land before it, or the session the user just created
    // is overwritten by the rotated pair of the one they replaced.
    final jwt = await _withSlot(() async {
      final response = await _postForm(endpoints.token, {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirectUri,
        'client_id': clientId,
        'code_verifier': verifier,
        // RFC 8707, and not optional: the token this omits comes back with an
        // `aud` the MCP server will not accept.
        'resource': mcpUrl.toString(),
      });
      if (response.statusCode != 200) {
        throw AuthException(_describeTokenError(response));
      }
      final jwt = await _adoptTokens(response.json, clientId: clientId);
      // The mirror of the clearing in [_signInLocal], and for the same reason
      // within this server's slot: a stale local-mode flag would let
      // [validJwt] answer "no bearer needed" the day the refresh token is
      // gone, instead of the honest NotSignedIn.
      await _store.write(_keyLocalMode, null);
      return jwt;
    });

    // A profile the platform cannot give us is not a failed sign-in: the user
    // simply has not connected Microsoft yet. Name them from the JWT and let
    // the UI offer the connect step.
    final account = await _profileAccount();
    if (account != null) {
      await _store.write(_keyAccountJson, jsonEncode(account.toJson()));
      return account;
    }
    return _accountFromClaims(decodeJwtPayload(jwt)) ??
        const AccountInfo(displayName: 'Signed in');
  }

  /// Walks the discovery chain: challenge → protected-resource metadata →
  /// authorization-server metadata.
  ///
  /// One method, used by both sign-in (which already holds the challenge) and
  /// a post-relaunch refresh (which does not and re-probes to get it).
  Future<_AuthServerEndpoints> _discoverEndpoints([
    Uri? resourceMetadataUrl,
  ]) async {
    final metadataUrl = resourceMetadataUrl ?? await _probeAuthChallenge();
    if (metadataUrl == null) {
      throw const AuthException(
        'The MCP server is not asking for a sign-in, so there is no '
        'authorization server to talk to.',
      );
    }

    final metadata = await _getJson(
      metadataUrl,
      'the MCP server\'s protected-resource metadata',
    );
    final servers = metadata['authorization_servers'];
    final issuer = servers is List && servers.isNotEmpty ? servers.first : null;
    if (issuer is! String || issuer.isEmpty) {
      throw const AuthException(
        'The MCP server did not name an authorization server to sign in with.',
      );
    }

    // RFC 8414: the issuer's well-known document, which is where the real
    // endpoint paths live — they are not guessable from the issuer.
    final asMetadata = await _getJson(
      Uri.parse('${_trimSlash(issuer)}/.well-known/oauth-authorization-server'),
      'the authorization server\'s metadata',
    );
    final authorize = asMetadata['authorization_endpoint'];
    final token = asMetadata['token_endpoint'];
    if (authorize is! String || token is! String) {
      throw const AuthException(
        'The authorization server did not publish the endpoints needed to '
        'sign in.',
      );
    }
    // Optional by design: a server that publishes no registration endpoint is
    // not broken, it simply has to have been told about this app in advance.
    // Only an http(s) URL counts, because `tryParse` accepts almost anything:
    // a relative path or a `urn:` here is a malformed document, and posting to
    // it would throw an ArgumentError out of the HTTP client rather than say
    // what is wrong. Anything else reads as "no registration offered", which
    // is the one situation the static fallback exists for.
    final register = asMetadata['registration_endpoint'];
    final registerUri = register is String ? Uri.tryParse(register) : null;
    final registerIsHttp = registerUri != null &&
        (registerUri.isScheme('http') || registerUri.isScheme('https'));
    return _AuthServerEndpoints(
      Uri.parse(authorize),
      Uri.parse(token),
      registerIsHttp ? registerUri : null,
    );
  }

  /// Registers this app as a public client (RFC 7591) and returns its id.
  ///
  /// No secret is asked for and none would ever be kept: the authorization
  /// server advertises `token_endpoint_auth_methods_supported: ["none"]` and
  /// registers what this sends as a public client.
  ///
  /// Fresh on every interactive sign-in, on purpose. A stored registration
  /// cannot be checked cheaply — an id the server has forgotten is answered
  /// with a 400 in the BROWSER, which this app never sees, so the user would
  /// sit out the callback timeout — and the URI it was registered with names a
  /// loopback port that will not be free next time.
  Future<String> _registerClient(Uri endpoint, String redirectUri) async {
    final http.Response response;
    try {
      response = await _http.post(
        endpoint,
        headers: const {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'client_name': clientName,
          'redirect_uris': [redirectUri],
          'grant_types': ['authorization_code', 'refresh_token'],
          'response_types': ['code'],
          'token_endpoint_auth_method': 'none',
        }),
      ).timeout(_requestTimeout);
    } on http.ClientException catch (e) {
      throw _TransportFailure(
        'Could not reach the sign-in service to register this app: '
        '${e.message}',
      );
    } on SocketException catch (e) {
      throw _TransportFailure(
        'Could not reach the sign-in service to register this app: '
        '${e.message}',
      );
    } on TimeoutException {
      throw _TransportFailure(
        'Could not reach the sign-in service to register this app: timed out '
        'after ${_describeDuration(_requestTimeout)}',
      );
    }

    final json = _decodeJsonObject(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Read, never cast: this is the least predictable reply in the flow — a
      // gateway's own error page is JSON too, in whatever shape it likes.
      final description = json['error_description'];
      final error = json['error'];
      final detail = description is String && description.isNotEmpty
          ? description
          : error is String && error.isNotEmpty
              ? error
              : 'HTTP ${response.statusCode}';
      throw AuthException(
        'The authorization server refused to register this app: $detail',
      );
    }

    final registered = json['client_id'];
    if (registered is! String || registered.isEmpty) {
      throw const AuthException(
        'The authorization server registered this app but returned no client '
        'id.',
      );
    }
    // RFC 7591 lets a server hand back metadata it changed. A redirect URI it
    // rewrote would surface as a 400 in the browser the app never sees, so
    // the echo is checked here, where the failure can be named.
    final echoed = json['redirect_uris'];
    if (echoed is List && !echoed.contains(redirectUri)) {
      throw const AuthException(
        'The authorization server registered this app under a redirect URI '
        'other than the one it asked for.',
      );
    }
    return registered;
  }

  /// The loopback listener the browser's redirect comes back to.
  ///
  /// Port 0 lets the OS pick (RFC 8252 §7.3), which a registering sign-in can
  /// do because it tells the server the URI it actually bound. The fallback
  /// path has to ask for [staticRedirectPort], and that is the one thing about
  /// it that can fail outright.
  Future<HttpServer> _bindCallbackListener(int port) async {
    try {
      return await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException catch (e) {
      if (port == staticRedirectPort) {
        throw const AuthException(
          'Port $staticRedirectPort is in use, so sign-in cannot start. This '
          'server offers no client registration, so the port is fixed by the '
          'pre-registered redirect URI. Find the holder: '
          'lsof -nP -iTCP:$staticRedirectPort -sTCP:LISTEN',
        );
      }
      throw AuthException(
        'Could not open a loopback port for the sign-in callback: ${e.message}',
      );
    }
  }

  /// One browser round trip on an already-bound listener: open the authorize
  /// page, wait on the loopback redirect, return its `code`.
  ///
  /// The caller owns [server] and closes it, because the same listener has to
  /// be bound before the registration that names its port.
  Future<String> _authorizeRound({
    required HttpServer server,
    required Uri authorizeEndpoint,
    required String clientId,
    required String redirectUri,
    required String challenge,
    required String state,
  }) async {
    final authorizeUrl = authorizeEndpoint.replace(queryParameters: {
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'state': state,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      // Sent on the authorize request as well as the token request: the
      // authorization server binds the audience at THIS step.
      'resource': mcpUrl.toString(),
      // No `scope`: this authorization server issues what the client is
      // registered for, and naming a scope it does not know is an error.
    });
    final launched = await _openBrowser(authorizeUrl);
    if (!launched) {
      throw const AuthException('Could not open a browser to sign in.');
    }
    return awaitCallbackCode(server, state);
  }

  /// Waits for the browser's redirect and returns its `code`, answering the
  /// browser in every outcome so the user never sees a connection reset.
  ///
  /// Any local process can reach this port, so a request is only THE callback
  /// when it carries this run's `state`. Everything else is answered politely
  /// and the wait continues — a stray poll must not consume the sign-in, and a
  /// forged callback cannot abort a real one in flight.
  @visibleForTesting
  Future<String> awaitCallbackCode(HttpServer server, String expectedState) async {
    try {
      return await _firstMatchingCallback(server, expectedState)
          .timeout(_callbackTimeout);
    } on TimeoutException {
      throw const AuthException(
        'Sign-in timed out waiting for the browser. Try again.',
      );
    }
  }

  Future<String> _firstMatchingCallback(
      HttpServer server, String expectedState) async {
    await for (final request in server) {
      final params = request.uri.queryParameters;

      if (params['state'] != expectedState) {
        await _respond(
          request,
          'Sign-in in progress',
          'This request is not part of the sign-in — return to the browser '
              'window that opened.',
        );
        continue;
      }

      // A refusal is a normal HTTP 200 carrying `error`, not a transport
      // failure.
      final error = params['error'];
      if (error != null) {
        final description = params['error_description'] ?? '';
        final detail = description.isEmpty ? error : description;
        await _respond(request, 'Sign-in was not completed', detail);
        throw AuthorizeDenied(error, description, 'Sign-in was refused: $detail');
      }

      final code = params['code'];
      if (code == null || code.isEmpty) {
        await _respond(
          request,
          'Sign-in could not be completed',
          'The sign-in redirected back without an authorization code.',
        );
        throw const AuthException(
          'The sign-in redirected back without an authorization code.',
        );
      }

      await _respond(
        request,
        'Signed in',
        'Signed in — you can close this window and return to Bond Inbox.',
      );
      return code;
    }
    // The server was closed under the wait (sign-out, app shutdown).
    throw const AuthException(
      'Sign-in was interrupted before the browser returned.',
    );
  }

  Future<void> _respond(HttpRequest request, String heading, String detail) async {
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.html;
    // Closing the connection with the response keeps the forced server close
    // below from cutting a keep-alive socket mid-flush.
    response.persistentConnection = false;
    response.write(
      '<!doctype html><html><head><meta charset="utf-8">'
      '<title>Bond Inbox</title></head>'
      '<body style="font-family:system-ui;margin:48px;color:#1E2B28">'
      '<h2>${_escapeHtml(heading)}</h2>'
      '<p>${_escapeHtml(detail)}</p>'
      '</body></html>',
    );
    await response.close();
  }

  // ── Token lifecycle ───────────────────────────────────────────────────

  /// A JWT good for at least [_expiryMargin], refreshing if needed.
  ///
  /// Null means "send no bearer" — the local dev server's answer, and the one
  /// case where the absence of a token is not a problem. Public because the
  /// MCP client's bearer hook is wired to it.
  Future<String?> validJwt() async {
    final token = _jwt;
    final expiry = _jwtExpiry;
    if (token != null &&
        expiry != null &&
        expiry.difference(DateTime.now()) > _expiryMargin) {
      return token;
    }

    final refreshToken = await _store.read(_keyRefreshToken);
    if (refreshToken == null || refreshToken.isEmpty) {
      if (await _store.read(_keyLocalMode) == '1') return null;
      throw const NotSignedIn();
    }

    // whenComplete, not then: a FAILED refresh must clear the slot too, or
    // every later call reawaits the same poisoned future.
    //
    // Two guards, doing two jobs: this one coalesces the callers of THIS
    // method onto one exchange, and the slot lock inside [_refresh] keeps that
    // exchange from interleaving with a sign-in, a local sign-in or a
    // sign-out.
    return _refreshInFlight ??=
        _refresh().whenComplete(() => _refreshInFlight = null);
  }

  /// One refresh: discovery first, then the exchange under the slot lock.
  ///
  /// Discovery sits OUTSIDE the lock deliberately. It touches nothing in the
  /// slot — it walks the challenge, the protected-resource metadata and the
  /// authorization server's document, all of them public — and after a
  /// relaunch it is three HTTP calls, each able to sit out [_requestTimeout]
  /// on a network that is down. Holding the lock across all of that would
  /// leave a sign-out queued behind it looking dead for a minute and a half.
  /// The lock covers the token POST and its one retry, and nothing else.
  Future<String?> _refresh() async {
    // Empty after a relaunch: the endpoint was discovered in a previous
    // process, so walk the chain again rather than forcing an interactive
    // sign-in the user does not need.
    final endpoint = _tokenEndpoint ??= (await _discoverEndpoints()).token;
    return _withSlot(() => _doRefreshLocked(endpoint));
  }

  /// Runs under the slot lock, and so may clear the slot directly via
  /// [_clearLocked].
  ///
  /// Null carries [validJwt]'s "send no bearer" answer: the slot became a
  /// local-mode session while this was queued.
  Future<String?> _doRefreshLocked(Uri endpoint) async {
    final refreshToken = await _store.read(_keyRefreshToken);
    if (refreshToken == null || refreshToken.isEmpty) {
      // Read again, because [validJwt] read it BEFORE queuing here and the
      // slot can have changed hands in between. A local sign-in that ran while
      // this waited deleted the pair ON PURPOSE, and what it left behind is a
      // live session that sends no bearer — not a session that ended. Throwing
      // here would put "You are not signed in." on the inbox a moment after a
      // sign-in that worked. A sign-out clears the local flag too, so it still
      // lands on the throw below, which is what it should get.
      if (await _store.read(_keyLocalMode) == '1') return null;
      throw const NotSignedIn();
    }

    // The client this token was issued to: the authorization server binds the
    // two and answers a mismatch with `invalid_grant`. Missing only for a
    // session that predates ids being stored, which was necessarily issued to
    // the static client — the upgrade path, so it keeps refreshing instead of
    // being pushed through a sign-in it does not need.
    final stored = await _store.read(_keyClientId);
    final clientId = (stored == null || stored.isEmpty) ? staticClientId : stored;

    final form = {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientId,
      'resource': mcpUrl.toString(),
    };
    // Retried exactly once, and only when the request itself failed — a
    // dropped connection, an unresolvable host, a timeout. The first attempt
    // may well have REACHED the server, which rotated the token and lost the
    // reply on the way back; the authorization server honours a second
    // presentation of a token whose successor was never used, so the retry is
    // what makes an interrupted refresh invisible instead of a sign-out. The
    // same form is re-sent, presenting the same token, because that is exactly
    // what the grace is keyed on. An HTTP status is the server's judgement and
    // is never retried.
    _TokenResponse response;
    try {
      response = await _postForm(endpoint, form);
    } on _TransportFailure {
      await Future<void>.delayed(_refreshRetryDelay);
      response = await _postForm(endpoint, form);
    }

    if (response.statusCode != 200) {
      if (response.json['error'] == 'invalid_grant') {
        await _clearLocked();
        throw NotSignedIn(_sessionEndedMessage(response.json));
      }
      // Everything else (5xx, offline, throttling) is transient. Clearing
      // storage here would turn a dropped network into a forced sign-out.
      throw AuthException(_describeTokenError(response));
    }
    return _adoptTokens(response.json, clientId: clientId);
  }

  /// What to tell the user when the authorization server has ended the
  /// session, read from the `error_reason` it sends beside
  /// `error_description`.
  ///
  /// The four causes are genuinely different things to have happened, and one
  /// "Session expired" for all of them made a month of inactivity
  /// indistinguishable from a revoked grant in the field. This message IS
  /// user-visible — the inbox renders it as its load error — so it is written
  /// for someone who has just been signed out and wants to know why.
  ///
  /// `error_reason` is a non-standard extension, so an absent or unknown value
  /// falls back to the old text rather than inventing one; an older server
  /// says nothing here and is served exactly as before. The server's own
  /// description is for the log, not the user: it is written for an operator.
  String _sessionEndedMessage(Map<String, dynamic> json) {
    final description = json['error_description'];
    if (description is String && description.isNotEmpty) {
      debugPrint('The authorization server ended the session: $description');
    }
    final reason = json['error_reason'];
    switch (reason is String ? reason : null) {
      case 'expired':
        return 'Your session expired after a month without use — sign in '
            'again.';
      case 'revoked':
        return 'Your session was ended on the server — sign in again.';
      case 'client_mismatch':
        return 'Your saved session no longer matches this app\'s registration '
            '— sign in again.';
      case 'unknown':
        return 'The server no longer recognizes your session — sign in again.';
    }
    return 'Session expired — sign in again.';
  }

  /// Keeps the JWT in memory, persists the rotated refresh token beside the
  /// client it was issued to, returns the JWT.
  Future<String> _adoptTokens(
    Map<String, dynamic> json, {
    required String clientId,
  }) async {
    final accessToken = json['access_token'] as String?;
    if (accessToken == null || accessToken.isEmpty) {
      throw const AuthException(
        'The authorization server returned no access token.',
      );
    }
    _jwt = accessToken;
    _jwtExpiry = _expiryOf(accessToken, json);

    // Refresh tokens ROTATE here: the one just spent may already be dead, so
    // the replacement has to be stored on every single exchange.
    final refreshToken = json['refresh_token'] as String?;
    if (refreshToken != null && refreshToken.isNotEmpty) {
      // The client id is written HERE and only here, beside the token it
      // belongs to. Writing it earlier — at registration, say — would leave
      // the slot holding a new id next to an old refresh token whenever a
      // browser round was abandoned, and the next refresh would present the
      // wrong client and be signed out of a session that was fine.
      //
      // Two writes, not one atomic pair — the keychain offers no transaction.
      // A crash between them leaves the slot mismatched whichever is written
      // first, and the cost either way is one refresh answered `invalid_grant`
      // and one sign-in. Neither order is better, so this one is not worth
      // tuning.
      await _store.write(_keyClientId, clientId);
      await _store.write(_keyRefreshToken, refreshToken);
    }
    return accessToken;
  }

  /// When the JWT dies, preferring the token's own `exp` claim.
  ///
  /// `expires_in` is relative to a clock we did not read at the same instant
  /// the server did; `exp` is the value the server will actually enforce.
  DateTime _expiryOf(String jwt, Map<String, dynamic> json) {
    final exp = decodeJwtPayload(jwt)?['exp'];
    if (exp is num) {
      return DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000);
    }
    final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 3600;
    return DateTime.now().add(Duration(seconds: expiresIn));
  }

  /// Ends this slot's session, taking the slot lock.
  ///
  /// Split in two because the refresh path clears while it is ALREADY holding
  /// the lock — taking it again there would deadlock on itself. Every caller
  /// that is not already inside the lock uses this one.
  Future<void> _clear() => _withSlot(_clearLocked);

  Future<void> _clearLocked() async {
    _jwt = null;
    _jwtExpiry = null;
    invalidateStatusCache();
    await _store.write(_keyRefreshToken, null);
    await _store.write(_keyClientId, null);
    await _store.write(_keyAccountJson, null);
    await _store.write(_keyLocalMode, null);
  }

  // ── Platform queries ──────────────────────────────────────────────────

  /// The platform's view of the connected Microsoft account.
  ///
  /// Null means the question could not be answered — the callers turn that
  /// into their own safest answer rather than guessing here. Only a real
  /// answer is cached; a failure must not be remembered for 30 seconds.
  Future<Map<String, dynamic>?> _connectionStatus({bool bypassCache = false}) async {
    final cached = _statusCache;
    final cachedAt = _statusCachedAt;
    if (!bypassCache &&
        cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _statusCacheTtl) {
      return cached;
    }
    try {
      final status = await _mcp.callTool('connection_status', const {});
      _statusCache = status;
      _statusCachedAt = DateTime.now();
      return status;
    } on McpToolException {
      return null;
    } on McpTransportException {
      return null;
    }
  }

  /// The signed-in user's Microsoft profile, or null when there is none to
  /// have — no connected account, or the platform could not be reached.
  Future<AccountInfo?> _profileAccount() async {
    final Map<String, dynamic> profile;
    try {
      profile = await _mcp.callTool('get_profile', const {});
    } on McpToolException {
      return null;
    } on McpTransportException {
      return null;
    }
    if (profile['error'] == 'not_connected') return null;
    return AccountInfo(
      displayName: profile['display_name'] as String? ?? '',
      mail: profile['mail'] as String?,
      userPrincipalName: profile['user_principal_name'] as String?,
    );
  }

  // ── HTTP plumbing ─────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _getJson(Uri url, String what) async {
    final http.Response response;
    try {
      response = await _http
          .get(url, headers: const {'Accept': 'application/json'})
          .timeout(_requestTimeout);
    } on http.ClientException catch (e) {
      throw _TransportFailure('Could not read $what: ${e.message}');
    } on SocketException catch (e) {
      throw _TransportFailure('Could not read $what: ${e.message}');
    } on TimeoutException {
      throw _TransportFailure(
        'Could not read $what: timed out after '
        '${_describeDuration(_requestTimeout)}',
      );
    }
    if (response.statusCode != 200) {
      throw AuthException('Could not read $what (HTTP ${response.statusCode}).');
    }
    final json = _decodeJsonObject(response);
    if (json.isEmpty) {
      throw AuthException('Could not read $what: the response was not JSON.');
    }
    return json;
  }

  Future<_TokenResponse> _postForm(Uri endpoint, Map<String, String> form) async {
    final http.Response response;
    try {
      response = await _http.post(
        endpoint,
        headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
        body: form,
      ).timeout(_requestTimeout);
    } on http.ClientException catch (e) {
      throw _TransportFailure(
        'Could not reach the sign-in service: ${e.message}',
      );
    } on SocketException catch (e) {
      throw _TransportFailure(
        'Could not reach the sign-in service: ${e.message}',
      );
    } on TimeoutException {
      throw _TransportFailure(
        'Could not reach the sign-in service: timed out after '
        '${_describeDuration(_requestTimeout)}',
      );
    }
    return _TokenResponse(response.statusCode, _decodeJsonObject(response));
  }
}

/// A JWT's payload claims, or null when it is not a readable JWT.
///
/// Only ever used to name the user and to read `exp` — never to decide whether
/// the token is valid, which is the server's job. Padding is normalized
/// because base64url in a JWT is unpadded by spec and `base64Url.decode`
/// insists on it.
@visibleForTesting
Map<String, dynamic>? decodeJwtPayload(String jwt) {
  final parts = jwt.split('.');
  if (parts.length < 2) return null;
  try {
    final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    final decoded = jsonDecode(payload);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// Names the user from JWT claims when the platform has no profile to offer.
AccountInfo? _accountFromClaims(Map<String, dynamic>? claims) {
  if (claims == null) return null;
  final email = claims['email'];
  if (email is String && email.isNotEmpty) {
    return AccountInfo(displayName: email, mail: email);
  }
  final subject = claims['sub'];
  if (subject is String && subject.isNotEmpty) {
    return AccountInfo(displayName: subject);
  }
  return null;
}

/// Servers answer `application/json` with no charset, which makes `http`'s
/// `body` fall back to latin-1 and mangle non-ASCII display names. Decoding
/// the bytes as UTF-8 is the only correct read.
Map<String, dynamic> _decodeJsonObject(http.Response response) {
  try {
    final decoded =
        jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
    return decoded is Map<String, dynamic> ? decoded : const {};
  } on FormatException {
    return const {};
  }
}

String _describeTokenError(_TokenResponse response) {
  final description = response.json['error_description'] as String?;
  if (description != null && description.isNotEmpty) return description;
  final error = response.json['error'] as String?;
  if (error != null && error.isNotEmpty) {
    return 'Sign-in failed: $error (HTTP ${response.statusCode}).';
  }
  return 'Sign-in failed with HTTP ${response.statusCode}.';
}

/// A timeout the way a person reads one: `30s`, and `50ms` below a second,
/// where whole seconds alone would have said "timed out after 0s".
String _describeDuration(Duration duration) =>
    duration.inMilliseconds % 1000 == 0
        ? '${duration.inSeconds}s'
        : '${duration.inMilliseconds}ms';

String _trimSlash(String url) =>
    url.endsWith('/') ? url.substring(0, url.length - 1) : url;

String _escapeHtml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
