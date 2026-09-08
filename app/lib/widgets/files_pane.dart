import 'package:flutter/material.dart';

import '../models/attachment_models.dart';
import '../models/files_models.dart';
import '../theme/tokens.dart';
import 'attachment_card.dart';
import 'attachment_format.dart';
import 'attachment_search_tile.dart';
import 'chips.dart';
import 'home_search.dart';
import 'inline_alert.dart';
import 'link_unfurl.dart';
import 'message_row.dart' show DayDivider;
import 'preview/preview_kind.dart';
import 'time_format.dart';

/// One shelf holding every document in the mailbox, mail and chat together.
///
/// Grouped by DAY, because "where is that file" is a question about time before
/// it is a question about who sent it: a reader remembers that the quote came
/// in last Tuesday long after they have forgotten which of four people sent it.
/// The four kinds narrow the shelf and the source chips in the column header
/// scope it — there is no second source control here, because two controls for
/// one fact is how they come to disagree.
///
/// Search here asks about DOCUMENTS only. The same index and the same tile the
/// home feed uses, narrowed to the half of the answer this stop is about: a
/// message that mentions a contract is a fine answer somewhere else.
///
/// A pane with no providers in it: everything it draws is a prop, so its host
/// is the only place the reads happen and this file can be pumped on its own.
class FilesPane extends StatelessWidget {
  final List<FileRow> rows;

  /// Whether a read has come back. False draws a spinner rather than an empty
  /// shelf claiming there are no files.
  final bool loaded;

  final bool loadingMore;

  /// Whether the last page came back short. True takes the Load more away.
  final bool atEnd;

  /// The sentence to show when the newest read failed. A banner OVER the rows,
  /// never a replacement for them.
  final String? error;

  final FilesKind kind;
  final ValueChanged<FilesKind> onKind;

  /// The typed query, owned by the host — the box is a view of it.
  final TextEditingController searchController;

  /// The passages that answered, or null while the live shelf is up.
  final List<AttachmentChunkHit>? search;

  /// The RAW query those results answer, for the label over them.
  final String? searchQuery;

  final bool searching;
  final String? searchNotice;

  final ValueChanged<String> onSearch;
  final VoidCallback onExitSearch;

  /// The picture for a file, or null while there is none. An [ImageProvider]
  /// rather than bytes — see [AttachmentCard.image].
  final ImageProvider? Function(AttachmentRef attachment) thumbnailFor;

  /// Opens one file. The whole row rather than the ref, so the host can open
  /// it beside the thread it came from.
  final void Function(FileRow row) onOpen;

  /// Opens the conversation a file came with.
  final void Function(String source, String conversationKey) onOpenThread;

  /// Hands a link's address to the operating system. Null draws no button.
  final void Function(String url)? onOpenLink;

  final VoidCallback onLoadMore;

  /// Passed in rather than read from the clock, like every other timestamp in
  /// the widget layer, so a test can pin "3h ago".
  final DateTime now;

  const FilesPane({
    super.key,
    required this.rows,
    required this.loaded,
    required this.loadingMore,
    required this.atEnd,
    required this.kind,
    required this.onKind,
    required this.searchController,
    required this.searching,
    required this.onSearch,
    required this.onExitSearch,
    required this.thumbnailFor,
    required this.onOpen,
    required this.onOpenThread,
    required this.onLoadMore,
    required this.now,
    this.error,
    this.search,
    this.searchQuery,
    this.searchNotice,
    this.onOpenLink,
  });

  static const Key kindPillsKey = ValueKey('files-kind-pills');

  /// Keyed by the FILE rather than by the row's place in the list: a page
  /// landing above it would move an index, and a moving key throws away the
  /// widget holding whatever the reader was looking at.
  static Key rowKeyFor(FileRow row) => attachmentKey('file-row', row.ref);

  static Key threadLinkKeyFor(FileRow row) =>
      attachmentKey('file-row-thread', row.ref);

