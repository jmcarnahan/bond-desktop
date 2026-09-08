import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/person.dart';
import 'backend/backend_types.dart';
import 'backend/people_backend.dart';
import 'graph_auth.dart';

/// The organization's directory, read straight from Microsoft Graph.
///
/// Auth failures pass through UNWRAPPED, exactly as they do in graph_mail.dart
/// and graph_teams.dart. Everything else becomes a [DirectoryUnavailable],
/// because the recipients field has one decision to make about a failed
/// search — ask again on the next keystroke, or stop for the session — and a
/// status code is not what answers it. A 403 is the tenant refusing
/// `User.ReadBasic.All`; everything else is a bad moment.
///
/// The private `_request` / `_describe` / `_decodeObject` trio is a THIRD copy,
/// on purpose and for the reason the other two give: these files travel to
/// different banners and must not be able to break each other.
class GraphPeople implements PeopleBackend {
  static const String _base = 'https://graph.microsoft.com/v1.0';

  /// Everything a chip and a Teams chat need, and nothing else: the id is what
  /// opens a chat, the address is what sends mail, and the job title is the
  /// only thing that tells two people with the same name apart.
  static const String _select =
      'id,displayName,mail,userPrincipalName,jobTitle';

  /// What Graph will accept for `$top` on a `$search`.
  static const int _minTop = 1;
  static const int _maxTop = 50;

  /// A 429 with no parseable Retry-After waits this long; anything Graph asks
  /// for above [_maxBackoff] is clamped. Same numbers as graph_mail.dart.
  static const Duration _defaultBackoff = Duration(seconds: 5);
  static const Duration _maxBackoff = Duration(seconds: 60);

  final GraphAuth _auth;
  final http.Client _http;

