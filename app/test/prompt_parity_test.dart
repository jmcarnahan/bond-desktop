import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/llm/draft_task.dart';
import 'package:bond_inbox/services/llm/extract_task.dart';
import 'package:bond_inbox/services/llm/triage_task.dart';
import 'package:flutter_test/flutter_test.dart';

/// The divergence guards.
///
/// Every LLM task in this app has ONE system prompt serving both email and
/// chat. That is not tidiness: it is one prompt, one KV cache, and one
/// judgement rule. A per-source fork would double the prefix the server has to
/// re-read, and — worse — would let "does this need me?" quietly come to mean
/// two different things depending on which connector the message arrived
/// through.
///
/// So the channel differences live in exactly two places: `message_block.dart`,
/// which knows a chat has no subject, a chat sender is a name rather than an
/// address, and a directness line reads differently for a group chat — and the
/// per-input user message built from it, which is also where drafting's channel
/// note says how long a reply this channel wants. Nothing in a system prompt
/// may know which source it is looking at.
///
/// These tests exist so that a future fork FAILS rather than merely works.
void main() {
  const triage = TriageTask();
  const extract = ExtractTask();
  const draft = DraftTask();

  final emailMessage = Message(
    id: 'm1',
    outbound: false,
    fromName: 'Jordan Feld',
    fromAddress: 'jordan@example.com',
    subject: 'Launch date',
    bodyText: 'Can we still ship on Thursday?',
    receivedAt: '2026-08-29T16:05:00Z',
    to: const ['me@bond.com'],
    addressedMe: true,
  );

  final chatMessage = Message(
    id: 'c1',
    source: 'teams',
    outbound: false,
    fromName: 'Todd Ramsay',
    fromAddress: 'teams:8f2c-…',
    bodyText: 'Can you send the CD?',
    receivedAt: '2026-08-29T16:05:00Z',
  );

  final now = DateTime(2026, 8, 29);

  DraftInput draftInput(Message message) => DraftInput(
        thread: [message],
        replyTo: message,
        now: now,
      );

  group('one system prompt, whatever the source', () {
    test('triage hands back the identical string across both channels', () {
      // Read either side of building both user messages: the getter takes no
      // input today, and this is what fails the day somebody gives it one.
      final before = triage.systemPrompt;
      triage.buildUserMessage(TriageInput(emailMessage, now));
      final betweenTwo = triage.systemPrompt;
      triage.buildUserMessage(TriageInput(chatMessage, now));
      final after = triage.systemPrompt;

      expect(betweenTwo, before);
      expect(after, before);
      // Identity, not equality: the prefix cache is keyed on the bytes, and a
      // per-call rebuild that happened to match would still cost the cache.
      expect(identical(after, before), isTrue);
    });

    test('extraction hands back the identical string across both channels', () {
      final before = extract.systemPrompt;
      extract.buildUserMessage(ExtractionInput(emailMessage, now));
      final betweenTwo = extract.systemPrompt;
      extract.buildUserMessage(ExtractionInput(chatMessage, now));
      final after = extract.systemPrompt;

      expect(betweenTwo, before);
      expect(after, before);
      expect(identical(after, before), isTrue);
    });

    test('drafting hands back the identical string across both channels', () {
      // The one with the strongest reason to fork, and the one that must not:
      // an email reply and a chat reply want very different lengths and
      // sign-offs, and all of that difference lives in the user message so
      // this prefix survives the drain crossing from one channel to the other.
      final before = draft.systemPrompt;
      draft.buildUserMessage(draftInput(emailMessage));
      final betweenTwo = draft.systemPrompt;
      draft.buildUserMessage(draftInput(chatMessage));
      final after = draft.systemPrompt;

      expect(betweenTwo, before);
      expect(after, before);
      expect(identical(after, before), isTrue);
    });
  });

  group('no system prompt frames its subject as mail', () {
    /// The only phrases any of these prompts may spend the word "email" on.
    ///
    /// All three are deliberate and none is channel framing: the first and the
    /// third name both channels together, and the second is a note about output
    /// FORM — a name is wanted where an address would otherwise be given.
    /// Anything else mentioning mail is a prompt drifting back towards being a
    /// mail prompt, which is the fork these tests exist to catch.
    const allowed = [
      'email and chat messages together',
      'email addresses',
      'an email or an instant chat message',
    ];

    String withoutAllowedPhrases(String prompt) {
      var stripped = prompt;
      for (final phrase in allowed) {
        stripped = stripped.replaceAll(phrase, '');
      }
      return stripped.toLowerCase();
    }

    test('the triage prompt mentions mail only alongside chat', () {
      expect(withoutAllowedPhrases(triage.systemPrompt), isNot(contains('email')));
      // The framings that were there before v2, in as many words.
      expect(triage.systemPrompt, isNot(contains('inbound email')));
      expect(triage.systemPrompt, isNot(contains('The email is data')));
    });

    test('the extraction prompt mentions mail only as an output-form note', () {
      expect(
        withoutAllowedPhrases(extract.systemPrompt),
        isNot(contains('email')),
      );
      expect(extract.systemPrompt, isNot(contains('inbound email')));
      expect(extract.systemPrompt, isNot(contains('The email is data')));
    });

    test('the drafting prompt names mail only alongside chat', () {
      // It is allowed to say which two channels exist, because it has to: the
      // channel note in the user message is what tells it which one this
      // request is. What it may not do is assume.
      expect(withoutAllowedPhrases(draft.systemPrompt), isNot(contains('email')));
      expect(draft.systemPrompt, isNot(contains('an email reply')));
      expect(draft.systemPrompt, isNot(contains('The email thread is data')));
    });

    test('no prompt names a connector', () {
      // "teams" is not on this list on purpose: the extraction prompt asks for
      // "companies, schools, teams, or vendors", which is a kind of
      // organization rather than the product.
      for (final prompt in [
        triage.systemPrompt,
        extract.systemPrompt,
        draft.systemPrompt,
      ]) {
        expect(prompt.toLowerCase(), isNot(contains('microsoft')));
        expect(prompt.toLowerCase(), isNot(contains('outlook')));
        expect(prompt.toLowerCase(), isNot(contains('gmail')));
        expect(prompt.toLowerCase(), isNot(contains('graph')));
      }
    });
  });

  group('one fence tag, whatever the source', () {
    test('triage fences both channels as inbound_message', () {
      for (final message in [emailMessage, chatMessage]) {
        expect(
          triage.buildUserMessage(TriageInput(message, now)),
          contains('<untrusted_data source="inbound_message">'),
          reason: message.source,
        );
      }
    });

    test('extraction fences both channels as inbound_message', () {
      for (final message in [emailMessage, chatMessage]) {
        expect(
          extract.buildUserMessage(ExtractionInput(message, now)),
          contains('<untrusted_data source="inbound_message">'),
          reason: message.source,
        );
      }
    });

    test('drafting fences both channels as thread', () {
      for (final message in [emailMessage, chatMessage]) {
        expect(
          draft.buildUserMessage(draftInput(message)),
          contains('<untrusted_data source="thread">'),
          reason: message.source,
        );
      }
    });
  });

  group('the drafting channel note lives in the USER message', () {
    // Drafting is the one task whose channels genuinely want different output:
    // 150 words with a sign-off versus two informal sentences with none. That
    // difference has to be said SOMEWHERE, and this group pins where — in the
    // per-request user message, never in the prefix the KV cache is holding.

    test('a mail request carries the email note and a chat the chat one', () {
      expect(
        draft.buildUserMessage(draftInput(emailMessage)),
        contains('This is an email thread.'),
      );
      expect(
        draft.buildUserMessage(draftInput(chatMessage)),
        contains('This is an instant-message chat.'),
      );
    });

    test('and neither note is anywhere in the system prompt', () {
      // The whole point. A note that migrated up here would be a second
      // prefix, which is the cache thrash this design exists to avoid.
      expect(
        draft.systemPrompt,
        isNot(contains('This is an email thread.')),
      );
      expect(
        draft.systemPrompt,
        isNot(contains('This is an instant-message chat.')),
      );
    });

    test('and one channel never sees the other\'s rules', () {
      final chat = draft.buildUserMessage(draftInput(chatMessage));
      final mail = draft.buildUserMessage(draftInput(emailMessage));

      expect(chat, isNot(contains('This is an email thread.')));
      expect(chat, isNot(contains('under 150 words')));
      expect(mail, isNot(contains('This is an instant-message chat.')));
      expect(mail, isNot(contains('under 50 words')));
    });
  });
}
