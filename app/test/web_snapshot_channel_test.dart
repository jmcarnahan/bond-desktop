import 'dart:typed_data';

import 'package:bond_inbox/services/attachments/html_snapshot.dart';
import 'package:flutter/services.dart' show MethodCall, PlatformException;
import 'package:flutter_test/flutter_test.dart';

/// The Dart side of the web-snapshot channel: what it sends, and the fact that
/// every way it can fail is a null rather than a throw.
///
/// The Swift behind it cannot be exercised from here — there is no Runner under
/// `flutter test` — which is exactly the first case below: the ordinary answer
/// on a host with no channel registered is "no thumbnail", and the preview draws
/// its glyph card.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Answers `snapshot` with [reply], or throws [failure], recording the calls.
  List<MethodCall> mock({Object? reply, PlatformException? failure}) {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(htmlSnapshotChannel, (call) async {
      calls.add(call);
      if (failure != null) throw failure;
      return reply;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(htmlSnapshotChannel, null),
    );
    return calls;
  }

  const page = '<html><body><h1>Access review</h1></body></html>';

  test('no channel behind it is no thumbnail, not a throw', () async {
    // Nothing mocked: the messenger answers nothing, which `invokeMethod`
    // raises as a MissingPluginException.
    expect(await htmlSnapshotPng(page), isNull);
  });

  test('a page it drew comes back as bytes', () async {
    final calls = mock(reply: Uint8List.fromList([137, 80, 78, 71]));

    expect(await htmlSnapshotPng(page), [137, 80, 78, 71]);
    expect(calls.single.method, 'snapshot');
  });

  test('it sends the page, the viewport and the scale', () async {
    final calls = mock(reply: Uint8List.fromList([1]));

    await htmlSnapshotPng(page, width: 300, height: 180, scale: 2);

    final args = calls.single.arguments as Map;
    expect(args['html'], page);
    expect(args['width'], 300);
    expect(args['height'], 180);
    expect(args['scale'], 2);
  });

  test('an empty page is never sent at all', () async {
    final calls = mock(reply: Uint8List.fromList([1]));

    expect(await htmlSnapshotPng('   \n  '), isNull);
    expect(calls, isEmpty);
  });

  test('a refusal from the Runner is a null', () async {
    // Every code the Swift can send — a timeout, a page it would not render, a
    // second call while one was in flight — reads the same way here.
    for (final code in ['no_snapshot', 'busy', 'too_large', 'bad_args']) {
      mock(failure: PlatformException(code: code));
      expect(await htmlSnapshotPng(page), isNull, reason: code);
    }
  });

  test('a snapshot that answered nothing is a null', () async {
    mock(reply: null);

    expect(await htmlSnapshotPng(page), isNull);
  });
}
