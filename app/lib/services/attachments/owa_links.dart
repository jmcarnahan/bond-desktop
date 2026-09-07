/// The file that came as a link rather than as an attachment.
///
/// Outlook's "attach as link" does not produce a Graph attachment. The message
/// arrives with `hasAttachments: false` and an empty attachment list, and the
/// file is in the BODY: an OWALink entity, which Exchange renders to plain text
/// as a run delimited by zero-width spaces —
///
/// ```text
/// U+200B [<icon url>]<file name><<target url>> U+200B
/// ```
///
/// So the only place the fact exists is the body, and the only moment it
/// exists is the detail fetch. This file is the parse: it rewrites each run to
/// an `[[att:<id>]]` marker — the same marker `layOutBody` places a chip on, so
/// the file appears where the sender put it — and answers the rows the sync
/// should write.
///
/// Two discriminations carry the whole thing.
///
/// - **The delimiters, not the shape.** An ordinary hyperlink converts to the
///   same `text<url>` form. What separates the two is the U+200B on either
///   side, which Exchange writes for an entity and for nothing else. Reading
///   the shape alone would turn every link in every mail into an attachment.
/// - **The host, not the extension.** A row is only worth writing for a file a
///   connector can actually read through `inspect_file`: SharePoint and
///   OneDrive. A Google Drive link is a link neither connector can open, so its
///   run is merely cleaned to `name <url>` and no row is written — a chip that
///   could never be read is worse than the text the sender wrote.
///
/// Pure, and deliberately so: no store, no sync, no widgets. It is called from
/// `SyncService._fetchDetailInto` and tested on its own strings.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show immutable;

import 'attachment_policy.dart' show maxAttachmentsPerMessage;

/// One Outlook "attach as link" entity as Exchange renders it to text.
@immutable
class OwaLink {
  final String name;
  final String url;
  final String iconUrl;

  const OwaLink({
    required this.name,
    required this.url,
    required this.iconUrl,
  });
}

/// The zero-width space Exchange wraps an OWALink entity in.
///
/// Written as an escape and never as itself: a literal in the source is a
/// character no reader can see, no reviewer can check and any editor can eat.
const String _zwsp = '\u200b';

/// U+200B-delimited `[icon]name<url>`. The delimiters are what separate an
/// OWALink entity from an ordinary hyperlink, which converts to the same
/// `text<url>` shape without them. The icon may be empty; the name may not.
final RegExp _owaLink =
    RegExp(r'\u200b\[([^\]\u200b]*)\]([^<\u200b]+?)<([^>\u200b\s]+)>\u200b');

/// Hosts whose files a connector can read through `inspect_file`.
const Set<String> _cloudHosts = {'onedrive.live.com', '1drv.ms'};

/// The parsed [url] when — and only when — it is a web address.
///
/// The same rule `webUriOf` states in `widgets/attachment_format.dart`, and a
/// test pins that the two agree. Re-stated rather than imported because a
/// service must not reach up into the widget layer for a string function; the
/// reasoning behind the rule lives on `webUriOf`, where the button that would
/// otherwise hand a stranger the launcher is.
Uri? _webUriOf(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  return uri;
}

/// Whether [url] points at a file a connector can read: a web address whose
/// host is `*.sharepoint.com` (which covers `*-my.sharepoint.com`, where every
/// personal OneDrive for Business file lives), `onedrive.live.com`, or
/// `1drv.ms`.
///
/// The test is on the host SUFFIX with its dot, never on a substring:
/// `notsharepoint.com` and `sharepoint.com.evil.example` are other people's
/// domains, and a link to one of them is not a file this app can open.
bool isCloudFileUrl(String url) {
  final uri = _webUriOf(url);
  if (uri == null) return false;
  // `https://a.sharepoint.com@evil.example/x` has a host of `evil.example`
  // and a user of `a.sharepoint.com`; Dart reads it that way and so refuses
  // it below, but no file address ever carries a user, so the form itself is
  // refused rather than trusted to any one parser's reading.
  if (uri.userInfo.isNotEmpty) return false;
  final host = uri.host.toLowerCase();
  return host.endsWith('.sharepoint.com') || _cloudHosts.contains(host);
}

