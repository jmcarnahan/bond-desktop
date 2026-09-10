import 'dart:io';

import 'package:bond_inbox/services/server/server_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('server_log');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('open makes the folder the log lives in', () async {
    final file = File(p.join(root.path, 'logs', 'llama-server.log'));
    final log = ServerLog(file);
    await log.open();
    log.write('hello');
    await log.close();

    expect(await file.readAsString(), 'hello\n');
  });

  test('a log past maxBytes is rotated to .1 on open', () async {
    final file = File(p.join(root.path, 'logs', 'llama-server.log'));
    await file.parent.create(recursive: true);
    await file.writeAsString('x' * 200);

    final log = ServerLog(file, maxBytes: 100);
    await log.open();
    log.write('fresh');
    await log.close();

    expect(await File('${file.path}.1').readAsString(), 'x' * 200);
    expect(await file.readAsString(), 'fresh\n');
  });

  test('only one generation is kept', () async {
    final file = File(p.join(root.path, 'logs', 'llama-server.log'));
    await file.parent.create(recursive: true);
    await File('${file.path}.1').writeAsString('the run before last');
    await file.writeAsString('y' * 200);

    final log = ServerLog(file, maxBytes: 100);
    await log.open();
    await log.close();

    // The previous run is worth having; anything older has been superseded.
    expect(await File('${file.path}.1').readAsString(), 'y' * 200);
    expect(await File('${file.path}.2').exists(), isFalse);
  });

  test('a log under maxBytes is appended to, not rotated', () async {
    final file = File(p.join(root.path, 'logs', 'llama-server.log'));
    await file.parent.create(recursive: true);
    await file.writeAsString('earlier\n');

    final log = ServerLog(file, maxBytes: 1000);
    await log.open();
    log.write('later');
    await log.close();

    expect(await file.readAsString(), 'earlier\nlater\n');
    expect(await File('${file.path}.1').exists(), isFalse);
  });

  test('the tail holds the last N lines of this session', () async {
    final log = ServerLog(
      File(p.join(root.path, 'logs', 'llama-server.log')),
      tailLines: 3,
    );
    await log.open();
    for (var i = 1; i <= 10; i++) {
      log.write('line $i');
    }

    expect(log.tail, ['line 8', 'line 9', 'line 10']);
    await log.close();
  });

  test('the tail is only this session, never what was on disk', () async {
    final file = File(p.join(root.path, 'logs', 'llama-server.log'));
    await file.parent.create(recursive: true);
    await file.writeAsString('a crash from yesterday\n');

    final log = ServerLog(file);
    await log.open();
    log.write('today');

    // A tail read back off disk would be from the wrong run, which is
    // exactly the line a failure state must not show.
    expect(log.tail, ['today']);
    await log.close();
  });
}
