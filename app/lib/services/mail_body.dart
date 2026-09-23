/// One message body, from whatever the connector handed us to the text the
/// transcript, the prompts and the search index all read.
///
/// Why this file exists: Graph will convert a body to text on the server if
/// asked, and what it writes is `label <href>` for every anchor and `[alt]`
/// for every image. In automated mail that is most of the message — a
/// hundred-character SharePoint address on a line of its own, `[Main Logo]`,
/// `[Comment Icon]`, `[Author]`, a template placeholder the sender never
/// resolved — and the comment somebody actually wrote sits below the fold. So
/// the HTML part is fetched instead and converted HERE, where the rules are
/// ours and every one of them is a test.
///
/// Pure: no store, no sync, no widgets, no clock. `SyncService` calls
/// [mailBodyFromDetail] once per detail fetch;
/// `stripSenderIdentification` (`mail_text.dart`) runs AFTER, on the result,
/// because Exchange's first-contact tip is text Exchange added and not a
/// conversion question.
library;

import 'html_text.dart';

/// The three link rules callers outside the conversion ask for by name. They
/// are defined beside the converter that writes the runs, and re-exported
/// here because a prompt builder or a row renderer reaches for the body, not
/// for an HTML profile. A file that imports both says `show` on this one.
export 'html_text.dart'
    show canonicalLinkRun, safeLinksTargetOf, stripLinkTargets;

/// The body text for a message detail, read according to what the connector
/// says [content] is.
///
/// [contentType] is Graph's own word — `html` or `text` — and null is read as
/// text, which is what every connector that states nothing sends.
String mailBodyFromDetail({
  required String? content,
  required String? contentType,
}) {
  final body = content ?? '';
  if (body.isEmpty) return '';
  final type = (contentType ?? '').trim().toLowerCase();
  // `text/html` as well as `html`: Graph says the short word, MIME says the
  // long one, and a connector that passes a header through sends the latter.
  if (type == 'html' || type == 'text/html') return mailTextFromHtml(body);
  return tidyMailText(body);
}

/// An HTML body as the text a person reads.
String mailTextFromHtml(String html) =>
    _tidy(htmlToText(html, profile: HtmlProfile.mail));

/// A body that arrived as text already, cleaned but not rewritten.
///
/// Light on purpose. The sender's own line breaks are the structure, an
/// `[cid:…]` token and a `label <url>` run may already be in here from the
/// connector or from `extractOwaLinks`, and a U+200B is load-bearing — so
/// this trims, collapses and strips the tenant's banner, and touches nothing
/// else.
String tidyMailText(String text) => _tidy(text);

/// The shared tail of both paths: whitespace a reader would not miss, and the
/// one line the tenant injected.
String _tidy(String text) {
  var out = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  out = out
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n');
  out = stripExternalBanner(out);
  // `trim` leaves U+200B alone — it is not Unicode White_Space — so a body
  // that opens with an "attach as link" entity keeps the delimiter
  // `extractOwaLinks` needs.
  return out.trim();
}

/// The banner a tenant's transport rule prepends to the BODY of external
/// mail: not a header, not a property, the first line of the message.
///
/// Anchored at the head and nowhere else. The same sentence in the middle of
/// a body is a person quoting the banner, or writing about it, and deleting
/// their words in place at ingest is not recoverable. Both spellings of the
/// dash, an optional warning glyph or `CAUTION:` lead-in, and the brackets
/// some rules wrap the whole line in.
final RegExp _externalBanner = RegExp(
  r'^\s*[\[\(]?[^\n]{0,40}?External\s+(?:Email|Sender|Message)\b'
  r'[^\n]{0,160}?[Uu]se\s+caution\b[^\n]*(?:\r?\n)*',
  caseSensitive: false,
);

/// [text] without that banner at its head. Unchanged when it is not there.
String stripExternalBanner(String text) {
  final match = _externalBanner.firstMatch(text);
  if (match == null) return text;
  return text.substring(match.end);
}
