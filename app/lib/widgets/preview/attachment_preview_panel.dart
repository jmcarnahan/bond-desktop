/// One file, read beside the message it came with.
///
/// The panel is a ladder of refusals before it is a preview, and the order is
/// the design: a link is never fetched, a file over the connector's ceiling is
/// never fetched, a Word document is never fetched (the server already read
/// it), and only what is left is downloaded. Every one of those answers says
/// what it is and offers the way out that fits it, because "nothing happened"
/// is the worst thing a preview can do.
///
/// Three segments, always all three: **Preview** is the file, **Text** is its
/// words, **AI** is what the model made of it. They render whatever they have,
/// including "not yet" — a segment that disappeared while a digest was running
/// would move the controls under the reader's cursor.
///
/// Everything asynchronous is memoised in [State]. The inbox rebuilds on a
/// sixty-second poll, and a future created in `build` would re-download the
/// file every minute.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/attachment_models.dart';
import '../../services/attachments/attachment_bytes.dart';
import '../../services/attachments/xlsx_reader.dart';
import '../../theme/tokens.dart';
import '../attachment_format.dart';
import '../chips.dart';
import '../inline_alert.dart';
import 'eml_preview.dart';
import 'image_preview.dart';
import 'pdf_preview.dart';
import 'preview_engines.dart';
import 'preview_kind.dart';
import 'sheet_preview.dart';
import 'text_preview.dart';
import 'unsupported_preview.dart';

/// What the panel is showing about the file.
enum PreviewSegment { preview, text, ai }

class AttachmentPreviewPanel extends StatefulWidget {
  final AttachmentRef attachment;

  /// The bytes seam, never a backend or a cache: that is what lets a widget
  /// test render this with no socket, no isolate and no plugin.
  final AttachmentBytes bytes;

  final PreviewEngines engines;

  /// False inside the full viewer, where [PaneSurface] draws the header and
  /// its back arrow IS the way out — a second close control there would be two
  /// buttons doing one thing.
  final bool showHeader;

  /// Null hides the control. There is nowhere to expand to when the panel is
  /// already the whole pane.
  final VoidCallback? onExpand;

  final VoidCallback onClose;

  /// Handing the file to the operating system, and writing it somewhere the
  /// user picked. Null renders neither — a host with no way to do it must not
  /// offer to.
  final VoidCallback? onOpen;
  final VoidCallback? onSave;

  /// Wired in Phase 4. Rendered only when non-null, which is why they can ship
  /// here as nulls without an empty control on screen.
  final VoidCallback? onUseInReply;
  final VoidCallback? onPinToStoryline;

  /// Already on a storyline: the control says `Pinned` and stops answering,
  /// rather than disappearing. A button that vanished once it had been pressed
  /// would leave no sign that the pin happened.
  final bool pinned;

  /// Following a file out of this app — a OneDrive reference, a link a chat
  /// posted instead of a payload.
  final void Function(String url)? onOpenLink;

  const AttachmentPreviewPanel({
    super.key,
    required this.attachment,
    required this.bytes,
    required this.engines,
    this.showHeader = true,
    this.onExpand,
    required this.onClose,
    this.onOpen,
    this.onSave,
    this.onUseInReply,
    this.onPinToStoryline,
    this.pinned = false,
    this.onOpenLink,
  });

  static const Key expandKey = ValueKey('attachment-preview-expand');
  static const Key closeKey = ValueKey('attachment-preview-close');
  static const Key segmentsKey = ValueKey('attachment-preview-segments');
  static const Key loadingKey = ValueKey('attachment-preview-loading');
  static const Key errorKey = ValueKey('attachment-preview-error');
  static const Key retryKey = ValueKey('attachment-preview-retry');
  static const Key tooLargeKey = ValueKey('attachment-preview-too-large');
  static const Key openKey = ValueKey('attachment-preview-open');
  static const Key saveKey = ValueKey('attachment-preview-save');
  static const Key useInReplyKey = ValueKey('attachment-preview-use-in-reply');
  static const Key pinKey = ValueKey('attachment-preview-pin');
  static const Key sourceLinkKey = ValueKey('attachment-preview-source-link');
  static const Key openRefusedKey = ValueKey('attachment-preview-open-refused');

