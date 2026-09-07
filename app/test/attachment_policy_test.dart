import 'package:bond_inbox/services/attachments/attachment_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which attachments cost a fetch, and which are refused before one.
///
/// The judgement is pure and it is asked twice — once by each sync before it
/// queues work, once by each handler after it claims an item — so every case
/// here is a case both sides have to answer the same way.
void main() {
  Map<String, Object?> message({
    String triageStatus = 'triaged',
    String? gateReason,
    String direction = 'inbound',
  }) =>
      {
        'source_message_id': 'm1',
        'triage_status': triageStatus,
        'gate_reason': gateReason,
        'direction': direction,
      };

  Map<String, Object?> attachment({
    String kind = 'file',
    String? contentType = 'application/pdf',
    int size = 200 * 1024,
    Object? isInline = 0,
    int ordinal = 0,
    String? sourceUrl,
  }) =>
      {
        'attachment_id': 'att-1',
        'kind': kind,
        'content_type': contentType,
        'size': size,
        'is_inline': isInline,
        'ordinal': ordinal,
        'source_url': sourceUrl,
      };

  group('the message it came with', () {
    test('an ordinary triaged message\'s attachments are read', () {
      expect(attachmentTextPolicy(message(), attachment()), (true, null));
    });

    test('a gated message\'s attachments are never queued', () {
      expect(
        attachmentTextPolicy(
          message(triageStatus: 'skipped', gateReason: 'bulk_sender'),
          attachment(),
        ),
        (false, 'gated'),
      );
    });

    test('a chat skipped by birth is still eligible', () {
      // Every Teams message is stored `skipped` under `teams_source` — a
      // routing fact about a channel with no detail fetch, not a verdict.
      expect(
        attachmentTextPolicy(
          message(triageStatus: 'skipped', gateReason: 'teams_source'),
          attachment(),
        ),
        (true, null),
      );
    });

    test('the owner\'s own attachment is eligible', () {
      // The documents somebody sends are the storyline's biggest facts, and
      // this is the shape the store actually writes for them: `gates.dart`
      // marks every outbound message `skipped` under `outbound`, so a fixture
      // that left the status `triaged` asked a question the mailbox never
      // asks — and passed while the live path refused every sent document.
      expect(
        attachmentTextPolicy(
          message(
            direction: 'outbound',
            triageStatus: 'skipped',
            gateReason: 'outbound',
          ),
          attachment(),
        ),
        (true, null),
      );
    });

    test('a sent document is eligible however the send was gated', () {
      // The exemption is the direction, not the reason word: an outbound
      // message stored under some later gate reason is still the owner's own
      // document.
      expect(
        attachmentTextPolicy(
          message(
            direction: 'outbound',
            triageStatus: 'skipped',
            gateReason: 'newsletter',
          ),
          attachment(),
        ),
        (true, null),
      );
    });

    test('an inbound message gated as backlog is still refused', () {
      // The outbound arm must not widen into "skipped never means skipped".
      expect(
        attachmentTextPolicy(
          message(triageStatus: 'skipped', gateReason: 'backlog'),
          attachment(),
        ),
        (false, 'gated'),
      );
    });
  });

  group('what the attachment is', () {
    test('an inline signature image is refused', () {
      expect(
        attachmentTextPolicy(
          message(),
          attachment(contentType: 'image/png', isInline: 1),
        ),
        (false, 'inline'),
      );
    });

    test('an inline flag from a connector reads the same as one from a row',
        () {
      expect(
        attachmentTextPolicy(
          message(),
          attachment(contentType: 'image/png', isInline: true),
        ),
        (false, 'inline'),
      );
    });

    test('a 12 KB logo is refused even when nobody marked it inline', () {
      expect(
        attachmentTextPolicy(
          message(),
          attachment(contentType: 'image/png', size: 12 * 1024),
        ),
        (false, 'small_image'),
      );
    });

    test('a pasted screenshot above the floor is not refused for its size', () {
      expect(
        attachmentTextPolicy(
          message(),
          attachment(contentType: 'image/png', size: 240 * 1024),
        ),
        (true, null),
      );
    });

    test('a 40 MB video is refused before anything is fetched', () {
      expect(
        attachmentTextPolicy(
          message(),
          attachment(contentType: 'video/mp4', size: 40 * 1024 * 1024),
        ),
        (false, 'too_large'),
      );
    });

    test('a card is refused by kind', () {
      expect(
        attachmentTextPolicy(message(), attachment(kind: 'card')),
        (false, 'kind_card'),
      );
    });

    test('so is a quote of another message, and an unknown kind', () {
      expect(
        attachmentTextPolicy(
          message(),
          attachment(kind: 'message_reference'),
        ),
        (false, 'kind_message_reference'),
      );
      expect(
        attachmentTextPolicy(message(), attachment(kind: 'unknown')),
        (false, 'kind_unknown'),
      );
    });

    test('a forwarded message attached as a file is read', () {
      expect(
        attachmentTextPolicy(
          message(),
          attachment(kind: 'item', contentType: 'message/rfc822'),
        ),
        (true, null),
      );
    });

    test('a link attachment with no url is refused rather than fetched', () {
      expect(
        attachmentTextPolicy(message(), attachment(kind: 'reference')),
        (false, 'reference_no_url'),
      );
    });

    test('a link attachment that has one is read', () {
      expect(
        attachmentTextPolicy(
          message(),
          attachment(
            kind: 'reference',
            sourceUrl: 'https://contoso.example/sites/x/Shared/quote.docx',
          ),
        ),
        (true, null),
      );
    });

    test('the sixth attachment on a message is refused by ordinal', () {
      expect(
        attachmentTextPolicy(message(), attachment(ordinal: 4)),
        (true, null),
      );
      expect(
        attachmentTextPolicy(message(), attachment(ordinal: 5)),
        (false, 'over_cap'),
      );
    });

    test('a row missing every optional column is judged, not thrown at', () {
      expect(
        attachmentTextPolicy(const {}, const {}),
        (false, 'kind_unknown'),
      );
    });
  });

  group('the work-queue id', () {
    test('a message id and an attachment id make one entity id', () {
      expect(attachmentEntityId('m1', 'att-1'), 'm1|att-1');
    });

    test('and split back apart', () {
      expect(splitAttachmentEntityId('m1|att-1'), ('m1', 'att-1'));
    });

    test('a Graph id carrying its own separators survives the round trip', () {
      const messageId = 'AAMkAGI2=_x/y+z';
      const attachmentId = 'AAMkAGI2TG93AAA=';
      expect(
        splitAttachmentEntityId(attachmentEntityId(messageId, attachmentId)),
        (messageId, attachmentId),
      );
    });

    test('an id with no separator reads as a message and no attachment', () {
      // A work row that cannot be parsed still has to be able to complete.
      expect(splitAttachmentEntityId('m1'), ('m1', ''));
    });
  });

  group('the constants are what the plan settled on', () {
    test('the caps are stated once, here', () {
      expect(smallImageBytes, 20 * 1024);
      expect(maxAttachmentBytes, 25 * 1024 * 1024);
      expect(maxAttachmentsPerMessage, 5);
    });
  });
}
