import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/html_text.dart' show safeLinksTargetOf;
import '../theme/tokens.dart';

/// The canonical link run a stored body carries: `label <url>` — the words a
/// sender saw, one space, and the whole address in angle brackets. The
/// converters in `services/` write it (an HTML anchor becomes one), and this is
/// the only thing in a body that is not literal text.
///
/// A body is still NEVER markdown. Nothing here reads `*`, `_`, `#` or `[](…)`.
final RegExp _runPattern = RegExp(
  r'<([^<>\s]+)>|(https?://[^\s<>]+)',
  caseSensitive: false,
);

/// A zero-width space. `mail_text` leaves them in bodies as soft break points,
/// and one riding on the end of an address is not part of the address.
const String _zeroWidth = '\u200B';

/// How much text may be a label where the caller does not say.
///
/// A canonical run carries no marker for where its label STARTS, so the extent
/// is inferred (see [_labelStart]) and prose with no punctuation in it runs on:
/// `Verify access to the tool at <url>` would underline the whole ask. Past the
/// caps the guess was wrong, and the address — which is never wrong — paints
/// itself instead.
///
/// These defaults are the TIGHT pair, for a line a model wrote: an ask line and
/// the CTA banner are sentences with an address somewhere in them, and a name is
/// short. A BODY is the other way round — its runs came from real anchors, whose
/// text is a sentence as often as a phrase ("Why am I receiving this
/// notification from Office?") — so `MessageRow` passes its own, generous pair.
const int defaultMaxLabelChars = 60;
const int defaultMaxLabelWords = 5;

/// The pair a message BODY reads with. Long enough for the anchor text real mail
/// carries, still short of a paragraph.
const int bodyMaxLabelChars = 140;
const int bodyMaxLabelWords = 14;

/// Whether [label] reads as the name of a link rather than as the sentence an
/// address landed in the middle of — see [defaultMaxLabelChars].
bool _isLabelShaped(String label, int maxChars, int maxWords) =>
    label.length <= maxChars && label.split(_blanks).length <= maxWords;

/// A run of whitespace — a transcript walks every body on every frame, so this
/// is built once rather than per label.
final RegExp _blanks = RegExp(r'\s+');

/// Characters a label may not reach back across, scanning right to left from
/// the space before `<`.
///
/// Newlines and tabs stop it because a label lives on one line. The clause
/// punctuation stops it only where a space follows, so `plan.pdf` and
/// `docs.example.com` stay whole inside a label while `Sent it. Details <…>`
/// keeps its first sentence out. Brackets and quotes stop it outright, and so
/// does a zero-width space.
bool _isLabelStop(String c, String next) {
  if (c == '\n' || c == '\r' || c == '\t' || c == _zeroWidth) return true;
  if ('()[]{}<>"'.contains(c)) return true;
  if ('.,;:!?'.contains(c)) return next == ' ';
  return false;
}

/// One piece of a body.
sealed class LinkedRun {
  const LinkedRun();
}

/// Words that are exactly what they say, painted verbatim.
final class PlainRun extends LinkedRun {
  final String text;

  const PlainRun(this.text);
}

/// A link. [label] is what gets PAINTED and [target] is where a tap goes: the
/// two differ on purpose, which is what lets a clamped line paint five words
/// and still open a two-hundred-character address.
final class LinkRun extends LinkedRun {
  final String label;
  final Uri target;

  const LinkRun(this.label, this.target);
}

/// The parsed [raw] when — and only when — it is somewhere a tap may go.
///
/// The rule `webUriOf` states in `attachment_format.dart`, plus `mailto:`: the
/// address in a body run came off an HTML anchor the sender wrote, and a mail
/// composer is not the launcher that rule is about. Everything else —
/// `file:///…`, `smb://…`, a custom scheme — is a stranger's string handed to
/// the operating system, so it stays literal text and no tap is offered at all.
Uri? linkTargetOf(String raw) {
  final trimmed = raw.replaceAll(_zeroWidth, '').trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  switch (uri.scheme.toLowerCase()) {
    case 'http':
    case 'https':
      return uri.host.isEmpty ? null : uri;
    case 'mailto':
      return uri.path.contains('@') ? uri : null;
    default:
      return null;
  }
}

