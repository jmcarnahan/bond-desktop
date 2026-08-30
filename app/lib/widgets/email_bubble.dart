import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../theme/tokens.dart';
import 'time_format.dart';

/// One message in a thread rendered as a chat-style bubble. Inbound sits left
/// on a bordered surface; outbound sits right on a primary tint. Bodies are
/// plain-text [SelectableText] — mail content is NEVER markdown-rendered.
/// Long bodies collapse behind a Show more/less toggle.
class EmailBubble extends StatefulWidget {
  final Message message;

  const EmailBubble({super.key, required this.message});

  /// Collapse threshold — either many lines or a long body.
  static const int _maxLines = 12;
  static const int _maxChars = 600;

  @override
  State<EmailBubble> createState() => _EmailBubbleState();
}

class _EmailBubbleState extends State<EmailBubble> {
  bool _expanded = false;

  /// Graph's HTML→text conversion renders inline images (a signature logo,
  /// typically) as literal "[cid:…]" tokens — presentational noise, stripped
  /// for display only. The stored body stays as ingested.
  static final _cidToken = RegExp(r'[ \t]*\[cid:[^\]]+\][ \t]*');

  String get _body {
    // The preview stands in until the body arrives: bodies are fetched per
    // thread on open, and a bubble with nothing in it reads as an empty
    // message rather than as one still loading.
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
    return body.length > EmailBubble._maxChars ||
        '\n'.allMatches(body).length + 1 > EmailBubble._maxLines;
  }

  String get _visibleBody {
    final body = _body;
    if (_expanded || !_collapsible) return body;
    // Clamp to the first N lines, then the char cap, whichever hits first.
    final lines = body.split('\n');
    var clamped = lines.length > EmailBubble._maxLines
        ? lines.take(EmailBubble._maxLines).join('\n')
        : body;
    if (clamped.length > EmailBubble._maxChars) {
      clamped = clamped.substring(0, EmailBubble._maxChars);
    }
    return clamped.trimRight();
  }

  static String _caption(String who, String? iso) {
    final when = formatTimestamp(iso);
    return when == null ? who : '$who · $when';
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final outbound = message.outbound;
    final pending = message.pendingSend;

    final caption = pending
        ? 'Sending…'
        : _caption(
            outbound
                ? 'You'
                : (message.fromName ?? message.fromAddress ?? 'Unknown'),
            message.receivedAt,
          );

    // Only inbound mail is ever queued, so the suffix says "the model has not
    // reached this one yet" rather than appearing on every bubble in a thread.
    final triaging = !pending &&
        message.inbound &&
        (message.triageStatus == 'pending' ||
            message.triageStatus == 'processing');
    final summary = message.summary;

    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.all(BondSpacing.s12),
      decoration: BoxDecoration(
        color: outbound ? BondColors.primaryTint : BondColors.surface,
        borderRadius: BondRadii.mdAll,
        border: Border.all(
          color: outbound ? BondColors.primaryTintBorder : BondColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
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
          const SizedBox(height: BondSpacing.s8),
          Text(
            triaging ? '$caption · triaging' : caption,
            style: BondType.caption,
          ),
          // The model's one-line read of this message, labelled as the
          // model's: it sits under mail the LO can see for themselves, and it
          // must never be mistaken for something the sender wrote.
          if (summary != null && summary.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text('AI: $summary', style: BondType.caption),
          ],
        ],
      ),
    );

    return Opacity(
      opacity: pending ? 0.6 : 1,
      child: Row(
        mainAxisAlignment:
            outbound ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Flexible(child: bubble),
        ],
      ),
    );
  }
}

/// The Show more/less affordance — a quiet inline text toggle, kept local so
/// the bubble owns its own collapse without an ad-hoc button style.
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
