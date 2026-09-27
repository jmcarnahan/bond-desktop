import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/chat_mentions.dart';
import 'package:bond_inbox/services/chat_roster.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// The chat HTML a mention send carries, and the way back from it: Graph
/// echoes the html body, and the row built from that echo must read as the
/// words that were typed.
void main() {
  const ada = ChatMention(userId: 'aad-ada', displayName: 'Ada Park');
  const ben = ChatMention(userId: 'aad-ben', displayName: 'Ben Ortiz');

  group('chatHtmlWithMentions', () {
    test('the first @Name becomes the at-tag, a later one stays text', () {
      expect(
        chatHtmlWithMentions('@Ada Park hi, @Ada Park', const [ada]),
        '<at id="0">Ada Park</at> hi, @Ada Park',
      );
    });

    test('& is escaped first, so an entity typed stays an entity typed', () {
      expect(
        chatHtmlWithMentions('&lt; is <, "q" > 1', const [ada]),
        '<at id="0">Ada Park</at> &amp;lt; is &lt;, &quot;q&quot; &gt; 1',
      );
    });

    test('a name inside a longer word is not that person', () {
      const al = ChatMention(userId: 'aad-al', displayName: 'Al');
      expect(
        chatHtmlWithMentions('@Alan and @Al', const [al]),
        '@Alan and <at id="0">Al</at>',
      );
    });

    test('the longer name claims its own text before a shorter one', () {
      const adaShort = ChatMention(userId: 'aad-a', displayName: 'Ada');
      expect(
        chatHtmlWithMentions('@Ada Park and @Ada', const [adaShort, ada]),
        '<at id="1">Ada Park</at> and <at id="0">Ada</at>',
      );
    });

    test('a name with markup in it is escaped inside the tag too', () {
      const team = ChatMention(userId: 'aad-rd', displayName: 'R&D <Ops>');
      expect(
        chatHtmlWithMentions('ping', const [team]),
        '<at id="0">R&amp;D &lt;Ops&gt;</at> ping',
      );
    });

    test('new lines of every kind become <br>', () {
      expect(
        chatHtmlWithMentions('one\r\ntwo\nthree', const [ben]),
        '<at id="0">Ben Ortiz</at> one<br>two<br>three',
      );
    });
  });

  group('textWithoutClaimedMentions', () {
    test('takes out each claimed @Name and one space beside it', () {
      expect(
        textWithoutClaimedMentions('@Ada Park can you look?', const [ada]),
        'can you look?',
      );
      expect(
        textWithoutClaimedMentions('Looping in @Ada Park.', const [ada]),
        'Looping in.',
      );
      expect(
        textWithoutClaimedMentions(
          'Hi @Ada Park, and @Ben Ortiz too',
          const [ada, ben],
        ),
        'Hi, and too',
      );
    });

    test('leaves what the builder would not claim', () {
      // The second `@Ada Park` stays text in the html too.
      expect(
        textWithoutClaimedMentions('@Ada Park ping @Ada Park', const [ada]),
        'ping @Ada Park',
      );
      expect(
        textWithoutClaimedMentions('no names here', const [ada]),
        'no names here',
      );
    });
  });

  group('the echo', () {
    test('stores the words, not the markup', () {
      final row = TeamsSync.messageRow(
        {
          'id': 'sent-1',
          'messageType': 'message',
          'createdDateTime': '2026-09-20T10:00:00Z',
          'body': {
            'contentType': 'html',
            'content': '<at id="0">Ada Park</at> a &lt; b<br>ok',
          },
        },
        'chat-1',
        outbound: true,
      )!;

      expect(row['body_text'], 'Ada Park a < b\nok');
    });

    test('round-trips what was typed, minus the @ Teams drops', () {
      const typed = '@Ada Park is a < b & "c"?\nThanks, @Ben Ortiz';
      expect(
        stripChatHtml(chatHtmlWithMentions(typed, const [ada, ben])),
        'Ada Park is a < b & "c"?\nThanks, Ben Ortiz',
      );
      expect(
        stripChatHtml(chatHtmlWithMentions('&amp; stays', const [ada])),
        'Ada Park &amp; stays',
      );
    });

    test('an outbound row is never addressed to me by its own mentions', () {
      final row = TeamsSync.messageRow(
        {
          'id': 'sent-1',
          'messageType': 'message',
          'createdDateTime': '2026-09-20T10:00:00Z',
          'body': {
            'contentType': 'html',
            'content': '<at id="0">Jordan Bond</at> note to self',
          },
          'mentions': [
            {
              'id': 0,
              'mentionText': 'Jordan Bond',
              'mentioned': {
                'user': {'id': 'me-1', 'displayName': 'Jordan Bond'},
              },
            },
          ],
        },
        'chat-1',
        outbound: true,
        myId: 'me-1',
        mentions: const ['me-1'],
      )!;

      expect(row['addressed_me'], 0);
    });
  });

  group('teamsRosterLacks', () {
    Conversation chat(List<String> ids) => Conversation(
          id: 'chat-1',
          source: 'teams',
          participants: [
            for (final id in ids) Participant(name: id, email: 'teams:$id'),
          ],
        );

    test('a complete roster without the person refuses them', () {
      expect(teamsRosterLacks(chat(['aad-ada']), 'aad-ben'), isTrue);
      expect(teamsRosterLacks(chat(['aad-ada']), 'aad-ada'), isFalse);
    });

    test('a roster at the cap may be truncated, so it refuses nobody', () {
      final full = [for (var i = 0; i < teamsRosterCap; i++) 'aad-$i'];
      expect(teamsRosterLacks(chat(full), 'aad-ben'), isFalse);
    });

    test('a roster never read refuses nobody', () {
      expect(teamsRosterLacks(chat(const []), 'aad-ben'), isFalse);
    });
  });
}
