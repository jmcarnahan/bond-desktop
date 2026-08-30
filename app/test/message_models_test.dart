import 'package:bond_inbox/models/message_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConversationState.fromWire', () {
    test('maps the three known tokens', () {
      expect(ConversationState.fromWire('needs_reply'),
          ConversationState.needsReply);
      expect(ConversationState.fromWire('done'), ConversationState.done);
      expect(ConversationState.fromWire('waiting'), ConversationState.waiting);
    });

    test('unknown and null fall back to waiting, never to needsReply', () {
      expect(ConversationState.fromWire('archived'), ConversationState.waiting);
      expect(ConversationState.fromWire(null), ConversationState.waiting);
      expect(ConversationState.fromWire(''), ConversationState.waiting);
    });

    test('wire round-trips', () {
      for (final state in ConversationState.values) {
        expect(ConversationState.fromWire(state.wire), state);
      }
    });
  });

  group('CtaUrgency.fromWire', () {
    test('maps the known tokens', () {
      expect(CtaUrgency.fromWire('low'), CtaUrgency.low);
      expect(CtaUrgency.fromWire('high'), CtaUrgency.high);
      expect(CtaUrgency.fromWire('urgent'), CtaUrgency.urgent);
      expect(CtaUrgency.fromWire('normal'), CtaUrgency.normal);
    });

    test('unknown and null fall back to normal', () {
      expect(CtaUrgency.fromWire('CRITICAL'), CtaUrgency.normal);
      expect(CtaUrgency.fromWire(null), CtaUrgency.normal);
    });
  });

  group('Participant', () {
    test('display prefers name, then email, then empty', () {
      expect(const Participant(name: 'Ada', email: 'a@x.com').display, 'Ada');
      expect(const Participant(email: 'a@x.com').display, 'a@x.com');
      expect(const Participant(name: '', email: 'a@x.com').display, 'a@x.com');
      expect(const Participant().display, '');
    });
  });

  group('Conversation.fromJson', () {
    test('reads a fully-populated payload', () {
      final c = Conversation.fromJson({
        'id': 'conv-1',
        'source': 'teams',
        'subject': 'Closing Disclosure',
        'participants': [
          {'name': 'Sarah', 'email': 'sarah@x.com'},
          {'name': null, 'email': 'marcus@x.com'},
        ],
        'category': 'closing',
        'state': 'needs_reply',
        'cta_text': 'Return the signed CD',
        'cta_urgency': 'urgent',
        'message_count': 3,
        'inbound_count': 2,
        'last_inbound_at': '2026-08-28T10:00:00Z',
        'last_outbound_at': '2026-08-27T10:00:00Z',
        'last_message_at': '2026-08-28T10:00:00Z',
        'last_message_preview': 'Thursday EOD please',
      });

      expect(c.id, 'conv-1');
      expect(c.source, 'teams');
      expect(c.subject, 'Closing Disclosure');
      expect(c.participants.length, 2);
      expect(c.primaryParticipant?.display, 'Sarah');
      expect(c.primaryEmail, 'sarah@x.com');
      expect(c.participants[1].display, 'marcus@x.com');
      expect(c.category, 'closing');
      expect(c.state, ConversationState.needsReply);
      expect(c.ctaText, 'Return the signed CD');
      expect(c.ctaUrgency, CtaUrgency.urgent);
      expect(c.messageCount, 3);
      expect(c.inboundCount, 2);
      expect(c.lastInboundAt, '2026-08-28T10:00:00Z');
      expect(c.lastOutboundAt, '2026-08-27T10:00:00Z');
      expect(c.lastMessageAt, '2026-08-28T10:00:00Z');
      expect(c.lastMessagePreview, 'Thursday EOD please');
    });

    test('an empty payload yields defaults rather than throwing', () {
      final c = Conversation.fromJson(const {});
      expect(c.id, '');
      expect(c.source, 'email');
      expect(c.subject, isNull);
      expect(c.participants, isEmpty);
      expect(c.state, ConversationState.waiting);
      expect(c.ctaUrgency, CtaUrgency.normal);
      expect(c.messageCount, 0);
      expect(c.inboundCount, 0);
      expect(c.lastMessageAt, isNull);
    });

    test('explicit nulls everywhere hold the same defaults', () {
      final c = Conversation.fromJson(const {
        'id': null,
        'source': null,
        'subject': null,
        'participants': null,
        'category': null,
        'state': null,
        'cta_text': null,
        'cta_urgency': null,
        'message_count': null,
        'inbound_count': null,
        'last_message_at': null,
      });
      expect(c.id, '');
      expect(c.source, 'email');
      expect(c.participants, isEmpty);
      expect(c.state, ConversationState.waiting);
      expect(c.ctaUrgency, CtaUrgency.normal);
      expect(c.messageCount, 0);
    });

    test('a non-map entry in participants is skipped, not thrown on', () {
      final c = Conversation.fromJson(const {
        'participants': [
          {'name': 'Ada', 'email': 'ada@x.com'},
          'marcus@x.com',
          42,
          null,
        ],
      });
      expect(c.participants.length, 1);
      expect(c.participants.single.display, 'Ada');
    });

    test('numeric counts arriving as doubles still read as ints', () {
      final c = Conversation.fromJson(const {
        'message_count': 3.0,
        'inbound_count': 2.0,
      });
      expect(c.messageCount, 3);
      expect(c.inboundCount, 2);
    });

    test('copyWith changes state and nothing else', () {
      final c = Conversation.fromJson(const {
        'id': 'conv-1',
        'subject': 'Subject',
        'state': 'needs_reply',
        'cta_urgency': 'urgent',
        'message_count': 4,
      });
      final done = c.copyWith(state: ConversationState.done);
      expect(done.state, ConversationState.done);
      expect(done.id, c.id);
      expect(done.subject, c.subject);
      expect(done.ctaUrgency, c.ctaUrgency);
      expect(done.messageCount, c.messageCount);
      // The original is untouched.
      expect(c.state, ConversationState.needsReply);
    });
  });

  group('Conversation.fromRow', () {
    test('reads a sqlite row, decoding participants_json', () {
      final c = Conversation.fromRow(const {
        'source': 'email',
        'conversation_key': 'AAQk-1',
        'subject': 'Title commitment',
        'participants_json':
            '[{"name":"Tomas","email":"t@x.com"},{"email":"b@x.com"}]',
        'state': 'done',
        'category': 'title',
        'cta_text': null,
        'cta_urgency': 'low',
        'message_count': 2,
        'inbound_count': 1,
        'last_message_at': '2026-08-25T09:00:00Z',
        'last_message_preview': 'Clean commitment',
      });

      expect(c.id, 'AAQk-1');
      expect(c.state, ConversationState.done);
      expect(c.ctaUrgency, CtaUrgency.low);
      expect(c.participants.length, 2);
      expect(c.participants.first.display, 'Tomas');
      expect(c.participants[1].display, 'b@x.com');
    });

    test('malformed or non-list participants_json yields no participants', () {
      expect(
        Conversation.fromRow(const {'participants_json': 'not json'})
            .participants,
        isEmpty,
      );
      expect(
        Conversation.fromRow(const {'participants_json': '{"a":1}'})
            .participants,
        isEmpty,
      );
      expect(
        Conversation.fromRow(const {'participants_json': ''}).participants,
        isEmpty,
      );
      expect(
        Conversation.fromRow(const {}).participants,
        isEmpty,
      );
    });
  });

  group('Message.fromJson', () {
    test('reads a fully-populated payload', () {
      final m = Message.fromJson({
        'id': 'msg-1',
        'source': 'email',
        'direction': 'inbound',
        'from_name': 'Sarah',
        'from_address': 'sarah@x.com',
        'to': ['lo@x.com', 'ops@x.com'],
        'received_at': '2026-08-28T10:00:00Z',
        'subject': 'Closing Disclosure',
        'body_text': 'Body here',
        'gate_reason': null,
        'urgency': 'urgent',
        'category': 'closing',
        'summary': 'Sign by Thursday',
        'needs_action': true,
        'action_items': ['Sign the CD'],
        'triage_status': 'done',
      });

      expect(m.id, 'msg-1');
      expect(m.outbound, isFalse);
      expect(m.inbound, isTrue);
      expect(m.fromName, 'Sarah');
      expect(m.to, ['lo@x.com', 'ops@x.com']);
      expect(m.urgency, 'urgent');
      expect(m.needsAction, isTrue);
      expect(m.actionItems, ['Sign the CD']);
      expect(m.triageStatus, 'done');
      expect(m.pendingSend, isFalse);
    });

    test("direction 'outbound' sets outbound; anything else does not", () {
      expect(Message.fromJson(const {'direction': 'outbound'}).outbound, isTrue);
      expect(Message.fromJson(const {'direction': 'inbound'}).outbound, isFalse);
      expect(Message.fromJson(const {'direction': 'OUTBOUND'}).outbound, isFalse);
      expect(Message.fromJson(const {}).outbound, isFalse);
    });

    test('an empty payload yields defaults rather than throwing', () {
      final m = Message.fromJson(const {});
      expect(m.id, '');
      expect(m.source, 'email');
      expect(m.to, isEmpty);
      expect(m.bodyText, isNull);
      expect(m.actionItems, isEmpty);
      expect(m.triageStatus, 'pending');
      // Not-yet-triaged is null, distinct from "no action needed".
      expect(m.needsAction, isNull);
    });

    test('explicit nulls everywhere hold the same defaults', () {
      final m = Message.fromJson(const {
        'id': null,
        'source': null,
        'direction': null,
        'to': null,
        'body_text': null,
        'needs_action': null,
        'action_items': null,
        'triage_status': null,
      });
      expect(m.id, '');
      expect(m.source, 'email');
      expect(m.to, isEmpty);
      expect(m.needsAction, isNull);
      expect(m.actionItems, isEmpty);
      expect(m.triageStatus, 'pending');
    });

    test('non-string recipients stringify rather than throw', () {
      final m = Message.fromJson(const {
        'to': ['a@x.com', 42, null],
      });
      expect(m.to, ['a@x.com', '42', 'null']);
    });
  });

  group('Message.fromRow', () {
    test('reads a sqlite row, decoding JSON columns and the 0/1 bool', () {
      final m = Message.fromRow(const {
        'source': 'email',
        'source_message_id': 'AAMk-1',
        'direction': 'outbound',
        'from_name': 'You',
        'from_address': 'lo@x.com',
        'to_json': '["sarah@x.com"]',
        'received_at': '2026-08-28T10:00:00Z',
        'subject': 'RE: CD',
        'body_text': 'Sent it',
        'gate_reason': 'outbound',
        'urgency': 'normal',
        'category': 'closing',
        'summary': 'Ack',
        'needs_action': 1,
        'action_items_json': '["Follow up"]',
        'triage_status': 'done',
      });

      expect(m.id, 'AAMk-1');
      expect(m.outbound, isTrue);
      expect(m.to, ['sarah@x.com']);
      expect(m.gateReason, 'outbound');
      expect(m.needsAction, isTrue);
      expect(m.actionItems, ['Follow up']);
      expect(m.triageStatus, 'done');
    });

    test('needs_action 0 is false and a missing one stays null', () {
      expect(Message.fromRow(const {'needs_action': 0}).needsAction, isFalse);
      expect(Message.fromRow(const {'needs_action': 1}).needsAction, isTrue);
      expect(Message.fromRow(const {'needs_action': null}).needsAction, isNull);
      expect(Message.fromRow(const {}).needsAction, isNull);
    });

    test('malformed JSON columns decode to empty lists', () {
      final m = Message.fromRow(const {
        'to_json': '{oops',
        'action_items_json': 'null',
      });
      expect(m.to, isEmpty);
      expect(m.actionItems, isEmpty);
    });
  });

  group('TriageResult', () {
    test('fallback is the quiet middle', () {
      final r = TriageResult.fallback();
      expect(r.urgency, 'normal');
      expect(r.category, 'other');
      expect(r.summary, '');
      expect(r.needsAction, isFalse);
      expect(r.actionItems, isEmpty);
    });

    test('fromJson defaults match the fallback on an empty payload', () {
      final r = TriageResult.fromJson(const {});
      expect(r.urgency, 'normal');
      expect(r.category, 'other');
      expect(r.summary, '');
      expect(r.needsAction, isFalse);
      expect(r.actionItems, isEmpty);
    });
  });
}
