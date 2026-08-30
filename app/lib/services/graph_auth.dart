import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugPrint, immutable, protected, visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'pkce.dart';
import 'token_store.dart';

/// OAuth 2.0 authorization-code + PKCE sign-in against Microsoft Entra.
///
/// Designed as a PUBLIC client, but currently running in a dev-stage
/// confidential mode: the shared Azure registration has no public-client
/// platform, so token POSTs carry the registration's secret when a build
/// supplies one (see [_definedClientSecret]). No secret appears in this
/// source and none is ever persisted by the app.
///
/// The access token lives in memory only. Only the rotating refresh token,
/// the granted scope string, and the account summary are persisted.

/// Anything the caller can show the user verbatim. [message] is written for a
/// person, not a log line.
class AuthException implements Exception {
  final String message;

  const AuthException(this.message);

  @override
  String toString() => message;
}

/// There is no usable refresh token — the user must sign in interactively.
class NotSignedIn extends AuthException {
  const NotSignedIn([super.message = 'You are not signed in.']);
}

/// The stored grant is missing a scope this build now asks for. Refreshing
/// cannot fix it; only an interactive sign-in with the new consent can.
class ReconsentRequired extends AuthException {
  const ReconsentRequired([
    super.message =
        'This version needs additional Microsoft permissions. Sign in again '
            'to grant them.',
  ]);
}

/// The browser came back carrying an OAuth `error` instead of a code.
///
/// Held apart from a plain [AuthException] because [GraphAuth.signIn] has to
/// read the raw parameters to tell two very different things apart: a user who
/// clicked Cancel, and a tenant that refuses one of the scopes this build asks
/// for. Only the second is worth retrying with less.
class AuthorizeDenied extends AuthException {
  /// Entra's `error` parameter, e.g. `access_denied`, `consent_required`.
  final String error;

  /// Entra's `error_description`, which is where the AADSTS code lives.
  final String errorDescription;

  const AuthorizeDenied(this.error, this.errorDescription, String message)
      : super(message);

  /// True when this reads as "the tenant will not grant that consent" rather
  /// than "the person said no".
  ///
  /// AADSTS90094 is admin consent required; AADSTS65001 is consent not
  /// granted. Both arrive as `access_denied` in the `error` parameter, which is
  /// the same code a Cancel click produces — the description is the only thing
  /// that separates them.
  bool get isConsentProblem =>
      error == 'consent_required' ||
      errorDescription.contains('AADSTS90094') ||
      errorDescription.contains('AADSTS65001');
}

/// The signed-in user, as Graph's `/me` describes them. Only [displayName] is
/// guaranteed — a mailbox-less account has no `mail`, and both fields are
/// tolerated as absent so a thin `/me` payload cannot break the header.
@immutable
class AccountInfo {
  final String displayName;
  final String? mail;
  final String? userPrincipalName;

  const AccountInfo({
    required this.displayName,
    this.mail,
    this.userPrincipalName,
  });

