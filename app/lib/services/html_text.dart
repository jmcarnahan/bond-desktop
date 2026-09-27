/// HTML into the text every reader in this app gets, in two profiles.
///
/// One tag stripper, deliberately, and not a DOM: there is no HTML parser in
/// this app's dependencies (`xml` is XML-only and throws on the first unclosed
/// `<br>`), and the two callers want different things out of the same page.
///
/// - [HtmlProfile.document] is a file the owner already has — a rendered
///   analysis, a chart export — read so that a search can answer with it.
///   A picture's `alt` is a sentence worth indexing, so it is lifted out.
/// - [HtmlProfile.mail] is a message body a person is about to read. A
///   picture's `alt` is `[Main Logo]`, `[Comment Icon]` or a template
///   placeholder the sender never meant to show, so every image goes —
///   except an inline one, which becomes the `[cid:…]` token the transcript
///   splices the real picture onto. Anchors become the canonical
///   `label <target>` run the linkifier and the prompt stripper both read.
///
/// Pure and import-light: every rule below is a decision about text, and
/// testable without a database, a server, a file or a widget.
library;

/// Which reader the text is for. See the library comment.
enum HtmlProfile { document, mail }

/// The words in [html], converted for [profile].
///
/// A MAIL body is always cut to [htmlInputCap], once its scripts, styles and
/// pictures are gone. A document is cut only when [capProse] asks, and then
/// once its scripts and styles are gone. Either way the cap bounds the prose
/// passes rather than the page (see the cap for why). [capProse] means
/// nothing to the mail profile.
String htmlToText(
  String html, {
  required HtmlProfile profile,
  bool capProse = false,
}) =>
    switch (profile) {
      HtmlProfile.document => _documentText(html, cap: capProse),
      HtmlProfile.mail => _mailText(html),
    };

/// How many characters of markup a converter on the UI isolate is handed.
///
/// Every pass below is a regular expression over the whole string, and a mail
/// body or an HTML attachment preview is converted where a frame is waiting on
/// it. Two million characters is far past any message a person wrote, and the
/// cap bounds the cost of the passes that do the most work per character.
/// What is past the cap is dropped with no marker: a truncated body simply
/// ends, because a marker would be words the sender never wrote, sitting in
/// the text a model reads.
///
/// Never on the raw markup. The weight of a big page is rarely its words: a
/// Plotly export's prose FOLLOWS megabytes of script, and a report mailed
/// with its charts as base64 `data:` pictures carries megabytes inside one
/// `<img>`. A cap on the raw markup keeps that weight and cuts the words, and
/// a cut inside a tag leaves a half tag no later pass can remove. So the
/// mail profile cuts after [_dropNonProse] and after its pictures are
/// dropped, and the attachment preview, which is on the UI isolate, asks for
/// `capProse` so a document is cut after [_dropNonProse]. The sweeps there
/// are lazy or anchored scans, and the passes after them are the ones worth
/// bounding. Context directory extraction runs off the UI isolate and does
/// not cap at all.
const int htmlInputCap = 2 * 1024 * 1024;

/// [html] cut to [htmlInputCap] characters, never between the two halves of a
/// surrogate pair: half a pair is a string Dart will hold and UTF-8 cannot
/// encode, so it would travel as far as the database write and throw there.
///
/// Nor inside a tag. A cut that lands between a tag's `<` and its `>` backs
/// off to that `<`, because a half tag matches no tag pattern and would reach
/// the reader as markup. Only a `<` that opens a tag counts (a letter, `/` or
/// `!` after it), and only within [_tagBackOffLimit] of the cut: a lone `<`
/// in prose (`x < y`) with two megabytes of words after it is not a tag, and
/// backing off to it would keep a body of two characters.
String capHtmlInput(String html) {
  if (html.length <= htmlInputCap) return html;
  var end = htmlInputCap;
  final last = html.codeUnitAt(end - 1);
  if (last >= 0xd800 && last <= 0xdbff) end--;
  final cut = html.substring(0, end);
  final after = cut.lastIndexOf('>') + 1;
  final floor = cut.length - _tagBackOffLimit;
  int? open;
  for (final m in _tagStart.allMatches(cut, after > floor ? after : floor)) {
    open = m.start;
  }
  return open == null ? cut : cut.substring(0, open);
}

/// How far back from the cut [capHtmlInput] looks for the tag it landed in.
/// No real tag is longer; a data-URI picture is, and those are dropped whole
/// before the mail profile cuts.
const int _tagBackOffLimit = 64 * 1024;

/// A `<` that opens a tag, an end tag, a comment or a doctype.
final RegExp _tagStart = RegExp(r'<[A-Za-z/!]');

// ── the sweeps both profiles run first ─────────────────────────────────

/// The blocks whose contents are not prose and must go BEFORE anything else
/// looks at a tag.
///
/// A Plotly export is the case this exists for: megabytes of embedded
/// JavaScript wrapped around one page of findings. Strip the script first and
/// what is left is the page; strip tags first and the index fills with
/// minified JS that happens to contain English words. A mail body pays the
/// same toll for its `<style>` block, which every M365 notification carries.
///
/// The `(?<!/)` is what keeps a SELF-CLOSING tag out of this: `<svg …/>` opens
/// nothing, so pairing it with the next `</svg>` on the page would delete
/// everything between two unrelated charts.
final RegExp _htmlDropped = RegExp(
  r'<(script|style|svg|noscript|head)\b[^<>]*(?<!/)>[\s\S]*?</\1\s*>',
  caseSensitive: false,
);

/// The same blocks, UNCLOSED, running to the end of the file.
///
/// [_htmlDropped] only catches matched pairs, and a file that is truncated —
/// a download interrupted, a page still being written when the walk reached
/// it — routinely ends inside its `<script>`. Without this the tag is
/// stripped by [_htmlAnyTag] and its whole body survives as prose, which is
/// exactly the failure [_htmlDropped] exists to prevent.
///
/// Two exclusions, and both are about not deleting the document. A
/// self-closing tag (`(?<!/)` again) never opened a block, and every
/// matplotlib and Plotly export writes its inline `<svg …/>` that way — a
/// sweep to end of file from one of those loses every finding below the
/// chart. `head` is absent from the list entirely, because an omitted
/// `</head>` is legal HTML rather than a truncation, and what follows it is
/// the whole page; [_htmlOpenHead] handles that one properly.
final RegExp _htmlUnclosed = RegExp(
  r'<(script|style|svg|noscript)\b[^<>]*(?<!/)>[\s\S]*$',
  caseSensitive: false,
);

