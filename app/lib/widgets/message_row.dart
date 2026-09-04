import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../theme/tokens.dart';
import 'chips.dart';
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
String? dayKeyOf(Message m) => dayKeyOfIso(m.receivedAt);

/// One message in a thread, flat and left-aligned whichever way it went.
///
/// There are no bubbles and no right-hand column: a transcript reads top to
/// bottom in one gutter, and direction is carried by the avatar alone.
/// Consecutive messages from the same sender collapse under the first one's
/// header. Bodies are plain-text [SelectableText] — mail content is NEVER
/// markdown-rendered.
///
/// A row can also be FOLDED, which is a different thing from the `Show more`
/// clamp on a long body: folded, the message keeps its header and gives up its
/// body to a single muted line. The rules the host cannot see and this row
/// therefore does not invent:
///
/// - Folding is offered only where [collapsible] says so, and starts folded
///   only where [initiallyCollapsed] does. Both are the host's call, because
///   both need the whole thread to answer.
/// - What survives the fold is what says the message still wants something: an
///   open ask keeps its line, and a message carrying a [suggestion] says so in
///   one caption. A folded row must never be the reason an answer went unsent.
/// - The user's own toggle outlives every rebuild. Nothing recomputes it.
class MessageRow extends StatefulWidget {
  final Message message;

  /// False renders a continuation: no avatar, no name, no timestamp.
  final bool showHeader;

  /// Whether this message's own ask is still unanswered. The row does not work
  /// that out — the rule needs the whole thread, so the host passes the answer
  /// (`models/open_asks.dart`) in.
  final bool openAsk;

  /// What tapping the ask does. Null leaves it a statement — a row whose host
  /// has nowhere to send the tap must not look like it takes one.
  final VoidCallback? onAskTap;

  /// The answer offered to THIS message, drawn under it when the row is open.
  /// The row knows nothing about drafts — the host builds the card and this
  /// only places it, beneath the ask it answers.
  final Widget? suggestion;

  /// Whether the header folds this message away. False renders exactly what it
  /// always did: no chevron, no tap, nothing to fold.
  final bool collapsible;

  /// Whether it starts folded. Read once, at construction — see [_collapsed].
  final bool initiallyCollapsed;

  const MessageRow({
    super.key,
    required this.message,
    this.showHeader = true,
    this.openAsk = false,
    this.onAskTap,
    this.suggestion,
    this.collapsible = false,
    this.initiallyCollapsed = false,
  });

