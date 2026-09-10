import 'package:flutter/material.dart';

import '../models/context_models.dart';
import '../models/draft_provenance.dart' show DraftProvenance;
import '../theme/tokens.dart';
import 'preview/preview_kind.dart' show monoForName;
import 'preview/text_preview.dart';
import 'time_format.dart';

/// One file of one of the owner's own registered directories, read beside the
/// room that named it.
///
/// Prop-only, like every body in this folder: the host resolves the file, the
/// directory and the passage, and this draws them. A `StatefulWidget` for one
/// reason and no other — the located passage has to be SCROLLED to after the
/// first layout, and a stateless widget has no frame to do that on.
///
/// The digest sits ABOVE the words deliberately. A person opening this is
/// usually asking what is in the file, and one paragraph answers that where
/// ten pages do not; the words are underneath for the reader who wants the
/// sentence itself.
///
/// The located passage is a highlighted CONTAINER between two more blocks of
/// text rather than a coloured span inside one. Three selectable blocks keep
/// the copy-a-number use working the way it does everywhere else in the app,
/// and only a widget of its own has a `BuildContext` for
/// [Scrollable.ensureVisible] to scroll to.
class ContextFilePanelBody extends StatefulWidget {
  final ContextFile file;

  /// The directory's display name — half of the breadcrumb over the words.
  final String dirName;

  /// The extracted words, as the last pass stored them.
  final String text;

  final ContextFileDigest? digest;

  /// The section a citation named, in the chunker's own spelling.
  final String? locator;

  /// The stored passage under [locator], header line already off. Null when
  /// nothing named a section, or when the passage is gone.
  final String? located;

  /// Non-null only when this panel was opened from a room a reply can be
  /// drafted in.
  final VoidCallback? onConsult;

  /// Injected rather than read from the clock, like every other timestamp in
  /// the widget layer, so a test can pin "3h ago".
  final DateTime now;

  const ContextFilePanelBody({
    super.key,
    required this.file,
    required this.dirName,
    required this.text,
    this.digest,
    this.locator,
    this.located,
    this.onConsult,
    required this.now,
  });

  static const Key consultKey = Key('context-file-consult');
  static const Key digestKey = Key('context-file-digest');
  static const Key locatedKey = Key('context-file-located');
  static const Key bodyKey = Key('context-file-body');

  /// The most characters of a passage used to find it in the words.
  ///
  /// Finding the passage runs on two rungs. The whole passage, verbatim, is
  /// tried first, and whenever the chunker's slice survived into the stored
  /// text intact — which is the usual case — that is the end of it. The second
  /// rung exists for the case it does not: an extractor that re-flowed the
  /// whitespace between the walk that chunked the file and the walk that
  /// stored its words leaves a passage that is the same sentences with
  /// different breaks between them. So the first [matchPrefix] characters are
  /// split into words and hunted with any run of whitespace allowed between
  /// them.
  static const int matchPrefix = 60;

  @override
  State<ContextFilePanelBody> createState() => _ContextFilePanelBodyState();
}

