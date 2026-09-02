import 'package:bond_inbox/models/message_models.dart';
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
/// which knows a chat has no subject and a directness line reads differently
/// for a group chat, and the per-input user message built from it. Nothing in
/// a system prompt may know which source it is looking at.
///
/// These tests exist so that a future fork FAILS rather than merely works.
void main() {
  const triage = TriageTask();
  const extract = ExtractTask();

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
  });

  group('no system prompt frames its subject as mail', () {
    /// The only phrases either prompt is allowed to spend the word "email" on.
    ///
    /// Both are deliberate and neither is channel framing: the first names both
    /// channels together, and the second is a note about output FORM — a name
    /// is wanted where an address would otherwise be given. Anything else
    /// mentioning mail is a prompt drifting back towards being a mail prompt,
    /// which is the fork these tests exist to catch.
    const allowed = [
      'email and chat messages together',
      'email addresses',
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

    test('neither prompt names a connector', () {
      // "teams" is not on this list on purpose: the extraction prompt asks for
      // "companies, schools, teams, or vendors", which is a kind of
      // organization rather than the product.
      for (final prompt in [triage.systemPrompt, extract.systemPrompt]) {
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
  });
}
