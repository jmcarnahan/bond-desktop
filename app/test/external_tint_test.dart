import 'dart:math' as math;

import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/conversation_row.dart';
import 'package:bond_inbox/widgets/find_filter.dart';
import 'package:bond_inbox/widgets/label_chip.dart';
import 'package:bond_inbox/widgets/preview/attachment_preview_panel.dart';
import 'package:bond_inbox/widgets/preview/html_preview.dart';
import 'package:bond_inbox/widgets/preview/preview_engines.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';
import 'fixtures/fake_attachment_bytes.dart';
import 'fixtures/fake_pdf_renderer.dart';

/// Where a thread came from, on the four surfaces that say it: the row's stripe
/// and chip, the thread header's chip, the attachment preview's chip and
/// caution, and the `is:external` facet.
///
/// The rule under all four is ONE rule — the latest inbound sender's domain
/// against the owner's, computed at display time — and the tests that matter
/// most here are the ones that pin what is NOT external: a colleague's reply on
/// a thread a vendor is copied in on, a Teams sender with no domain at all, and
/// every thread at all while the app cannot say who the owner is.
///
/// Fictional domains throughout, and the owner's is a subdomain on purpose:
/// `eu.northwind.example.com` under `northwind.example.com` has to read as
/// home.

/// The owner's account domain, as `ownerDomainsOf` would hand it over.
const Set<String> _owned = {'northwind.example.com'};

const String _colleague = 'sam@northwind.example.com';
const String _branchOffice = 'jo@eu.northwind.example.com';
const String _vendor = 'sales@vendor.example.net';

Conversation _conv({
  String id = 'c1',
  String? latestInboundFrom,
  String? who = 'Sam Whitfield',
  String? subject = 'Launch date',
}) =>
    Conversation(
      id: id,
      subject: subject,
      participants: who == null ? const [] : [Participant(name: who)],
      state: ConversationState.needsReply,
      lastMessagePreview: 'Are we still on for Friday?',
      lastMessageAt: DateTime.now().toUtc().toIso8601String(),
      latestInboundFrom: latestInboundFrom,
    );

Message _msg({
  required String id,
  required String fromAddress,
  bool outbound = false,
  required Duration ago,
  List<AttachmentRef> attachments = const [],
}) =>
    Message(
      id: id,
      outbound: outbound,
      fromName: outbound ? null : 'Somebody',
      fromAddress: fromAddress,
      receivedAt: DateTime.now().toUtc().subtract(ago).toIso8601String(),
      bodyText: 'Body of $id.',
      triageStatus: 'done',
      attachments: attachments,
    );

/// WCAG 2.1 contrast, off the framework's own relative luminance so the
/// numbers below are the numbers a checker would give.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Row(children: [SizedBox(width: 460, child: child)]),
      ),
    );

/// A web page, the shape `attachment_preview_panel_test` gives one.
AttachmentRef _page() => ref(
      name: 'meeting-invite.html',
      contentType: 'text/html',
      size: 12 * 1024,
    );

