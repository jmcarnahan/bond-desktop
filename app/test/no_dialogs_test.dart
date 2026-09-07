import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The house rule, pinned: full screens with a back button, never popups.
///
/// The settings dialog was the last one, and it is a screen now. A file test
/// rather than a widget test because the rule is about what the code MAY
/// contain, not about what any one screen renders.
void main() {
  test('no file under lib/ opens a dialog', () {
    // `flutter test` runs from the package root, so lib/ is right here. The
    // walk up is for the odd runner that starts elsewhere.
    var dir = Directory.current;
    while (!Directory('${dir.path}/lib').existsSync() &&
        dir.parent.path != dir.path) {
      dir = dir.parent;
    }
    final lib = Directory('${dir.path}/lib');
    expect(lib.existsSync(), isTrue, reason: 'could not locate lib/');

    final offenders = <String>[];
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      // showDatePicker is on the list for the same reason: the lookback's
      // custom date in Settings is an inline text field on purpose, and the
      // Material date picker is a dialog like any other.
      if (source.contains('showDialog(') ||
          source.contains('AlertDialog(') ||
          source.contains('showDatePicker(')) {
        offenders.add(entity.path);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'popups are not the house pattern — use a full pane with a '
          'back arrow, the way PaneSurface does',
    );
  });
}
