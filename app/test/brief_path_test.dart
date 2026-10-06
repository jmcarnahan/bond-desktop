import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/calendar/brief_path.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pure rules that pick a brief's path: what looks like a list, what of
/// an invite is its own words, what makes a meeting topicless, which path a
/// meeting takes, what the related search embeds and what counts as
/// calendar logistics. Each is an unmeasured English-only heuristic; these
/// fictional fixtures pin what it does.
void main() {
  CalendarEvent event({
    String subject = 'Falcon budget review',
    String bodyPreview = '',
    String organizerName = '',
    List<Attendee> attendees = const [],
  }) =>
      CalendarEvent(
        id: 'evt-1',
        subject: subject,
        bodyPreview: bodyPreview,
        organizerName: organizerName,
        attendees: attendees,
      );

  List<String> others(int n) => [
        for (var i = 0; i < n; i++) 'guest$i@fabrikam.com',
      ];

  group('briefLooksLikeList', () {
    test('a list word first or last is a list', () {
      for (final a in [
        'dl-eng@contoso.com',
        'team@contoso.com',
        'eng-team@contoso.com',
        'all-hands@contoso.com',
        'everyone@fabrikam.com',
        'sales.staff@northwind.com',
        'allhands@example.com',
      ]) {
        expect(briefLooksLikeList(a), isTrue, reason: a);
      }
    });

    test('a word that merely starts with one is a person', () {
      for (final a in [
        'dlopez@contoso.com',
        'allen@contoso.com',
        'teamster@contoso.com',
        'dana.lee@fabrikam.com',
      ]) {
        expect(briefLooksLikeList(a), isFalse, reason: a);
      }
    });
  });

  group('briefAgendaOf', () {
    test('a bare "Join: <link>" line is join boilerplate', () {
      expect(
          briefAgendaOf(
              'Join: https://teams.example.com/l/abc Meeting ID: 221 756 307'),
          '');
      expect(
          briefAgendaOf(
              'Agenda: budget review. Join: https://teams.example.com/l/abc'),
          'Agenda: budget review.');
    });

    test('the old Teams block is cut at its rule', () {
      const preview = 'Walk through the Q3 pipeline numbers.\n'
          '________________________________________________________________\n'
          'Microsoft Teams meeting\nJoin on your computer, mobile app or room '
          'device\nClick here to join the meeting';
      expect(briefAgendaOf(preview), 'Walk through the Q3 pipeline numbers.');
    });

    test('the new Teams block is cut at its first line', () {
      const preview = 'Agree the launch checklist. '
          'Microsoft Teams Need help? Join the meeting now Meeting ID: 123 456';
      expect(briefAgendaOf(preview), 'Agree the launch checklist.');
    });

    test('Zoom and Meet blocks are cut', () {
      expect(
          briefAgendaOf('Pricing review. Dana Lee is inviting you to a '
              'scheduled Zoom meeting. Join Zoom Meeting https://example.com/j/1'),
          'Pricing review. Dana Lee');
      expect(
          briefAgendaOf('Roadmap. Join with Google Meet https://example.com/x'),
          'Roadmap.');
    });

    test('a plain agenda is kept, its links out and its whitespace closed',
        () {
      expect(
          briefAgendaOf('  Agenda:\n1. Renewal terms\n2. See '
              'https://example.com/doc  for the draft  '),
          'Agenda: 1. Renewal terms 2. See for the draft');
      expect(briefAgendaOf(''), '');
    });
  });

  group('briefIsTopicless', () {
    test('names, cadence words and an empty subject say nothing', () {
      expect(
          briefIsTopicless(event(
            subject: '1:1 | Dana & Sam | Weekly',
            attendees: const [
              Attendee(name: 'Dana Lee', address: 'dana@fabrikam.com'),
              Attendee(name: 'Sam Ortiz', address: 'sam@fabrikam.com'),
            ],
          )),
          isTrue);
      expect(briefIsTopicless(event(subject: 'Daily sync')), isTrue);
      expect(briefIsTopicless(event(subject: 'TGIF')), isTrue);
      expect(briefIsTopicless(event(subject: '')), isTrue);
    });

    test('a content word, or an agenda of forty characters, is a topic', () {
      expect(briefIsTopicless(event(subject: 'Budget')), isFalse);
      expect(briefIsTopicless(event(subject: 'Falcon weekly')), isFalse);
      expect(
          briefIsTopicless(event(
              subject: 'Weekly sync',
              bodyPreview: 'Go through the vendor shortlist and pick two.')),
          isFalse);
      expect(
          briefIsTopicless(event(
              subject: 'Weekly sync',
              bodyPreview: 'Short note.\n__________\nMicrosoft Teams meeting '
                  'Join on your computer or mobile app, a long block')),
          isTrue,
          reason: 'the join block is not an agenda');
    });
  });

  group('briefIsTopicless: whose names count', () {
    test("a room's or a list's name is not a person's: the subject keeps "
        'its topic', () {
      expect(
          briefIsTopicless(event(
            subject: 'Falcon weekly',
            attendees: const [
              Attendee(
                  name: 'Conf Room Falcon',
                  address: 'room-falcon@contoso.com',
                  type: 'resource'),
            ],
          )),
          isFalse,
          reason: 'a room is named after the thing, not a person');
      expect(
          briefIsTopicless(event(
            subject: 'Falcon weekly',
            attendees: const [
              Attendee(name: 'Falcon Team', address: 'falcon-team@contoso.com'),
            ],
          )),
          isFalse,
          reason: 'a list is named after the thing, not a person');
    });

    test("a person's name is still a name (the documented rule)", () {
      expect(
          briefIsTopicless(event(
            subject: 'Falcon weekly',
            attendees: const [
              Attendee(name: 'Falcon Lee', address: 'falcon.lee@fabrikam.com'),
            ],
          )),
          isTrue);
    });

    test('a forwarded subject is judged without its FW:', () {
      expect(briefIsTopicless(event(subject: 'FW: Weekly sync')), isTrue);
      expect(briefIsTopicless(event(subject: 'FW: Falcon weekly')), isFalse);
    });

    test('status and update are generic meeting words', () {
      expect(briefIsTopicless(event(subject: 'Weekly status update')), isTrue);
      expect(briefIsTopicless(event(subject: 'Falcon status update')), isFalse);
    });
  });

  group('briefPathOf', () {
    test('five others is people, six is related', () {
      expect(briefPathOf(event(), otherAddresses: others(5)), BriefPath.people);
      expect(
          briefPathOf(event(), otherAddresses: others(6)), BriefPath.related);
    });

    test('a list in a small room is related', () {
      expect(
          briefPathOf(event(),
              otherAddresses: [...others(2), 'eng-team@contoso.com']),
          BriefPath.related);
    });

    test('a topicless meeting stays on people up to fifteen others', () {
      final weekly = event(subject: 'Weekly sync');
      expect(briefPathOf(weekly, otherAddresses: others(6)), BriefPath.people);
      expect(briefPathOf(weekly, otherAddresses: others(15)), BriefPath.people);
      expect(
          briefPathOf(weekly, otherAddresses: others(16)), BriefPath.related);
    });

    test('the wire words', () {
      expect(BriefPath.people.wire, 'people');
      expect(BriefPath.related.wire, 'related');
    });

    test("the wire words are the stored brief's path words", () {
      // models/ may not import services/, so MeetingBrief spells the words
      // itself; this keeps the two spellings one.
      expect(BriefPath.people.wire, MeetingBrief.pathPeople);
      expect(BriefPath.related.wire, MeetingBrief.pathRelated);
    });
  });

  group('briefQueryText', () {
    test('the subject, then the agenda on its own line, whitespace closed',
        () {
      expect(
          briefQueryText(event(
              subject: '  Falcon   budget ',
              bodyPreview: 'Agree the\n\nQ3 numbers.\n'
                  '__________\nMicrosoft Teams meeting')),
          'Falcon budget\nAgree the Q3 numbers.');
    });

    test("Re: and Fw: come off the subject, as they do the message cards'",
        () {
      expect(briefQueryText(event(subject: 'FW: Falcon review')),
          'Falcon review');
      expect(briefQueryText(event(subject: 'RE: Fwd: Falcon review')),
          'Falcon review');
      expect(
          briefQueryText(event(
              subject: 'Re:', bodyPreview: 'Agree the Q3 launch numbers.')),
          'Agree the Q3 launch numbers.');
    });

    test('no agenda is the subject alone; nothing at all is empty', () {
      expect(briefQueryText(event(subject: 'Falcon budget')), 'Falcon budget');
      expect(briefQueryText(event(subject: '  ', bodyPreview: '')), '');
    });
  });

  group('briefIsLogisticsSubject', () {
    test('answers, invitations, cancellations, proposals, auto-replies', () {
      for (final s in [
        'Accepted: Falcon budget review',
        'RE: Accepted: Falcon budget review',
        'Fw: RE: Declined: Falcon budget review',
        'Tentative: Falcon budget review',
        'Tentatively accepted: Falcon budget review',
        'Canceled: Falcon budget review',
        'Cancelled: Falcon budget review',
        'Invitation: Falcon budget review',
        'Updated invitation with note: Falcon budget review',
        'New Time Proposed: Falcon budget review',
        'Automatic reply: out until Monday',
        // The message cards' own stripReFw, numbered replies included.
        'RE[2]: Accepted: Falcon review',
      ]) {
        expect(briefIsLogisticsSubject(s), isTrue, reason: s);
      }
    });

    test('talk about the topic is not', () {
      for (final s in [
        'Falcon budget review',
        'RE: Falcon budget numbers',
        'Re: the accepted budget',
        '',
      ]) {
        expect(briefIsLogisticsSubject(s), isFalse, reason: s);
      }
    });
  });
}