/// A `<head>` whose end tag was omitted, ending where the body begins.
///
/// Only ever reached when there is no `</head>` — a closed head is already
/// gone with [_htmlDropped], leaving no `<head` for this to match. With no
/// `<body` on the page the lookahead fails and nothing is dropped, which is
/// the honest answer: there is no way to tell where such a head ends, and
/// keeping a title and some meta is cheaper than losing the document.
///
/// The body cannot run past a later `<head`, for the reason [_mailAnchor]
/// cannot run past a later `<a`: a page of unclosed heads must not scan to
/// the end once per opener.
final RegExp _htmlOpenHead = RegExp(
  r'<head\b[^<>]*(?<!/)>(?:(?!<head\b)[\s\S])*?(?=<body\b)',
  caseSensitive: false,
);

/// A comment, whose body cannot run past a later `<!--`: an unclosed one must
/// not scan the rest of the page once per opener.
final RegExp _htmlComment = RegExp(r'<!--(?:(?!<!--)[\s\S])*?-->');

/// Any tag. `[^<>]` rather than `[^>]`, and the difference is the running
/// time: a body full of stray `<` with no `>` after them (`a < b`, a thousand
/// times) made every `<` scan to the end of the text, which is quadratic.
/// Excluding `<` stops each attempt at the next one, so a lone `<` in prose
/// is left as text even when a real tag follows it later. Every other tag
/// pattern in this file uses `[^<>]*` for the same reason.
///
/// The trade: a tag whose attribute value holds a raw `<`
/// (`<span title="a<b">`) no longer matches as one tag, and leaves a fragment
/// such as `<span title="a` in the text. The old pattern cut such a tag at
/// the first `>` inside a value and leaked a fragment too.
final RegExp _htmlAnyTag = RegExp(r'<[^<>]*>');

/// An attribute whose value is longer than any address a server would take.
///
/// A mailed report carries its data inside the markup as often as beside it:
/// `<a download href="data:text/csv;base64,…">` (a pandas or nbconvert
/// export), `style="background-image:url(data:…)"`. Those megabytes are not
/// in an `<img>`, so the mail profile's picture drop leaves them, and the cap
/// then keeps two megabytes of base64 as the body; the cap's tag back-off
/// looks only [_tagBackOffLimit] behind the cut, so it cannot save it.
///
/// Any quoted or unquoted value of eight kilobytes or more is blanked,
/// whatever is in it, rather than only a value that starts `data:`. That one
/// rule catches the style case too, where the `data:` sits inside `url(…)`,
/// and a value that long is never an address a click could use: common
/// servers refuse a request line past eight kilobytes.
///
/// Linear on hostile input, which is why it is this shape and not a smarter
/// one. Each attempt starts at whitespace and an attribute name, and each
/// value run stops at the character that could open the next attempt: a
/// double-quoted value at `"`, a single-quoted one at `'`, an unquoted one at
/// whitespace, a quote or `=`. So no two attempts of one kind scan the same
/// characters, and a run that falls short fails in one step back per
/// character. `<` and `>` end every run as well, so a value can never reach
/// past its own tag. The cost: a value of that length holding a raw `<` or
/// `>` is not blanked, and the cap sees it as before. It is applied only to
/// the text of an opening tag of eight kilobytes or more, never to prose: a
/// CI log in a `<pre>` holds `token=` and nine kilobytes of base64, and that
/// is the sender's text.
final RegExp _longAttrValue = RegExp(
  r'''(\s[A-Za-z_:][-\w:.]*\s*=\s*)'''
  r'''(?:"[^"<>]{8192,}"|'[^'<>]{8192,}'|[^\s"'<>=]{8192,})''',
);

/// Comments first (one can contain a `</script>` that would otherwise close a
/// block early), then every matched block, then an unclosed head, and only
/// then the unclosed tail — asking for the tail first would eat the rest of
/// the page from the first `<script>` in a file that closes it perfectly
/// well, and an unclosed script inside an unclosed head is a script the head
/// sweep has already taken. The long attribute values go last, once the
/// scripts and styles whose text could look like one are gone, and before
/// either profile's cap.
String _dropNonProse(String raw) => raw
    .replaceAll(_htmlComment, '')
    .replaceAll(_htmlDropped, '')
    .replaceAll(_htmlOpenHead, '')
    .replaceAll(_htmlUnclosed, '')
    .replaceAllMapped(_htmlOpenTag, (t) => t[0]!.length < 8192
        ? t[0]!
        : t[0]!.replaceAllMapped(_longAttrValue, (m) => '${m[1]}""'));

/// An opening tag, read whole so that [_longAttrValue] only ever looks inside
/// one. `[^<>]*` for the reason [_htmlAnyTag] gives.
final RegExp _htmlOpenTag = RegExp(r'<[A-Za-z][^<>]*>');

/// A `<pre>` or `<textarea>` block, an opening tag that MAY start a styled
/// block, any other tag, or a run of the whitespace HTML itself treats as one
/// space.
///
/// The protected blocks are `<pre>`, `<textarea>`, and an element from
/// [_preStyledTags] whose inline `style` sets `white-space: pre`, `pre-wrap`
/// or `pre-line` (ticketing and CI mailers write comment bodies that way, and
/// a pasted Google Docs span does too).
///
/// A block's body cannot run past a later opening tag of its OWN name, for
/// the same reason [_mailAnchor] cannot run past a later `<a`: an unclosed one
/// must not scan the rest of the page once per opening tag. That is also the
/// limit: an element nested inside another of the same name ends the outer
/// one's protection, so a styled `<div>` holding a plain `<div>` finds that
/// `<div` before its own `</div>`, is not protected, and folds.
///
/// The styled block is NOT matched here, only its opening tag, and that is
/// what keeps the fold linear. As one pattern it had to ask the body scan
/// again for every `style=` and every `white-space:pre` a single tag repeated,
/// and an unclosed tag with a thousand of them ahead of a megabyte walked the
/// megabyte a thousand times. [_foldSourceWhitespace] gives each opener ONE
/// attempt instead: [_preStyle] reads the tag's own text, and
/// [_styledBlockEnd] looks for the closer no further than the next opener of
/// that name. The styled names are a fixed list for the same reason: each
/// name's attempts stop at that name's next opener, so a character is walked
/// at most once per name in the list, where a thousand invented names each
/// styled and unclosed would walk the rest of the page once per name.
final RegExp _sourceWhitespace = RegExp(
  r'(<(pre|textarea)\b[^<>]*>(?:(?!<\2\b)[\s\S])*?</\2\s*>)'
  '|(<($_preStyledTags)\\b[^<>]*>)'
  r'|(<[^<>]*>)|[\t\r\n ]+',
  caseSensitive: false,
);