  @override
  State<AttachmentPreviewPanel> createState() => _AttachmentPreviewPanelState();
}

class _AttachmentPreviewPanelState extends State<AttachmentPreviewPanel> {
  PreviewSegment _segment = PreviewSegment.preview;

  /// The file itself. Null where this kind of file is never fetched — a link,
  /// something over the cap, a document the server already read for us.
  Future<Uint8List>? _bytesLoad;

  /// The pipeline's own extracted words. Always asked for: every kind has a
  /// Text segment, and this call never throws.
  Future<String?>? _textLoad;

  /// Derived from [_bytesLoad] and created only where the segment showing
  /// needs them — opening a two-hundred-page PDF to pull its text is real work
  /// to spend on a tab nobody clicked.
  Future<WorkbookTables>? _workbookLoad;
  Future<String>? _pdfTextLoad;

  /// OneDrive's rendering of a chat's shared document, for the one kind that
  /// has a picture but no bytes to draw it from.
  Future<Uint8List?>? _thumbLoad;

  @override
  void initState() {
    super.initState();
    _load(resetSegment: true);
  }

  @override
  void didUpdateWidget(AttachmentPreviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // `sameAttachment`, never `==`: [AttachmentRef] has no value equality, and
    // a digest landing between two frames must not re-download the file the
    // reader is looking at.
    if (!sameAttachment(oldWidget.attachment, widget.attachment)) {
      _load(resetSegment: true);
    }
  }

  /// Everything this attachment needs asked for once, here — never in `build`.
  void _load({bool resetSegment = false}) {
    if (resetSegment) _segment = PreviewSegment.preview;
    final attachment = widget.attachment;
    final kind = previewKindFor(attachment);

    _workbookLoad = null;
    _pdfTextLoad = null;
    _thumbLoad = null;
    _textLoad = _held(widget.bytes.textFor(attachment));
    _bytesLoad = _needsBytes(kind)
        ? _held(widget.bytes.bytesFor(attachment))
        : null;

    if (kind == PreviewKind.document && _hasRenderedThumbnail) {
      _thumbLoad = _held(widget.bytes.thumbnailFor(attachment));
    }
    _ensureDerived();
  }

  /// Every future this panel memoises, acknowledged at birth.
  ///
  /// A `FutureBuilder` subscribes on a LATER frame than the one that starts
  /// the work — a retry begins from a button press, and a derived load can
  /// settle before the segment that shows it has ever been built. Dart reports
  /// an error delivered to a future with no listener as unhandled, which takes
  /// down the zone rather than reaching the panel's own error state. This
  /// listener does nothing but be there; the future it returns is still the one
  /// the builders read, errors and all.
  Future<T> _held<T>(Future<T> future) {
    unawaited(future.then((_) {}, onError: (Object _) {}));
    return future;
  }

  /// The loads that hang off the bytes, for the segment that is showing.
  void _ensureDerived() {
    final bytes = _bytesLoad;
    if (bytes == null) return;
    final attachment = widget.attachment;
    final kind = previewKindFor(attachment);

    if (kind == PreviewKind.sheet) {
      _workbookLoad ??= _held(bytes.then(widget.engines.workbook));
    }
    if (kind == PreviewKind.pdf && _segment == PreviewSegment.text) {
      _pdfTextLoad ??= _held(bytes.then(_pdfTextOf));
    }
  }

  /// Every page's words, and the document closed again whatever happened.
  Future<String> _pdfTextOf(Uint8List data) async {
    final doc = await widget.engines.pdf.open(data, sourceName: _sourceName);
    try {
      return (await doc.pageTexts()).join('\n\n');
    } finally {
      await doc.dispose();
    }
  }

  /// Which kinds are worth a download.
  ///
  /// A link has none. A document was read by the server, so its words are in
  /// the store and its bytes buy nothing this panel draws. Everything
  /// unsupported is named, not drawn. Save and Open fetch on their own when a
  /// person asks for the file itself.
  bool _needsBytes(PreviewKind kind) {
    if (_isTooLarge) return false;
    return switch (kind) {
      PreviewKind.image ||
      PreviewKind.pdf ||
      PreviewKind.sheet ||
      PreviewKind.text => true,
      PreviewKind.document ||
      PreviewKind.eml ||
      PreviewKind.link ||
      PreviewKind.unsupported => false,
    };
  }

