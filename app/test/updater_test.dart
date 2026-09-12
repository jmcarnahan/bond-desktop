import 'package:bond_inbox/services/system/updater.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Dart half of the updater channel, with a scripted Sparkle on the other
/// end.
///
/// What this file pins is the degradation. A build that cannot update itself is
/// the ORDINARY case here — every `flutter run` build and every test binary is
/// one, because the four `SU*` keys Sparkle needs are written into Info.plist
/// by `dist/bundle.sh` and by nothing else — so a missing channel, a platform
/// that raises and a reply of nothing all have to come back as
/// `UpdaterStatus.unavailable` with a sentence a settings pane can render,
/// never as an exception on the way into Settings.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const updater = ChannelUpdater();
  final calls = <MethodCall>[];

  void answer(Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ChannelUpdater.channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ChannelUpdater.channel, null);
  });

  test('a configured updater decodes field for field', () async {
    answer((_) => <String, Object?>{
          'available': true,
          'automatic': true,
          // Seconds since the epoch, as an NSDate's
          // timeIntervalSince1970 arrives.
          'lastCheck': 1757592000.0,
        });

    final status = await updater.status();

    expect(status.available, isTrue);
    expect(status.automatic, isTrue);
    expect(
      status.lastCheck,
      DateTime.fromMillisecondsSinceEpoch(1757592000000, isUtc: true),
    );
    expect(status.unavailableReason, isNull);
    expect(calls.single.method, 'status');
  });

  test('an integer timestamp decodes the same as a double', () async {
    // The platform channel codec sends a whole-numbered Double as an int, so
    // both spellings reach Dart and both have to mean the same instant.
    answer((_) => <String, Object?>{
          'available': true,
          'automatic': false,
          'lastCheck': 1757592000,
        });

    final status = await updater.status();

    expect(
      status.lastCheck,
      DateTime.fromMillisecondsSinceEpoch(1757592000000, isUtc: true),
    );
  });

  test('a missing lastCheck is never-checked, not an error', () async {
    answer((_) => <String, Object?>{'available': true, 'automatic': false});

    final status = await updater.status();

    expect(status.available, isTrue);
    expect(status.lastCheck, isNull);
    expect(status.unavailableReason, isNull);
  });

  test('an unavailable updater carries the reason it gave', () async {
    answer((_) => <String, Object?>{
          'available': false,
          'automatic': false,
          'error': 'The feed URL is missing.',
        });

    final status = await updater.status();

    expect(status.available, isFalse);
    expect(status.unavailableReason, 'The feed URL is missing.');
  });

  test('unavailable with no reason still gets a sentence', () async {
    // The section renders one sentence or none, and none would leave a reader
    // with a missing button and no explanation for it.
    answer((_) => <String, Object?>{'available': false, 'automatic': false});

    final status = await updater.status();

    expect(status, UpdaterStatus.unavailable);
    expect(
      status.unavailableReason,
      'Updates are not configured in this build.',
    );
  });

  test('a platform that raises is the unavailable answer, not a crash',
      () async {
    answer((_) => throw PlatformException(code: 'boom'));

    expect(await updater.status(), UpdaterStatus.unavailable);
  });

  test('a null reply is the unavailable answer too', () async {
    answer((_) => null);

    expect(await updater.status(), UpdaterStatus.unavailable);
  });

  test('a check is one call and nothing else', () async {
    answer((_) => null);

    await updater.checkForUpdates();

    expect(calls.single.method, 'checkForUpdates');
  });

  test('the automatic switch sends the bool it was given', () async {
    answer((_) => null);

    await updater.setAutomaticChecks(true);
    await updater.setAutomaticChecks(false);

    expect(calls.map((c) => c.method), ['setAutomaticChecks', 'setAutomaticChecks']);
    expect(calls.map((c) => c.arguments), [true, false]);
  });

  test('a command a raising platform refuses is swallowed', () async {
    // Both commands are fire-and-forget from a settings pane: there is nothing
    // useful for it to do with a throw, and Sparkle's own window is what the
    // user is looking at by then anyway.
    answer((_) => throw PlatformException(code: 'unavailable'));

    await updater.checkForUpdates();
    await updater.setAutomaticChecks(true);
  });

  test('with no handler at all every answer is the could-not-ask one',
      () async {
    // What a `flutter test` binary really gets: `MissingPluginException` from
    // every call.
    expect(await updater.status(), UpdaterStatus.unavailable);
    await updater.checkForUpdates();
    await updater.setAutomaticChecks(true);
  });

  test('the null updater answers unavailable and does nothing', () async {
    const nothing = NullUpdater();

    expect(await nothing.status(), UpdaterStatus.unavailable);
    await nothing.checkForUpdates();
    await nothing.setAutomaticChecks(true);
    expect(calls, isEmpty);
  });
}
