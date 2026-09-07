import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/widgets/attachment_search_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';

/// What a passage of a document says when it answers a search, and where
/// tapping it goes.

final DateTime _now = DateTime.utc(2026, 9, 6, 12);

AttachmentChunkHit _hit({
  String? name = 'Q3 forecast.xlsx',
  String locator = 'Sheet Revenue rows 42–81',
  String text = 'Renewal at 4.25% fixed for sixty months.',
  String? senderName = 'Dana Whitfield',
  bool outbound = false,
  String? receivedAt = '2026-09-06T09:00:00Z',
  String? conversationKey = 'c1',
  String source = 'email',
}) {
  return AttachmentChunkHit(
    ref: ref(
      source: source,
      name: name,
      contentType: null,
      conversationKey: conversationKey,
    ),
    chunkId: 7,
    seq: 3,
    locator: locator,
    text: text,
    senderName: senderName,
    outbound: outbound,
    receivedAt: receivedAt,
    distance: 0.2,
  );
}

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Align(alignment: Alignment.topLeft, child: child),
      ),
    );

void main() {
  testWidgets('names the file and where in it the passage sits',
      (tester) async {
    await tester.pumpWidget(
      _host(AttachmentSearchTile(hit: _hit(), now: _now)),
    );

    expect(
      find.text('Q3 forecast.xlsx · Sheet Revenue rows 42–81'),
      findsOneWidget,
    );
    expect(find.text('📊'), findsOneWidget);
  });

  testWidgets('a passage with nowhere in particular names only the file',
      (tester) async {
    await tester.pumpWidget(
      _host(AttachmentSearchTile(hit: _hit(locator: ''), now: _now)),
    );

    expect(find.text('Q3 forecast.xlsx'), findsOneWidget);
  });

  testWidgets('a file nobody named still says it is a file', (tester) async {
    await tester.pumpWidget(_host(AttachmentSearchTile(
      hit: _hit(name: null, locator: ''),
      now: _now,
    )));

    expect(find.text('(unnamed)'), findsOneWidget);
  });

  testWidgets('the passage reads as one breath, however the document wrapped',
      (tester) async {
    await tester.pumpWidget(_host(AttachmentSearchTile(
      hit: _hit(text: '  Revenue\t\t4,200\n\nCost   1,100  '),
      now: _now,
    )));

    expect(find.text('Revenue 4,200 Cost 1,100'), findsOneWidget);
  });

  testWidgets('a long passage is cut where the tile stops reading',
      (tester) async {
    final long = List.filled(200, 'renewal').join(' ');
    await tester.pumpWidget(
      _host(AttachmentSearchTile(hit: _hit(text: long), now: _now)),
    );

    final snippet = tester.widget<Text>(find.textContaining('renewal renewal'));
    expect(snippet.data, endsWith('…'));
    expect(snippet.data!.length, AttachmentSearchTile.snippetCap + 1);
    expect(snippet.maxLines, 2);
  });

  testWidgets('says who attached it and when', (tester) async {
    await tester.pumpWidget(_host(AttachmentSearchTile(
      hit: _hit(receivedAt: '2026-09-06T09:00:00Z'),
      now: _now,
    )));

    expect(find.text('Dana Whitfield'), findsOneWidget);
    expect(find.text('3h ago'), findsOneWidget);
  });

  testWidgets("the owner's own document says 'you'", (tester) async {
    await tester.pumpWidget(_host(AttachmentSearchTile(
      hit: _hit(outbound: true, senderName: 'Jordan Meade'),
      now: _now,
    )));

    expect(find.text('you'), findsOneWidget);
    expect(find.text('Jordan Meade'), findsNothing);
  });

  testWidgets('a sender nobody recorded claims nobody', (tester) async {
    await tester.pumpWidget(_host(AttachmentSearchTile(
      hit: _hit(senderName: null, receivedAt: null),
      now: _now,
    )));

    expect(find.text('Dana Whitfield'), findsNothing);
    expect(find.textContaining('ago'), findsNothing);
  });

  testWidgets('tapping opens the thread the document sits on', (tester) async {
    final opened = <(String, String)>[];
    await tester.pumpWidget(_host(AttachmentSearchTile(
      hit: _hit(source: 'teams', conversationKey: 'chat-9'),
      now: _now,
      onOpenThread: (source, key) => opened.add((source, key)),
    )));

    await tester.tap(find.byType(AttachmentSearchTile));
    expect(opened, [('teams', 'chat-9')]);
  });

  testWidgets('a passage with no thread to open is a statement',
      (tester) async {
    await tester.pumpWidget(_host(AttachmentSearchTile(
      hit: _hit(conversationKey: null),
      now: _now,
      onOpenThread: (_, _) {},
    )));

    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('a host that offers nowhere to go draws no control',
      (tester) async {
    await tester.pumpWidget(
      _host(AttachmentSearchTile(hit: _hit(), now: _now)),
    );

    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets("the document's own words are never labelled as the model's",
      (tester) async {
    await tester.pumpWidget(_host(AttachmentSearchTile(
      hit: _hit(text: 'Renewal at 4.25% fixed.'),
      now: _now,
    )));

    expect(find.text('Renewal at 4.25% fixed.'), findsOneWidget);
    expect(find.textContaining('AI:'), findsNothing);
  });
}