void main() {
  group('the tone', () {
    test('the chip carries its own text contrast, light and dark', () {
      final external = bondToneColors[BondTone.external]!;

      // 4.5:1 is the AA bar for body text, and the chip's label is small text
      // on its own fill — so the pair has to clear it without help from
      // whatever is underneath the pill.
      expect(
        _contrast(external.foreground, external.background),
        greaterThanOrEqualTo(4.5),
      );

      // The pill is a light tint that has to be VISIBLE on both grounds this
      // app draws: the white card in the main pane and the burgundy rail.
      expect(
        _contrast(external.background, BondColors.surface),
        greaterThan(1.0),
      );
      expect(
        _contrast(external.background, BondColors.rail),
        greaterThanOrEqualTo(3.0),
      );
      // And its edge is what gives it a shape on white, where the fill alone
      // nearly matches the card.
      expect(
        _contrast(external.border, external.background),
        greaterThan(1.3),
      );
    });

    test('the stripe clears 3:1 on both grounds, carrying no text', () {
      // The one external mark with nothing written on it, so the non-text
      // bar (WCAG 1.4.11) is the one it has to clear — on the card it sits on
      // and on the rail, in case a dark surface ever draws a row.
      expect(
        _contrast(BondColors.external, BondColors.surface),
        greaterThanOrEqualTo(3.0),
      );
      expect(
        _contrast(BondColors.external, BondColors.rail),
        greaterThanOrEqualTo(3.0),
      );
    });

    test('no label can wear it', () {
      // The External chip means "from outside the owner's domains", and a
      // label the owner painted the same colour would make it mean two
      // things. The picker offers only [labelTones], and even a stored
      // 'external' word — a later build, a hand-edited row — falls back to
      // Stone rather than dressing a label as the chip.
      expect(labelTones, isNot(contains(BondTone.external)));
      expect(labelToneOf('external'), BondTone.neutral);
    });

    test('it is a colour of its own, not a second copy of another tone', () {
      // Copper already means "this wants you". An external tint that read as
      // attention would make the two marks argue on the same row.
      for (final tone in BondTone.values) {
        if (tone == BondTone.external) continue;
        expect(
          bondToneColors[tone]!.background,
          isNot(bondToneColors[BondTone.external]!.background),
          reason: tone.name,
        );
      }
    });
  });

  group('a row', () {
    testWidgets('a stranger gets the stripe and the chip', (tester) async {
      await tester.pumpWidget(_host(ConversationRow(
        conversation: _conv(latestInboundFrom: _vendor),
        selected: false,
        onTap: () {},
        ownerDomains: _owned,
      )));

      expect(find.byKey(ConversationRow.externalStripeKey), findsOneWidget);
      expect(find.text('External'), findsOneWidget);
      final stripe = tester.widget<ColoredBox>(
        find.byKey(ConversationRow.externalStripeKey),
      );
      expect(stripe.color, BondColors.external);
    });

    testWidgets('a colleague gets neither, and so does a branch office',
        (tester) async {
      for (final address in const [_colleague, _branchOffice]) {
        await tester.pumpWidget(_host(ConversationRow(
          conversation: _conv(latestInboundFrom: address),
          selected: false,
          onTap: () {},
          ownerDomains: _owned,
        )));

        expect(
          find.byKey(ConversationRow.externalStripeKey),
          findsNothing,
          reason: address,
        );
        expect(find.text('External'), findsNothing, reason: address);
      }
    });

    testWidgets('a chat sender has no domain and is never a stranger',
        (tester) async {
      // Every Teams sender is `teams:<id>`. A colleague's chat is the most
      // internal message this app carries.
      await tester.pumpWidget(_host(ConversationRow(
        conversation: _conv(latestInboundFrom: 'teams:19:abc123'),
        selected: false,
        onTap: () {},
        ownerDomains: _owned,
      )));

      expect(find.byKey(ConversationRow.externalStripeKey), findsNothing);
      expect(find.text('External'), findsNothing);
    });

    testWidgets('with no owner domains nothing is external', (tester) async {
      // A signed-out app, and every host that has not resolved the account
      // yet: the row it drew before any of this existed.
      await tester.pumpWidget(_host(ConversationRow(
        conversation: _conv(latestInboundFrom: _vendor),
        selected: false,
        onTap: () {},
      )));

      expect(find.byKey(ConversationRow.externalStripeKey), findsNothing);
      expect(find.text('External'), findsNothing);
    });

    testWidgets('a thread nobody has written into stays plain', (tester) async {
      // Null is the answer from every read that does not run the subquery, and
      // it must read as "cannot tell" rather than as a stranger.
      await tester.pumpWidget(_host(ConversationRow(
        conversation: _conv(),
        selected: false,
        onTap: () {},
        ownerDomains: _owned,
      )));

      expect(find.byKey(ConversationRow.externalStripeKey), findsNothing);
      expect(find.text('External'), findsNothing);
    });
  });

  group('the thread header', () {
    Future<void> pump(
      WidgetTester tester, {
      required List<Message> messages,
      Set<String> ownerDomains = _owned,
      // What the row's stored subselect answered, and so what the header
      // reads FIRST — the transcript is only the fallback for a row loaded
      // before the column existed.
      String? storedFrom = _vendor,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ThreadDetailPanel(
            conversation: _conv(latestInboundFrom: storedFrom),
            messages: messages,
            onMarkDone: () {},
            ownerDomains: ownerDomains,
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('the chip stands where the tenant banner used to', (tester) async {
      await pump(tester, messages: [
        _msg(id: 'm1', fromAddress: _vendor, ago: const Duration(hours: 3)),
      ]);

      expect(find.byKey(ThreadDetailPanel.externalChipKey), findsOneWidget);
      expect(find.text('External'), findsOneWidget);
      // Beside the state chip rather than instead of it: where a thread came
      // from and how it is doing are two facts.
      expect(find.text('Needs reply'), findsOneWidget);
    });

    testWidgets('a colleague answering a vendor un-tints the thread',
        (tester) async {
      // The whole reason the rule is the LATEST INBOUND sender. The vendor is
      // still on the thread and the conversation row still carries their
      // address; once somebody inside answers, the thread the reader is looking
      // at is an internal one — and the stored subselect is what serves that
      // answer to every surface.
      await pump(
        tester,
        storedFrom: _colleague,
        messages: [
          _msg(id: 'm1', fromAddress: _vendor, ago: const Duration(hours: 5)),
          _msg(id: 'm2', fromAddress: _colleague, ago: const Duration(hours: 2)),
        ],
      );

      expect(find.byKey(ThreadDetailPanel.externalChipKey), findsNothing);
    });

    testWidgets('the stored answer wins over the transcript', (tester) async {
      // The subselect reads through the kept filter and the transcript does
      // not: a gated `noreply@` can be the transcript's newest inbound while
      // the row, `is:external` and the preview all say internal. The header
      // agrees with THEM — one rule, four surfaces — rather than tinting off
      // a message the pipeline filed away.
      await pump(
        tester,
        storedFrom: _colleague,
        messages: [
          _msg(id: 'm1', fromAddress: _colleague, ago: const Duration(hours: 5)),
          _msg(id: 'm2', fromAddress: _vendor, ago: const Duration(hours: 1)),
        ],
      );

      expect(find.byKey(ThreadDetailPanel.externalChipKey), findsNothing);
    });

    testWidgets('a row without the stored answer falls back to the transcript',
        (tester) async {
      // A conversation loaded before the column existed carries null, and the
      // transcript's newest inbound is still a better answer than none.
      await pump(
        tester,
        storedFrom: null,
        messages: [
          _msg(id: 'm1', fromAddress: _colleague, ago: const Duration(hours: 5)),
          _msg(id: 'm2', fromAddress: _vendor, ago: const Duration(hours: 2)),
        ],
      );

      expect(find.byKey(ThreadDetailPanel.externalChipKey), findsOneWidget);
    });

    testWidgets('the owner\'s own reply is not the sender the rule means',
        (tester) async {
      // Outbound messages are skipped on the fallback path exactly as the
      // subselect skips them: the newest INBOUND message is the person the
      // thread is waiting on, and answering a stranger does not make them a
      // colleague.
      await pump(
        tester,
        storedFrom: null,
        messages: [
          _msg(id: 'm1', fromAddress: _vendor, ago: const Duration(hours: 5)),
          _msg(
            id: 'm2',
            fromAddress: _colleague,
            outbound: true,
            ago: const Duration(hours: 1),
          ),
        ],
      );

      expect(find.byKey(ThreadDetailPanel.externalChipKey), findsOneWidget);
    });

    testWidgets('no owner domains, no chip', (tester) async {
      await pump(
        tester,
        messages: [
          _msg(id: 'm1', fromAddress: _vendor, ago: const Duration(hours: 3)),
        ],
        ownerDomains: const {},
      );

      expect(find.byKey(ThreadDetailPanel.externalChipKey), findsNothing);
    });
  });

  group('the attachment preview', () {
    Future<void> pump(
      WidgetTester tester, {
      required bool external,
    }) async {
      final attachment = _page();
      final bytes = FakeAttachmentBytes();
      bytes.textByKey[FakeAttachmentBytes.keyOf(attachment)] =
          'Confirm your interest by Friday.';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 700,
            child: AttachmentPreviewPanel(
              attachment: attachment,
              bytes: bytes,
              engines: PreviewEngines(
                pdf: FakePdfRenderer(),
                workbook: (_) async => throw UnimplementedError(),
              ),
              onClose: () {},
              onOpenInBrowser: (_) {},
              senderIsExternal: external,
            ),
          ),
        ),
      ));
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
    }

    testWidgets('a stranger\'s page says so in the header and on the card',
        (tester) async {
      await pump(tester, external: true);

      expect(find.byKey(AttachmentPreviewPanel.externalChipKey), findsOneWidget);
      expect(find.text(HtmlPreview.cautionExternal), findsOneWidget);
      expect(find.text(HtmlPreview.caution), findsNothing);
    });

    testWidgets('a colleague\'s page keeps the ordinary sentence',
        (tester) async {
      await pump(tester, external: false);

      expect(find.byKey(AttachmentPreviewPanel.externalChipKey), findsNothing);
      expect(find.text(HtmlPreview.caution), findsOneWidget);
      expect(find.text(HtmlPreview.cautionExternal), findsNothing);
    });
  });

  group('is:external', () {
    test('it is a facet now, and it narrows to the strangers', () {
      final vendor = _conv(id: 'a', latestInboundFrom: _vendor);
      final inside = _conv(id: 'b', latestInboundFrom: _colleague);

      expect(FindQuery.parse('is:external').externalOnly, isTrue);
      expect(FindQuery.parse('is:external').hasThreadFacets, isTrue);
      expect(
        conversationMatches(vendor, 'is:external', ownerDomains: _owned),
        isTrue,
      );
      expect(
        conversationMatches(inside, 'is:external', ownerDomains: _owned),
        isFalse,
      );
    });

    test('it combines with the other facets AND-wise, like every one of them',
        () {
      final query = FindQuery.parse('is:external launch');
      expect(query.externalOnly, isTrue);
      expect(query.text, 'launch');

      final vendor = _conv(id: 'a', latestInboundFrom: _vendor);
      expect(
        conversationMatchesQuery(vendor, query, ownerDomains: _owned),
        isTrue,
      );
      expect(
        conversationMatchesQuery(
          _conv(id: 'b', latestInboundFrom: _vendor, subject: 'Invoice'),
          query,
          ownerDomains: _owned,
        ),
        isFalse,
      );
    });

    test('a caller that knows no owner domains narrows to nothing', () {
      // Not "everything": the facet asks for the threads the app can say are
      // external, and an app that cannot name the owner can say that about
      // none of them. The same answer `Conversation.isExternalTo` gives.
      expect(
        conversationMatches(
          _conv(id: 'a', latestInboundFrom: _vendor),
          'is:external',
        ),
        isFalse,
      );
    });

    test('there is no -is:external, so it stays the words somebody typed', () {
      // `-label:` is this grammar's only negation. An unrecognised facet is
      // text, verbatim — the rule the whole parser rests on.
      final query = FindQuery.parse('-is:external');

      expect(query.externalOnly, isFalse);
      expect(query.hasThreadFacets, isFalse);
      expect(query.text, '-is:external');
    });
  });
}