  @override
  State<MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends State<MessageRow> {
  bool _expanded = false;

  /// Whether this message is folded to its header.
  ///
  /// Seeded once and NEVER recomputed — there is deliberately no
  /// `didUpdateWidget` arm for it. A transcript rebuilds on every sync, every
  /// draft reload and every inbox setState; re-reading
  /// [MessageRow.initiallyCollapsed] on any of those would fold a message the
  /// user had just opened, under their cursor, for a reason they could not see.
  late bool _collapsed;

  /// The avatar's diameter, and the width the gutter keeps reserved on
  /// continuation rows so bodies stay in one column.
  static const double _avatarSize = 36;

  @override
  void initState() {
    super.initState();
    _collapsed = widget.initiallyCollapsed && widget.collapsible;
  }

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

  /// Whether the body is long enough to earn the `Show more` clamp. Unrelated
  /// to [_collapsed], which folds the whole message rather than trimming it.
  bool get _bodyOverflows {
    final body = _body;
    return body.length > _maxChars ||
        '\n'.allMatches(body).length + 1 > _maxLines;
  }

  String get _visibleBody {
    final body = _body;
    if (_expanded || !_bodyOverflows) return body;
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

    // A queued reply is always the thread's last message and always on its way
    // out; folding it would hide the only thing on screen saying so.
    final folds = widget.collapsible && !pending;
    final collapsed = folds && _collapsed;
    final suggestion = widget.suggestion;

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
                _header(meta, folds: folds),
                const SizedBox(height: 2),
              ],
              if (collapsed)
                // One line of what was said, and then only what still wants
                // something: the fold hides reading, never answering.
                Text(
                  _body.split('\n').firstWhere(
                        (line) => line.trim().isNotEmpty,
                        orElse: () => '',
                      ),
                  style: BondType.caption.copyWith(color: BondColors.inkMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              else ...[
                SelectableText(
                  _visibleBody,
                  style: BondType.body.copyWith(
                    color: BondColors.ink,
                    height: 1.4,
                  ),
                ),
                if (_bodyOverflows) ...[
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
                // model's: it sits under mail the user can see for themselves,
                // and it must never be mistaken for something the sender wrote.
                if (summary != null && summary.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    'AI: $summary',
                    style:
                        BondType.caption.copyWith(color: BondColors.inkMuted),
                  ),
                ],
              ],
              // The ask this message is still waiting on. The thread banner
              // carries only the newest one, so an older message keeps its own
              // here until a reply answers it. Folded or not: a message that
              // wants an answer has to say so from behind the fold too.
              if (widget.openAsk) ...[
                const SizedBox(height: BondSpacing.s4),
                _askLine(message),
              ]
              // No ask, but an answer waiting under the fold — the hint that
              // there is something actionable here, in the ask's place.
              else if (collapsed && suggestion != null) ...[
                const SizedBox(height: BondSpacing.s4),
                Text(
                  '✨ Suggested reply',
                  style: BondType.caption.copyWith(color: BondColors.inkMuted),
                ),
              ],
              if (!collapsed && suggestion != null)
                Padding(
                  padding: const EdgeInsets.only(top: BondSpacing.s8),
                  child: suggestion,
                ),
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

  /// Who said it and when — and, where the row folds, the whole affordance for
  /// folding it. The header is the target rather than a separate button: it is
  /// the one part of the message that stays whichever way the row is, so the
  /// place to press is the same open and closed.
  ///
  /// Its own transparent Material, because ink paints on the nearest Material
  /// ANCESTOR — which is behind the pane's opaque surface, the same trap
  /// `_askLine` and `thread_detail_panel._ctaBanner` document.
  Widget _header(String meta, {required bool folds}) {
    final line = Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
          child: Text(
            _senderName,
            style: BondType.body.copyWith(fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (meta.isNotEmpty) ...[
          const SizedBox(width: BondSpacing.s8),
          Text(meta, style: BondType.caption),
        ],
        if (folds) ...[
          const SizedBox(width: BondSpacing.s4),
          Icon(
            _collapsed ? Icons.expand_more : Icons.expand_less,
            size: 16,
            color: BondColors.inkMuted,
          ),
        ],
      ],
    );

    if (!folds) return line;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => setState(() => _collapsed = !_collapsed),
        borderRadius: BondRadii.smAll,
        child: line,
      ),
    );
  }

  /// The open ask, in the same copper ink an inbox row tints its CTA with.
  /// Triage names an action item where it can; where it only judged that a
  /// reply is owed, the generic line still has to say so.
  ///
  /// A call to action the reader can act on: where the host gave it somewhere
  /// to go, the line is the way into the reply.
  Widget _askLine(Message message) {
    final ask = message.actionItems.isNotEmpty
        ? message.actionItems.first
        : 'Reply expected';
    final deadline = message.deadline;

    final onTap = widget.onAskTap;
    final line = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: BondSpacing.s8,
      runSpacing: BondSpacing.s4,
      children: [
        Text(
          ask,
          style: BondType.caption.copyWith(
            color: BondColors.onAttentionTint,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (deadline != null && deadline.isNotEmpty)
          BondChip.semantic(deadline, BondTone.attention),
      ],
    );

    if (onTap == null) return line;
    // Its own transparent Material: ink paints on the nearest Material
    // ancestor, which sits behind the pane's opaque surface — the same trap
    // `thread_detail_panel._ctaBanner` documents.
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BondRadii.smAll,
        child: line,
      ),
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
