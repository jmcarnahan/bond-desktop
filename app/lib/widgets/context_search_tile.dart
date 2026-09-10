import 'package:flutter/material.dart';

import '../models/context_models.dart';
import '../models/draft_provenance.dart' show DraftProvenance;
import '../theme/tokens.dart';

/// One passage of one of the owner's own directory files that answered a
/// query.
///
/// [AttachmentSearchTile]'s twin over the third corpus, and the differences
/// are what each row IS. A document arrived on a message, so that tile opens
/// the thread and names the sender and the date it came; a directory file is
/// the owner's own, belongs to no thread and has no sender — so this one
/// opens the FILE, and there is no right-hand column to put anybody in.
///
/// **The snippet is the file's own words**, so it is drawn as a quote — caption
/// weight, muted — and never under the `AI:` label the message rows use. That
/// label is a promise a model wrote what follows, and a verbatim passage
/// behind it would make the promise a lie exactly where a reader is deciding
/// whether to trust what they are reading.
///
/// Height-bounded on purpose (one line of title, two of snippet), for the
/// attachment tile's reason: the search body stacks these above a scrolling
/// list.
class ContextSearchTile extends StatelessWidget {
  final ContextChunkHit hit;

  /// Null makes the tile a statement rather than a control, the same way a
  /// chip with nowhere to go is.
  final VoidCallback? onOpen;

  const ContextSearchTile({super.key, required this.hit, this.onOpen});

  /// Characters, and generous: two lines of caption at this width hold about
  /// this much, and cutting shorter than the layout does loses words for
  /// nothing.
  static const int snippetCap = 160;

  static ValueKey<String> keyFor(ContextChunkHit hit) =>
      ValueKey('search-dir-${hit.chunkId}');

  /// The passage on one breath, with the chunker's own header line taken off.
  ///
  /// Every stored passage opens with `<rel path> · <locator>` so the embedding
  /// carries it. The title above already says both, and a snippet that
  /// repeated them would spend its first line saying what the row is called.
  String get _snippet {
    final newline = hit.text.indexOf('\n');
    final body = newline < 0 ? hit.text : hit.text.substring(newline + 1);
    final collapsed = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= snippetCap) return collapsed;
    return '${collapsed.substring(0, snippetCap)}…';
  }

  /// The section is drawn as a breadcrumb, the way the reply caption and the
  /// provenance chips draw one. The chunker spells a heading path `Pricing >
  /// Q4 rates`, and a comparison operator sitting in the middle of a search
  /// result reads as one; two spellings of the same section across two
  /// surfaces reads as two different sections.
  String get _title {
    final name = '${hit.dirName}/${hit.relPath}';
    return hit.locator.isEmpty
        ? name
        : '$name · ${DraftProvenance.locatorLabel(hit.locator)}';
  }

  @override
  Widget build(BuildContext context) {
    final body = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: BondSpacing.s8,
        vertical: BondSpacing.s8,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(
            width: _glyphWidth,
            child: Icon(Icons.folder_open_outlined, size: 16),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _title,
                  style: BondType.small.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _snippet,
                  style: BondType.caption.copyWith(color: BondColors.inkMuted),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (onOpen == null) return body;

    // A bare [InkWell] needs its own transparent [Material] to paint into.
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BondRadii.smAll,
        child: body,
      ),
    );
  }

  /// The attachment tile's glyph column, to the pixel, so a directory hit and
  /// a document hit stacked above each other start their titles at the same x.
  static const double _glyphWidth = 20;
}