  static const Key emptyKey = ValueKey('files-empty');
  static const Key loadMoreKey = ValueKey('files-load-more');

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HomeSearchField(
          controller: searchController,
          active: search != null || searching,
          onSubmit: onSearch,
          onClear: onExitSearch,
        ),
        const SizedBox(height: BondSpacing.s12),
        BondFilterPillRow<FilesKind>(
          key: kindPillsKey,
          options: FilesKind.values,
          selected: kind,
          labelOf: (k) => k.label,
          onSelected: onKind,
        ),
        const SizedBox(height: BondSpacing.s12),
        if (error != null) ...[
          InlineAlert(
            severity: InlineAlertSeverity.error,
            text: error!,
            maxLines: 2,
          ),
          const SizedBox(height: BondSpacing.s12),
        ],
        // Attention rather than error: the shelf under it is working, and one
        // thing you can do to it is off.
        if (searchNotice != null) ...[
          InlineAlert(
            severity: InlineAlertSeverity.attention,
            text: searchNotice!,
            maxLines: 2,
          ),
          const SizedBox(height: BondSpacing.s12),
        ],
        // A line, never a spinner, and never in place of the body: the shelf
        // the reader was looking at stays under it until the answer lands.
        if (searching) ...[
          Text('Searching…', style: BondType.small),
          const SizedBox(height: BondSpacing.s8),
        ],
        Expanded(child: search != null ? _results(search!) : _shelf()),
      ],
    );
  }

  /// What a query came back with. Documents and nothing else — see the class
  /// doc.
  Widget _results(List<AttachmentChunkHit> hits) {
    final label = searchQuery == null
        ? 'DOCUMENTS'
        : 'DOCUMENTS · "${searchQuery!}"';
    return ListView(
      children: [
        Text(label, style: BondType.label),
        const SizedBox(height: BondSpacing.s8),
        if (hits.isEmpty)
          Text(
            'No documents match.',
            style: BondType.small.copyWith(color: BondColors.inkMuted),
          )
        else
          for (final hit in hits)
            AttachmentSearchTile(
              key: AttachmentSearchTile.keyFor(hit.ref),
              hit: hit,
              now: now,
              onOpenThread: onOpenThread,
            ),
      ],
    );
  }

  /// The live shelf, in day runs.
  Widget _shelf() {
    if (!loaded) return const Center(child: CircularProgressIndicator());
    if (rows.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text('No files yet.', key: emptyKey, style: BondType.small),
      );
    }

    final children = <Widget>[];
    String? previousDay;
    var run = <FileRow>[];

    void flush() {
      if (run.isEmpty) return;
      children.add(DayDivider(
        label: formatDayLabel(run.first.receivedAt) ?? 'Undated',
      ));
      children.add(Wrap(
        spacing: BondSpacing.s8,
        runSpacing: BondSpacing.s8,
        children: [for (final row in run) _entry(row)],
      ));
      run = <FileRow>[];
    }

    for (final row in rows) {
      final day = dayKeyOfIso(row.receivedAt) ?? '';
      if (previousDay != null && day != previousDay) flush();
      previousDay = day;
      run.add(row);
    }
    flush();

    if (!atEnd) {
      children.add(Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: loadMoreKey,
          onPressed: loadingMore ? null : onLoadMore,
          child: Text(loadingMore ? 'Loading…' : 'Load more'),
        ),
      ));
    }

    return ListView(children: children);
  }

  /// One file: the card, then who sent it and when, then the way back into the
  /// conversation it came with.
  ///
  /// The caption is under the card rather than on it because it is about the
  /// MESSAGE. A card says what a file is wherever it is drawn, and the shelf is
  /// the one place that also has to say where it came from.
  Widget _entry(FileRow row) {
    final ref = row.ref;
    final who =
        row.outbound ? 'you' : (row.fromName ?? row.fromAddress ?? '(no sender)');
    final when = relativeTime(row.receivedAt, now) ?? '';
    final key = row.conversationKey;

    return SizedBox(
      width: AttachmentCard.width,
      child: Column(
        key: rowKeyFor(row),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isLink(ref))
            LinkUnfurl(
              attachment: ref,
              onOpen: () => onOpen(row),
              onOpenLink: onOpenLink,
            )
          else
            AttachmentCard(
              attachment: ref,
              image: _imageFor(ref),
              onTap: () => onOpen(row),
            ),
          const SizedBox(height: BondSpacing.s4),
          Text(
            when.isEmpty ? who : '$who · $when',
            style: BondType.caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (key != null)
            TextButton(
              key: threadLinkKeyFor(row),
              onPressed: () => onOpenThread(row.source, key),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 24),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                alignment: Alignment.centerLeft,
                textStyle: BondType.caption,
              ),
              child: Text(
                row.subject ?? 'Open thread',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  bool _isLink(AttachmentRef ref) =>
      const {'reference', 'message_reference', 'card'}.contains(ref.kind);

  /// A picture for a photograph or for a document this build might render —
  /// the same narrowing the transcript applies. Asking for one of a
  /// spreadsheet is asking for a picture that can never arrive.
  ImageProvider? _imageFor(AttachmentRef ref) {
    const drawable = {
      PreviewKind.image,
      PreviewKind.pdf,
      PreviewKind.document,
    };
    if (!drawable.contains(previewKindFor(ref))) return null;
    return thumbnailFor(ref);
  }
}
