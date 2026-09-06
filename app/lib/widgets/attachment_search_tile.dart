import 'package:flutter/material.dart';

import '../models/attachment_models.dart';
import '../theme/tokens.dart';
import 'attachment_format.dart';
import 'time_format.dart';

/// One passage of an attached document that answered a query.
///
/// A way INTO the thread the document sits on, not a reader for the document:
/// the whole tile is one tap that opens the conversation the file came with,
/// because a passage on its own answers "where do I look" and almost never
/// "what do I do".
///
/// **The snippet is the document's own words**, so it is rendered as a quote —
/// caption weight, muted — and never under the `AI:` label the message rows
/// use. That label is a promise that a model wrote what follows, and putting a
/// verbatim passage behind it would make the promise a lie in the one place a
/// reader is deciding whether to trust what they are reading.
///
/// Height-bounded on purpose (one line of title, two of snippet): the search
/// body stacks these above a scrolling list, so an unbounded one would push
/// the results it is introducing off the screen.
class AttachmentSearchTile extends StatelessWidget {
  final AttachmentChunkHit hit;

  /// Injected rather than read from the clock, like every other timestamp in
  /// the widget layer, so a test can pin "3h ago".
  final DateTime now;

  /// Null — or a hit whose message is gone — makes the tile a statement rather
  /// than a control, the same way a chip with nowhere to go is.
  final void Function(String source, String conversationKey)? onOpenThread;

  const AttachmentSearchTile({
    super.key,
    required this.hit,
    required this.now,
    this.onOpenThread,
  });

  /// Characters, and generous: two lines of caption at this width hold about
  /// this much, and cutting shorter than the layout does loses words for
  /// nothing.
  static const int snippetCap = 160;

  static ValueKey<String> keyFor(AttachmentRef attachment) =>
      attachmentKey('search-doc', attachment);

  /// The passage on one breath: a spreadsheet chunk arrives with tabs and
  /// newlines in it, and rendering those as-is would make two lines of caption
  /// out of three words.
  String get _snippet {
    final collapsed = hit.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= snippetCap) return collapsed;
    return '${collapsed.substring(0, snippetCap)}…';
  }

  String get _title {
    final name = hit.ref.name ?? '(unnamed)';
    return hit.locator.isEmpty ? name : '$name · ${hit.locator}';
  }

  @override
  Widget build(BuildContext context) {
    final ref = hit.ref;
    final conversationKey = ref.conversationKey;
    final open = onOpenThread == null || conversationKey == null
        ? null
        : () => onOpenThread!(ref.source, conversationKey);
    final who = hit.outbound ? 'you' : (hit.senderName ?? '');
    final when = relativeTime(hit.receivedAt, now) ?? '';

    final body = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: BondSpacing.s8,
        vertical: BondSpacing.s8,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _glyphWidth,
            child: Text(
              attachmentGlyph(ref.kind, ref.contentType, name: ref.name),
            ),
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
          const SizedBox(width: BondSpacing.s12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(who, style: BondType.caption),
              Text(
                when,
                style: BondType.caption.copyWith(color: BondColors.inkMuted),
              ),
            ],
          ),
        ],
      ),
    );

    // Nowhere to go, no control: an orphaned passage — its message swept, or a
    // pin outliving the thread — is a statement, exactly as a chip with no
    // `onTap` is. Ink that answers a tap by doing nothing is worse than none.
    if (open == null) return body;

    // A bare [InkWell] needs its own transparent [Material] to paint into.
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: open,
        borderRadius: BondRadii.smAll,
        child: body,
      ),
    );
  }

  /// Wide enough for the widest glyph in [attachmentGlyph] plus its gap, so
  /// every title in a stack of these starts at the same x.
  static const double _glyphWidth = 20;
}