/// The elements a `white-space: pre` style protects: the ones mail writes a
/// comment body into. See [_sourceWhitespace] for why the list is fixed.
const String _preStyledTags =
    'div|span|p|td|th|li|code|blockquote|font|section|article';

/// An inline style that keeps source whitespace, read on ONE tag's text.
///
/// Linear on that text: every value run starts after a quote and stops at the
/// next one, so repeated `style=` attributes never scan the same characters
/// twice, and the first `white-space:pre` found is the answer.
final RegExp _preStyle = RegExp(
  r'''\bstyle\s*=\s*["'][^"'<>]*?white-space\s*:\s*pre''',
  caseSensitive: false,
);

/// The next opening or closing tag of each styled name, for
/// [_styledBlockEnd]. Built once per name.
final Map<String, RegExp> _sameNameEdge = {
  for (final name in _preStyledTags.split('|'))
    name: RegExp('<(/?)$name\\b', caseSensitive: false),
};

/// What must follow `</name` for it to be a closing tag.
final RegExp _closeTail = RegExp(r'\s*>');

/// Where the styled block whose opening tag ends at [from] ends, or null
/// when a later opener of the same [name] (or the end of the input) comes
/// before its closer. Scans no further than that next opener, which is what
/// bounds each opener to one walk of its own body.
int? _styledBlockEnd(String html, int from, String name) {
  for (final edge in _sameNameEdge[name]!.allMatches(html, from)) {
    if (edge.group(1)!.isEmpty) return null;
    final tail = _closeTail.matchAsPrefix(html, edge.end);
    if (tail != null) return tail.end;
  }
  return null;
}

String _lineFeeds(String block) =>
    block.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

/// The source's own line breaks as what they are in HTML: a space.
///
/// A `<br>` and a block tag are the only line breaks a page has. Exchange
/// writes plain-text mail as `line<br>\r\nline<br>\r\n…`, and a converter that
/// maps the `<br>` to a newline AND keeps the CR/LF beside it double-spaces
/// every such message; a sender whose client wrapped a paragraph at 76
/// columns gets a line break in the middle of each sentence. So every run of
/// tab, CR, LF and space folds to one space before any tag writes a newline.
///
/// A `<pre>` block is the exception, because there the source's newlines ARE
/// the layout: its body is kept as written, with CR/LF read as LF. Its
/// newlines survive every later pass; the indentation does not, because
/// [_normalizeWhitespace] trims the blanks around each newline. A
/// `<textarea>` and an element styled `white-space: pre…` are kept the same
/// way, with the nesting limit [_sourceWhitespace] states.
///
/// A tag is left as written too. Whitespace inside one separates attributes,
/// which every tag pattern already reads with `\s`, or sits inside an
/// attribute value, where it is the value's own business: [_anchorRun] takes
/// the tab, CR and LF out of an `href` the way a browser does, which a space
/// written here would have turned into `%20`.
///
/// U+00A0 is left for [_normalizeWhitespace], and U+200B is in no class here,
/// for the reason given there.
String _foldSourceWhitespace(String html) {
  final out = StringBuffer();
  var written = 0;
  for (final m in _sourceWhitespace.allMatches(html)) {
    // Inside a styled block already written whole.
    if (m.start < written) continue;
    out.write(html.substring(written, m.start));
    written = m.end;
    final pre = m.group(1);
    if (pre != null) {
      out.write(_lineFeeds(pre));
      continue;
    }
    final opener = m.group(3);
    if (opener != null && _preStyle.hasMatch(opener)) {
      final end = _styledBlockEnd(html, m.end, m.group(4)!.toLowerCase());
      if (end != null) {
        out.write(_lineFeeds(html.substring(m.start, end)));
        written = end;
        continue;
      }
    }
    out.write(opener ?? m.group(5) ?? ' ');
  }
  out.write(html.substring(written));
  return out.toString();
}

/// Runs of spaces collapse; tabs survive, because they are what separates one
/// table cell from the next and a row read as one word is a row nobody can
/// search.
///
/// U+200B is absent from every class here on purpose. Exchange delimits an
/// "attach as link" entity with zero-width spaces and nothing else, so a
/// converter that trims or collapses them turns every linked file in every
/// body into an ordinary hyperlink — `extractOwaLinks` reads the delimiters,
/// not the shape. Dart's own `trim` leaves U+200B alone (it is not Unicode
/// White_Space), which is why the trims below are safe.
String _normalizeWhitespace(String text) => text
    .replaceAll(RegExp(r'[ \u00a0]+'), ' ')
    .replaceAll(RegExp(r'[ \t]*\n[ \t]*'), '\n')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();

// ── the document profile ───────────────────────────────────────────────

final RegExp _htmlHeadingOpen = RegExp(r'<h([1-6])\b[^<>]*>', caseSensitive: false);
final RegExp _htmlHeadingClose = RegExp(r'</h[1-6]\s*>', caseSensitive: false);
final RegExp _htmlBlock = RegExp(
  r'</?(p|div|section|article|li|tr|table|br|hr|blockquote|pre)\b[^<>]*>',
  caseSensitive: false,
);
final RegExp _htmlCell = RegExp(r'</(td|th)\s*>', caseSensitive: false);

/// The attributes that carry the only words a picture has.
///
/// A chart in an analysis is an `<img>` or an inline `<svg>`, and its `alt`
/// or `aria-label` is the one sentence saying what it shows — routinely the
/// most retrievable line on the page.
///
/// `svg` earns its place here only for the SELF-CLOSING spelling: a matched
/// `<svg>…</svg>` is gone with [_htmlDropped] before labels are lifted, and
/// its label with it. That is the right trade — the alternative is lifting
/// labels out of a block that may hold a megabyte of path data — and
/// `<svg …/>`, which is what a chart export writes, keeps its sentence.
final RegExp _htmlLabelled = RegExp(
  r'<(img|svg|figure|div)\b[^<>]*?\b(alt|aria-label|title)\s*=\s*'
  '''(?:"([^"]*)"|'([^']*)')''',
  caseSensitive: false,
);

