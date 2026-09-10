import 'package:bond_inbox/services/server/llama_binary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LlamaBinary.resolve', () {
    // The compile-time define is empty under `flutter test`, which is what
    // lets the other three rungs be reached at all. Pinned so a `--dart-define`
    // sneaking into the test command explains the failures below.
    test('the compile-time define is unset in tests', () {
      expect(LlamaBinary.define, isEmpty);
    });

    test('the environment variable wins over the sidecar', () {
      final resolved = LlamaBinary.resolve(
        environment: {'BOND_LLAMA_SERVER': '/opt/homebrew/bin/llama-server'},
        resolvedExecutable: '/Apps/Bond Desktop.app/Contents/MacOS/Bond Desktop',
        exists: (_) => true,
      );
      expect(resolved, '/opt/homebrew/bin/llama-server');
    });

    test('an empty environment variable is not a path', () {
      final resolved = LlamaBinary.resolve(
        environment: {'BOND_LLAMA_SERVER': ''},
        resolvedExecutable: '/Apps/Bond Desktop.app/Contents/MacOS/Bond Desktop',
        exists: (_) => true,
      );
      expect(
        resolved,
        '/Apps/Bond Desktop.app/Contents/MacOS/llama-server',
      );
    });

    test('the sidecar beside the executable is the shipped answer', () {
      final asked = <String>[];
      final resolved = LlamaBinary.resolve(
        environment: const {},
        resolvedExecutable: '/Apps/Bond Desktop.app/Contents/MacOS/Bond Desktop',
        exists: (path) {
          asked.add(path);
          return true;
        },
      );
      // Contents/MacOS and nowhere else: the ggml backend modules are `.so`
      // files loaded from the executable's own directory.
      expect(resolved, '/Apps/Bond Desktop.app/Contents/MacOS/llama-server');
      expect(asked, ['/Apps/Bond Desktop.app/Contents/MacOS/llama-server']);
    });

    test('null when there is no sidecar and no override', () {
      final resolved = LlamaBinary.resolve(
        environment: const {},
        resolvedExecutable: '/usr/local/bin/dart',
        exists: (_) => false,
      );
      expect(resolved, isNull);
    });

    test('the missing-runtime sentence is fixed', () {
      expect(
        LlamaBinary.missingReason,
        'The model runtime is missing from this build',
      );
    });
  });
}
