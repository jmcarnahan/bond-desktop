import 'dart:io';

import 'package:bond_inbox/services/server/router_preset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('RouterPreset', () {
    test('the default trio writes the INI llama-server expects', () {
      // A folder WITH A SPACE in it, unquoted, because that is the whole
      // gotcha: llama-server's INI parser reads a value to end of line, and a
      // path helpfully wrapped in quotes arrives with the quotes still in it.
      final ini = RouterPreset.defaults('/tmp/Bond Models').toIni();

      expect(ini, '''
version = 1

[*]
jinja = true
flash-attn = on
load-mode = mmap+mlock

[bond-embed]
model = /tmp/Bond Models/ggml-org_embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf
embedding = true
pooling = mean
load-on-startup = true

[bond-bulk]
model = /tmp/Bond Models/ggml-org_Qwen3-4B-Instruct-2507-Q8_0-GGUF/qwen3-4b-instruct-2507-q8_0.gguf
c = 32768
parallel = 4
load-on-startup = true

[bond-prose]
model = /tmp/Bond Models/ggml-org_Qwen3.8-27B-GGUF/Qwen3.8-27B-Q4_K_M.gguf
c = 32768
parallel = 1
load-on-startup = true
''');
    });

    test('modelIds are the router ids, in file order', () {
      expect(
        RouterPreset.defaults('/tmp/models').modelIds,
        ['bond-embed', 'bond-bulk', 'bond-prose'],
      );
    });

    test('modelPath flattens the repo slash to an underscore', () {
      final preset = RouterPreset.defaults('/models');
      final embed = preset.models.first;
      expect(
        preset.modelPath(embed),
        '/models/ggml-org_embeddinggemma-300M-GGUF/'
        'embeddinggemma-300M-Q8_0.gguf',
      );
    });

    test('the hash is stable for one folder and moves with it', () {
      final a = RouterPreset.defaults('/tmp/Bond Models');
      final b = RouterPreset.defaults('/tmp/Bond Models');
      final elsewhere = RouterPreset.defaults('/tmp/Other Models');

      expect(a.hash, b.hash);
      expect(a.hash, hasLength(64));
      // The hash is what says an adopted server is serving the right weights,
      // so a different folder must not hash the same.
      expect(a.hash, isNot(elsewhere.hash));
    });

    test('a changed flag changes the hash', () {
      final preset = RouterPreset.defaults('/tmp/models');
      final tweaked = RouterPreset(
        modelsFolder: '/tmp/models',
        models: [
          for (final m in preset.models)
            RouterModelSpec(
              id: m.id,
              repo: m.repo,
              file: m.file,
              args: {...m.args, 'c': '8192'},
            ),
        ],
      );
      expect(preset.hash, isNot(tweaked.hash));
    });

    test('missingFiles names only what is not on disk', () async {
      final root = await Directory.systemTemp.createTemp('router_preset');
      addTearDown(() => root.delete(recursive: true));

      final preset = RouterPreset.defaults(root.path);
      expect(preset.missingFiles(), hasLength(3));

      final present = preset.models[1];
      final path = preset.modelPath(present);
      await Directory(p.dirname(path)).create(recursive: true);
      await File(path).writeAsString('not really a gguf');

      final missing = preset.missingFiles();
      expect(missing, hasLength(2));
      expect(missing, isNot(contains(path)));
      expect(
        missing.map(p.basename),
        containsAll(<String>[
          'embeddinggemma-300M-Q8_0.gguf',
          'Qwen3.8-27B-Q4_K_M.gguf',
        ]),
      );
    });
  });
}