/// A deterministic attachment id for a link: `link-` + the first 64 bits of
/// sha256(url), as 16 hex characters.
///
/// Derived from the url rather than allocated, because there is no connector
/// id to borrow — the same message fetched twice must produce the same row and
/// the same work item, or every detail fetch would double the shelf. Never
/// contains `|`, which is the separator `attachmentEntityId` splits a work
/// item's id on.
String linkAttachmentId(String url) =>
    'link-${sha256.convert(utf8.encode(url)).toString().substring(0, 16)}';

/// The rewritten body and the rows to upsert beside it.
typedef OwaLinkExtraction = ({String body, List<Map<String, Object?>> rows});

/// Rewrites every accepted run to `[[att:<id>]]`, every other run to
/// `name <url>`, and answers the rows to upsert.
///
/// [startOrdinal] is where this message's link rows are numbered from — the
/// count of the connector's own attachments, so the real files keep the low
/// ordinals and the per-message cap counts them first.
///
/// A body with no U+200B is returned as it came, without the regex being run:
/// the delimiter is the cheap test, and nearly every message fails it.
OwaLinkExtraction extractOwaLinks(String? bodyText, {int startOrdinal = 0}) {
  final body = bodyText ?? '';
  if (!body.contains(_zwsp)) return (body: body, rows: const []);

  final rows = <Map<String, Object?>>[];
  // The same file linked twice is one row and two markers: the shelf shows
  // what came with the message, not how many times the sender pasted it.
  final seen = <String, String>{};

  final rewritten = body.replaceAllMapped(_owaLink, (match) {
    final icon = match.group(1) ?? '';
    final name = (match.group(2) ?? '').trim();
    final raw = match.group(3) ?? '';

    // A run with no name is not a file anybody can be shown; the url alone is
    // the honest remainder.
    if (name.isEmpty) return raw;
    if (!isCloudFileUrl(raw)) return '$name <$raw>';
    // The address is stored as Dart READ it, never as the sender wrote it:
    // `https://a.sharepoint.com\@evil.example/x` passes the gate with a host
    // of `a.sharepoint.com` and re-serialises with the backslash as a slash,
    // whereas the raw string, handed to a parser that treats `\` as `/` and
    // reads the host after the `@`, would go to `evil.example`. What the gate
    // approved is what the server is asked for.
    final url = _webUriOf(raw)!.toString();

    final existing = seen[url];
    if (existing != null) return existing;

    // The body is the sender's, so the number of runs in it is the sender's
    // too. A row past the per-message cap could never be read — the policy
    // refuses it by ordinal before any fetch — and a row that exists only to
    // be refused on every sync, and to sit on the shelf, is not worth
    // writing. The run is cleaned like a foreign host's instead.
    if (startOrdinal + rows.length >= maxAttachmentsPerMessage) {
      return '$name <$url>';
    }

    final link = OwaLink(name: name, url: url, iconUrl: icon);
    final id = linkAttachmentId(link.url);
    rows.add({
      'attachment_id': id,
      'ordinal': startOrdinal + rows.length,
      'kind': 'reference',
      'name': link.name,
      // Both unknown until the first read: a link carries no metadata, and the
      // connector states the size and the type when it inspects the file.
      'content_type': null,
      'size': 0,
      'is_inline': false,
      'content_id': null,
      'source_url': link.url,
      // The icon is Office's own file-type glyph on a CDN — decoration, and
      // never a picture of this file. Storing it would put a stranger's url in
      // the column the preview fetches a thumbnail from.
      'thumbnail_url': null,
      'card_text': null,
    });
    final marker = '[[att:$id]]';
    seen[url] = marker;
    return marker;
  });

  // A delimiter left over from a run this regex did not match is invisible
  // garbage: it reaches search, a card and a prompt as a character nobody can
  // see or type.
  return (body: rewritten.replaceAll(_zwsp, ''), rows: rows);
}
