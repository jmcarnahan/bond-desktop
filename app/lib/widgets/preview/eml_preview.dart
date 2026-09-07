/// A message that came attached to a message, read the way messages are read.
///
/// Outlook forwards mail as a file, and the file is a message: it has a
/// sender, a time and a body. Rendering it through the same [MessageRow] the
/// transcript uses is the whole design — a forwarded message should look like
/// what it is, and inventing a second way to draw one would be two things to
/// keep in step.
///
/// **No preview inside a preview.** The nested row is handed no
/// `onOpenAttachment`, so nothing in it takes a tap. A panel that opened a
/// third pane from inside its own body has no way back out that a reader would
/// find.
library;

import 'package:flutter/material.dart';

import '../../models/attachment_models.dart';
import '../../models/message_models.dart';
import '../../theme/tokens.dart';
import '../message_row.dart';

/// The attached message as a [Message], so the row can draw it.
///
/// The three `item_*` columns are what the connector said about the message
/// inside the file; they are NULL until a later phase asks Graph for them, and
/// the row already renders a message with no sender and no time as one.
///
/// `triageStatus: 'skipped'` and `isRead: true` are the two flags that keep the
/// row quiet: this message is not in anybody's inbox, so it must not draw a
/// `triaging` suffix or an unread mark for work no queue is doing on it.
Message messageForItem(AttachmentRef ref, String? bodyText) => Message(
      id: 'att-${ref.messageId}-${ref.attachmentId}',
      outbound: false,
      source: ref.source,
      fromName: ref.itemFrom,
      receivedAt: ref.itemReceived,
      subject: ref.itemSubject,
      bodyText: bodyText,
      triageStatus: 'skipped',
      isRead: true,
    );

class EmlPreview extends StatelessWidget {
  final AttachmentRef attachment;

  /// The body, from whatever the pipeline extracted. Null and empty are the
  /// same thing here and say so in one line.
  final String? bodyText;

  const EmlPreview({super.key, required this.attachment, this.bodyText});

  static const Key rowKey = ValueKey('eml-preview-row');
  static const Key noBodyKey = ValueKey('eml-preview-no-body');

  @override
  Widget build(BuildContext context) {
    final subject =
        attachment.itemSubject ?? attachment.name ?? '(no subject)';
    final body = bodyText ?? '';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            subject,
            style: BondType.body.copyWith(fontWeight: FontWeight.w600),
          ),
          if (body.trim().isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: BondSpacing.s8),
              child: Text(
                "This message's body is not cached.",
                key: noBodyKey,
                style: BondType.caption.copyWith(color: BondColors.inkMuted),
              ),
            )
          else
            MessageRow(
              key: rowKey,
              message: messageForItem(attachment, body),
            ),
        ],
      ),
    );
  }
}