/// [text] split into the words and the links in it, in order.
///
/// Two shapes become a link, and nothing else does:
///
/// - A canonical run, `label <url>`. The label is painted and the ` <url>` tail
///   is NOT — the address rides along as the target. With no label before it
///   (start of line, a bracket, the end of the previous run) the address paints
///   itself.
/// - A bare `http(s)` address, painted as itself.
///
/// A target [linkTargetOf] refuses makes no link: the run stays literal, angle
/// brackets and all, because a body must never hide what it could not vouch
/// for. Everything outside a run is untouched.
///
/// [maxLabelChars] and [maxLabelWords] say how much text may be a label — see
/// [defaultMaxLabelChars] for why a body and an ask line answer differently.
List<LinkedRun> linkSpansOf(
  String text, {
  int maxLabelChars = defaultMaxLabelChars,
  int maxLabelWords = defaultMaxLabelWords,
}) {
  final runs = <LinkedRun>[];
  // Where the plain text not yet emitted starts, and how far back a label may
  // reach — never into a run already taken.
  var cursor = 0;
  var floor = 0;

  void addPlain(int from, int to) {
    if (to > from) runs.add(PlainRun(text.substring(from, to)));
  }

  for (final match in _runPattern.allMatches(text)) {
    final bracketed = match.group(1);
    if (bracketed != null) {
      final target = linkTargetOf(bracketed);
      if (target == null) continue;
      // Canonical form is one space between label and address. Anything else
      // touching the `<` means there is no label to paint.
      final spaced = match.start > 0 && text[match.start - 1] == ' ';
      final labelEnd = spaced ? match.start - 1 : match.start;
      // The blanks in front of the label belong to the plain run before it, or
      // the words either side of a dropped tail run into each other.
      var labelStart = spaced ? _labelStart(text, labelEnd, floor) : labelEnd;
      while (labelStart < labelEnd && _isBlank(text[labelStart])) {
        labelStart++;
      }
      final label = text
          .substring(labelStart, labelEnd)
          .replaceAll(_zeroWidth, '')
          .trim();
      if (label.isEmpty ||
          !_isLabelShaped(label, maxLabelChars, maxLabelWords)) {
        addPlain(cursor, match.start);
        runs.add(LinkRun(bracketed.replaceAll(_zeroWidth, ''), target));
      } else {
        addPlain(cursor, labelStart);
        runs.add(LinkRun(label, target));
      }
      cursor = match.end;
      floor = match.end;
      continue;
    }

    // A bare address. Sentence punctuation after it belongs to the sentence.
    final kept = _withoutTrailingPunctuation(match.group(2)!);
    if (kept.isEmpty) continue;
    final url = kept.replaceAll(_zeroWidth, '');
    final target = linkTargetOf(url);
    if (target == null) continue;
    addPlain(cursor, match.start);
    runs.add(LinkRun(url, target));
    cursor = match.start + kept.length;
    floor = cursor;
  }

  addPlain(cursor, text.length);
  return runs;
}

/// The first ANCHORED web link in [text] — the words a sender wrote over it and
/// the address behind them — or null when the body offers none.
///
/// What a call-to-action button is built from. An automated notification's whole
/// point is somewhere else ("View comment", "Approve request", "Open in the
/// tracker"), and the one thing in the body that says where is its first anchor:
/// real notification mail puts its CTA above the footer links, so first is the
/// one the sender meant.
///
/// ANCHORED, and that is the whole of the filter. A run whose label is its own
/// address — a bare `https://…` in the prose, or a canonical run the label caps
/// refused — is skipped, because a button reading
/// *https://…safelinks…%2Foverview%23comment-…* tells a reader nothing and does
/// not fit on a row. `mailto:` is skipped for a different reason: a composer is
/// not an external tool, and the thing this answers is "the real action is over
/// there".
///
/// Pure, and it reads the body through [linkSpansOf] rather than a pattern of
/// its own: the address a button opens must be the same address the same words
/// open when they are tapped in the transcript, and two parsers would eventually
/// disagree. The label caps default to the BODY pair — these runs came from real
/// anchors, whose text is a sentence as often as a phrase.
LinkRun? firstLinkOf(
  String text, {
  int maxLabelChars = bodyMaxLabelChars,
  int maxLabelWords = bodyMaxLabelWords,
}) {
  for (final run in linkSpansOf(
    text,
    maxLabelChars: maxLabelChars,
    maxLabelWords: maxLabelWords,
  )) {
    if (run is! LinkRun) continue;
    if (run.target.scheme.toLowerCase() != 'http' &&
        run.target.scheme.toLowerCase() != 'https') {
      continue;
    }
    if (run.label.trim().isEmpty) continue;
    // The address painting itself is not an anchor. Asked of the LABEL through
    // [linkTargetOf] rather than compared against `target.toString()`: `Uri`
    // re-normalizes percent-encoding on the way back out, and a Safe Links
    // wrapper is nothing but percent-encoding, so a string comparison there
    // would call the address an anchor about half the time.
    if (linkTargetOf(run.label) != null) continue;
    return run;
  }
  return null;
}

