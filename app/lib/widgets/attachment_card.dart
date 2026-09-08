import 'package:flutter/material.dart';

import '../models/attachment_models.dart';
import '../theme/tokens.dart';
import 'attachment_chip.dart';
import 'attachment_format.dart';
import 'hover_actions.dart';

/// One file, drawn the size a file is worth.
///
/// Slack's file card, plus the one line Slack cannot draw. A chip names a file
/// and stops; a card shows what the file LOOKS like — its first page, its
/// picture — beside its name and its size, which is what a reader scans a
/// transcript for when they are hunting a document rather than reading a
/// conversation.
///
/// The extra line is the model's: `AI: <one sentence>`, under the same label
/// every model line in the app wears. That label is the promise that a model
/// wrote what follows, and a digest sitting unlabelled under a file name would
/// read as something the sender said about their own attachment.
///
/// Selection is fill and border, never size — [AttachmentChip]'s rule, and for
/// its reason: a card that grew when it was picked would reflow the run
/// beneath it and move the next file out from under the pointer.
class AttachmentCard extends StatelessWidget {
  final AttachmentRef attachment;

  /// Whether this is the file the preview is showing. Compared by the host
  /// through `sameAttachment` — [AttachmentRef] has no `==`.
  final bool selected;

  /// The file's own picture — a PDF's first page, a photograph — or null when
  /// the host has none. An [ImageProvider] rather than bytes, so nothing under
  /// here ever reads a disk and a test can hand over a `MemoryImage`.
  final ImageProvider? image;

  /// What tapping it does. Null leaves it a statement, [AttachmentChip]'s rule:
  /// a card whose host has nowhere to send the tap must not look like it takes
  /// one.
  final VoidCallback? onTap;

  /// Puts this file into the reply being written. Null draws no hover strip at
  /// all — a host that cannot reply here must not offer to.
  final VoidCallback? onUseInReply;

  /// The bookmark-bar shape: a pill-card of one line and its digest, no
  /// picture and no hover strip. A pinned file is being LISTED rather than
  /// read, and a row of 320px cards under a room's name would be the room.
  final bool compact;

  const AttachmentCard({
    super.key,
    required this.attachment,
    this.selected = false,
    this.image,
    this.onTap,
    this.onUseInReply,
    this.compact = false,
  });

  /// Wide enough for a file name and a sentence about it, narrow enough that
  /// two sit side by side in the reading column.
  static const double width = 320;

  /// The bookmark bar's width, [PinnedDocumentsBar]'s old entry cap: a name
  /// can be arbitrarily long and a bar of them cannot.
  static const double compactWidth = 200;

  static ValueKey<String> keyFor(AttachmentRef attachment) =>
      attachmentKey('attachment-card', attachment);

  /// The picture INSIDE the card, when there is one. Its own key so a test can
  /// tell "this file has a rendering" from "this file has a card".
  static ValueKey<String> imageKeyFor(AttachmentRef attachment) =>
      attachmentKey('attachment-card-image', attachment);

  static Key useInReplyKeyFor(AttachmentRef attachment) =>
      attachmentKey('attachment-card-use', attachment);

  /// How tall the rendering is allowed to be. Enough to recognise a page by,
  /// short enough that three files on one message still leave the words above
  /// them on screen.
  static const double _imageHeight = 120;

  /// The band a file with no rendering gets instead — the glyph, at a size
  /// that reads as the file's own mark rather than as decoration.
  static const double _glyphBandHeight = 72;

