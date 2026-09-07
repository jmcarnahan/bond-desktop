/// Every document on a storyline, on a shelf of its own, the pinned ones
/// first.
///
/// A storyline is several conversations about one thing, and the files that
/// matter to it are scattered down all of them. This is the answer to "where
/// is the quote" that does not involve scrolling four threads: every file on
/// every member thread is here, and pinning is how a person floats the one
/// they keep coming back to — and how they keep a file whose thread later
/// leaves the storyline.
///
/// Shaped like the member strip beside it (`storyline_timeline.dart`), because
/// they are the same kind of list: small bordered entries that explain
/// themselves in two lines and lead somewhere when tapped.
///
/// Unpinning is TWO taps in place — never a dialog. The house rule, and the
/// same shape Settings uses to clear the cache: `Remove` turns into
/// `Remove document` beside a `Cancel`, and nothing leaves until the second
/// press. What leaves is the PIN, not the file: a document on a member thread
/// stays on the shelf where it always was.
library;

import 'package:flutter/material.dart';

import '../models/attachment_models.dart';
import '../theme/tokens.dart';
import 'attachment_format.dart';

class AttachmentDocumentsStrip extends StatefulWidget {
  final List<AttachmentRef> documents;

  final void Function(AttachmentRef attachment) onOpen;

  /// Which storyline this shelf belongs to, so an entry can tell whether the
  /// pin it carries is a pin to THIS one. A file pinned to a different
  /// storyline is an ordinary thread document here. Null renders every entry
  /// as unpinned, which is the honest answer when nobody said.
  final String? storylineId;

  /// Null renders a shelf nothing can be pinned from — the entries are there,
  /// the `Pin` is not.
  final void Function(AttachmentRef attachment)? onPin;

  /// Null renders a read-only shelf: the entries are there, the two-step
  /// Remove is not.
  final void Function(AttachmentRef attachment)? onUnpin;

  const AttachmentDocumentsStrip({
    super.key,
    required this.documents,
    required this.onOpen,
    this.storylineId,
    this.onPin,
    this.onUnpin,
  });

  /// Wide enough for a file name and a sentence of the model's read, narrow
  /// enough that three fit across the pane.
  static const double entryMaxWidth = 320;

  static const Key emptyKey = ValueKey('attachment-documents-empty');

  static ValueKey<String> entryKeyFor(AttachmentRef attachment) =>
      attachmentKey('document-entry', attachment);

  static ValueKey<String> pinKeyFor(AttachmentRef attachment) =>
      attachmentKey('document-pin', attachment);

  static ValueKey<String> unpinKeyFor(AttachmentRef attachment) =>
      attachmentKey('document-unpin', attachment);

  static ValueKey<String> confirmKeyFor(AttachmentRef attachment) =>
      attachmentKey('document-unpin-confirm', attachment);

  @override
  State<AttachmentDocumentsStrip> createState() =>
      _AttachmentDocumentsStripState();
}

class _AttachmentDocumentsStripState extends State<AttachmentDocumentsStrip> {
  /// Which entry is asking a second time, by the pair of ids that identifies a
  /// file — never an index, which moves the moment the list is re-read.
  String? _confirming;

  static String _idOf(AttachmentRef attachment) =>
      '${attachment.messageId}/${attachment.attachmentId}';

  /// Pinned to THIS storyline, which is the only pin this shelf can undo.
  bool _isPinnedHere(AttachmentRef attachment) {
    final storylineId = widget.storylineId;
    return storylineId != null &&
        attachment.pinnedStorylineId == storylineId;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.documents.isEmpty) {
      return Text(
        'No documents on this storyline yet.',
        key: AttachmentDocumentsStrip.emptyKey,
        style: BondType.caption.copyWith(color: BondColors.inkMuted),
      );
    }
    return Wrap(
      spacing: BondSpacing.s8,
      runSpacing: BondSpacing.s8,
      children: [
        for (final document in widget.documents) _entry(document),
      ],
    );
  }

  Widget _entry(AttachmentRef document) {
    final pinned = _isPinnedHere(document);
    final pin = widget.onPin;
    final unpin = widget.onUnpin;
    final confirming = _confirming == _idOf(document);
    final glyph = attachmentGlyph(
      document.kind,
      document.contentType,
      name: document.name,
    );
    final subtitle = [
      formatBytes(document.size),
      document.digest?.summary ?? '',
    ].where((part) => part.isNotEmpty).join(' · ');

    return Container(
      key: AttachmentDocumentsStrip.entryKeyFor(document),
      constraints: const BoxConstraints(
        maxWidth: AttachmentDocumentsStrip.entryMaxWidth,
      ),
      decoration: BoxDecoration(
        color: BondColors.faintGround,
        borderRadius: BondRadii.smAll,
        border: Border.all(color: BondColors.border),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: BondSpacing.s8,
        vertical: BondSpacing.s4,
      ),
      // Its own transparent Material: ink paints on the nearest Material
      // ancestor, and the storyline pane is a decorated Container.
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () => widget.onOpen(document),
          borderRadius: BondRadii.smAll,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                // The marker rather than a second line: the order already says
                // which files were pinned, and the glyph is what makes that
                // readable once the shelf is longer than a screen.
                '${pinned ? '📌 ' : ''}$glyph ${document.name ?? '(unnamed)'}',
                style: BondType.caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  style: BondType.caption.copyWith(color: BondColors.inkMuted),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              if (pinned && unpin != null)
                _unpinControls(document, unpin, confirming)
              else if (!pinned && pin != null)
                _pinControl(document, pin),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pinControl(
    AttachmentRef document,
    void Function(AttachmentRef) pin,
  ) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        key: AttachmentDocumentsStrip.pinKeyFor(document),
        onPressed: () => pin(document),
        child: const Text('Pin'),
      ),
    );
  }

  Widget _unpinControls(
    AttachmentRef document,
    void Function(AttachmentRef) unpin,
    bool confirming,
  ) {
    if (!confirming) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: AttachmentDocumentsStrip.unpinKeyFor(document),
          onPressed: () => setState(() => _confirming = _idOf(document)),
          child: const Text('Remove'),
        ),
      );
    }
    // A `Wrap`, not a `Row`: two labelled buttons are wider than a 320-pixel
    // entry, and a confirmation that overflows its own card is a confirmation
    // nobody can read the second half of.
    return Wrap(
      spacing: BondSpacing.s4,
      children: [
        TextButton(
          key: AttachmentDocumentsStrip.confirmKeyFor(document),
          onPressed: () {
            setState(() => _confirming = null);
            unpin(document);
          },
          style: TextButton.styleFrom(foregroundColor: BondColors.error),
          child: const Text('Remove document'),
        ),
        TextButton(
          onPressed: () => setState(() => _confirming = null),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
