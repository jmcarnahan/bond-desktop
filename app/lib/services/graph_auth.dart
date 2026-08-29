import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show immutable;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'pkce.dart';
import 'token_store.dart';

/// OAuth 2.0 authorization-code + PKCE sign-in against Microsoft Entra as a
/// PUBLIC client: there is no client secret anywhere in this file, and adding
/// one makes Entra reject every request the app sends.
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
  static const String redirectUri = 'http://localhost:8400';

  /// Fixed by the registration above. There is no fallback port: binding
  /// anything else produces a redirect Entra will not accept.
  static const int redirectPort = 8400;

  /// A list because Teams support later appends `Chat.Read` here. Any
  /// addition needs interactive re-consent — see [needsReconsent].
  static const List<String> scopes = ['Mail.Read', 'User.Read', 'offline_access'];

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
  final List<String> _scopes;

  /// In memory only, deliberately: a leaked access token is short-lived,
  /// while a leaked refresh token is not.
  String? _accessToken;
  DateTime? _accessTokenExpiry;

  /// Single-flight guard for [getValidAccessToken]. Concurrent callers share
  /// one POST; Microsoft rotates refresh tokens, so a second concurrent
  /// exchange would race on an already-consumed one.
  Future<String>? _refreshInFlight;

  GraphAuth({
    http.Client? httpClient,
    TokenStore? store,
    List<String>? scopeOverride,
  })  : _http = httpClient ?? http.Client(),
        _store = store ?? const SecureTokenStore(),
        _scopes = scopeOverride ?? scopes;

  String get _scopeParam => _scopes.join(' ');

  // ── State ─────────────────────────────────────────────────────────────

  Future<bool> get isSignedIn async {
    final token = await _store.read(_keyRefreshToken);
    return token != null && token.isNotEmpty;
  }

  /// True when a scope this build asks for is absent from what Entra
  /// actually granted. Null storage means "not signed in", not "missing
  /// consent" — the sign-in screen handles that case.
  Future<bool> get needsReconsent async {
    final granted = await _store.read(_keyGrantedScopes);
    if (granted == null || granted.isEmpty) return false;
    final grantedSet = {
      for (final scope in granted.split(RegExp(r'\s+')))
        if (scope.isNotEmpty) _bareScope(scope),
    };
    for (final wanted in _scopes) {
      // offline_access never appears in a granted scope string; its presence
      // is proven by the refresh token itself.
      if (_bareScope(wanted) == 'offline_access') continue;
      if (!grantedSet.contains(_bareScope(wanted))) return true;
    }
    return false;
  }

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

  Future<AccountInfo> signIn() async {
    final verifier = randomUrlSafe(64);
    final challenge = pkceChallengeFor(verifier);
    final state = randomUrlSafe(32);

    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, redirectPort);
    } on SocketException {
      throw const AuthException(
        'Port $redirectPort is in use, so sign-in cannot start. This port is '
        'fixed by the Azure app registration. Find the holder: '
        'lsof -nP -iTCP:$redirectPort -sTCP:LISTEN',
      );
    }

    final String code;
    try {
      final authorizeUrl =
          Uri.parse('$_authority/authorize').replace(queryParameters: {
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'scope': _scopeParam,
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
      code = await _awaitCallbackCode(server, state);
    } finally {
      // Unconditional: an abandoned or failed sign-in must not hold port
      // 8400 for the rest of the process's life.
      await server.close(force: true);
    }

    final response = await _postToken({
      'client_id': clientId,
      'scope': _scopeParam,
      'code': code,
      'redirect_uri': redirectUri,
      'grant_type': 'authorization_code',
      'code_verifier': verifier,
    });
    if (response.statusCode != 200) {
      throw AuthException(_describeTokenError(response));
    }
    final accessToken = await _adoptTokens(response.json);
    return _fetchAccount(accessToken);
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
      throw AuthException('Microsoft did not complete sign-in: $detail');
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

    final response = await _postToken({
      'client_id': clientId,
      'scope': _scopeParam,
      'refresh_token': refreshToken,
      'grant_type': 'refresh_token',
    });

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
