import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/attachments/attachment_markers.dart';
import 'package:bond_inbox/services/llm/draft_task.dart';
import 'package:bond_inbox/services/llm/message_block.dart';
import 'package:bond_inbox/services/llm/needs_you_task.dart';
import 'package:bond_inbox/services/llm/reply_decision_task.dart';
import 'package:bond_inbox/services/llm/triage_task.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// The markers a chat body carries where a file or an image sat, and the one
/// rule about them: **the row reads them, and no model ever sees one.**
///
/// A `[[att:AAMk…]]` in a prompt is a token this app minted and nobody typed,
/// and a model shown one reasons about the token. The last group is the safety
/// net for that — every prompt this app builds, over a message carrying both
/// marker forms.
void main() {
  group('what the stripper leaves', () {
    test('a file-only chat body strips to nothing and the markers say why', () {
      const body = '[[att:file-1]]';

      expect(stripAttachmentMarkers(body), '');
      expect(isMarkerOnly(body), isTrue);
      expect(attachmentMarkers(body), [('att', 'file-1')]);
    });

    test('an inline image marker keeps the hosted content id', () {
      const body = '[[img:1a2b3c==]]';

      expect(attachmentMarkers(body), [('img', '1a2b3c==')]);
      expect(isMarkerOnly(body), isTrue);
    });

    test('stripping markers leaves the sentence around them readable', () {
      const body = 'The signed copy is [[att:file-1]] here, have a look.';

      expect(
        stripAttachmentMarkers(body),
        'The signed copy is here, have a look.',
      );
    });

    test('a body with no markers is returned unchanged', () {
      // Byte for byte, indentation and trailing newline included: almost every
      // body asked about is ordinary mail, where a run of spaces is a numbered
      // list and collapsing it would rewrite the message.
      const body = '1. Homepage copy\n'
          '   the sub-head still reads like the old one.\n';

      expect(stripAttachmentMarkers(body), body);
    });

    test('null and empty both read as nothing', () {
      expect(stripAttachmentMarkers(null), '');
      expect(stripAttachmentMarkers(''), '');
      expect(isMarkerOnly(null), isTrue);
      expect(attachmentMarkers(null), isEmpty);
    });

    test('markers come back in the order the sender put them', () {
      const body = 'Two things: [[att:a]] and then [[img:b]].';

      expect(attachmentMarkers(body), [('att', 'a'), ('img', 'b')]);
    });

    test('a body of nothing but markers and whitespace is marker-only', () {
      expect(isMarkerOnly('  [[att:a]] \n [[img:b]]  '), isTrue);
      expect(isMarkerOnly('Look: [[att:a]]'), isFalse);
    });
  });

  group('where the markers come from', () {
    test('a shared file becomes a marker rather than an empty body', () {
      const html = '<div><attachment id="file-1"></attachment></div>';

      expect(stripChatHtml(html), '[[att:file-1]]');
    });

    test('a pasted image becomes one keyed by its hosted content id', () {
      const html = '<div>Here it is '
          r'<img src="https://graph.microsoft.com/v1.0/chats/19:x/messages/'
          r'17/hostedContents/1a2b3c/$value" width="250"></div>';

      expect(stripChatHtml(html), 'Here it is [[img:1a2b3c]]');
      expect(hostedContentIds(html), ['1a2b3c']);
    });

    test('an entity a person typed cannot mint a marker', () {
      // `_decodeEntities` runs last, after the markers are written, so a
      // literal `&lt;attachment …` stays literal.
      const html = '<div>&lt;attachment id="nope"&gt;&lt;/attachment&gt;</div>';

      expect(stripChatHtml(html), '<attachment id="nope"></attachment>');
      expect(attachmentMarkers(stripChatHtml(html)), isEmpty);
    });

    test('an ordinary chat message is unchanged by any of this', () {
      expect(stripChatHtml('<div>Thursday works for me.</div>'),
          'Thursday works for me.');
      expect(hostedContentIds('<div>Thursday works.</div>'), isEmpty);
      expect(hostedContentIds(null), isEmpty);
    });
  });

  group('what stands in for a body that is only a file', () {
    AttachmentRef ref({
      String id = 'att-1',
      String? name = 'lease-addendum.pdf',
      bool isInline = false,
      String? cardText,
    }) =>
        AttachmentRef(
          source: 'teams',
          messageId: 'c1',
          attachmentId: id,
          name: name,
          isInline: isInline,
          cardText: cardText,
        );

    test('the file names say what arrived', () {
      expect(
        attachmentStandIn([ref()]),
        'Shared a file: lease-addendum.pdf',
      );
    });

    test('at most three of them', () {
      expect(
        attachmentStandIn([
          for (var i = 0; i < 5; i++) ref(id: 'att-$i', name: 'doc-$i.pdf'),
        ]),
        'Shared a file: doc-0.pdf, doc-1.pdf, doc-2.pdf',
      );
    });

    test('a file nobody named is still a file', () {
      expect(attachmentStandIn([ref(name: null)]),
          'Shared a file: (unnamed)');
    });

    test('a rendered card IS the message, so it wins', () {
      expect(
        attachmentStandIn([ref(cardText: 'Approve the September invoice?')]),
        'Approve the September invoice?',
      );
    });

    test('an image on its own is said once, not described', () {
      expect(
        attachmentStandIn([ref(id: 'hosted-1', name: null, isInline: true)]),
        'Shared an image',
      );
    });

    test('nothing attached says nothing', () {
      expect(attachmentStandIn(const []), '');
    });
  });

  group('no prompt this app builds contains a marker', () {
    final now = DateTime.utc(2026, 9, 4);
    const marked = 'Signed copy [[att:file-1]] and a shot of it [[img:hc-9]].';

    Message chat({String body = marked, List<AttachmentRef> attachments = const []}) =>
        Message(
          id: 'c1',
          source: 'teams',
          outbound: false,
          fromName: 'Dana Kessler',
          receivedAt: '2026-09-04T09:00:00.000Z',
          bodyText: body,
          attachments: attachments,
        );

    void expectClean(String prompt) {
      expect(prompt, isNot(contains('[[att:')));
      expect(prompt, isNot(contains('[[img:')));
    }

    test('triage', () {
      expectClean(
        const TriageTask().buildUserMessage(
          TriageInput(chat(), now, thread: [chat()]),
        ),
      );
    });

    test('the reply decision', () {
      expectClean(
        const ReplyDecisionTask().buildUserMessage(
          ReplyDecisionInput(message: chat(), now: now, context: [chat()]),
        ),
      );
    });

    test('the needs-you verdict', () {
      expectClean(
        const NeedsYouTask().buildUserMessage(
          NeedsYouInput(message: chat(), now: now, thread: [chat()]),
        ),
      );
    });

    test('the draft', () {
      expectClean(
        const DraftTask().buildUserMessage(
          DraftInput(replyTo: chat(), now: now, thread: [chat(), chat()]),
        ),
      );
    });

    test('and the block every one of them renders through', () {
      expectClean(buildMessageBlock(chat()));
    });

    // The other way a marker gets into a body, and the one that arrives on
    // MAIL: a file attached as a link is not in Graph's attachment list, so
    // the sync's own parse writes a `reference` row and puts the marker where
    // the link sat. A minted token is a minted token whichever pass wrote it.
    const linkId = 'link-9f2a1c0d4b6e8a11';
    Message linked() => Message(
          id: 'm1',
          source: 'email',
          outbound: false,
          fromName: 'Dana Kessler',
          fromAddress: 'dana@example.com',
          receivedAt: '2026-09-04T09:00:00.000Z',
          bodyText: 'Please review [[att:$linkId]] before Friday.',
          attachments: const [
            AttachmentRef(
              source: 'email',
              messageId: 'm1',
              attachmentId: linkId,
              kind: 'reference',
              name: 'HARBORLIGHT TALENT AGREEMENT.pdf',
              sourceUrl:
                  'https://southbayequity2-my.sharepoint.com/:b:/g/personal/'
                  'jane_southbayequity2_onmicrosoft_com/EaBcDeFgHiJkLmNoPqRsTuVwXyZ',
            ),
          ],
        );

    test('and a mail whose file came as a link', () {
      expectClean(buildMessageBlock(linked()));
      expectClean(
        const TriageTask().buildUserMessage(
          TriageInput(linked(), now, thread: [linked()]),
        ),
      );
      expectClean(
        const ReplyDecisionTask().buildUserMessage(
          ReplyDecisionInput(message: linked(), now: now, context: [linked()]),
        ),
      );
      expectClean(
        const NeedsYouTask().buildUserMessage(
          NeedsYouInput(message: linked(), now: now, thread: [linked()]),
        ),
      );
      expectClean(
        const DraftTask().buildUserMessage(
          DraftInput(replyTo: linked(), now: now, thread: [linked()]),
        ),
      );
      // The marker comes out and the sentence around it still reads. A body
      // that stripped to nothing is where the block names the file instead —
      // that case is the marker-only test below.
      expect(
        buildMessageBlock(linked()),
        contains('Please review before Friday.'),
      );
    });


    test('a marker-only chat message reads as what was shared', () {
      final block = buildMessageBlock(chat(
        body: '[[att:file-1]]',
        attachments: [
          const AttachmentRef(
            source: 'teams',
            messageId: 'c1',
            attachmentId: 'file-1',
            name: 'lease-addendum.pdf',
          ),
        ],
      ));

      expect(block, contains('Shared a file: lease-addendum.pdf'));
      expectClean(block);
    });
  });
}