  factory AccountInfo.fromJson(Map<String, dynamic> json) {
    return AccountInfo(
      displayName: json['displayName'] as String? ?? '',
      mail: json['mail'] as String?,
      userPrincipalName: json['userPrincipalName'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'displayName': displayName,
        'mail': mail,
        'userPrincipalName': userPrincipalName,
      };
}

/// One token exchange's outcome. Kept as a pair because `invalid_grant` has
/// to be told apart from every other non-200 — the first means signed out,
/// the rest must leave the stored refresh token alone.
@immutable
class _TokenResponse {
  final int statusCode;
  final Map<String, dynamic> json;

  const _TokenResponse(this.statusCode, this.json);
}

class GraphAuth {
  // ── Azure app registration (public client) ────────────────────────────
  static const String clientId = '[MS_CLIENT_ID]';

  /// Tenant-specific endpoints, not `/common`: this registration is
  /// single-tenant, and `/common` fails at the authorize step for it.
  static const String tenantId = '[MS_TENANT_ID]';

  /// Must match the portal's redirect URI byte for byte in BOTH the
  /// authorize and token requests — a trailing slash is a mismatch.
  ///
  /// This is the-crm's registered redirect, borrowed because it is the one
  /// URI the shared Azure app actually has (http://localhost:8400 is not
  /// registered — Entra answers AADSTS50011). The path is meaningless to the
  /// loopback listener, which answers every request on the port; only the
  /// byte-exact string matters to Entra. Once the portal gains a "Mobile and
  /// desktop applications" entry for this app, switch back to a dedicated
  /// port and URI.
  static const String redirectUri =
      'http://localhost:8001/connections/microsoft/callback';

  /// Fixed by the registration above. There is no fallback port: binding
  /// anything else produces a redirect Entra will not accept. the-crm's
  /// backend binds this same port when it is running, so the two cannot
  /// sign in at the same time.
  static const int redirectPort = 8001;

  /// Dev-stage escape hatch. This registration has no public-client platform
  /// and nobody on the team can currently reach the Azure portal to add one,
  /// so the token exchange must authenticate the way the-crm's backend does:
  /// with the shared registration's client secret (Entra accepts secret +
  /// PKCE together — a confidential client with PKCE is valid).
  ///
  /// The secret arrives at BUILD time via --dart-define=MS_CLIENT_SECRET=…
  /// (`make app-run` injects it from the-crm's .env). It is never committed
  /// and never stored by this app — but it IS baked into the local binary,
  /// so a build made this way must not be distributed. Empty means "behave
  /// as a true public client", which is what this should return to the day
  /// the registration gains a Mobile and desktop platform.
  static const String _definedClientSecret =
      String.fromEnvironment('MS_CLIENT_SECRET');

  /// What the app cannot run without. Missing any of these means the stored
  /// grant is unusable and the user must sign in again — see [needsReconsent].
  static const List<String> coreScopes = [
    'Mail.Read',
    'User.Read',
    'offline_access',
  ];

  /// What the app asks for on top, and can do without.
  ///
  /// All three are requested in ONE consent round, `Chat.Read` included even
  /// though nothing reads Teams yet: a second round later would mean a second
  /// consent prompt, and the point of asking now is that the user sees one.
  ///
  /// A tenant that refuses these does not cost the user the session — the
  /// sign-in retries with [coreScopes] alone and the features that need them
  /// report themselves unavailable through [hasScope].
  static const List<String> extendedScopes = [
    'Mail.ReadWrite',
    'Mail.Send',
    'Chat.Read',
  ];

  /// What an interactive sign-in requests: everything, required and optional
  /// alike.
  static const List<String> scopes = [...coreScopes, ...extendedScopes];

  /// Which granted scopes stand in for a scope this app wants.
  ///
  /// Exactly one pair, and deliberately not a general lattice: Entra's own
  /// consent hierarchy makes `Mail.ReadWrite` include `Mail.Read`, so a grant
  /// carrying only the former satisfies a build asking for the latter. Nothing
  /// else here subsumes anything.
  static const Map<String, Set<String>> _subsumedBy = {
    'mail.read': {'mail.readwrite'},
  };

  static const String _authority =
      'https://login.microsoftonline.com/$tenantId/oauth2/v2.0';
  static const String _meEndpoint = 'https://graph.microsoft.com/v1.0/me';

  static const String _keyRefreshToken = 'refresh_token';
  static const String _keyGrantedScopes = 'granted_scopes';
  static const String _keyAccountJson = 'account_json';

  /// A token this close to expiry is treated as already expired, so a request
  /// started now cannot arrive after it dies.
  static const Duration _expiryMargin = Duration(minutes: 5);

  /// A browser round trip that has not come back by now is abandoned.
  static const Duration _callbackTimeout = Duration(minutes: 5);

  final http.Client _http;
  final TokenStore _store;

  /// Absent any of these, the grant is unusable — [needsReconsent] iterates
  /// this set and nothing else.
  final List<String> _requiredScopes;

  /// Asked for, and survivable when refused.
  final List<String> _extendedScopes;

  /// In memory only, deliberately: a leaked access token is short-lived,
  /// while a leaked refresh token is not.
  String? _accessToken;
  DateTime? _accessTokenExpiry;

  /// Single-flight guard for [getValidAccessToken]. Concurrent callers share
  /// one POST; Microsoft rotates refresh tokens, so a second concurrent
  /// exchange would race on an already-consumed one.
  Future<String>? _refreshInFlight;

  /// [scopeOverride] keeps the meaning it has always had: it replaces the
  /// REQUIRED set, and — unless [extendedScopeOverride] says otherwise — turns
  /// the extended set off entirely, so a test that names three scopes gets a
  /// sign-in that asks for exactly those three.
  GraphAuth({
    http.Client? httpClient,
    TokenStore? store,
    List<String>? scopeOverride,
    List<String>? extendedScopeOverride,
    String? clientSecret,
  })  : _http = httpClient ?? http.Client(),
        _store = store ?? const SecureTokenStore(),
        _requiredScopes = scopeOverride ?? coreScopes,
        _extendedScopes = extendedScopeOverride ??
            (scopeOverride == null ? extendedScopes : const []),
        _clientSecret = clientSecret ?? _definedClientSecret;

  final String _clientSecret;

  /// The secret rides on every token POST when present — Entra treats this
  /// registration as confidential, and both the code exchange AND the
  /// refresh fail with AADSTS7000218 without it.
  Map<String, String> _withClientAuth(Map<String, String> form) => {
        ...form,
        if (_clientSecret.isNotEmpty) 'client_secret': _clientSecret,
      };

  /// Everything an interactive sign-in asks for, required first.
  List<String> get _requestedScopes => [..._requiredScopes, ..._extendedScopes];

  String get _scopeParam => _requestedScopes.join(' ');

  // ── State ─────────────────────────────────────────────────────────────

  Future<bool> get isSignedIn async {
    final token = await _store.read(_keyRefreshToken);
    return token != null && token.isNotEmpty;
  }

  /// True when a scope this build REQUIRES is absent from what Entra actually
  /// granted. Null storage means "not signed in", not "missing consent" — the
  /// sign-in screen handles that case.
  ///
  /// The extended scopes are deliberately not checked. They are allowed to be
  /// missing: a tenant that refuses them leaves a perfectly usable session, and
  /// treating that as re-consent would put the user in a sign-in loop over a
  /// consent nobody in the loop can grant.
  Future<bool> get needsReconsent async {
    final grantedSet = await _grantedBareScopes();
    if (grantedSet.isEmpty) return false;
    for (final wanted in _requiredScopes) {
      // offline_access never appears in a granted scope string; its presence
      // is proven by the refresh token itself.
      final bare = _bareScope(wanted);
      if (bare == 'offline_access') continue;
      if (!_isGranted(grantedSet, bare)) return true;
    }
    return false;
  }

  /// Whether the stored grant carries [bareScope] — what the UI asks before it
  /// offers to send mail, save a draft, or read Teams.
  ///
  /// Reads the GRANT, never the request: a degraded sign-in asked for
  /// `Mail.Send` and did not get it, and the honest answer is the one Entra
  /// gave. False when nothing is stored, which is also the right answer for a
  /// signed-out app. `offline_access` is not answerable here — it never appears
  /// in a granted scope string.
  Future<bool> hasScope(String bareScope) async {
    final grantedSet = await _grantedBareScopes();
    if (grantedSet.isEmpty) return false;
    return _isGranted(grantedSet, _bareScope(bareScope));
  }

  /// What Entra granted, reduced to bare lowercase names. Empty when nothing
  /// is stored.
  Future<Set<String>> _grantedBareScopes() async {
    final granted = await _store.read(_keyGrantedScopes);
    if (granted == null || granted.isEmpty) return const {};
    return {
      for (final scope in granted.split(RegExp(r'\s+')))
        if (scope.isNotEmpty) _bareScope(scope),
    };
  }

  /// Subsumption-aware membership: a wanted scope counts as granted when the
  /// grant names it, or names something that includes it — see [_subsumedBy].
  static bool _isGranted(Set<String> grantedSet, String wantedBare) =>
      grantedSet.contains(wantedBare) ||
      (_subsumedBy[wantedBare]?.any(grantedSet.contains) ?? false);

  Future<AccountInfo?> get storedAccount async {
    final raw = await _store.read(_keyAccountJson);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return AccountInfo.fromJson(decoded);
    } on FormatException {
      return null;
    }
  }

  Future<void> signOut() => _clear();

  // ── Interactive sign-in ───────────────────────────────────────────────

  /// The full interactive sign-in, including the one permitted retry with less.
  ///
  /// Asking for everything at once is what keeps this to a single consent
  /// prompt in the normal case. When the tenant refuses the extended set the
  /// round is run again with [coreScopes] alone — ONCE, and only when the
  /// refusal reads as a consent problem rather than a Cancel click, so a user
  /// who backed out is not handed a second browser window.
  ///
  /// `prompt=consent` is deliberately never sent: it would re-prompt a user
  /// whose consent is already on file, every single sign-in.
  Future<AccountInfo> signIn() async {
    try {
      return await _signInWith(_requestedScopes);
    } on AuthorizeDenied catch (e) {
      if (_extendedScopes.isEmpty || !e.isConsentProblem) rethrow;
      debugPrint(
        'GraphAuth: retrying sign-in without the extended scopes — '
        'Entra said: ${e.errorDescription}',
      );
      return _signInWith(_requiredScopes);
    }
  }

  /// One complete sign-in: authorize, exchange, fetch the account.
  Future<AccountInfo> _signInWith(List<String> roundScopes) async {
    final verifier = randomUrlSafe(64);
    final scopeParam = roundScopes.join(' ');

    final code = await authorizeRound(
      scopeParam: scopeParam,
      challenge: pkceChallengeFor(verifier),
      state: randomUrlSafe(32),
    );

    final response = await _postToken(_withClientAuth({
      'client_id': clientId,
      'scope': scopeParam,
      'code': code,
      'redirect_uri': redirectUri,
      'grant_type': 'authorization_code',
      'code_verifier': verifier,
    }));
    if (response.statusCode != 200) {
      throw AuthException(_describeTokenError(response));
    }
    final accessToken = await _adoptTokens(response.json);
    return _fetchAccount(accessToken);
  }

  /// One browser round trip: open the authorize page, wait on the loopback
  /// redirect, return its `code`.
  ///
  /// Overridable so the consent-degrade path above can be tested without a
  /// browser and without binding a port. Production has exactly one
  /// implementation — this one.
  @protected
  @visibleForTesting
  Future<String> authorizeRound({
    required String scopeParam,
    required String challenge,
    required String state,
  }) async {
    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, redirectPort);
    } on SocketException {
      throw const AuthException(
        'Port $redirectPort is in use, so sign-in cannot start. This port is '
        'fixed by the Azure app registration — the-crm binds it too, so stop '
        'the-crm before signing in here. Find the holder: '
        'lsof -nP -iTCP:$redirectPort -sTCP:LISTEN',
      );
    }