/// What this gives up is nesting-aware structure; what it keeps is every
/// heading, every table cell, every paragraph and every picture's label,
/// which is the whole of what a rendered analysis says.
String _documentText(String raw, {bool cap = false}) {
  var text = _dropNonProse(raw);
  // Cut after the script sweep, never before it: see [htmlInputCap].
  if (cap) text = capHtmlInput(text);
  text = _foldSourceWhitespace(text);

  // The picture labels are lifted out BEFORE the tags go, each onto its own
  // line, because a stripper that only deletes tags deletes them with it.
  final labels = <String>[];
  for (final match in _htmlLabelled.allMatches(text)) {
    final value = (match.group(3) ?? match.group(4) ?? '').trim();
    if (value.isNotEmpty) labels.add(value);
  }

  text = text
      .replaceAllMapped(
        _htmlHeadingOpen,
        (m) => '\n${'#' * int.parse(m.group(1)!)} ',
      )
      .replaceAll(_htmlHeadingClose, '\n')
      .replaceAll(_htmlCell, '\t')
      .replaceAll(_htmlBlock, '\n')
      .replaceAll(_htmlAnyTag, '');

  text = _normalizeWhitespace(decodeHtmlEntities(text));

  if (labels.isNotEmpty) text = '$text\n\n${labels.join('\n')}';
  return text.trim();
}

// ── the mail profile ───────────────────────────────────────────────────

/// The private markers the mail pass carries through the tag strip.
///
/// A canonical link run is written with real angle brackets, and
/// [_htmlAnyTag] would read `<https://…>` as a tag and delete it. So a run is
/// spliced in with its brackets held as [_openMark]/[_closeMark] and restored
/// once every tag is gone. The quote marks work the same way for a
/// `<blockquote>`, whose depth can only be known while the tags still exist
/// but whose `> ` prefix can only be written once the lines do.
///
/// The fifth, [_ampMark], holds a run's `&`. A run's label and target are
/// decoded once, as the run is built, and the whole text is decoded again
/// after the tags go; without the mark a label the sender escaped twice
/// (`&amp;lt;b&amp;gt;`) would be decoded twice inside an anchor and once
/// outside one.
///
/// C0 controls, because no mail body has one: [_mailText] strips all five from
/// its input before it writes any of them, so a crafted body cannot forge a
/// bracket, an ampersand or a quote level.
const String _quoteOpen = '\u0001';
const String _quoteClose = '\u0002';
const String _openMark = '\u0003';
const String _closeMark = '\u0004';
const String _ampMark = '\u0005';

final RegExp _mailMarks =
    RegExp('[$_quoteOpen$_quoteClose$_openMark$_closeMark$_ampMark]');

final RegExp _mailImg = RegExp(r'<img\b[^<>]*>', caseSensitive: false);
/// An anchor, whose body cannot run across a later `<a` or `</a`: an unclosed
/// `<a` would otherwise scan the rest of the body for a `</a>` past every other
/// anchor, once per unclosed tag, and take them all into one label.
final RegExp _mailAnchor = RegExp(
  r'<a\b([^<>]*)>((?:(?!</?a\b)[\s\S])*?)</a\s*>',
  caseSensitive: false,
);
final RegExp _mailQuoteOpen =
    RegExp(r'<blockquote\b[^<>]*>', caseSensitive: false);
final RegExp _mailQuoteClose =
    RegExp(r'</blockquote\s*>', caseSensitive: false);
final RegExp _mailItemOpen = RegExp(r'<li\b[^<>]*>', caseSensitive: false);
final RegExp _mailItemClose = RegExp(r'</li\s*>', caseSensitive: false);
final RegExp _mailBlock = RegExp(
  r'</?(p|div|section|article|table|tbody|thead|tfoot|caption|br|hr|pre|'
  r'h[1-6]|ul|ol|dl|dd|dt|center|fieldset|form)\b[^<>]*>',
  caseSensitive: false,
);

/// A row opens a line and closes nothing.
///
/// Both ends mapped to a newline is what double-spaces a table, and a
/// notification mail whose layout IS a table then reads as a blank line
/// between every pair of cells. `tr` is absent from [_mailBlock] for this.
final RegExp _mailRowOpen = RegExp(r'<tr\b[^<>]*>', caseSensitive: false);
final RegExp _mailRowClose = RegExp(r'</tr\s*>', caseSensitive: false);

/// A run of `<div>` boundaries with nothing but a space between them is ONE
/// line break.
///
/// Outlook writes a message as one `<div>` per line, and a browser draws
/// `<div>one</div><div>two</div>` as two lines with no gap. Mapping each end
/// of each div to its own newline read it as a blank line between every pair,
/// the same double spacing [_foldSourceWhitespace] removes from `<br>` mail. A
/// blank line the sender typed is `<div><br></div>`, and the `<br>` still
/// writes it. `<p>` keeps its paragraph gap.
final RegExp _mailDivRun =
    RegExp(r'(?:</?div\b[^<>]*>[ ]*)+', caseSensitive: false);

final RegExp _attrHref = _attrPattern('href');
final RegExp _attrSrc = _attrPattern('src');

RegExp _attrPattern(String name) => RegExp(
      '''\\b$name\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s"'>]+))''',
      caseSensitive: false,
    );

String _attrOf(RegExp pattern, String tag) {
  final m = pattern.firstMatch(tag);
  if (m == null) return '';
  return m.group(1) ?? m.group(2) ?? m.group(3) ?? '';
}

