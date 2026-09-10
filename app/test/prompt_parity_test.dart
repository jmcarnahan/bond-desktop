import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/attachments/attachment_retriever.dart';
import 'package:bond_inbox/services/context/context_pack_render.dart';
import 'package:bond_inbox/services/context/context_retriever.dart';
import 'package:bond_inbox/services/llm/attachment_digest_task.dart';
import 'package:bond_inbox/services/llm/context_brief_task.dart';
import 'package:bond_inbox/services/llm/context_digest_task.dart';
import 'package:bond_inbox/services/llm/draft_task.dart';
import 'package:bond_inbox/services/llm/extract_task.dart';
import 'package:bond_inbox/services/llm/needs_you_task.dart';
import 'package:bond_inbox/services/llm/reply_decision_task.dart';
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
  const replyDecision = ReplyDecisionTask();
  const needsYou = NeedsYouTask();
  const attachmentDigest = AttachmentDigestTask();
  const contextDigest = ContextDigestTask();
  const contextBrief = ContextBriefTask();

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

  final contextDigestInput = ContextDigestInput(
    relPath: 'analysis/pricing.md',
    kind: 'doc',
    text: 'The renewal is 2,600 a month.',
    now: now,
  );

  final contextBriefInput = ContextBriefInput(
    displayName: 'atlas',
    claudeMd: '# Atlas\n\nReplies here stay short.\n',
    fileMap: 'analysis/pricing.md · What the renewal costs · How much?',
    now: now,
  );

  const excerpt = AttachmentExcerpt(
    name: 'Lease Addendum.pdf',
    locator: 'part 2',
    sender: 'Jordan Feld',
    date: '2026-08-28',
    text: 'The rent rises to 2,600 on 1 January.',
    ref: AttachmentRef(
      source: 'email',
      messageId: 'm1',
      attachmentId: 'a1',
    ),
  );

  DraftInput draftInput(Message message,
          {List<AttachmentExcerpt> excerpts = const [],
          ContextPack? directories}) =>
      DraftInput(
        thread: [message],
        replyTo: message,
        attachmentExcerpts: excerpts,
        directories: directories,
        now: now,
      );

  ReplyDecisionInput replyDecisionInput(Message message,
          {List<AttachmentExcerpt> excerpts = const [],
          ContextPack? directories}) =>
      ReplyDecisionInput(
        context: const [],
        message: message,
        attachmentExcerpts: excerpts,
        directories: directories,
        now: now,
      );

  const directoryPack = ContextPack(
    directories: ['acme'],
    briefs: [
      ContextBriefLine(
        dirName: 'acme',
        about: 'A renewal pricing model for the Marrowfield portfolio.',
        keyFacts: ['Q4 rates hold at nine.'],
        vocabulary: ['Marrowfield'],
      ),
    ],
    guidance: [
      ContextGuidance(label: 'guidance', text: 'Answer in two lines.'),
      ContextGuidance(label: 'SKILL vendor-replies', text: 'Name the rung.'),
    ],
    excerpts: [
      ContextExcerpt(
        dirName: 'acme',
        relPath: 'docs/pricing.md',
        locator: 'Pricing > Q4 rates',
        modified: '2026-08-30',
        text: 'Q4 rates hold at nine.',
        fileId: 1,
        dirId: 'd1',
      ),
    ],
    skills: ['vendor-replies'],
  );

  NeedsYouInput needsYouInput(Message message,
          {List<String> digests = const []}) =>
      NeedsYouInput(
        message: message,
        attachmentDigests: digests,
        now: now,
      );

  AttachmentDigestInput digestInput(Message message) => AttachmentDigestInput(
        message: message,
        name: 'Lease Addendum.pdf',
        contentType: 'application/pdf',
        size: 240 * 1024,
        text: 'The tenant pays 2,400 on the fourth of each month.',
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

      // And with documents retrieved into it, which is a whole block of text
      // the prompt did not used to carry — and which lives in the USER message
      // precisely so this stays true.
      draft.buildUserMessage(draftInput(emailMessage, excerpts: [excerpt]));
      expect(identical(draft.systemPrompt, before), isTrue);
    });

    test('the reply decision hands back the identical string across both', () {
      final before = replyDecision.systemPrompt;
      replyDecision.buildUserMessage(replyDecisionInput(emailMessage));
      final betweenTwo = replyDecision.systemPrompt;
      replyDecision.buildUserMessage(replyDecisionInput(chatMessage));
      final after = replyDecision.systemPrompt;

      expect(betweenTwo, before);
      expect(after, before);
      expect(identical(after, before), isTrue);

      replyDecision
          .buildUserMessage(replyDecisionInput(emailMessage, excerpts: [excerpt]));
      expect(identical(replyDecision.systemPrompt, before), isTrue);
    });

    test('needs-you hands back the identical string across both channels', () {
      final before = needsYou.systemPrompt;
      needsYou.buildUserMessage(needsYouInput(emailMessage));
      final betweenTwo = needsYou.systemPrompt;
      needsYou.buildUserMessage(needsYouInput(chatMessage));
      final after = needsYou.systemPrompt;

      expect(betweenTwo, before);
      expect(after, before);
      expect(identical(after, before), isTrue);

      needsYou.buildUserMessage(needsYouInput(
        emailMessage,
        digests: const ['Lease Addendum.pdf: The rent rises in January.'],
      ));
      expect(identical(needsYou.systemPrompt, before), isTrue);
    });

    test('the directory tasks hand back the identical string every time', () {
      // Neither of these has a channel to fork ON — they read the owner's own
      // files — so what this guards is the OTHER half of the rule: one KV
      // prefix serves every file in every registered directory, and a prompt
      // rebuilt per call would pay to re-read it on each one.
      final digestBefore = contextDigest.systemPrompt;
      contextDigest.buildUserMessage(contextDigestInput);
      expect(identical(contextDigest.systemPrompt, digestBefore), isTrue);

      final briefBefore = contextBrief.systemPrompt;
      contextBrief.buildUserMessage(contextBriefInput);
      expect(identical(contextBrief.systemPrompt, briefBefore), isTrue);
    });

    test('the attachment digest hands back the identical string across both',
        () {
      // The task with the least reason to know its channel and the most to
      // gain from not knowing: one KV prefix serves every document in the
      // mailbox, whichever connector carried it.
      final before = attachmentDigest.systemPrompt;
      attachmentDigest.buildUserMessage(digestInput(emailMessage));
      final betweenTwo = attachmentDigest.systemPrompt;
      attachmentDigest.buildUserMessage(digestInput(chatMessage));
      final after = attachmentDigest.systemPrompt;

      expect(betweenTwo, before);
      expect(after, before);
      expect(identical(after, before), isTrue);
    });
  });

  group('no system prompt frames its subject as mail', () {
    /// The only phrases any of these prompts may spend the word "email" on.
    ///
    /// All four are deliberate and none is channel framing: three of them name
    /// both channels together, and 'email addresses' is a note about output
    /// FORM — a name is wanted where an address would otherwise be given.
    /// Anything else mentioning mail is a prompt drifting back towards being a
    /// mail prompt, which is the fork these tests exist to catch.
    ///
    /// The last entry arrived when the reply decision came under this guard:
    /// its rules say the message "may be an email or a chat message", which
    /// names the two together in the same way the first and third do.
    const allowed = [
      'email and chat messages together',
      'email addresses',
      'an email or an instant chat message',
      'an email or a chat message',
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

    test('the reply-decision prompt names mail only alongside chat', () {
      expect(
        withoutAllowedPhrases(replyDecision.systemPrompt),
        isNot(contains('email')),
      );
    });

    test('the needs-you prompt does not name a channel at all', () {
      // The STRICT form, and the only prompt held to it: no stripping, because
      // there is nothing to strip. What varies by channel — how directly the
      // message came at the reader, who the owner is — is stated in the user
      // message, so the rules have no reason to know which connector this
      // arrived through.
      final prompt = needsYou.systemPrompt.toLowerCase();
      expect(prompt, isNot(contains('email')));
      expect(prompt, isNot(contains('mail')));
      expect(prompt, isNot(contains('chat')));
    });

    test('the attachment-digest prompt does not name a channel at all', () {
      // The STRICT form, like needs-you's. It reads a DOCUMENT, and how the
      // document arrived is exactly the thing the rules tell the model to say
      // nothing about.
      final prompt = attachmentDigest.systemPrompt.toLowerCase();
      expect(prompt, isNot(contains('email')));
      expect(prompt, isNot(contains('mail')));
      expect(prompt, isNot(contains('chat')));
    });

    test('the directory-digest prompt does not name a channel at all', () {
      // The STRICT form. It reads a FILE off the owner's own disk; how
      // anyone reaches the owner about that file is not a fact about it, and
      // a prompt that knew would be a prompt reasoning about tooling.
      final prompt = contextDigest.systemPrompt.toLowerCase();
      expect(prompt, isNot(contains('email')));
      expect(prompt, isNot(contains('mail')));
      expect(prompt, isNot(contains('chat')));
    });

    test('the directory-brief prompt does not name a channel at all', () {
      // The STRICT form too, and the one with the most temptation: the brief
      // is compiled FOR a reply. It still may not know what the reply will
      // be sent through.
      final prompt = contextBrief.systemPrompt.toLowerCase();
      expect(prompt, isNot(contains('email')));
      expect(prompt, isNot(contains('mail')));
      expect(prompt, isNot(contains('chat')));
    });

    test('no prompt names a connector', () {
      // "teams" is not on this list on purpose: the extraction prompt asks for
      // "companies, schools, teams, or vendors", which is a kind of
      // organization rather than the product.
      for (final prompt in [
        triage.systemPrompt,
        extract.systemPrompt,
        draft.systemPrompt,
        replyDecision.systemPrompt,
        needsYou.systemPrompt,
        attachmentDigest.systemPrompt,
        contextDigest.systemPrompt,
        contextBrief.systemPrompt,
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

    test('the reply decision fences both channels as inbound_message', () {
      for (final message in [emailMessage, chatMessage]) {
        expect(
          replyDecision.buildUserMessage(replyDecisionInput(message)),
          contains('<untrusted_data source="inbound_message">'),
          reason: message.source,
        );
      }
    });

    test('needs-you fences both channels as inbound_message', () {
      for (final message in [emailMessage, chatMessage]) {
        expect(
          needsYou.buildUserMessage(needsYouInput(message)),
          contains('<untrusted_data source="inbound_message">'),
          reason: message.source,
        );
      }
    });

    test('the digest fences the covering message and the document apart', () {
      for (final message in [emailMessage, chatMessage]) {
        final built = attachmentDigest.buildUserMessage(digestInput(message));
        // Two fences and not one, because they are two different things to the
        // model: the message is why the document was sent, and the document is
        // the only thing being read.
        expect(
          built,
          contains('<untrusted_data source="message">'),
          reason: message.source,
        );
        expect(
          built,
          contains('<untrusted_data source="document">'),
          reason: message.source,
        );
      }
    });
  });

  group('directories do not reach a system prompt', () {
    // The owner's own folders are a whole block of text the prompt did not
    // used to carry, and it lives in the USER message for the reason the
    // documents do: the 27B holds ONE KV prefix, and a system prompt that
    // moved when a room linked a project would be re-read on every draft that
    // crossed from a room with one to a room without.
    test('both system prompts are identical with and without a pack', () {
      final before = [draft.systemPrompt, replyDecision.systemPrompt];

      draft.buildUserMessage(draftInput(emailMessage));
      draft.buildUserMessage(
          draftInput(emailMessage, directories: directoryPack));
      replyDecision.buildUserMessage(replyDecisionInput(chatMessage));
      replyDecision.buildUserMessage(
          replyDecisionInput(chatMessage, directories: directoryPack));

      expect(identical(draft.systemPrompt, before[0]), isTrue);
      expect(identical(replyDecision.systemPrompt, before[1]), isTrue);
    });

    test('the fence labels name a directory and never a connector', () {
      // The same rule every prompt in this app keeps: nothing the model reads
      // may say which product the message arrived through, and a fence label
      // is the app's own word rather than the owner's.
      for (final built in [
        draft.buildUserMessage(
            draftInput(emailMessage, directories: directoryPack)),
        replyDecision.buildUserMessage(
            replyDecisionInput(emailMessage, directories: directoryPack)),
      ]) {
        expect(built, contains('<untrusted_data source="directory_brief">'));
        expect(built, contains('<untrusted_data source="directory_excerpts">'));
      }
      for (final label in const [
        'directory_brief',
        'directory_guidance',
        'directory_excerpts',
      ]) {
        expect(label, isNot(contains('email')));
        expect(label, isNot(contains('mail')));
        expect(label, isNot(contains('chat')));
      }
    });

    test('the rendered blocks name no channel either', () {
      // The fixture is chosen to reach every WORD the three renderers write
      // for themselves — the whole-file wording, the digest wording, the two
      // brief headings and a guidance label — because those are the only
      // strings in the output this test can actually fail on. A pack whose
      // own text simply happens to say nothing about mail would pass this
      // whichever way the renderers were worded, which is no test at all.
      const everyWording = ContextPack(
        directories: ['acme'],
        briefs: [
          ContextBriefLine(
            dirName: 'acme',
            about: 'A renewal pricing model for the Marrowfield portfolio.',
            keyFacts: ['Q4 rates hold at nine.'],
            vocabulary: ['Marrowfield'],
          ),
        ],
        guidance: [
          ContextGuidance(label: 'guidance', text: 'Answer in two lines.'),
        ],
        excerpts: [
          ContextExcerpt(
            dirName: 'acme',
            relPath: 'notes.md',
            // The whole-file wording.
            locator: '',
            modified: '2026-08-30',
            text: 'Q4 rates hold at nine.',
            fileId: 1,
            dirId: 'd1',
          ),
          ContextExcerpt(
            dirName: 'acme',
            relPath: 'analysis.html',
            // The digest wording, and the truncation note beside it.
            locator: 'digest',
            modified: '2026-08-31',
            text: 'What the rung schedule concluded.',
            fileId: 2,
            dirId: 'd1',
            truncated: true,
          ),
        ],
        skills: ['vendor-replies'],
      );

      final brief = renderContextBrief(everyWording, 700);
      final guidance = renderContextGuidance(everyWording, 1500);
      final excerpts = renderContextExcerpts(everyWording, 2500);

      // Every wording is actually in the output being checked.
      expect(brief, contains('Facts:'));
      expect(brief, contains('Terms:'));
      expect(guidance, contains('[guidance]'));
      expect(excerpts, contains('whole file'));
      expect(excerpts, contains("digest (a model's summary of this file)"));
      expect(excerpts, contains('(truncated)'));

      final rendered = [brief, guidance, excerpts].join('\n').toLowerCase();
      for (final channel in const [
        'email',
        'mail',
        'chat',
        'microsoft',
        'outlook',
        'gmail',
        'graph',
        'teams',
      ]) {
        expect(rendered, isNot(contains(channel)), reason: channel);
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

  group('attachments do not reach a system prompt', () {
    // A Teams body records where a shared file sat as `[[att:<id>]]`. Every
    // user message strips those (attachment_markers_test is the exhaustive
    // pass); the point HERE is that adding an attachment to a message cannot
    // move a system prompt, because that is the byte the prefix cache is
    // keyed on.
    final withAttachment = Message(
      id: 'c2',
      source: 'teams',
      outbound: false,
      fromName: 'Dana Kessler',
      fromAddress: 'teams:8f2c-…',
      bodyText: 'Signed copy [[att:file-1]].',
      receivedAt: '2026-08-29T16:05:00Z',
      attachments: const [
        AttachmentRef(
          source: 'teams',
          messageId: 'c2',
          attachmentId: 'file-1',
          name: 'lease-addendum.pdf',
        ),
      ],
    );

    test('the triage system prompt is identical with and without them', () {
      final before = triage.systemPrompt;
      triage.buildUserMessage(TriageInput(
        withAttachment,
        now,
        attachments: const [
          {'attachment_id': 'file-1', 'name': 'lease-addendum.pdf',
            'size': 184320, 'is_inline': 0},
        ],
      ));

      expect(identical(triage.systemPrompt, before), isTrue);
    });

    test('and so is every other one', () {
      final before = [
        extract.systemPrompt,
        draft.systemPrompt,
        replyDecision.systemPrompt,
        needsYou.systemPrompt,
        attachmentDigest.systemPrompt,
      ];

      extract.buildUserMessage(ExtractionInput(withAttachment, now));
      draft.buildUserMessage(draftInput(withAttachment));
      replyDecision.buildUserMessage(replyDecisionInput(withAttachment));
      needsYou.buildUserMessage(needsYouInput(withAttachment));
      attachmentDigest.buildUserMessage(digestInput(withAttachment));

      expect(identical(extract.systemPrompt, before[0]), isTrue);
      expect(identical(draft.systemPrompt, before[1]), isTrue);
      expect(identical(replyDecision.systemPrompt, before[2]), isTrue);
      expect(identical(needsYou.systemPrompt, before[3]), isTrue);
      expect(identical(attachmentDigest.systemPrompt, before[4]), isTrue);
    });

    test('a marker in the covering message never reaches the digest prompt',
        () {
      // The digest renders its message through `buildMessageBlock`, which is
      // the one place a marker is stripped for every prompt in the app.
      final built = attachmentDigest.buildUserMessage(
        digestInput(withAttachment),
      );

      expect(built, isNot(contains('[[att:')));
      expect(built, contains('Signed copy'));
    });

    test('no system prompt names an attachment marker', () {
      for (final prompt in [
        triage.systemPrompt,
        extract.systemPrompt,
        draft.systemPrompt,
        replyDecision.systemPrompt,
        needsYou.systemPrompt,
        attachmentDigest.systemPrompt,
      ]) {
        expect(prompt, isNot(contains('[[att:')));
        expect(prompt, isNot(contains('[[img:')));
      }
    });
  });
}
