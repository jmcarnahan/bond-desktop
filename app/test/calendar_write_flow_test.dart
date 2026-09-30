import 'dart:async';

import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/calendar/calendar_writes.dart';
import 'package:bond_inbox/widgets/calendar_write_flow.dart';
import 'package:bond_inbox/widgets/write_confirm_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A writer whose previews and commits answer from queues, recording what
/// it was asked.
class _FakeWriter implements CalendarWriter {
  final List<PreviewResult> previews = [];
  final List<WriteOutcome> commits = [];
  final List<CalendarWrite> previewed = [];
  final List<({CalendarWrite write, WritePreview? preview, bool isUndo})>
      committed = [];

  /// When set, a commit answers only once the test completes it, so a
  /// second trigger lands while the first send is still in flight.
  Completer<WriteOutcome>? hold;

  @override
  Future<PreviewResult> preview(CalendarWrite write) async {
    previewed.add(write);
    return previews.removeAt(0);
  }

  @override
  Future<WriteOutcome> commit(
    CalendarWrite write, {
    WritePreview? preview,
    bool isUndo = false,
  }) async {
    committed.add((write: write, preview: preview, isUndo: isUndo));
    final held = hold;
    if (held != null) return held.future;
    return commits.removeAt(0);
  }
}

void main() {
  late _FakeWriter writer;
  late List<(String, CalendarWrite?)> done;

  setUp(() {
    writer = _FakeWriter();
    done = [];
  });

  const accept = RespondToEvent('e1', RsvpResponse.accept);
  const toDana = WritePreview(
      method: 'POST', path: '/me/events/e1/accept', notifies: ['dana@contoso.com']);
  const private = WritePreview(method: 'PATCH', path: '/me/events/e1');

  Future<void> pump(WidgetTester tester, {CalendarWrite write = accept}) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CalendarWriteFlow(
            writer: writer,
            onDone: (message, undo) => done.add((message, undo)),
            builder: (context, start, busy) => TextButton(
              key: const ValueKey('go'),
              onPressed: busy
                  ? null
                  : () => start(write,
                      summary: 'Accept "Design review"',
                      doneMessage: 'Accepted "Design review".'),
              child: Text(busy ? 'busy' : 'Go'),
            ),
          ),
        ),
      ));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
  }

  testWidgets('a write that emails waits on the strip, and Enter sends it',
      (tester) async {
    writer.previews.add(const PreviewReady(toDana, needsConfirm: true));
    writer.commits.add(const WriteOutcome.ok(eventId: 'e1'));
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('go')));
    await settle(tester);

    expect(find.byType(WriteConfirmStrip), findsOneWidget);
    expect(find.text('This emails: dana@contoso.com'), findsOneWidget);
    expect(find.text('busy'), findsOneWidget);
    expect(writer.committed, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);

    expect(writer.committed.single.write, accept);
    expect(writer.committed.single.preview, toDana);
    expect(done.single.$1, 'Accepted "Design review". Emailed dana@contoso.com.');
    expect(done.single.$2, isNull);
    expect(find.byType(WriteConfirmStrip), findsNothing);
    expect(find.text('Go'), findsOneWidget);
  });

  testWidgets('a private write commits at once and passes its undo on',
      (tester) async {
    const undo = DeleteEvent('made');
    writer.previews.add(const PreviewReady(private, needsConfirm: false));
    writer.commits.add(const WriteOutcome.ok(undo: undo, eventId: 'e1'));
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('go')));
    await settle(tester);

    expect(find.byType(WriteConfirmStrip), findsNothing);
    expect(writer.committed.single.preview, private);
    expect(done.single.$1, 'Accepted "Design review".');
    expect(done.single.$2, undo);
  });

  testWidgets('a failed preview says so, and Try again previews again',
      (tester) async {
    writer.previews
      ..add(const PreviewFailed("Couldn't reach the calendar. Nothing was "
          'changed.', retry: accept))
      ..add(const PreviewReady(toDana, needsConfirm: true));
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('go')));
    await settle(tester);

    expect(find.byKey(CalendarWriteFlow.errorKey), findsOneWidget);
    expect(find.text("Couldn't reach the calendar. Nothing was changed."),
        findsOneWidget);
    expect(find.text('Go'), findsOneWidget);

    await tester.tap(find.byKey(CalendarWriteFlow.retryKey));
    await settle(tester);
    expect(writer.previewed, [accept, accept]);
    expect(find.byKey(CalendarWriteFlow.errorKey), findsNothing);
    expect(find.byType(WriteConfirmStrip), findsOneWidget);
  });

  testWidgets('a failure with no retry offers none, and ✕ clears it',
      (tester) async {
    writer.previews.add(const PreviewFailed(
        'Only the organiser can change this meeting.'));
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('go')));
    await settle(tester);
    expect(find.byKey(CalendarWriteFlow.retryKey), findsNothing);

    await tester.tap(find.byKey(CalendarWriteFlow.dismissErrorKey));
    await settle(tester);
    expect(find.byKey(CalendarWriteFlow.errorKey), findsNothing);
  });

  testWidgets('a failed commit says its message under the buttons',
      (tester) async {
    writer.previews.add(const PreviewReady(toDana, needsConfirm: true));
    writer.commits.add(const WriteOutcome.failed(
        'This event changed in Outlook — check it and try again.'));
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('go')));
    await settle(tester);
    await tester.tap(find.byKey(WriteConfirmStrip.confirmKey));
    await settle(tester);

    expect(find.text('This event changed in Outlook — check it and try again.'),
        findsOneWidget);
    expect(find.byType(WriteConfirmStrip), findsNothing);
    expect(done, isEmpty);
  });

  testWidgets('a click and an Enter in the same frame send ONE write',
      (tester) async {
    writer.previews.add(const PreviewReady(toDana, needsConfirm: true));
    final hold = Completer<WriteOutcome>();
    writer.hold = hold;
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('go')));
    await settle(tester);
    expect(find.byType(WriteConfirmStrip), findsOneWidget);

    // Both before any pump: neither sees a rebuilt, disabled strip.
    await tester.tap(find.byKey(WriteConfirmStrip.confirmKey));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(writer.committed, hasLength(1));

    hold.complete(const WriteOutcome.ok(eventId: 'e1'));
    await settle(tester);
    expect(writer.committed, hasLength(1));
    expect(done, hasLength(1));
  });

  testWidgets("a write that went through rebuilds the buttons fresh, so "
      "their own state starts over", (tester) async {
    writer.previews.add(const PreviewReady(private, needsConfirm: false));
    writer.commits.add(const WriteOutcome.ok(eventId: 'e1'));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CalendarWriteFlow(
          writer: writer,
          onDone: (message, undo) => done.add((message, undo)),
          builder: (context, start, busy) => _Stateful(
            onGo: () => start(accept,
                summary: 'Accept "Design review"',
                doneMessage: 'Accepted "Design review".'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pump();
    expect(find.text('open'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('go')));
    await settle(tester);
    expect(done, hasLength(1));
    expect(find.text('open'), findsNothing);
    expect(find.text('closed'), findsOneWidget);
  });

  testWidgets('dismissing the strip sends nothing', (tester) async {
    writer.previews.add(const PreviewReady(toDana, needsConfirm: true));
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('go')));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    expect(find.byType(WriteConfirmStrip), findsNothing);
    expect(writer.committed, isEmpty);
    expect(find.text('Go'), findsOneWidget);
  });
}

/// Buttons with state of their own, the way EventActions keeps its open
/// field: a toggle, and the write.
class _Stateful extends StatefulWidget {
  const _Stateful({required this.onGo});

  final VoidCallback onGo;

  @override
  State<_Stateful> createState() => _StatefulState();
}

class _StatefulState extends State<_Stateful> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          TextButton(
            key: const ValueKey('open'),
            onPressed: () => setState(() => _open = true),
            child: Text(_open ? 'open' : 'closed'),
          ),
          TextButton(
            key: const ValueKey('go'),
            onPressed: widget.onGo,
            child: const Text('Go'),
          ),
        ],
      );
}
