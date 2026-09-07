/// The placeholders a chat body carries where a file or an image sat, and the
/// two things anything ever does with them: take them out, or read them back.
///
/// Teams puts a shared file in the message body as `<attachment id="…">` and a
/// pasted screenshot as an `<img>` pointing at a hosted-content id. The HTML
/// stripper used to delete both, which turned "here is the contract" into an
/// empty message and a screenshot into nothing at all. It now writes
/// `[[att:<id>]]` and `[[img:<id>]]` instead, so `messages.body_text` records
/// WHERE in the sentence the file was.
///
/// That makes the stored body the truth and every reader responsible for its
/// own view of it: the row renders a chip at the marker, and every prompt and
/// every embedding takes the marker out first, because a model shown
/// `[[att:AAMk…]]` reads it as a token to reason about rather than as a file.
library;

/// Both marker forms. `[^\]]*` rather than a strict id charset on purpose: a
/// marker this app did not write must still be removed rather than left in a
/// prompt because its id looked unfamiliar.
final RegExp _marker = RegExp(r'\[\[(?:att|img):[^\]]*\]\]');

/// The same shape, capturing — one regex would do for both, but the stripping
/// side wants no groups and the reading side wants two.
final RegExp _capturingMarker = RegExp(r'\[\[(att|img):([^\]]*)\]\]');

/// Runs of horizontal space and blank lines, which is what removing a marker
/// from the middle of a sentence leaves behind.
final RegExp _spaceRun = RegExp(r'[ \t]{2,}');
final RegExp _blankRun = RegExp(r'\n{3,}');

/// [text] with every marker replaced by a space, and the space that leaves
/// tidied up.
///
/// A space rather than nothing, because a marker between two words is where a
/// file sat in a sentence — "see [[att:x]] for the numbers" must not come out
/// as "seefor the numbers".
///
/// **A body carrying no marker is returned byte for byte**, and that early
/// return is the whole reason the tidying is safe. Almost every body this is
/// asked about is ordinary mail, where a run of spaces is a numbered list or an
/// indented quote and collapsing it would rewrite the message. Only a body that
/// actually lost a marker gets the cleanup, and such a body is a chat message —
/// short, unindented, and worth reading tidily.
///
/// Returns `''` for null and empty, so callers can hand over a nullable column
/// without a null check of their own.
String stripAttachmentMarkers(String? text) {
  if (text == null || text.isEmpty) return '';
  if (!_marker.hasMatch(text)) return text;
  return text
      .replaceAll(_marker, ' ')
      .replaceAll(_spaceRun, ' ')
      .replaceAll(_blankRun, '\n\n')
      .trim();
}

/// Whether [text] is nothing but markers — the shape a Teams message has when
/// somebody shared a file and typed no words with it.
///
/// This is what tells the prompt builders to synthesise a stand-in sentence
/// instead of sending the model a blank body.
bool isMarkerOnly(String? text) => stripAttachmentMarkers(text).isEmpty;

/// Every marker in [text], in the order it appears, as `(kind, id)` where kind
/// is `'att'` or `'img'`.
///
/// The row uses it to draw an attachment where the sender put it rather than
/// in a block at the bottom. An id it names may have no stored row — an edit
/// can remove a file the body still mentions — so callers look the id up and
/// skip what they cannot find.
List<(String kind, String id)> attachmentMarkers(String? text) {
  if (text == null || text.isEmpty) return const [];
  return [
    for (final match in _capturingMarker.allMatches(text))
      (match[1]!, match[2] ?? ''),
  ];
}

/// A pasted or inline image, as Teams writes it: an `<img>` whose src points
/// at the hosted-content endpoint. The captured group is the hosted-content
/// id, which is both the id the bytes are fetched by and the key an `image`
/// attachment row is stored under.
///
/// Public alongside [hostedContentIds] because the stripper wants the pattern
/// and the row builder wants the ids, and one regex is what keeps them
/// agreeing about what an inline image is.
final RegExp hostedImageTag = RegExp(
  r'''<img[^>]*src="[^"]*?/hostedContents/([A-Za-z0-9+/=_-]+)/\$value[^"]*"[^>]*>''',
  caseSensitive: false,
);

/// Every hosted-content id in [html], in body order.
///
/// It lives HERE, in the file that owns the marker vocabulary, rather than
/// beside the chat sync: `TeamsSync` writes a marker per image and
/// `GraphTeams` builds an attachment row per image, and a backend that had to
/// import the sync to ask this question would be a layer pointing the wrong
/// way. A second copy of the pattern in the other file is how the two would
/// come to disagree.
List<String> hostedContentIds(String? html) => [
      for (final match in hostedImageTag.allMatches(html ?? '')) match[1]!,
    ];
