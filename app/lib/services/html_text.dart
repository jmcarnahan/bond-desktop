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

/// Comments first (one can contain a `</script>` that would otherwise close a
/// block early), then every matched block, then an unclosed head, and only
/// then the unclosed tail — asking for the tail first would eat the rest of
/// the page from the first `<script>` in a file that closes it perfectly
/// well, and an unclosed script inside an unclosed head is a script the head
/// sweep has already taken.
String _dropNonProse(String raw) => raw
    .replaceAll(_htmlComment, '')
    .replaceAll(_htmlDropped, '')
    .replaceAll(_htmlOpenHead, '')
    .replaceAll(_htmlUnclosed, '');

/// A `<pre>` block, a tag, or a run of the whitespace HTML itself treats as
/// one space.
///
/// The `<pre>` body cannot run past a later `<pre`, for the same reason
/// [_mailAnchor] cannot run past a later `<a`: an unclosed one must not scan
/// the rest of the page once per opening tag.
final RegExp _sourceWhitespace = RegExp(
  r'(<pre\b[^<>]*>(?:(?!<pre\b)[\s\S])*?</pre\s*>)|(<[^<>]*>)|[\t\r\n ]+',
  caseSensitive: false,
);

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
/// [_normalizeWhitespace] trims the blanks around each newline.
///
/// A tag is left as written too. Whitespace inside one separates attributes,
/// which every tag pattern already reads with `\s`, or sits inside an
/// attribute value, where it is the value's own business: [_anchorRun] takes
/// the tab, CR and LF out of an `href` the way a browser does, which a space
/// written here would have turned into `%20`.
///
/// U+00A0 is left for [_normalizeWhitespace], and U+200B is in no class here,
/// for the reason given there.
String _foldSourceWhitespace(String html) =>
    html.replaceAllMapped(_sourceWhitespace, (m) {
      final pre = m.group(1);
      if (pre != null) {
        return pre.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      }
      return m.group(2) ?? ' ';
    });

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
  return '[cid:$cid]';
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
    if (_bareAddress.hasMatch(text) &&
        text.toLowerCase() != uri.path.trim().toLowerCase()) {
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
  if (_looksLikeUrl(text)) {
    // A `mailto:` label over anything else, or an address on another host
    // (or one that will not parse): the label is discarded, because the words
    // would promise a destination the click does not reach.
    if (text.toLowerCase().startsWith('mailto:')) return href;
    final claimed = _labelHost(text);
    if (claimed == null ||
        claimed != _bareHost(Uri.tryParse(href)?.host ?? '')) {
      return href;
    }
  }
  return '$text <$href>';
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

const Map<String, String> _namedEntities = {
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&#39;': "'",
  '&apos;': "'",
  '&nbsp;': ' ',
};

final RegExp _numericEntity = RegExp(r'&#(x?)([0-9a-fA-F]+);');

/// [text] with its entities as characters. `&amp;` LAST, so a double-escaped
/// `&amp;lt;` becomes `&lt;` and not `<`.
String decodeHtmlEntities(String text) {
  var out = text;
  for (final entry in _namedEntities.entries) {
    if (entry.key == '&amp;') continue;
    out = out.replaceAll(entry.key, entry.value);
  }
  out = out.replaceAllMapped(_numericEntity, (m) {
    final code = int.tryParse(m.group(2)!, radix: m.group(1)!.isEmpty ? 10 : 16);
    // Out of range, a surrogate half, or unparseable: left as it was typed
    // rather than turned into a replacement character. The surrogate range is
    // named explicitly and it is the one that matters: half a pair is a
    // string Dart will hold and UTF-8 cannot encode, so it would travel this
    // far and then throw at the database write or the embedding POST.
    if (code == null ||
        code < 32 ||
        code > 0x10ffff ||
        (code >= 0xd800 && code <= 0xdfff)) {
      return m.group(0)!;
    }
    return String.fromCharCode(code);
  });
  return out.replaceAll('&amp;', '&');
}