bool _isBlank(String c) =>
    c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == _zeroWidth;

/// Where the label ending at [labelEnd] starts — see [_isLabelStop].
int _labelStart(String text, int labelEnd, int floor) {
  var start = labelEnd;
  for (var i = labelEnd - 1; i >= floor; i--) {
    // The last character of the label is never a stop: an anchor may well end
    // in a full stop, and reading one as a sentence boundary would throw the
    // whole label away.
    if (i < labelEnd - 1 && _isLabelStop(text[i], text[i + 1])) break;
    start = i;
  }
  return start;
}

/// [url] with the punctuation that ended the sentence taken off it. A closing
/// bracket survives only where the address opened one.
String _withoutTrailingPunctuation(String url) {
  var end = url.length;
  while (end > 0) {
    final c = url[end - 1];
    if ('.,;:!?\'"'.contains(c) || c == _zeroWidth) {
      end--;
      continue;
    }
    if ((c == ')' && !url.substring(0, end).contains('(')) ||
        (c == ']' && !url.substring(0, end).contains('['))) {
      end--;
      continue;
    }
    break;
  }
  return url.substring(0, end);
}

/// Plain text with the links in it live.
///
/// Mail content is NEVER markdown-rendered — this is the one narrow exception,
/// and it is links only: the two shapes [linkSpansOf] names, painted in the
/// product copper and underlined, and every other character left exactly as it
/// was stored.
///
/// Selection copies what is PAINTED, which for a canonical run is the label
/// rather than the address. That is the accepted trade: the reader who wants
/// the address clicks it.
///
/// Hovering a live link writes the host it opens on a caption line under the
/// text, and leaving it takes the line away. A label is the sender's words and
/// the host is where the click actually goes, so the reader can see both
/// before deciding. A line in the layout rather than a tooltip, because this
/// app has no popups.
class LinkedText extends StatefulWidget {
  final String text;

  final TextStyle? style;

  /// Where a tap on a link goes. Null paints the labels with no link styling
  /// and takes no taps — a host with nowhere to send one must not look like it
  /// takes one, the same rule `MessageRow.onOpenLink` follows.
  final void Function(Uri target)? onOpenLink;

  /// Whether the words can be selected and copied. A body can; a caption in a
  /// banner or an ask line never could, and this does not give it a selection
  /// handle it never had.
  final bool selectable;

  final int? maxLines;
  final TextOverflow? overflow;

  /// How much text may be a label. The defaults are the tight pair, for a line a
  /// model wrote; a body passes [bodyMaxLabelChars] and [bodyMaxLabelWords] —
  /// see [defaultMaxLabelChars].
  final int maxLabelChars;
  final int maxLabelWords;

  const LinkedText(
    this.text, {
    super.key,
    this.style,
    this.onOpenLink,
    this.selectable = true,
    this.maxLines,
    this.overflow,
    this.maxLabelChars = defaultMaxLabelChars,
    this.maxLabelWords = defaultMaxLabelWords,
  });

  @override
  State<LinkedText> createState() => _LinkedTextState();
}

