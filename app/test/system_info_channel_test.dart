import 'package:bond_inbox/services/system/system_info.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Dart half of the system channel, with a scripted Swift on the other
/// end.
///
/// Every method here is one the first-run wizard leans on — the hardware
/// readout, the free-space check, the jump to System Settings — and every one
/// of them is documented as never throwing. That is what this file pins: a
/// channel that is missing, a platform that raises, or a reply that is null
/// all have to come back as the "could not ask" answer the callers already
/// handle.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const info = ChannelSystemInfo();
  final calls = <MethodCall>[];

  void answer(Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ChannelSystemInfo.channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ChannelSystemInfo.channel, null);
  });

  test('a hardware map decodes field for field', () async {
    answer((_) => <String, Object?>{
          'chip': 'Apple M3 Max',
          'memoryBytes': 68719476736,
          'appleSilicon': true,
          'rosetta': false,
          'osVersion': '15.6',
        });

    final hardware = await info.hardware();

    expect(hardware.chip, 'Apple M3 Max');
    expect(hardware.memoryBytes, 68719476736);
    expect(hardware.appleSilicon, isTrue);
    expect(hardware.rosetta, isFalse);
    expect(hardware.osVersion, '15.6');
    expect(calls.single.method, 'hardware');
  });

  test('a null reply is the unknown machine, not a crash', () async {
    answer((_) => null);

    expect(await info.hardware(), HardwareInfo.unknown);
  });

  test('a platform that raises is the unknown machine too', () async {
    answer((_) => throw PlatformException(code: 'boom'));

    expect(await info.hardware(), HardwareInfo.unknown);
  });

  test('a partial map fills its own gaps', () async {
    // `appleSilicon` defaults true and `memoryBytes` zero for
    // `HardwareInfo.unknown`'s reason: nothing is refused for being on the
    // wrong architecture, and a size check against zero fails loudly rather
    // than passing silently.
    answer((_) => <String, Object?>{'chip': 'Apple M1'});

    final hardware = await info.hardware();

    expect(hardware.chip, 'Apple M1');
    expect(hardware.memoryBytes, 0);
    expect(hardware.appleSilicon, isTrue);
    expect(hardware.osVersion, '');
  });

  test('free space carries the path it is asked about', () async {
    answer((_) => 12345);

    expect(await info.freeBytes('/Volumes/Models'), 12345);
    expect(calls.single.arguments, {'path': '/Volumes/Models'});
  });

  test('free space that cannot be asked is null, never an exception',
      () async {
    answer((_) => throw PlatformException(code: 'nope'));

    expect(await info.freeBytes('/tmp'), isNull);
  });

  test('the settings jump reports whether it opened', () async {
    answer((_) => true);
    expect(await info.openNotificationSettings(), isTrue);

    answer((_) => false);
    expect(await info.openNotificationSettings(), isFalse);

    // A reply of nothing at all is a pane that did not open.
    answer((_) => null);
    expect(await info.openNotificationSettings(), isFalse);
  });

  test('with no handler at all every answer is the could-not-ask one',
      () async {
    // What a `flutter test` binary really gets: `MissingPluginException` from
    // every call, which must not turn a hardware readout into a crash.
    expect(await info.hardware(), HardwareInfo.unknown);
    expect(await info.freeBytes('/tmp'), isNull);
    expect(await info.sha256('/tmp/x'), isNull);
    expect(await info.beginActivity('testing'), isNull);
    expect(await info.openNotificationSettings(), isFalse);
    await info.endActivity(1);
  });
}