String _mailText(String raw) {
  var text = _dropNonProse(raw.replaceAll(_mailMarks, ''));
  text = _foldSourceWhitespace(text);

  // Images before anchors, so a linked icon is an anchor with no label left
  // and drops whole rather than leaving its target on a line of its own.
  text = text.replaceAllMapped(_mailImg, (m) => _imageToken(m.group(0)!));
  // The cut comes here, once the scripts, the styles and the pictures are
  // gone, so a base64 chart costs the body nothing (see [htmlInputCap]).
  text = capHtmlInput(text);
  text = text.replaceAllMapped(_mailAnchor, (m) => _anchorRun(m));

  text = text
      .replaceAll(_mailQuoteOpen, '\n$_quoteOpen\n')
      .replaceAll(_mailQuoteClose, '\n$_quoteClose\n')
      .replaceAll(_mailItemOpen, '\n- ')
      .replaceAll(_mailItemClose, '\n')
      .replaceAll(_mailRowOpen, '\n')
      .replaceAll(_mailRowClose, '')
      .replaceAll(_htmlCell, '\t')
      .replaceAll(_mailDivRun, '\n')
      .replaceAll(_mailBlock, '\n')
      .replaceAll(_htmlAnyTag, '');

  // Nothing between here and the restore can write a marker:
  // [decodeHtmlEntities] refuses every code point under 32, so no `&#3;` in a
  // body becomes a bracket.
  text = decodeHtmlEntities(text);
  text = _normalizeWhitespace(text).replaceAll(RegExp(r' *\t *'), '\t');

  text = text
      .replaceAll(_openMark, '<')
      .replaceAll(_closeMark, '>')
      .replaceAll(_ampMark, '&');
  return _applyQuotePrefixes(text);
}

/// An inline picture becomes the `[cid:…]` token the transcript splices the
/// real bytes onto; every other picture becomes nothing at all.
///
/// Dropping without a placeholder is the point of this profile. Graph's own
/// text conversion writes `[alt]`, and the alt text in automated mail is
/// `[Main Logo]`, `[Comment Icon]`, `[Author]` or a template placeholder the
/// sender never resolved — lines that cost the reader the top of the message
/// and cost the models tokens to ignore.
String _imageToken(String tag) {
  final src = decodeHtmlEntities(_attrOf(_attrSrc, tag)).trim();
  if (!src.toLowerCase().startsWith('cid:')) return '';
  final cid = src.substring(4).replaceAll(RegExp(r'^<|>$'), '').trim();
  if (cid.isEmpty) return '';
  // The id is decoded already, so its `&`, `<` and `>` ride behind the marks
  // through the whole-text decode and the tag strip, the way a link run's do
  // (see [_ampMark]): `cid:a&amp;amp;b` names `a&amp;b`, and decoding it a
  // second time would name a picture that is not in the message.
  final held = cid
      .replaceAll('&', _ampMark)
      .replaceAll('<', _openMark)
      .replaceAll('>', _closeMark);
  return '[cid:$held]';
}

String _anchorRun(Match match) {
  // Tab, CR and LF inside an address are dropped, not kept: the URL standard
  // strips them before parsing, so that is the address a browser opens.
  final href = decodeHtmlEntities(_attrOf(_attrHref, match.group(1) ?? ''))
      .replaceAll(RegExp(r'[\t\r\n]'), '');
  // The label is the anchor's own text: its tags gone, its entities decoded,
  // its newlines flattened, so a CTA a designer wrapped in four spans reads
  // as the two words on the button. A `<br>` or a block tag inside it is a
  // space rather than nothing, or `View<br>order` reads as one word.
  final label = _normalizeWhitespace(
    decodeHtmlEntities(
      (match.group(2) ?? '')
          .replaceAll(_mailBlock, ' ')
          .replaceAll(_htmlAnyTag, ''),
    ).replaceAll('\n', ' '),
  );
  final run = canonicalLinkRun(label: label, target: href);
  // Label and target are decoded already, so their `&` is held behind its
  // mark through the second, whole-text decode (see [_ampMark]).
  return run
      .replaceAll('&', _ampMark)
      .replaceAll('<', _openMark)
      .replaceAll('>', _closeMark);
}