class _LinkedTextState extends State<LinkedText> {
  /// The recognizers this widget made, which nothing else will dispose. Rebuilt
  /// — and the old ones dropped — whenever the text changes.
  final List<TapGestureRecognizer> _recognizers = [];

  late List<InlineSpan> _spans;

  /// The target of the live link under the mouse, or null. What the caption
  /// line under the text names.
  Uri? _hovered;

  @override
  void initState() {
    super.initState();
    _buildSpans();
  }

  @override
  void didUpdateWidget(LinkedText old) {
    super.didUpdateWidget(old);
    // A fresh closure every parent build is the normal case, so identity is
    // not compared: the recognizer calls whatever `widget.onOpenLink` is at the
    // moment of the tap. Only whether there is one at all changes the paint.
    if (old.text != widget.text ||
        old.style != widget.style ||
        old.maxLabelChars != widget.maxLabelChars ||
        old.maxLabelWords != widget.maxLabelWords ||
        (old.onOpenLink == null) != (widget.onOpenLink == null)) {
      _buildSpans();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  void _buildSpans() {
    _disposeRecognizers();
    // New spans are new links: a target hovered in the old text may not be in
    // this one, and its exit event will never come.
    _hovered = null;
    final live = widget.onOpenLink != null;
    final linkStyle = (widget.style ?? const TextStyle()).copyWith(
      color: BondColors.primary,
      decoration: TextDecoration.underline,
      decorationColor: BondColors.primary,
    );
    _spans = [
      for (final run in linkSpansOf(
        widget.text,
        maxLabelChars: widget.maxLabelChars,
        maxLabelWords: widget.maxLabelWords,
      ))
        switch (run) {
          PlainRun(:final text) => TextSpan(text: text),
          LinkRun(:final label, :final target) => live
              ? TextSpan(
                  text: label,
                  style: linkStyle,
                  recognizer: _recognizerFor(target),
                  mouseCursor: SystemMouseCursors.click,
                  onEnter: (_) => _hover(target),
                  onExit: (_) => _hover(null),
                )
              : TextSpan(text: label),
        },
    ];
  }

  void _hover(Uri? target) {
    if (!mounted || _hovered == target) return;
    setState(() => _hovered = target);
  }

  /// What the caption says for [target]: the host, which is the part of an
  /// address a person checks; the address itself for `mailto:`, which has no
  /// host; the whole target for anything else.
  ///
  /// A Safe Links wrapper is read through to the address it carries. The
  /// stored target stays the wrapper so the tenant's scan runs, but its host
  /// is Microsoft's on every wrapped link in an M365 mailbox, and a caption
  /// that says so for all of them tells the reader nothing about where one
  /// goes.
  static String _hostOf(Uri target) {
    final unwrapped = safeLinksTargetOf(target.toString());
    final unwrappedHost =
        unwrapped == null ? '' : Uri.tryParse(unwrapped)?.host ?? '';
    if (unwrappedHost.isNotEmpty) return unwrappedHost;
    if (target.host.isNotEmpty) return target.host;
    if (target.scheme.toLowerCase() == 'mailto') return target.path;
    return target.toString();
  }

  TapGestureRecognizer _recognizerFor(Uri target) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () => widget.onOpenLink?.call(target);
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  Widget build(BuildContext context) {
    final text = Text.rich(
      TextSpan(children: _spans),
      style: widget.style,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
    // Selection comes from a SelectionArea rather than `SelectableText.rich`:
    // SelectableText's only tap hook is the whole-widget `onTap` and it ignores
    // a span's recognizer, which would leave every link in a body dead.
    final body = widget.selectable ? SelectionArea(child: text) : text;
    if (widget.onOpenLink == null) return body;
    // A live body is ALWAYS in the column, and only the caption comes and
    // goes. Returning the bare body when nothing is hovered would change the
    // root widget's type on every enter and exit, which remounts the paragraph
    // and its SelectionArea: a drag-select crossing a link would lose its
    // selection mid-gesture.
    final hovered = _hovered;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        body,
        if (hovered != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              _hostOf(hovered),
              key: const ValueKey('linked-text-hover-host'),
              style:
                  BondType.caption.copyWith(color: BondColors.inkSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}