  @override
  Widget build(BuildContext context) {
    if (compact) return _compact();

    final body = SizedBox(
      width: width,
      child: Container(
        decoration: BoxDecoration(
          color: selected ? BondColors.previewGround : BondColors.surface,
          borderRadius: BondRadii.mdAll,
          border: Border.all(
            color: selected ? BondColors.primary : BondColors.border,
          ),
        ),
        // The rendering runs to the card's own edges, so the corners have to
        // come off it rather than off a box inside it.
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _picture(),
            Padding(
              padding: const EdgeInsets.all(BondSpacing.s8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _displayName,
                    style: BondType.small.copyWith(
                      fontWeight: FontWeight.w600,
                      color: BondColors.ink,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (_caption.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(_caption, style: BondType.caption),
                  ],
                  ?_digestLine(maxLines: 2),
                  ?_readingHint(),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return _hoverable(_tappable(body, BondRadii.mdAll));
  }

  /// The rendering, or the mark that stands in for one.
  ///
  /// A file with no picture gets a band with its glyph rather than an empty
  /// frame: the frame is what an image that has not arrived yet looks like
  /// (see [InlineImageThumb]), and a spreadsheet is not a picture that failed
  /// to load.
  Widget _picture() {
    final provider = image;
    if (provider == null) {
      return Container(
        height: _glyphBandHeight,
        width: double.infinity,
        alignment: Alignment.center,
        color: BondColors.previewGround,
        child: Text(_glyph, style: const TextStyle(fontSize: 28)),
      );
    }
    return SizedBox(
      key: imageKeyFor(attachment),
      height: _imageHeight,
      width: double.infinity,
      child: Image(
        image: provider,
        fit: BoxFit.cover,
        // The same picture across a rebuild keeps its pixels rather than
        // flashing empty while it decodes again — a transcript rebuilds on
        // every sync.
        gaplessPlayback: true,
        errorBuilder: (context, error, stack) => Container(
          color: BondColors.previewGround,
          alignment: Alignment.center,
          child: Text(_glyph, style: const TextStyle(fontSize: 28)),
        ),
      ),
    );
  }

  /// The bookmark-bar shape. One line saying it is pinned and what it is, then
  /// the model's read of it — which is the whole reason a person pins a
  /// document rather than remembering where it was.
  Widget _compact() {
    final body = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: compactWidth),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: BondSpacing.s8,
          vertical: BondSpacing.s4,
        ),
        decoration: BoxDecoration(
          color: selected ? BondColors.previewGround : BondColors.faintGround,
          borderRadius: BondRadii.fullAll,
          border: Border.all(
            color: selected ? BondColors.primary : BondColors.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '📌 $_glyph ${attachment.name ?? '(unnamed)'}',
              style: BondType.caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            ?_digestLine(maxLines: 1),
          ],
        ),
      ),
    );
    // No hover strip here even when the host wired one: this is a bar of
    // bookmarks, and a strip that appeared over a 200px pill would cover the
    // name it is offering to act on.
    return _tappable(body, BondRadii.fullAll);
  }

  /// The model's one-line read, under the label every model line wears.
  ///
  /// The key is [attachmentKey]`('digest', …)` — the same one the chip row's
  /// captions carried before the card took the line over, so a test that found
  /// a digest by its file still finds it.
  Widget? _digestLine({required int maxLines}) {
    final summary = attachment.digest?.summary ?? '';
    if (summary.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        'AI: $summary',
        key: attachmentKey('digest', attachment),
        style: BondType.caption.copyWith(color: BondColors.inkMuted),
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// What the model is doing with this file, in the model's own quiet voice —
  /// and only once a digest is genuinely on its way: the words have landed and
  /// the model has not answered yet. [AttachmentChip] draws the same hint for
  /// the same reason, and the two must stay in step.
  Widget? _readingHint() {
    if (attachment.textStatus != 'done') return null;
    if (attachment.digestStatus != 'pending') return null;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        'reading…',
        style: BondType.caption.copyWith(color: BondColors.inkMuted),
      ),
    );
  }

  /// Its own transparent Material, because ink paints on the nearest Material
  /// ANCESTOR — which here is behind the pane's opaque surface, the trap
  /// `message_row._askLine` and `thread_detail_panel._ctaBanner` document.
  Widget _tappable(Widget body, BorderRadius radius) {
    final tap = onTap;
    if (tap == null) return body;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(onTap: tap, borderRadius: radius, child: body),
    );
  }

  Widget _hoverable(Widget body) {
    final use = onUseInReply;
    if (use == null) return body;
    return HoverActions(
      actions: [
        HoverAction(
          icon: Icons.reply_outlined,
          tooltip: 'Use in reply',
          onTap: use,
          key: useInReplyKeyFor(attachment),
        ),
      ],
      child: body,
    );
  }

  String get _glyph => attachmentGlyph(
        attachment.kind,
        attachment.contentType,
        name: attachment.name,
      );

  /// The size and what kind of thing this is, in one line.
  ///
  /// The kind is the model's word for it — a `quote`, a `contract` — when the
  /// model read the document, because that is what the reader is looking for;
  /// the extension is the fallback, because it is the only other thing said
  /// about a file that is not its name. `other` is the digest's "I could not
  /// say", so it defers to the extension rather than printing itself.
  String get _caption {
    final parts = [formatBytes(attachment.size), _kindLabel]
        .where((part) => part.isNotEmpty);
    return parts.join(' · ');
  }

  String get _kindLabel {
    final kind = attachment.digest?.kind ?? '';
    if (kind.isNotEmpty && kind != 'other') {
      // Capitalised to sit beside an upper-case extension: `240 KB · quote`
      // next to `240 KB · PDF` reads as two different captions.
      return kind[0].toUpperCase() + kind.substring(1);
    }
    return extensionOf(attachment.name).toUpperCase();
  }

  /// The name, truncated on graphemes before the `Text` sees it — the chip's
  /// cap and the chip's reason: ellipsis alone lays out the whole string
  /// first, and a 300-character name in a `Wrap` measures every character on
  /// every frame.
  String get _displayName {
    final name = attachment.name?.trim() ?? '';
    if (name.isEmpty) return '(unnamed)';
    final characters = name.characters;
    if (characters.length <= AttachmentChip.nameCap) return name;
    return '${characters.take(AttachmentChip.nameCap)}…';
  }
}
