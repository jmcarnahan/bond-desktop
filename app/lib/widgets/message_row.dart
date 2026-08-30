import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../theme/tokens.dart';
import 'time_format.dart';

/// How long a gap can be before a message stops reading as part of the same
/// breath and gets its own header again.
const Duration _runWindow = Duration(minutes: 5);

/// Collapse threshold — either many lines or a long body.
const int _maxLines = 12;
const int _maxChars = 600;

/// Graph's HTML→text conversion renders inline images (a signature logo,
/// typically) as literal "[cid:…]" tokens — presentational noise, stripped for
/// display only. The stored body stays as ingested.
final RegExp _cidToken = RegExp(r'[ \t]*\[cid:[^\]]+\][ \t]*');

/// Inbound avatar fills, picked from the existing token set rather than a new
/// one. Five is enough that adjacent senders rarely collide and few enough
/// that the transcript still reads as one palette.
const List<Color> _avatarPalette = [
  BondColors.primaryDeep,
  BondColors.attention,
  BondColors.success,
  BondColors.darkTileAlt,
  BondColors.channelVideo,
];

/// Two letters from a display name, one from an address, "?" from nothing.
/// Never throws on the half-empty senders a mailbox is full of.
String initialsFor(String? name, String? address) {
  final words = [
    for (final w in (name ?? '').split(RegExp(r'\s+')))
      if (w.isNotEmpty) w,
  ];
  if (words.length >= 2) {
    return '${words.first[0]}${words.last[0]}'.toUpperCase();
  }
  if (words.length == 1) return words.first[0].toUpperCase();

  final addr = (address ?? '').trim();
  if (addr.isNotEmpty) return addr[0].toUpperCase();
  return '?';
}

/// The avatar fill. Outbound is always the product's own primary — "this one
/// is you" should not depend on which address the account signs with. Everyone
/// else gets a stable color per address, so a sender looks the same in every
/// thread.
Color avatarColorFor(String? address, {required bool outbound}) {
  if (outbound) return BondColors.primary;
  final hash = (address ?? '').toLowerCase().hashCode;
  final index = hash.remainder(_avatarPalette.length).abs();
  return _avatarPalette[index];
}

/// Whether [b] collapses under [a]: same sender, same direction, and close
/// enough in time. An unparseable timestamp on either side breaks the run —
/// the header is the safe answer.
bool sameRun(Message a, Message b) {
  if (a.outbound != b.outbound) return false;
  if ((a.fromAddress ?? '').toLowerCase() !=
      (b.fromAddress ?? '').toLowerCase()) {
    return false;
  }
  final first = DateTime.tryParse(a.receivedAt ?? '');
  final second = DateTime.tryParse(b.receivedAt ?? '');
  if (first == null || second == null) return false;
  return second.difference(first).abs() <= _runWindow;
}

/// The local calendar day a message landed on, as `yyyy-mm-dd`. Null when the
/// timestamp does not parse, which reads as "no day divider" upstream.
String? dayKeyOf(Message m) {
  final parsed = DateTime.tryParse(m.receivedAt ?? '');
  if (parsed == null) return null;
  final local = parsed.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}

/// One message in a thread, flat and left-aligned whichever way it went.
///
/// There are no bubbles and no right-hand column: a transcript reads top to
/// bottom in one gutter, and direction is carried by the avatar alone.
/// Consecutive messages from the same sender collapse under the first one's
/// header. Bodies are plain-text [SelectableText] — mail content is NEVER
/// markdown-rendered.
class MessageRow extends StatefulWidget {
  final Message message;

  /// False renders a continuation: no avatar, no name, no timestamp.
  final bool showHeader;

  const MessageRow({
    super.key,
    required this.message,
    this.showHeader = true,
  });

