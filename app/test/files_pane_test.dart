import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/models/files_models.dart';
import 'package:bond_inbox/widgets/attachment_card.dart';
import 'package:bond_inbox/widgets/attachment_search_tile.dart';
import 'package:bond_inbox/widgets/chips.dart';
import 'package:bond_inbox/widgets/files_pane.dart';
import 'package:bond_inbox/widgets/inline_alert.dart';
import 'package:bond_inbox/widgets/link_unfurl.dart';
import 'package:bond_inbox/widgets/message_row.dart' show DayDivider;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';

/// The Files stop's pane: one shelf, by day, with four ways to narrow it.
///
/// A pane with no providers in it, so everything here is pumped directly. What
/// is pinned is the grouping (a day is the first thing a reader remembers), the
/// two ways out of a row (the file beside, its thread beside) and the search
/// body, which shows documents and nothing else.

void main() {
  final now = DateTime.parse('2026-09-05T12:00:00Z');

  FileRow row(
    String id, {
    String? name,
    String kind = 'file',
    String? contentType = 'application/pdf',
    String? sourceUrl,
    String receivedAt = '2026-09-05T09:00:00.000Z',
    String? conversationKey = 'conv-1',
    String? subject = 'The lease',
    String? fromName = 'Dana Whitfield',
    bool outbound = false,
  }) =>
      FileRow(
        ref: ref(
          attachmentId: id,
          name: name ?? '$id.pdf',
          kind: kind,
          contentType: contentType,
          sourceUrl: sourceUrl,
          conversationKey: conversationKey,
        ),
        fromName: fromName,
        outbound: outbound,
        receivedAt: receivedAt,
        subject: subject,
      );

  Future<void> pumpPane(
    WidgetTester tester, {
    List<FileRow> rows = const [],
    bool loaded = true,
    bool loadingMore = false,
    bool atEnd = true,
    String? error,
    FilesKind kind = FilesKind.all,
    ValueChanged<FilesKind>? onKind,
    List<AttachmentChunkHit>? search,
    String? searchQuery,
    bool searching = false,
    String? searchNotice,
    void Function(FileRow)? onOpen,
    void Function(String, String)? onOpenThread,
    VoidCallback? onLoadMore,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: FilesPane(
            rows: rows,
            loaded: loaded,
            loadingMore: loadingMore,
            atEnd: atEnd,
            error: error,
            kind: kind,
            onKind: onKind ?? (_) {},
            searchController: controller,
            search: search,
            searchQuery: searchQuery,
            searching: searching,
            searchNotice: searchNotice,
            onSearch: (_) {},
            onExitSearch: () {},
            thumbnailFor: (_) => null,
            onOpen: onOpen ?? (_) {},
            onOpenThread: onOpenThread ?? (_, _) {},
            onLoadMore: onLoadMore ?? () {},
            now: now,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  group('the shelf', () {
    testWidgets('nothing read yet is a spinner, not an empty shelf',
        (tester) async {
      await pumpPane(tester, loaded: false);

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(FilesPane.emptyKey), findsNothing);
    });

    testWidgets('nothing to show says so', (tester) async {
      await pumpPane(tester);

      expect(find.byKey(FilesPane.emptyKey), findsOneWidget);
    });

    testWidgets('files are grouped by the day they arrived', (tester) async {
      await pumpPane(tester, rows: [
        row('a', receivedAt: '2026-09-05T09:00:00.000Z'),
        row('b', receivedAt: '2026-09-05T08:00:00.000Z'),
        row('c', receivedAt: '2026-09-03T08:00:00.000Z'),
      ]);

      expect(find.byType(DayDivider), findsNWidgets(2));
      expect(find.byType(AttachmentCard), findsNWidgets(3));
    });

    testWidgets('a row says who sent it and how long ago', (tester) async {
      await pumpPane(tester, rows: [
        row('a', receivedAt: '2026-09-05T09:00:00.000Z'),
      ]);

      expect(find.text('Dana Whitfield · 3h ago'), findsOneWidget);
    });

    testWidgets("the owner's own send is titled you", (tester) async {
      await pumpPane(tester, rows: [
        row('a', outbound: true, receivedAt: '2026-09-05T09:00:00.000Z'),
      ]);

      expect(find.text('you · 3h ago'), findsOneWidget);
    });

    testWidgets('a link is an unfurl rather than a card', (tester) async {
      final link = row(
        'l1',
        kind: 'reference',
        name: 'Budget.xlsx',
        contentType: null,
        sourceUrl: 'https://contoso.sharepoint.com/Budget.xlsx',
      );
      await pumpPane(tester, rows: [link]);

      expect(find.byType(LinkUnfurl), findsOneWidget);
      expect(find.byType(AttachmentCard), findsNothing);
      expect(find.text('🔗 SharePoint'), findsOneWidget);
    });
  });

  group('the four kinds', () {
    testWidgets('the pills say which shelf this is and change it',
        (tester) async {
      final picked = <FilesKind>[];
      await pumpPane(
        tester,
        kind: FilesKind.images,
        onKind: picked.add,
      );

      final pills = find.descendant(
        of: find.byKey(FilesPane.kindPillsKey),
        matching: find.byType(BondFilterPill),
      );
      expect(pills, findsNWidgets(4));

      await tester.tap(
        find.descendant(
          of: find.byKey(FilesPane.kindPillsKey),
          matching: find.text('Links'),
        ),
      );
      await tester.pump();

      expect(picked, [FilesKind.links]);
    });
  });

  group('the two ways out of a row', () {
    testWidgets('the card opens the file it stands for', (tester) async {
      final opened = <String>[];
      final file = row('a');
      await pumpPane(
        tester,
        rows: [file],
        onOpen: (r) => opened.add(r.ref.attachmentId),
      );

      expect(find.byKey(FilesPane.rowKeyFor(file)), findsOneWidget);
      await tester.tap(find.byType(AttachmentCard));
      await tester.pump();

      expect(opened, ['a']);
    });

    testWidgets('the caption opens the thread the file came with',
        (tester) async {
      final opened = <String>[];
      final file = row('a', conversationKey: 'conv-9', subject: 'The lease');
      await pumpPane(
        tester,
        rows: [file],
        onOpenThread: (source, key) => opened.add('$source/$key'),
      );

      await tester.tap(find.byKey(FilesPane.threadLinkKeyFor(file)));
      await tester.pump();

      expect(opened, ['email/conv-9']);
    });

    testWidgets('a file whose thread is unknown offers no way into one',
        (tester) async {
      final file = row('a', conversationKey: null);
      await pumpPane(tester, rows: [file]);

      expect(find.byKey(FilesPane.threadLinkKeyFor(file)), findsNothing);
    });
  });

  group('paging and failures', () {
    testWidgets('a shelf at its end offers no Load more', (tester) async {
      await pumpPane(tester, rows: [row('a')]);

      expect(find.byKey(FilesPane.loadMoreKey), findsNothing);
    });

    testWidgets('more to come is a button, and it fires once', (tester) async {
      var asked = 0;
      await pumpPane(
        tester,
        rows: [row('a')],
        atEnd: false,
        onLoadMore: () => asked++,
      );

      await tester.tap(find.byKey(FilesPane.loadMoreKey));
      await tester.pump();

      expect(asked, 1);
    });

    testWidgets('a page already on its way cannot be asked for twice',
        (tester) async {
      var asked = 0;
      await pumpPane(
        tester,
        rows: [row('a')],
        atEnd: false,
        loadingMore: true,
        onLoadMore: () => asked++,
      );

      expect(find.text('Loading…'), findsOneWidget);
      await tester.tap(find.byKey(FilesPane.loadMoreKey));
      await tester.pump();

      expect(asked, 0);
    });

    testWidgets('a failed read is a banner over the rows, never instead of them',
        (tester) async {
      await pumpPane(
        tester,
        rows: [row('a')],
        error: "Couldn't read your files just now.",
      );

      expect(find.byType(InlineAlert), findsOneWidget);
      expect(find.byType(AttachmentCard), findsOneWidget);
    });
  });

  group('asking the shelf a question', () {
    AttachmentChunkHit hit(String id) => AttachmentChunkHit(
          ref: ref(
            attachmentId: id,
            name: '$id.pdf',
            conversationKey: 'conv-1',
          ),
          chunkId: 1,
          seq: 0,
          locator: 'page 2',
          text: 'The tenant pays on the fourth.',
          senderName: 'Dana Whitfield',
          outbound: false,
          receivedAt: '2026-09-05T09:00:00.000Z',
          distance: 0.2,
        );

    testWidgets('results are documents, under the query that found them',
        (tester) async {
      await pumpPane(
        tester,
        rows: [row('a')],
        search: [hit('doc')],
        searchQuery: 'lease has:file',
      );

      expect(find.text('DOCUMENTS · "lease has:file"'), findsOneWidget);
      expect(find.byType(AttachmentSearchTile), findsOneWidget);
      // The live shelf is out of the way while an answer is up.
      expect(find.byType(DayDivider), findsNothing);
    });

    testWidgets('an answer of nothing is a sentence, not an empty pane',
        (tester) async {
      await pumpPane(tester, search: const [], searchQuery: 'lease');

      expect(find.text('No documents match.'), findsOneWidget);
    });

    testWidgets('a query in flight says so over whatever is showing',
        (tester) async {
      await pumpPane(tester, rows: [row('a')], searching: true);

      expect(find.text('Searching…'), findsOneWidget);
      expect(find.byType(AttachmentCard), findsOneWidget);
    });

    testWidgets('a notice sits over the shelf rather than replacing it',
        (tester) async {
      await pumpPane(
        tester,
        rows: [row('a')],
        searchNotice: 'Search is unavailable — the embedding server is off',
      );

      expect(find.byType(InlineAlert), findsOneWidget);
      expect(find.byType(AttachmentCard), findsOneWidget);
    });
  });
}