/// The `> ` prefixes for every line inside a `<blockquote>`, one level per
/// nesting, written once the lines exist.
String _applyQuotePrefixes(String text) {
  if (!text.contains(_quoteOpen) && !text.contains(_quoteClose)) return text;

  // Code units rather than characters: the markers are C0 controls, so no
  // surrogate pair is ever split by the comparisons below.
  final out = StringBuffer();
  var depth = 0;
  var atLineStart = true;
  for (final unit in text.codeUnits) {
    if (unit == 0x01) {
      depth++;
      continue;
    }
    if (unit == 0x02) {
      if (depth > 0) depth--;
      continue;
    }
    if (unit == 0x0a) {
      out.write('\n');
      atLineStart = true;
      continue;
    }
    if (atLineStart) {
      out.write('> ' * depth);
      atLineStart = false;
    }
    out.writeCharCode(unit);
  }
  return out
      .toString()
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

// ── links ──────────────────────────────────────────────────────────────

/// The parsed [url] when — and only when — it is a web address.
///
/// The same rule `webUriOf` states in `widgets/attachment_format.dart`, and a
/// test pins that the two agree. A body is the SENDER's string: `file:///…`
/// runs a local application, `smb://…` mounts a share, and a custom scheme
/// opens whichever app registered it, so a target the reader could click is
/// `http` or `https` with a real host and nothing else.
Uri? webTargetOf(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  return uri;
}

/// Microsoft's click-time rewriter. The suffix is tested WITH its dot, never
/// as a substring: `safelinks.protection.outlook.com.evil.example` is
/// somebody else's domain.
const String _safeLinksSuffix = '.safelinks.protection.outlook.com';

/// The address a Safe Links wrapper actually points at, or null when [url] is
/// not a wrapper or carries nothing openable.
///
/// Used to READ a wrapper — to build a label a person can recognise, and to
/// show where a link goes. The stored target stays the wrapper: the tenant
/// bought click-time scanning, and a click that skips it is a click the
/// tenant's policy never saw.
String? safeLinksTargetOf(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return null;
  if (!uri.host.toLowerCase().endsWith(_safeLinksSuffix)) return null;
  final wrapped = uri.queryParameters['url'];
  if (wrapped == null) return null;
  // Whatever came back is run through the same gate as any other target: a
  // wrapper is a string a sender chose, and `url=javascript%3A…` is the
  // shape that asks a reader's trust in the domain to carry a scheme.
  return webTargetOf(wrapped)?.toString();
}

/// How long a label built from a wrapped address may be. Long enough to carry
/// a host and where in it the link goes, short enough that the line does not
/// become the wall of URL this whole profile exists to remove.
const int _builtLabelCap = 60;

/// A host and the first thing after it, which is as much of an address as a
/// person reads before deciding whether to click.
String _readableLabelFor(String url) {
  final uri = webTargetOf(url);
  if (uri == null) return '';
  final segments = uri.pathSegments.where((s) => s.isNotEmpty);
  final label =
      segments.isEmpty ? uri.host : '${uri.host}/${segments.first}';
  if (label.length <= _builtLabelCap) return label;
  return '${label.substring(0, _builtLabelCap - 1)}…';
}

final RegExp _urlIsh =
    RegExp(r'^(?:https?://|www\.|mailto:)\S+$', caseSensitive: false);

/// A label that is itself an address rather than a description of one.
bool _looksLikeUrl(String label) => _urlIsh.hasMatch(label);

/// Two addresses compared the way a reader would: scheme, a leading `www.`
/// and a trailing slash are not the difference between them.
String _comparable(String url) => url
    .toLowerCase()
    .replaceFirst(RegExp(r'^https?://'), '')
    .replaceFirst(RegExp(r'^www\.'), '')
    .replaceFirst(RegExp(r'/$'), '');

/// One anchor as the canonical text run the rest of the app reads:
/// `label <target>`, with exactly one space before the bracket.
///
/// The five answers, and why each is the one:
///
/// - `label <target>` when there is a label and an openable target. This is
///   the form the linkifier finds, [stripLinkTargets] undoes for a prompt,
///   and `extractOwaLinks` reads between its zero-width spaces.
/// - The target alone when the label is the address again, which is what
///   every "paste a link" anchor is. Printing it twice is the noise.
/// - The target alone, too, when the label reads as an address on a
///   DIFFERENT host. A label that looks like an address is a claim about
///   where the click lands, and `https://bank.example` painted over a link to
///   somewhere else is the shape of a phishing mail; when the claim is false,
///   where the link really goes is what the reader needs. The claim is about
///   the HOST: a label on the target's own host that leaves off a path or a
///   tracking query is true, and keeps its words. A label that is exactly an
///   email address over a `mailto:` naming a different one is the same claim
///   and gets the same answer. A Safe Links wrapper is the one exception,
///   handled first: its label is rebuilt from the address it carries. A bare
///   domain (`bank.example`) is not read as a claim, because `Report.xlsx`
///   and `Node.js` look the same; the hover caption shows the host instead.
/// - The label alone when the target is not openable — `javascript:`, a
///   relative path, a bare fragment. A run whose bracket holds something no
///   click can follow is worse than the words the sender wrote.
/// - Nothing at all when there is no label. In mail that anchor is a linked
///   logo or a linked icon, and its target is the opaque hundred-character
///   address that opens the message with a line nobody can read.
String canonicalLinkRun({required String label, required String target}) {
  final text = label.trim();
  final raw = target.trim();
  if (raw.isEmpty) return text;

  final web = webTargetOf(raw);
  final uri = Uri.tryParse(raw);
  final String href;
  if (web != null) {
    // Stored as Dart READ it, never as the sender wrote it: a host reached
    // through a backslash or a userinfo `@` is a host one parser resolves
    // differently from the next.
    href = web.toString();
  } else if (uri != null &&
      uri.scheme.toLowerCase() == 'mailto' &&
      uri.path.trim().isNotEmpty) {
    href = uri.toString();
    // A plain address whose label is that same address: the words are the
    // whole of it, and `mailto:` in front of them is markup a reader has to
    // look past. A CTA with a prefilled cc, subject or body keeps its target,
    // because that query is the message the sender composed.
    if (!uri.hasQuery && _comparable(text) == _comparable(uri.path.trim())) {
      return text;
    }
    // An address painted over a composer for a different one.
    if (_bareAddress.hasMatch(text) && labelClaimsOtherHost(text, href)) {
      return href;
    }
  } else {
    return text;
  }

  if (web != null && (text.isEmpty || _looksLikeUrl(text))) {
    final unwrapped = safeLinksTargetOf(href);
    if (unwrapped != null) {
      final built = _readableLabelFor(unwrapped);
      // The label says where the link goes; the target stays the wrapper.
      if (built.isNotEmpty) return '$built <$href>';
    }
  }

  if (text.isEmpty) return '';
  if (_looksLikeUrl(text) && _comparable(text) == _comparable(href)) {
    return href;
  }
  // A label that promises a destination the click does not reach is
  // discarded: see [labelClaimsOtherHost], the rule the painter applies too.
  if (labelClaimsOtherHost(text, href)) return href;
  return '$text <$href>';
}

/// Whether [label], painted over a link to [target], claims a destination the
/// click does not reach.
///
/// ONE rule for two places. [canonicalLinkRun] applies it to a real anchor as
/// the body is converted, and `linkSpansOf` (`widgets/linked_text.dart`)
/// applies it again when a `label <url>` run is painted, because a stored body
/// reaches the painter by paths the converter never saw: escaped
/// `&lt;url&gt;` text, a body Graph converted itself (the MCP connection), a
/// Teams message.
///
/// True for:
///
/// - an address-shaped label (`https://…`, `www.…`, `mailto:…`) that is not
///   the target again and names another host, or no host a reader can check
///   (it will not parse, or it carries userinfo). The claim is about the HOST:
///   a label on the target's own host that leaves off a path or a tracking
///   query is true;
/// - a `mailto:` label over anything but that same address;
/// - a label that is exactly one email address, over a `mailto:` naming a
///   different one.
///
/// A Safe Links wrapper is read through to the address it carries, so the
/// claim is judged against where the click finally lands.
///
/// A bare domain (`bank.example`) is never a claim, because `Report.xlsx` and
/// `Node.js` look the same; the hover caption shows the host instead. Nor is
/// an email address over a web link, which is a person's name for a page.
bool labelClaimsOtherHost(String label, String target) {
  final text = label.trim();
  final href = target.trim();
  if (text.isEmpty || href.isEmpty) return false;
  final uri = Uri.tryParse(href);
  final mailto = uri != null && uri.scheme.toLowerCase() == 'mailto';
  if (mailto && _bareAddress.hasMatch(text)) {
    return text.toLowerCase() != uri.path.trim().toLowerCase();
  }
  if (!_looksLikeUrl(text)) return false;
  // A Safe Links wrapper is judged by the address it carries, as
  // [canonicalLinkRun] reads it: the label that function built for it
  // (`www.bank.example/statements`) names the wrapped host, never Microsoft's,
  // and a painter that compared it with the wrapper would repaint every such
  // run as two hundred characters of wrapper.
  final lands = safeLinksTargetOf(href) ?? href;
  if (_comparable(text) == _comparable(lands)) return false;
  if (text.toLowerCase().startsWith('mailto:')) return true;
  final claimed = _labelHost(text);
  return claimed == null ||
      claimed != _bareHost(Uri.tryParse(lands)?.host ?? '');
}

/// A label that is exactly one email address.
final RegExp _bareAddress = RegExp(r'^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$');

/// A host as a reader compares it: case and a leading `www.` are not the
/// difference between two.
String _bareHost(String host) =>
    host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');

/// The host an address-shaped label names, or null when it names none.
String? _labelHost(String label) {
  final spelled =
      label.toLowerCase().startsWith('www.') ? 'https://$label' : label;
  final uri = Uri.tryParse(spelled);
  // `https://bank.example@evil.example` is a label whose host, to Dart and to
  // a browser, is evil.example, while a reader sees bank.example. A label
  // carrying userinfo claims nothing a reader can check, so it names no host.
  if (uri == null || uri.userInfo.isNotEmpty) return null;
  final host = uri.host;
  return host.isEmpty ? null : _bareHost(host);
}

/// [text] with the `<target>` tail taken off every canonical run, keeping the
/// label.
///
/// For a prompt and for an embedding: a hundred characters of tracking query
/// are tokens the model spends to learn nothing, and the label is what the
/// sentence was about. A run with no label at all becomes its address in
/// plain text rather than nothing, because that address was the only thing
/// the sender put there; a bare URL that was never in a run is left alone.
String stripLinkTargets(String text) {
  if (!text.contains('<')) return text;
  return text.replaceAllMapped(_linkRunTail, (m) {
    final target = m.group(1)!;
    // Preceded by a label and a space: the label already says it.
    final before = m.start == 0 ? '' : text[m.start - 1];
    final labelled = m.group(0)!.startsWith(' ') &&
        before.isNotEmpty &&
        !_isBreak(before);
    return labelled ? '' : target;
  });
}

final RegExp _linkRunTail =
    RegExp(r' ?<((?:https?|mailto):[^>\s]+)>', caseSensitive: false);

bool _isBreak(String ch) => ch == '\n' || ch == '\t' || ch == ' ';

// ── entities ───────────────────────────────────────────────────────────

/// Every named character reference HTML 4.01 defines (all 252 of them), plus
/// `&apos;`, as a code point.
///
/// Mail used to reach this app through Graph's own text conversion, which
/// decoded them; since the HTML part is converted here, a newsletter that
/// escapes its punctuation by name (`We&rsquo;re`, `&copy; 2026`, the
/// `&zwnj;` padding behind a preheader) would otherwise be stored, shown,
/// indexed and prompted with the entity spelled out. HTML 4.01 rather than
/// HTML5's two thousand: it is the set every mail template writer reaches for,
/// it is small enough to review by eye, and it needs no new dependency.
///
/// Names are case-sensitive, as HTML says (`&Eacute;` is É and `&eacute;` is
/// é), and every one needs its `;`. A name not in the table is left as typed.
const Map<String, int> _namedEntities = {
  // Latin-1 (U+00A0 to U+00FF).
  // A plain space rather than U+00A0, as this decoder has always answered:
  // both profiles fold U+00A0 into a space anyway, and a caller of
  // [decodeHtmlEntities] outside them gets the same answer they always did.
  'nbsp': 0x20,
  'iexcl': 0xA1, 'cent': 0xA2, 'pound': 0xA3, 'curren': 0xA4,
  'yen': 0xA5, 'brvbar': 0xA6, 'sect': 0xA7, 'uml': 0xA8, 'copy': 0xA9,
  'ordf': 0xAA, 'laquo': 0xAB, 'not': 0xAC, 'shy': 0xAD, 'reg': 0xAE,
  'macr': 0xAF, 'deg': 0xB0, 'plusmn': 0xB1, 'sup2': 0xB2, 'sup3': 0xB3,
  'acute': 0xB4, 'micro': 0xB5, 'para': 0xB6, 'middot': 0xB7, 'cedil': 0xB8,
  'sup1': 0xB9, 'ordm': 0xBA, 'raquo': 0xBB, 'frac14': 0xBC, 'frac12': 0xBD,
  'frac34': 0xBE, 'iquest': 0xBF, 'Agrave': 0xC0, 'Aacute': 0xC1, 'Acirc': 0xC2,
  'Atilde': 0xC3, 'Auml': 0xC4, 'Aring': 0xC5, 'AElig': 0xC6, 'Ccedil': 0xC7,
  'Egrave': 0xC8, 'Eacute': 0xC9, 'Ecirc': 0xCA, 'Euml': 0xCB, 'Igrave': 0xCC,
  'Iacute': 0xCD, 'Icirc': 0xCE, 'Iuml': 0xCF, 'ETH': 0xD0, 'Ntilde': 0xD1,
  'Ograve': 0xD2, 'Oacute': 0xD3, 'Ocirc': 0xD4, 'Otilde': 0xD5, 'Ouml': 0xD6,
  'times': 0xD7, 'Oslash': 0xD8, 'Ugrave': 0xD9, 'Uacute': 0xDA, 'Ucirc': 0xDB,
  'Uuml': 0xDC, 'Yacute': 0xDD, 'THORN': 0xDE, 'szlig': 0xDF, 'agrave': 0xE0,
  'aacute': 0xE1, 'acirc': 0xE2, 'atilde': 0xE3, 'auml': 0xE4, 'aring': 0xE5,
  'aelig': 0xE6, 'ccedil': 0xE7, 'egrave': 0xE8, 'eacute': 0xE9, 'ecirc': 0xEA,
  'euml': 0xEB, 'igrave': 0xEC, 'iacute': 0xED, 'icirc': 0xEE, 'iuml': 0xEF,
  'eth': 0xF0, 'ntilde': 0xF1, 'ograve': 0xF2, 'oacute': 0xF3, 'ocirc': 0xF4,
  'otilde': 0xF5, 'ouml': 0xF6, 'divide': 0xF7, 'oslash': 0xF8, 'ugrave': 0xF9,
  'uacute': 0xFA, 'ucirc': 0xFB, 'uuml': 0xFC, 'yacute': 0xFD, 'thorn': 0xFE,
  'yuml': 0xFF,
  // Symbols, Greek letters, arrows and mathematical operators.
  'fnof': 0x192, 'Alpha': 0x391, 'Beta': 0x392, 'Gamma': 0x393, 'Delta': 0x394,
  'Epsilon': 0x395, 'Zeta': 0x396, 'Eta': 0x397, 'Theta': 0x398, 'Iota': 0x399,
  'Kappa': 0x39A, 'Lambda': 0x39B, 'Mu': 0x39C, 'Nu': 0x39D, 'Xi': 0x39E,
  'Omicron': 0x39F, 'Pi': 0x3A0, 'Rho': 0x3A1, 'Sigma': 0x3A3, 'Tau': 0x3A4,
  'Upsilon': 0x3A5, 'Phi': 0x3A6, 'Chi': 0x3A7, 'Psi': 0x3A8, 'Omega': 0x3A9,
  'alpha': 0x3B1, 'beta': 0x3B2, 'gamma': 0x3B3, 'delta': 0x3B4,
  'epsilon': 0x3B5, 'zeta': 0x3B6, 'eta': 0x3B7, 'theta': 0x3B8, 'iota': 0x3B9,
  'kappa': 0x3BA, 'lambda': 0x3BB, 'mu': 0x3BC, 'nu': 0x3BD, 'xi': 0x3BE,
  'omicron': 0x3BF, 'pi': 0x3C0, 'rho': 0x3C1, 'sigmaf': 0x3C2, 'sigma': 0x3C3,
  'tau': 0x3C4, 'upsilon': 0x3C5, 'phi': 0x3C6, 'chi': 0x3C7, 'psi': 0x3C8,
  'omega': 0x3C9, 'thetasym': 0x3D1, 'upsih': 0x3D2, 'piv': 0x3D6,
  'bull': 0x2022, 'hellip': 0x2026, 'prime': 0x2032, 'Prime': 0x2033,
  'oline': 0x203E, 'frasl': 0x2044, 'weierp': 0x2118, 'image': 0x2111,
  'real': 0x211C, 'trade': 0x2122, 'alefsym': 0x2135, 'larr': 0x2190,
  'uarr': 0x2191, 'rarr': 0x2192, 'darr': 0x2193, 'harr': 0x2194,
  'crarr': 0x21B5, 'lArr': 0x21D0, 'uArr': 0x21D1, 'rArr': 0x21D2,
  'dArr': 0x21D3, 'hArr': 0x21D4, 'forall': 0x2200, 'part': 0x2202,
  'exist': 0x2203, 'empty': 0x2205, 'nabla': 0x2207, 'isin': 0x2208,
  'notin': 0x2209, 'ni': 0x220B, 'prod': 0x220F, 'sum': 0x2211, 'minus': 0x2212,
  'lowast': 0x2217, 'radic': 0x221A, 'prop': 0x221D, 'infin': 0x221E,
  'ang': 0x2220, 'and': 0x2227, 'or': 0x2228, 'cap': 0x2229, 'cup': 0x222A,
  'int': 0x222B, 'there4': 0x2234, 'sim': 0x223C, 'cong': 0x2245,
  'asymp': 0x2248, 'ne': 0x2260, 'equiv': 0x2261, 'le': 0x2264, 'ge': 0x2265,
  'sub': 0x2282, 'sup': 0x2283, 'nsub': 0x2284, 'sube': 0x2286, 'supe': 0x2287,
  'oplus': 0x2295, 'otimes': 0x2297, 'perp': 0x22A5, 'sdot': 0x22C5,
  'lceil': 0x2308, 'rceil': 0x2309, 'lfloor': 0x230A, 'rfloor': 0x230B,
  'lang': 0x2329, 'rang': 0x232A, 'loz': 0x25CA, 'spades': 0x2660,
  'clubs': 0x2663, 'hearts': 0x2665, 'diams': 0x2666,
  // Markup-significant and internationalization characters.
  'quot': 0x22, 'amp': 0x26, 'lt': 0x3C, 'gt': 0x3E, 'OElig': 0x152,
  'oelig': 0x153, 'Scaron': 0x160, 'scaron': 0x161, 'Yuml': 0x178,
  'circ': 0x2C6, 'tilde': 0x2DC, 'ensp': 0x2002, 'emsp': 0x2003,
  'thinsp': 0x2009, 'zwnj': 0x200C, 'zwj': 0x200D, 'lrm': 0x200E, 'rlm': 0x200F,
  'ndash': 0x2013, 'mdash': 0x2014, 'lsquo': 0x2018, 'rsquo': 0x2019,
  'sbquo': 0x201A, 'ldquo': 0x201C, 'rdquo': 0x201D, 'bdquo': 0x201E,
  'dagger': 0x2020, 'Dagger': 0x2021, 'permil': 0x2030, 'lsaquo': 0x2039,
  'rsaquo': 0x203A, 'euro': 0x20AC,
  // Not in HTML 4.01, but XHTML and HTML5 both define it and mail uses it.
  'apos': 0x27,
};

/// One reference: numeric (`&#8217;`, `&#x2019;`) or named (`&rsquo;`). A name
/// is a letter and then one to eight letters or digits, which covers the
/// longest in the table (`thetasym`) and nothing longer.
final RegExp _entity =
    RegExp(r'&(?:#(x?)([0-9a-fA-F]+)|([A-Za-z][A-Za-z0-9]{1,8}));');

/// [text] with its entities as characters.
///
/// ONE pass, and that is what keeps `&amp;` last in effect: a replacement is
/// never scanned again, so a double-escaped `&amp;rsquo;` becomes `&rsquo;`
/// and not `’`, and `&amp;lt;` becomes `&lt;` and not `<`. It is also what
/// keeps the decode linear: one scan with a map lookup per match, never one
/// `replaceAll` per table entry.
String decodeHtmlEntities(String text) {
  if (!text.contains('&')) return text;
  return text.replaceAllMapped(_entity, (m) {
    final name = m.group(3);
    final int? code;
    if (name != null) {
      code = _namedEntities[name];
    } else {
      code = int.tryParse(m.group(2)!, radix: m.group(1)!.isEmpty ? 10 : 16);
    }
    // Unknown, out of range, a surrogate half, or unparseable: left as it was
    // typed rather than turned into a replacement character. The surrogate
    // range is named explicitly and it is the one that matters: half a pair is
    // a string Dart will hold and UTF-8 cannot encode, so it would travel this
    // far and then throw at the database write or the embedding POST. Under
    // 32 is refused so that no `&#3;` in a body can forge one of the mail
    // profile's markers.
    if (code == null ||
        code < 32 ||
        code > 0x10ffff ||
        (code >= 0xd800 && code <= 0xdfff)) {
      return m.group(0)!;
    }
    return String.fromCharCode(code);
  });
}
