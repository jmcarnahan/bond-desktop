import 'package:bond_inbox/widgets/preview/unsupported_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Saying there is no preview, which is a better answer than an empty pane.
Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SizedBox(height: 400, child: child)));

void main() {
  testWidgets('it names the file and says why there is nothing',
      (tester) async {
    await tester.pumpWidget(_host(const UnsupportedPreview(
      glyph: '🗜',
      name: 'Bundle.zip',
      size: 2048,
    )));

    expect(find.text('🗜'), findsOneWidget);
    expect(find.text('Bundle.zip'), findsOneWidget);
    expect(find.text('2 KB'), findsOneWidget);
    expect(find.text('There is no preview for this kind of file.'),
        findsOneWidget);
  });

  testWidgets('a size nobody stated is not shown', (tester) async {
    await tester.pumpWidget(_host(const UnsupportedPreview(
      glyph: '📎',
      name: 'Mystery',
      size: 0,
    )));

    expect(find.text('0 B'), findsNothing);
  });

  testWidgets('the host can say why in its own words', (tester) async {
    await tester.pumpWidget(_host(const UnsupportedPreview(
      glyph: '🔗',
      reason: 'This is a link, not a file.',
    )));

    final reason = tester.widget<Text>(
      find.byKey(UnsupportedPreview.reasonKey),
    );
    expect(reason.data, 'This is a link, not a file.');
  });

  testWidgets('the way out renders only when there is one', (tester) async {
    await tester.pumpWidget(_host(const UnsupportedPreview(glyph: '🔗')));
    expect(find.byType(TextButton), findsNothing);

    await tester.pumpWidget(_host(UnsupportedPreview(
      glyph: '🔗',
      action: TextButton(onPressed: () {}, child: const Text('Open in Teams')),
    )));
    expect(find.text('Open in Teams'), findsOneWidget);
  });
}