    try {
      final authorizeUrl =
          Uri.parse('$_authority/authorize').replace(queryParameters: {
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'scope': scopeParam,
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
      });
      // The system browser, not a webview: it already holds the corporate
      // session, and Entra blocks embedded webviews for public clients.
      final launched = await launchUrl(
        authorizeUrl,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw const AuthException(
          'Could not open a browser for the Microsoft sign-in page.',
        );
      }
      return await _awaitCallbackCode(server, state);
    } finally {
      // Unconditional: an abandoned or failed sign-in must not hold port
      // 8001 for the rest of the process's life — including between the two
      // rounds of a consent degrade, which would otherwise fail to bind.
      await server.close(force: true);
    }
  }

  /// Waits for the browser's redirect and returns its `code`, answering the
  /// browser in every outcome so the user never sees a connection reset.
  Future<String> _awaitCallbackCode(HttpServer server, String expectedState) async {
    final HttpRequest request;
    try {
      request = await server.first.timeout(_callbackTimeout);
    } on TimeoutException {
      throw const AuthException(
        'Sign-in timed out waiting for the browser. Try again.',
      );
    }

    final params = request.uri.queryParameters;

    // A denied consent is a normal HTTP 200 carrying `error`, not a
    // transport failure.
    final error = params['error'];
    if (error != null) {
      final description = params['error_description'] ?? '';
      final detail = description.isEmpty ? error : description;
      await _respond(request, 'Sign-in was not completed', detail);
      throw AuthorizeDenied(
        error,
        description,
        'Microsoft did not complete sign-in: $detail',
      );
    }

    // Any local process can reach this port; only the response carrying back
    // this run's state is ours.
    if (params['state'] != expectedState) {
      await _respond(
        request,
        'Sign-in could not be verified',
        'This response did not come from the sign-in Bond Inbox started.',
      );
      throw const AuthException(
        'The sign-in response failed its state check and was rejected. '
        'Start sign-in again.',
      );
    }

    final code = params['code'];
    if (code == null || code.isEmpty) {
      await _respond(
        request,
        'Sign-in could not be completed',
        'Microsoft redirected back without an authorization code.',
      );
      throw const AuthException(
        'Microsoft redirected back without an authorization code.',
      );
    }

    await _respond(
      request,
      'Signed in',
      'Signed in — you can close this window and return to Bond Inbox.',
    );
    return code;
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

  /// A token good for at least [_expiryMargin], refreshing if needed.
  Future<String> getValidAccessToken() async {
    final token = _accessToken;
    final expiry = _accessTokenExpiry;
    if (token != null &&
        expiry != null &&
        expiry.difference(DateTime.now()) > _expiryMargin) {
      return token;
    }

    // Never refresh into a missing consent: Entra answers AADSTS65001, which
    // looks exactly like an expired session and would sign the user out.
    if (await needsReconsent) throw const ReconsentRequired();

    // whenComplete, not then: a FAILED refresh must clear the slot too, or
    // every later call reawaits the same poisoned future.
    return _refreshInFlight ??=
        _doRefresh().whenComplete(() => _refreshInFlight = null);
  }

  Future<String> _doRefresh() async {
    final refreshToken = await _store.read(_keyRefreshToken);
    if (refreshToken == null || refreshToken.isEmpty) {
      throw const NotSignedIn();
    }

    final response = await _postToken(_withClientAuth({
      'client_id': clientId,
      'scope': await _refreshScopeParam(),
      'refresh_token': refreshToken,
      'grant_type': 'refresh_token',
    }));

    if (response.statusCode != 200) {
      if (response.json['error'] == 'invalid_grant') {
        await _clear();
        throw const NotSignedIn('Session expired — sign in again.');
      }
      // Everything else (5xx, offline, throttling) is transient. Clearing
      // storage here would turn a dropped network into a forced sign-out.
      throw AuthException(_describeTokenError(response));
    }

    return _adoptTokens(response.json);
  }

  /// What a refresh asks for: the requested set, minus anything Entra did not
  /// actually grant.
  ///
  /// This exists because of the consent degrade. A session that fell back to
  /// the core scopes has no consent for `Mail.Send`, and a refresh that asked
  /// for it anyway comes back `invalid_grant` / AADSTS65001 — which
  /// [_doRefresh] reads as "the session is over" and acts on by clearing the
  /// keychain. Narrowing to the grant means a degraded session stays signed in
  /// instead of being logged out on its first token refresh.
  ///
  /// `offline_access` is always kept: it never appears in a granted scope
  /// string, and dropping it is what stops Entra handing back a rotated
  /// refresh token. With nothing stored the full request stands.
  Future<String> _refreshScopeParam() async {
    final grantedSet = await _grantedBareScopes();
    if (grantedSet.isEmpty) return _scopeParam;
    final kept = [
      for (final scope in _requestedScopes)
        if (_bareScope(scope) == 'offline_access' ||
            _isGranted(grantedSet, _bareScope(scope)))
          scope,
    ];
    return kept.isEmpty ? _scopeParam : kept.join(' ');
  }

  /// Persists what must survive a relaunch, keeps the access token in memory,
  /// and returns it.
  Future<String> _adoptTokens(Map<String, dynamic> json) async {
    final accessToken = json['access_token'] as String?;
    if (accessToken == null || accessToken.isEmpty) {
      throw const AuthException(
        'Microsoft returned a token response with no access token.',
      );
    }
    final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 3600;
    _accessToken = accessToken;
    _accessTokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));

    // Microsoft ROTATES refresh tokens: the one just spent may already be
    // dead, so the replacement has to be stored on every single exchange.
    final refreshToken = json['refresh_token'] as String?;
    if (refreshToken != null && refreshToken.isNotEmpty) {
      await _store.write(_keyRefreshToken, refreshToken);
    }

    // The SERVER's grant, never the requested list — Entra can and does
    // grant a different set than was asked for.
    final granted = json['scope'] as String?;
    if (granted != null && granted.isNotEmpty) {
      await _store.write(_keyGrantedScopes, granted);
    }

    return accessToken;
  }

  Future<AccountInfo> _fetchAccount(String accessToken) async {
    final response = await _http.get(
      Uri.parse(_meEndpoint),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (response.statusCode != 200) {
      throw AuthException(
        'Signed in, but Microsoft Graph rejected the token '
        '(HTTP ${response.statusCode}).',
      );
    }
    final account = AccountInfo.fromJson(_decodeJsonObject(response));
    await _store.write(_keyAccountJson, jsonEncode(account.toJson()));
    return account;
  }

  Future<_TokenResponse> _postToken(Map<String, String> form) async {
    final http.Response response;
    try {
      response = await _http.post(
        Uri.parse('$_authority/token'),
        headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
        body: form,
      );
    } on http.ClientException catch (e) {
      throw AuthException('Could not reach Microsoft sign-in: ${e.message}');
    } on SocketException catch (e) {
      throw AuthException('Could not reach Microsoft sign-in: ${e.message}');
    }
    return _TokenResponse(response.statusCode, _decodeJsonObject(response));
  }

  Future<void> _clear() async {
    _accessToken = null;
    _accessTokenExpiry = null;
    await _store.deleteAll();
  }
}

/// Graph and Entra answer `application/json` with no charset, which makes
/// `http`'s `body` fall back to latin-1 and mangle non-ASCII display names.
/// Decoding the bytes as UTF-8 is the only correct read.
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
  final error = response.json['error'] as String?;
  final description = response.json['error_description'] as String?;
  if (description != null && description.isNotEmpty) return description;
  if (error != null && error.isNotEmpty) {
    return 'Microsoft sign-in failed: $error (HTTP ${response.statusCode}).';
  }
  return 'Microsoft sign-in failed with HTTP ${response.statusCode}.';
}

/// Entra returns grants resource-qualified and case-folded — `Mail.Read` can
/// come back as `https://graph.microsoft.com/mail.read` — so both sides are
/// reduced to a bare lowercase name before they are compared.
String _bareScope(String scope) {
  final slash = scope.lastIndexOf('/');
  return (slash >= 0 ? scope.substring(slash + 1) : scope).toLowerCase();
}

String _escapeHtml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