  @override
  State<MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends State<MessageRow> {
  bool _expanded = false;

  /// The avatar's diameter, and the width the gutter keeps reserved on
  /// continuation rows so bodies stay in one column.
  static const double _avatarSize = 36;

  String get _body {
    // The preview stands in until the body arrives: bodies are fetched per
    // thread on open, and a row with nothing in it reads as an empty message
    // rather than as one still loading.
    final bodyText = widget.message.bodyText;
    final raw = (bodyText == null || bodyText.isEmpty)
        ? (widget.message.bodyPreview ?? '')
        : bodyText;
    if (!raw.contains('[cid:')) return raw;
    return raw
        .replaceAll(_cidToken, '')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trimRight();
  }

  bool get _collapsible {
    final body = _body;
    return body.length > _maxChars ||
        '\n'.allMatches(body).length + 1 > _maxLines;
  }

  String get _visibleBody {
    final body = _body;
    if (_expanded || !_collapsible) return body;
    // Clamp to the first N lines, then the char cap, whichever hits first.
    final lines = body.split('\n');
    var clamped =
        lines.length > _maxLines ? lines.take(_maxLines).join('\n') : body;
    if (clamped.length > _maxChars) {
      clamped = clamped.substring(0, _maxChars);
    }
    return clamped.trimRight();
  }

  String get _senderName {
    final message = widget.message;
    final name = message.fromName;
    if (name != null && name.isNotEmpty) return name;
    final address = message.fromAddress;
    if (address != null && address.isNotEmpty) return address;
    return message.outbound ? 'You' : '(no sender)';
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final pending = message.pendingSend;

    // Only inbound mail is ever queued, so the suffix says "the model has not
    // reached this one yet" rather than appearing on every row in a thread.
    final triaging = !pending &&
        message.inbound &&
        (message.triageStatus == 'pending' ||
            message.triageStatus == 'processing');

    final when = pending ? '' : (formatTimestamp(message.receivedAt) ?? '');
    final meta = !triaging
        ? when
        : when.isEmpty
            ? 'triaging'
            : '$when · triaging';
    final summary = message.summary;

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        widget.showHeader
            ? _avatar(message)
            : const SizedBox(width: _avatarSize),
        const SizedBox(width: BondSpacing.s12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.showHeader) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Text(
                        _senderName,
                        style:
                            BondType.body.copyWith(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(width: BondSpacing.s8),
                      Text(meta, style: BondType.caption),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
              ],
              SelectableText(
                _visibleBody,
                style: BondType.body.copyWith(
                  color: BondColors.ink,
                  height: 1.4,
                ),
              ),
              if (_collapsible) ...[
                const SizedBox(height: BondSpacing.s4),
                _ShowToggle(
                  expanded: _expanded,
                  onTap: () => setState(() => _expanded = !_expanded),
                ),
              ],
              if (pending) ...[
                const SizedBox(height: BondSpacing.s4),
                Text('Sending…', style: BondType.caption),
              ],
              // The model's one-line read of this message, labelled as the
              // model's: it sits under mail the LO can see for themselves, and
              // it must never be mistaken for something the sender wrote.
              if (summary != null && summary.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  'AI: $summary',
                  style: BondType.caption.copyWith(color: BondColors.inkMuted),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    return Padding(
      padding: EdgeInsets.only(
        top: widget.showHeader ? BondSpacing.s16 : BondSpacing.s4,
      ),
      child: Opacity(opacity: pending ? 0.6 : 1, child: row),
    );
  }

  Widget _avatar(Message message) {
    return Container(
      width: _avatarSize,
      height: _avatarSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: avatarColorFor(message.fromAddress, outbound: message.outbound),
      ),
      child: Text(
        initialsFor(message.fromName, message.fromAddress),
        style: BondType.caption.copyWith(
          color: BondColors.onDarkPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// The day separator between runs of messages — a hairline with the day's
/// name sitting in the gap.
class DayDivider extends StatelessWidget {
  final String label;

  const DayDivider({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: BondSpacing.s16),
      child: Row(
        children: [
          const Expanded(
            child: Divider(height: 1, color: BondColors.border),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s12),
            child: Text(label, style: BondType.caption),
          ),
          const Expanded(
            child: Divider(height: 1, color: BondColors.border),
          ),
        ],
      ),
    );
  }
}

/// The Show more/less affordance — a quiet inline text toggle, kept local so
/// the row owns its own collapse without an ad-hoc button style.
class _ShowToggle extends StatelessWidget {
  final bool expanded;
  final VoidCallback onTap;

  const _ShowToggle({required this.expanded, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BondRadii.smAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          expanded ? 'Show less' : 'Show more',
          style: BondType.label.copyWith(
            letterSpacing: 0,
            color: BondColors.primary,
          ),
        ),
      ),
    );
  }
}
