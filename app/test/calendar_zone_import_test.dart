import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `flutter_timezone` is read in ONE place, pinned so it stays there.
///
/// The device zone is a plugin call that throws under `flutter test` and can
/// answer a name the `timezone` database does not know. `calendar_zone.dart`
/// is where both are handled — the failure is caught, and an unknown name
/// falls through to the mailbox's zone and then UTC — so a second import
/// elsewhere would be a second, unguarded reading of the device zone, and a
/// calendar that could show two different "todays".
///
/// A file test rather than a behaviour test because the rule is about what
/// the code MAY contain, the same reason `mcp_tool_names_test` is written
/// this way.
void main() {
  /// The package root: `flutter test` runs from it, so lib/ is right here. The
  /// walk up is for the odd runner that starts elsewhere.
  Directory libDir() {
    var dir = Directory.current;
    while (!Directory('${dir.path}/lib').existsSync() &&
        dir.parent.path != dir.path) {
      dir = dir.parent;
    }
    final lib = Directory('${dir.path}/lib');
    expect(lib.existsSync(), isTrue, reason: 'could not locate lib/');
    return lib;
  }

  test('only calendar_zone.dart imports flutter_timezone', () {
    final lib = libDir();

    // An import or export of the package, either quote style.
    final importsPlugin = RegExp(
        r"""^\s*(?:import|export)\s+['"]package:flutter_timezone/""",
        multiLine: true);

    final importers = <String>[];
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (importsPlugin.hasMatch(entity.readAsStringSync())) {
        importers.add(entity.path
            .substring(lib.parent.path.length + 1)
            .replaceAll(r'\', '/'));
      }
    }

    // A regex that stopped matching would otherwise pass by finding nothing,
    // so the one importer must be found.
    expect(
      importers,
      ['lib/services/calendar/calendar_zone.dart'],
      reason: 'the device zone is read through CalendarZone, never the '
          'plugin directly',
    );
  });
}