  /// Refused on the size the connector claimed, against the ceiling that same
  /// connector states — `bytes.maxPreviewBytes`, never the MCP constant: the
  /// SDK path streams and goes further, and a panel quoting the wrong number
  /// would refuse a file the app could have shown.
  ///
  /// A file already on disk is never too large: the download that the cap
  /// exists to prevent has already happened.
  bool get _isTooLarge {
    final attachment = widget.attachment;
    if (attachment.blobPath != null && attachment.blobPath!.isNotEmpty) {
      return false;
    }
    return attachment.size > widget.bytes.maxPreviewBytes;
  }

  /// A chat's shared file is the one document OneDrive will draw a picture of
  /// without this app downloading it.
  bool get _hasRenderedThumbnail =>
      widget.attachment.source != 'email' && widget.attachment.kind == 'file';

  String get _sourceName =>
      widget.attachment.name ?? widget.attachment.attachmentId;

  String get _glyph => attachmentGlyph(
    widget.attachment.kind,
    widget.attachment.contentType,
    name: widget.attachment.name,
  );

  @override
  Widget build(BuildContext context) {
    // Beside the thread, a height-filling bordered surface — the same one the
    // thread pane wears, so the two read as peers rather than as a card
    // floating over a pane. Inside the full viewer the host's `PaneSurface`
    // already draws that border and the header; drawing a second one there
    // was a box within a box, so without a header this is the bare column.
    final column = _column();
    if (!widget.showHeader) return column;
    return Container(
      decoration: BoxDecoration(
        color: BondColors.surface,
        borderRadius: BondRadii.mdAll,
        border: Border.all(color: BondColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: column,
    );
  }

  Widget _column() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showHeader) ...[
          _header(),
          const Divider(height: 1, color: BondColors.border),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(
            BondSpacing.s16,
            BondSpacing.s12,
            BondSpacing.s16,
            0,
          ),
          child: BondFilterPillRow<PreviewSegment>(
            key: AttachmentPreviewPanel.segmentsKey,
            options: PreviewSegment.values,
            selected: _segment,
            labelOf: _segmentLabel,
            onSelected: (segment) => setState(() {
              _segment = segment;
              _ensureDerived();
            }),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              BondSpacing.s16,
              BondSpacing.s12,
              BondSpacing.s16,
              BondSpacing.s12,
            ),
            child: _body(),
          ),
        ),
        const Divider(height: 1, color: BondColors.border),
        Padding(
          padding: const EdgeInsets.all(BondSpacing.s12),
          child: _actions(),
        ),
      ],
    );
  }

  static String _segmentLabel(PreviewSegment segment) => switch (segment) {
    PreviewSegment.preview => 'Preview',
    PreviewSegment.text => 'Text',
    PreviewSegment.ai => 'AI',
  };

  Widget _header() {
    final size = formatBytes(widget.attachment.size);
    final expand = widget.onExpand;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: BondSpacing.s16,
        vertical: BondSpacing.s12,
      ),
      child: Row(
        children: [
          Text(_glyph, style: BondType.body),
          const SizedBox(width: BondSpacing.s8),
          Expanded(
            child: Text(
              widget.attachment.name ?? '(unnamed attachment)',
              style: BondType.body.copyWith(fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (size.isNotEmpty) ...[
            const SizedBox(width: BondSpacing.s8),
            Text(size, style: BondType.caption),
          ],
          if (expand != null)
            IconButton(
              key: AttachmentPreviewPanel.expandKey,
              onPressed: expand,
              icon: const Icon(Icons.open_in_full),
              iconSize: 18,
              tooltip: 'Expand',
            ),
          IconButton(
            key: AttachmentPreviewPanel.closeKey,
            onPressed: widget.onClose,
            icon: const Icon(Icons.close),
            iconSize: 18,
            tooltip: 'Close preview',
          ),
        ],
      ),
    );
  }

  /// The things a person can do with the file, whatever the panel is showing.
  ///
  /// Open and Save are hidden for a link (there is no file) and for a file
  /// over the cap (there is nothing this app can fetch to hand over) — in both
  /// cases the body already offers the link out instead.
  ///
  /// Open alone is withheld for a file the operating system would RUN — see
  /// [openRefused]. A caption stands where the button was, because a control
  /// that simply vanished for one file and not the next reads as a bug rather
  /// than as a decision.
  Widget _actions() {
    final kind = previewKindFor(widget.attachment);
    final fetchable = kind != PreviewKind.link && !_isTooLarge;
    final refused = openRefused(widget.attachment);
    final openable = fetchable && !refused;
    final open = widget.onOpen;
    final save = widget.onSave;
    final useInReply = widget.onUseInReply;
    final pin = widget.onPinToStoryline;

    return Wrap(
      spacing: BondSpacing.s8,
      runSpacing: BondSpacing.s4,
      children: [
        if (openable && open != null)
          TextButton.icon(
            key: AttachmentPreviewPanel.openKey,
            onPressed: open,
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('Open'),
          ),
        if (fetchable && refused && open != null)
          Text(
            'Open is off for files that can run. Save it instead.',
            key: AttachmentPreviewPanel.openRefusedKey,
            style: BondType.caption.copyWith(color: BondColors.inkMuted),
          ),
        if (fetchable && save != null)
          TextButton.icon(
            key: AttachmentPreviewPanel.saveKey,
            onPressed: save,
            icon: const Icon(Icons.download_outlined, size: 16),
            label: const Text('Save…'),
          ),
        if (useInReply != null)
          TextButton.icon(
            key: AttachmentPreviewPanel.useInReplyKey,
            onPressed: useInReply,
            icon: const Icon(Icons.reply_outlined, size: 16),
            label: const Text('Use in reply'),
          ),
        if (pin != null)
          TextButton.icon(
            key: AttachmentPreviewPanel.pinKey,
            onPressed: widget.pinned ? null : pin,
            icon: const Icon(Icons.push_pin_outlined, size: 16),
            label: Text(widget.pinned ? 'Pinned' : 'Pin to storyline'),
          ),
      ],
    );
  }

  // ── The body ladder ──────────────────────────────────────────────────

  Widget _body() {
    // The model's read needs no bytes and is the same answer for every kind,
    // including the ones this panel refuses to fetch.
    if (_segment == PreviewSegment.ai) return _aiBody();

    final kind = previewKindFor(widget.attachment);
    if (kind == PreviewKind.link) return _linkBody();
    // The words the server extracted need no bytes, so the cap has nothing to
    // say about them. Checked BEFORE the refusal below, which would otherwise
    // make the Text segment unreachable for exactly the files whose text is
    // the only thing this app can still show.
    if (_isTooLarge && _segment == PreviewSegment.text) return _textBody();
    if (_isTooLarge) return _tooLargeBody();
    if (kind == PreviewKind.document) return _documentBody();
    if (kind == PreviewKind.unsupported) return _unsupportedBody();
    if (kind == PreviewKind.eml) return _emlBody();

    return FutureBuilder<Uint8List>(
      future: _bytesLoad,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const ColoredBox(
            color: BondColors.previewGround,
            child: Center(
              child: CircularProgressIndicator(
                key: AttachmentPreviewPanel.loadingKey,
              ),
            ),
          );
        }
        if (snapshot.hasError || snapshot.data == null) return _errorBody();
        return _readyBody(kind, snapshot.data!);
      },
    );
  }

  Widget _linkBody() => UnsupportedPreview(
    glyph: '🔗',
    name: widget.attachment.name ?? widget.attachment.cardText,
    reason: 'This is a link, not a file.',
    action: _sourceLink(),
  );

  /// Over the connector's ceiling, and what is left to do about it.
  ///
  /// With a link, the link IS the answer. Without one — which is every mail
  /// attachment, since Graph gives a mail file no sharing url — the reader
  /// would otherwise be looking at a dead end, so the sentence says the two
  /// things that are still true: the message in their mail app has the file,
  /// and the Text segment beside this one may already have its words.
  Widget _tooLargeBody() {
    final link = _sourceLink();
    final size = formatBytes(widget.attachment.size);
    return UnsupportedPreview(
      key: AttachmentPreviewPanel.tooLargeKey,
      glyph: _glyph,
      name: widget.attachment.name,
      size: widget.attachment.size,
      reason: link != null
          ? 'This file is $size — too large to preview here.'
          : 'This file is $size — over what this connection can hand over. '
              'Open the message in your mail app to get it. Its text, if the '
              'server read it, is under Text.',
      action: link,
    );
  }

  /// The way out of a refusal: the file where it actually lives.
  ///
  /// Only for a WEB address — see [webUriOf]. The url is the sender's own
  /// string, so a hostile one gets no button at all rather than a disabled
  /// one: a greyed-out control invites a second look at something there is
  /// nothing safe to do with, and a refusal with no explanation for it is a
  /// worse answer than a refusal that simply offers nothing.
  Widget? _sourceLink() {
    final url = widget.attachment.sourceUrl;
    final openLink = widget.onOpenLink;
    if (url == null || openLink == null) return null;
    if (webUriOf(url) == null) return null;
    return TextButton.icon(
      key: AttachmentPreviewPanel.sourceLinkKey,
      onPressed: () => openLink(url),
      icon: const Icon(Icons.open_in_new, size: 16),
      label: Text(
        widget.attachment.source == 'teams'
            ? 'Open in Teams'
            : 'Open in Outlook',
      ),
    );
  }

  Widget _errorBody() => Align(
    alignment: Alignment.topCenter,
    child: InlineAlert(
      key: AttachmentPreviewPanel.errorKey,
      severity: InlineAlertSeverity.error,
      text: 'Could not load ${widget.attachment.name ?? 'this file'}.',
      maxLines: 2,
      action: TextButton(
        key: AttachmentPreviewPanel.retryKey,
        onPressed: () => setState(() {
          _bytesLoad = _held(widget.bytes.bytesFor(widget.attachment));
          _workbookLoad = null;
          _pdfTextLoad = null;
          _ensureDerived();
        }),
        child: const Text('Try again'),
      ),
    ),
  );

  /// A Word or PowerPoint file: the server read it, so its words ARE the
  /// preview. A chat's shared file gets OneDrive's picture above them, which
  /// is the only rendering of a document this app ever shows without holding
  /// the bytes.
  Widget _documentBody() {
    if (_segment == PreviewSegment.text) return _textBody();
    final thumb = _thumbLoad;
    if (thumb == null) return _textBody();
    return FutureBuilder<Uint8List?>(
      future: thumb,
      builder: (context, snapshot) {
        final png = snapshot.data;
        if (png == null) return _textBody();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: Image.memory(
                png,
                fit: BoxFit.contain,
                // OneDrive answers a rendering request with a sign-in page
                // when the session has drifted, so these bytes are not always
                // a picture. An undecodable image throws into the widget tree
                // and takes the whole panel with it; nothing at all is the
                // right amount of noise for a thumbnail that never arrived,
                // and the words below it are what the reader came for anyway.
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
                // The same bytes across a rebuild keep the frame that is
                // already decoded rather than blanking for one frame.
                gaplessPlayback: true,
              ),
            ),
            const SizedBox(height: BondSpacing.s12),
            Expanded(child: _textBody()),
          ],
        );
      },
    );
  }

  Widget _unsupportedBody() {
    if (_segment == PreviewSegment.text) return _textBody();
    return UnsupportedPreview(
      glyph: _glyph,
      name: widget.attachment.name,
      size: widget.attachment.size,
    );
  }

  Widget _emlBody() {
    if (_segment == PreviewSegment.text) return _textBody();
    return FutureBuilder<String?>(
      future: _textLoad,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox.shrink();
        }
        return EmlPreview(
          attachment: widget.attachment,
          bodyText: snapshot.data,
        );
      },
    );
  }

  Widget _readyBody(PreviewKind kind, Uint8List data) {
    final text = _segment == PreviewSegment.text;
    return switch (kind) {
      PreviewKind.image =>
        text
            ? _textBody()
            : ImagePreview(bytes: data, name: widget.attachment.name),
      PreviewKind.pdf =>
        text
            ? _pdfTextBody()
            : PdfPreview(
                bytes: data,
                sourceName: _sourceName,
                renderer: widget.engines.pdf,
              ),
      PreviewKind.sheet => _sheetBody(asText: text),
      PreviewKind.text => TextPreview(
        // Malformed bytes are shown as best they can be rather than thrown
        // over: a log with one bad byte in it is still a log.
        text: utf8.decode(data, allowMalformed: true),
        mono: monoForName(widget.attachment.name),
        note: _textNote,
      ),
      // Never reached — the ladder above answers these four before any bytes
      // are asked for.
      PreviewKind.document ||
      PreviewKind.eml ||
      PreviewKind.link ||
      PreviewKind.unsupported => _unsupportedBody(),
    };
  }

  Widget _pdfTextBody() => FutureBuilder<String>(
    future: _pdfTextLoad,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(
          child: CircularProgressIndicator(
            key: AttachmentPreviewPanel.loadingKey,
          ),
        );
      }
      return TextPreview(
        text: snapshot.data ?? '',
        emptyReason:
            'There are no words in this document — '
            'it is probably a scan.',
      );
    },
  );

  Widget _sheetBody({required bool asText}) => FutureBuilder<WorkbookTables>(
    future: _workbookLoad,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(
          child: CircularProgressIndicator(
            key: AttachmentPreviewPanel.loadingKey,
          ),
        );
      }
      final workbook = snapshot.data;
      if (snapshot.hasError || workbook == null) {
        return UnsupportedPreview(
          glyph: _glyph,
          name: widget.attachment.name,
          reason: 'This workbook could not be read.',
        );
      }
      if (!asText) return SheetPreview(workbook: workbook);
      // The first sheet only: the Text segment is for copying numbers out
      // of, and a workbook flattened into one stream of tabs would be a
      // worse answer than the table beside it.
      final sheets = workbook.sheets;
      return TextPreview(
        text: sheets.isEmpty ? '' : sheetAsTsv(sheets.first),
        mono: true,
        emptyReason: 'This workbook has no rows.',
      );
    },
  );

  /// The words the pipeline extracted, and why there are none when there are
  /// none.
  Widget _textBody() => FutureBuilder<String?>(
    future: _textLoad,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const SizedBox.shrink();
      }
      return TextPreview(
        text: snapshot.data ?? '',
        mono: monoForName(widget.attachment.name),
        note: _textNote,
        emptyReason: _textEmptyReason,
      );
    },
  );

  /// Why there are no words, in the order the reader would ask: is it still
  /// coming, was it refused, or was there simply nothing to read.
  String get _textEmptyReason {
    final attachment = widget.attachment;
    if (attachment.textStatus == 'pending') return 'Still reading this file…';
    final reason = attachment.textReason;
    if (reason != null && reason.isNotEmpty) return 'Not read: $reason.';
    return 'No text was extracted from this file.';
  }

  /// Where the extractor stopped. A reader told nothing would believe a
  /// truncated document is the whole of it.
  String? get _textNote => widget.attachment.textTruncated
      ? 'Text was cut at ${widget.attachment.textChars} characters.'
      : null;

  /// What the model made of the document, always labelled as the model's — the
  /// same `AI:` prefix every other model line in this app wears.
  Widget _aiBody() {
    final attachment = widget.attachment;
    final digest = attachment.digest;
    if (digest == null) {
      if (attachment.digestStatus == 'pending') {
        return _quietLine('Still reading this file…');
      }
      if (attachment.digestStatus == 'error') {
        return const Align(
          alignment: Alignment.topCenter,
          child: InlineAlert(
            severity: InlineAlertSeverity.error,
            text: 'The model could not read this file.',
          ),
        );
      }
      return _quietLine('This file was not sent to the model.');
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'AI: ${digest.summary}',
            style: BondType.caption.copyWith(color: BondColors.inkMuted),
          ),
          ..._digestList('Facts', digest.facts),
          ..._digestList('Asks', digest.asks),
        ],
      ),
    );
  }

  List<Widget> _digestList(String label, List<String> items) {
    if (items.isEmpty) return const [];
    return [
      const SizedBox(height: BondSpacing.s12),
      Text(label, style: BondType.label),
      const SizedBox(height: BondSpacing.s4),
      for (final item in items)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text('• $item', style: BondType.small),
        ),
    ];
  }

  Widget _quietLine(String text) => Align(
    alignment: Alignment.topLeft,
    child: Text(
      text,
      style: BondType.caption.copyWith(color: BondColors.inkMuted),
    ),
  );
}