class _ContextFilePanelBodyState extends State<ContextFilePanelBody> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _highlight = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _highlight.currentContext;
      if (target == null || !mounted) return;
      // Zero duration: the panel opens ALREADY at the passage, because
      // animating there would show the reader the top of a file they did not
      // ask about and then take it away.
      Scrollable.ensureVisible(target, alignment: 0.1, duration: Duration.zero);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Where [located] starts inside [text], or -1.
  int get _matchAt {
    final raw = widget.located;
    if (raw == null || widget.text.isEmpty) return -1;
    final passage = raw.trim();
    if (passage.isEmpty) return -1;

    // The passage as the chunker cut it. A markdown section keeps its heading
    // line, so the needle spans a line break more often than not, and only a
    // verbatim try can follow it across one.
    final verbatim = widget.text.indexOf(passage);
    if (verbatim >= 0) return verbatim;

    // The words are the same and only the breaks between them moved, so hunt
    // the opening words with any run of whitespace allowed between them.
    final words = passage
        .substring(
          0,
          passage.length < ContextFilePanelBody.matchPrefix
              ? passage.length
              : ContextFilePanelBody.matchPrefix,
        )
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .map(RegExp.escape);
    if (words.isEmpty) return -1;
    return RegExp(words.join(r'\s+')).firstMatch(widget.text)?.start ?? -1;
  }

  @override
  Widget build(BuildContext context) {
    final mono = monoForName(widget.file.relPath);
    final consult = widget.onConsult;

    return ListView(
      key: ContextFilePanelBody.bodyKey,
      controller: _scroll,
      padding: const EdgeInsets.all(BondSpacing.s12),
      children: [
        Text(_caption, style: BondType.caption.copyWith(
          color: BondColors.inkMuted,
        )),
        if (consult != null) ...[
          const SizedBox(height: BondSpacing.s8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: ContextFilePanelBody.consultKey,
              onPressed: consult,
              icon: const Icon(Icons.auto_awesome, size: 16),
              label: const Text('Consult for the reply'),
            ),
          ),
          Text(
            'Regenerates the suggestion with this file read first.',
            style: BondType.caption.copyWith(color: BondColors.inkMuted),
          ),
        ],
        if (widget.digest != null) ...[
          const SizedBox(height: BondSpacing.s12),
          _digestBlock(widget.digest!),
        ],
        const SizedBox(height: BondSpacing.s12),
        ..._words(mono: mono),
      ],
    );
  }

  /// `<dir>/<path> · modified 3h ago`, plus `· truncated` when the extractor
  /// cut the words short — a reader concluding something from a file's
  /// silence should know the file was not read whole — and `· § Pricing › Q4
  /// rates` when a citation named a section.
  ///
  /// The section is named in words even though the passage is usually marked
  /// in the text below, because the two can disagree: a file re-read since the
  /// draft quoted it may no longer contain the passage, and a reader who
  /// arrived by a chip is owed the name of what was cited either way. The
  /// summary is not a section of the file, so it is left off.
  String get _caption {
    final when = relativeTime(widget.file.mtime, widget.now) ??
        (widget.file.mtime.length >= 10
            ? widget.file.mtime.substring(0, 10)
            : widget.file.mtime);
    final truncated = widget.file.status == 'truncated' ? ' · truncated' : '';
    final locator = widget.locator;
    final section = locator == null || locator.isEmpty || locator == 'digest'
        ? ''
        : ' · § ${DraftProvenance.locatorLabel(locator)}';
    return '${widget.dirName}/${widget.file.relPath} · modified $when'
        '$truncated$section';
  }

  /// The model's summary of this file, under the label the rest of the app
  /// reserves for a model's words.
  ///
  /// `AI` is a promise that what follows was written by a model rather than by
  /// a person — the rule `AttachmentSearchTile` states for why a verbatim
  /// passage must NEVER carry it — and a digest is exactly a model's words, so
  /// it belongs under it.
  Widget _digestBlock(ContextFileDigest digest) => Column(
        key: ContextFilePanelBody.digestKey,
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('AI', style: BondType.label),
          if (digest.purpose.isNotEmpty) ...[
            const SizedBox(height: BondSpacing.s4),
            Text(digest.purpose, style: BondType.body),
          ],
          for (final finding in digest.findings) ...[
            const SizedBox(height: BondSpacing.s4),
            Text('• $finding', style: BondType.small),
          ],
        ],
      );

  /// The file's words, in three pieces when a passage was named and one when
  /// it was not.
  List<Widget> _words({required bool mono}) {
    if (widget.text.trim().isEmpty) {
      return const [
        TextPreview(
          text: '',
          emptyReason: 'No text was extracted from this file.',
        ),
      ];
    }

    final at = _matchAt;
    final passage = widget.located?.trim();
    if (at < 0 || passage == null) {
      // Nothing to mark: either no section was named, or the passage no longer
      // reads back out of the words this pass stored.
      return [TextPreview(text: widget.text, mono: mono)];
    }

    final style = mono ? BondType.mono : BondType.body.copyWith(height: 1.4);
    // Clamped to what is there: a passage runs to the end of the file at
    // least as often as it runs out before it.
    final end = at + passage.length > widget.text.length
        ? widget.text.length
        : at + passage.length;

    return [
      if (at > 0) SelectableText(widget.text.substring(0, at), style: style),
      Container(
        key: _highlight,
        color: BondColors.primary.withValues(alpha: 0.12),
        child: SelectableText(
          widget.text.substring(at, end),
          key: ContextFilePanelBody.locatedKey,
          style: style,
        ),
      ),
      if (end < widget.text.length)
        SelectableText(widget.text.substring(end), style: style),
    ];
  }
}