  GraphPeople(this._auth, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  /// People in the organization matching [query].
  ///
  /// `$search` rather than `$filter startswith`: a person is looked for by
  /// whichever part of their name comes to mind, and `startswith` on
  /// displayName finds nobody by their surname. It costs the
  /// `ConsistencyLevel: eventual` header and `$count=true`, which Graph
  /// REQUIRES together with `$search` on `/users` and refuses the request
  /// without.
  ///
  /// The query is sanitised first because `$search`'s own syntax lives inside
  /// the quoted string: a `"` would close it, and `&`, `#` and `%` are URL
  /// punctuation that a hand-built query string must not carry raw. Stripping
  /// them is right rather than escaping them — none of the four appears in a
  /// name anybody is typing, and a search that returns the wrong people is
  /// worse than one that ignores a character.
  @override
  Future<List<Person>> searchPeople(String query, {int top = 10}) async {
    final cleaned = _sanitise(query);
    if (cleaned.isEmpty) return const [];

    final response = await _request('GET', _searchUri(cleaned, top),
        headers: const {'ConsistencyLevel': 'eventual'});

    // The tenant has not granted User.ReadBasic.All. Nothing retryable about
    // it: consent and a reconnect are the only things that change the answer.
    if (response.statusCode == 403) {
      throw const DirectoryUnavailable(
        scopeMissing: true,
        message: 'Directory search is not enabled for this account.',
      );
    }
    if (response.statusCode != 200) {
      throw DirectoryUnavailable(
        scopeMissing: false,
        message: _describe(response, 'The directory could not be searched'),
      );
    }

    final value = _decodeObject(response)['value'];
    return [
      for (final entry in value is List ? value : const [])
        if (entry is Map && (entry['id'] as String? ?? '').isNotEmpty)
          Person(
            id: entry['id'] as String,
            displayName: entry['displayName'] as String? ?? '',
            mail: _present(entry['mail']),
            userPrincipalName: _present(entry['userPrincipalName']),
            jobTitle: _present(entry['jobTitle']),
            source: PersonSource.directory,
          ),
    ];
  }

  /// [user]'s profile photo, straight from Graph.
  ///
  /// `/me/photos/{size}/$value` for the signed-in user and
  /// `/users/{id}/photos/{size}/$value` for anybody else — the first needs only
  /// `User.Read`, which every session has, so the owner's own face survives a
  /// tenant that never granted the directory scope.
  ///
  /// A 404 is null rather than a failure, and covers three different truths
  /// Graph does not separate: this person uploaded no picture, this person is
  /// not in the directory, or the mailbox is not a user at all. All three end
  /// at the same avatar, so telling them apart would buy nothing.
  ///
  /// The response is read as BYTES and never decoded here — `$value` on a
  /// photo is the image itself, not JSON, and the content type is whatever the
  /// person uploaded.
  @override
  Future<ProfilePhoto?> profilePhoto(String user, {String size = '96x96'}) async {
    final response = await _request('GET', _photoUri(user, size));

    if (response.statusCode == 200) {
      return ProfilePhoto(
        bytes: response.bodyBytes,
        contentType: response.headers['content-type'] ?? _defaultPhotoType,
      );
    }
    if (response.statusCode == 404) return null;
    // The tenant has not granted User.ReadBasic.All: the same permanent answer
    // the search gets, and for the same reason.
    if (response.statusCode == 403) {
      throw const DirectoryUnavailable(
        scopeMissing: true,
        message: 'Profile photos are not enabled for this account.',
      );
    }
    throw DirectoryUnavailable(
      scopeMissing: false,
      message: _describe(response, 'The profile photo could not be read'),
    );
  }

  /// Graph serves whatever was uploaded; this is only what a response with no
  /// content type at all is read as.
  static const String _defaultPhotoType = 'image/jpeg';

  /// The photo endpoint for one person. Built with the path escaped rather
  /// than by interpolation: a UPN is a legitimate value for [user] and carries
  /// an `@`, which is path punctuation Graph will not take raw.
  Uri _photoUri(String user, String size) {
    final trimmed = user.trim();
    final who = trimmed.isEmpty
        ? 'me'
        : 'users/${Uri.encodeComponent(trimmed)}';
    return Uri.parse(
      '$_base/$who/photos/${Uri.encodeComponent(size)}/\$value',
    );
  }

  /// Built by hand rather than through `queryParameters`, which encodes a
  /// space as `+` — and `$search`'s value is a quoted expression with spaces
  /// inside it that Graph's OData parser wants as `%20`. Same reason
  /// graph_teams.dart builds its own query strings.
  Uri _searchUri(String query, int top) {
    final search = '"displayName:$query" OR "mail:$query"';
    final buffer = StringBuffer()
      ..write('\$search=${Uri.encodeComponent(search)}')
      ..write('&\$select=$_select')
      ..write('&\$top=${top.clamp(_minTop, _maxTop)}')
      // Both are Graph's price for `$search` on /users, not options.
      ..write('&\$count=true')
      ..write('&\$orderby=displayName');
    return Uri.parse('$_base/users').replace(query: buffer.toString());
  }

  /// The query with everything that could break the `$search` expression or
  /// the query string taken out, and its whitespace collapsed.
  ///
  /// Removed characters become a SPACE rather than nothing: `a&b` is two words
  /// somebody ran together, and gluing them into `ab` would search for a name
  /// that does not exist.
  static String _sanitise(String query) => query
      .replaceAll(RegExp(r'["&#%\x00-\x1f\x7f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String? _present(Object? raw) =>
      raw is String && raw.isNotEmpty ? raw : null;

  /// One authenticated request, retrying at most once for a throttle and once
  /// for a 401 — the same policy as the other two Graph files, and for the
  /// same reasons.
  Future<http.Response> _request(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    var retriedThrottle = false;
    var retriedAuth = false;

    while (true) {
      // Outside the try: an AuthException from here is not a transport failure
      // and must reach the caller as itself.
      final token = await _auth.getValidAccessToken();
      final sent = {'Authorization': 'Bearer $token', ...headers};

      final http.Response response;
      try {
        response = await _http.get(uri, headers: sent);
      } on http.ClientException catch (e) {
        throw DirectoryUnavailable(
          scopeMissing: false,
          message: 'Could not reach Microsoft Graph: ${e.message}',
        );
      } on SocketException catch (e) {
        throw DirectoryUnavailable(
          scopeMissing: false,
          message: 'Could not reach Microsoft Graph: ${e.message}',
        );
      }

      if (response.statusCode == 429 && !retriedThrottle) {
        retriedThrottle = true;
        await Future<void>.delayed(_retryAfter(response));
        continue;
      }
      if (response.statusCode == 401 && !retriedAuth) {
        retriedAuth = true;
        continue;
      }
      return response;
    }
  }

  static Duration _retryAfter(http.Response response) {
    final raw = response.headers['retry-after'];
    final seconds = raw == null ? null : int.tryParse(raw.trim());
    if (seconds == null || seconds < 0) return _defaultBackoff;
    final asked = Duration(seconds: seconds);
    return asked > _maxBackoff ? _maxBackoff : asked;
  }

  /// A string rather than an exception, unlike the `_describe` in the other
  /// two Graph files: the caller decides `scopeMissing` from the status, and
  /// this only supplies the words.
  static String _describe(http.Response response, String prefix) {
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    final snippet = body.length > 300 ? '${body.substring(0, 300)}…' : body;
    return '$prefix (HTTP ${response.statusCode}).'
        '${snippet.isEmpty ? '' : ' $snippet'}';
  }

  /// Graph answers `application/json` with no charset, which makes `http`'s
  /// `body` getter fall back to latin-1 and mangle non-ASCII names — and this
  /// call is nothing BUT names. Decoding the bytes is the only correct read.
  static Map<String, dynamic> _decodeObject(http.Response response) {
    try {
      final decoded =
          jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
      return decoded is Map<String, dynamic> ? decoded : const {};
    } on FormatException {
      return const {};
    }
  }
}
