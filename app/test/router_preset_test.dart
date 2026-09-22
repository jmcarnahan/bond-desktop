import 'dart:io';

import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:bond_inbox/services/server/router_preset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/test_manifest.dart';

/// The preset is now a PROJECTION of the manifest rather than a table of its
/// own, so every case here builds one through `testManifest()` — except the
/// first, which builds it from the real committed asset. That one is the
/// pin: it is what says the JSON a model bump edits still writes the INI
/// llama-server has always been given.
void main() {
  group('RouterPreset', () {
    test('the committed manifest writes the INI llama-server expects', () {
      // `flutter test` runs from `app/`, so the asset is a plain file here —
      // no bundle, no binding, no channel.
      final manifest = ModelManifest.parse(
        File('assets/models/manifest.json').readAsStringSync(),
      );

      // A folder WITH A SPACE in it, unquoted, because that is the whole
      // gotcha: llama-server's INI parser reads a value to end of line, and a
      // path helpfully wrapped in quotes arrives with the quotes still in it.
      final ini = manifest.toPreset('/tmp/Bond Models').toIni();

      expect(ini, '''
version = 1

[*]
jinja = true
flash-attn = on
load-mode = mmap+mlock

[bond-embed]
model = /tmp/Bond Models/Qwen_Qwen3-Embedding-0.6B-GGUF/Qwen3-Embedding-0.6B-Q8_0.gguf
embedding = true
pooling = last
load-on-startup = true

[bond-bulk]
model = /tmp/Bond Models/ggml-org_Qwen3-4B-Instruct-2507-Q8_0-GGUF/qwen3-4b-instruct-2507-q8_0.gguf
c = 16384
parallel = 4
load-on-startup = true

[bond-prose]
model = /tmp/Bond Models/ggml-org_Qwen3.8-27B-GGUF/Qwen3.8-27B-Q4_K_M.gguf
model-draft = /tmp/Bond Models/ggml-org_Qwen3.8-27B-GGUF/mtp-Qwen3.8-27B-Q4_0.gguf
c = 16384
parallel = 1
load-on-startup = true
spec-type = draft-mtp
''');
    });

    test('the draft line sits between the model and its flags', () {
      // POSITION is the assertion. `model-draft` is the other half of what
      // the section loads rather than one more option, and llama-server reads
      // an INI value to end of line, so the path is unquoted exactly as
      // `model` is.
      final preset = testManifest(proseSidecar: testSidecar())
          .toPreset('/tmp/Bond Models');
      final lines = preset.toIni().split('\n');
      final start = lines.indexOf('[bond-prose]');
      const folder = '/tmp/Bond Models/ggml-org_Qwen3.8-27B-GGUF';

      expect(
        lines.sublist(start, start + 6),
        [
          '[bond-prose]',
          'model = $folder/Qwen3.8-27B-Q4_K_M.gguf',
          'model-draft = $folder/mtp-Qwen3.8-27B-Q4_0.gguf',
          'c = 32768',
          'parallel = 1',
          'load-on-startup = true',
        ],
      );
    });

    test('a model with no draft writes no line for one', () {
      final preset = testPreset('/tmp/models');

      expect(preset.toIni(), isNot(contains('model-draft')));
      for (final m in preset.models) {
        expect(preset.draftPath(m), isNull, reason: m.id);
      }
    });

    test('adding a draft moves the hash', () {
      // The hash is what says an adopted server is serving the right
      // configuration. A server started before the head existed is loading
      // one file where this build loads two, so it must not be reused.
      final plain = testManifest().toPreset('/tmp/models');
      final drafted =
          testManifest(proseSidecar: testSidecar()).toPreset('/tmp/models');

      expect(drafted.hash, isNot(plain.hash));
      expect(drafted.hash, hasLength(64));
    });

    test('missingFiles names the draft alone when only it is absent',
        () async {
      final root = await Directory.systemTemp.createTemp('router_draft');
      addTearDown(() => root.delete(recursive: true));

      final preset =
          testManifest(proseSidecar: testSidecar()).toPreset(root.path);
      // Four files for three sections, which is the point of the case.
      expect(preset.missingFiles(), hasLength(4));

      for (final m in preset.models) {
        final path = preset.modelPath(m);
        await Directory(p.dirname(path)).create(recursive: true);
        await File(path).writeAsString('not really a gguf');
      }

      final missing = preset.missingFiles();
      expect(missing, [
        p.join(root.path, 'ggml-org_Qwen3.8-27B-GGUF',
            'mtp-Qwen3.8-27B-Q4_0.gguf'),
      ]);
    });

    test('an inbox Mac gets a preset with no writing model in it', () {
      final manifest = ModelManifest.parse(
        File('assets/models/manifest.json').readAsStringSync(),
      );

      final inbox =
          manifest.forTier(MachineTier.inbox).toPreset('/tmp/Bond Models');

      // No `[bond-prose]` section at all. The supervisor starts every model
      // the preset names and refuses while any of their files is missing, so
      // a section for a checkpoint this tier never downloads would be a
      // server that cannot start on a machine that is set up correctly.
      expect(inbox.modelIds, ['bond-embed', 'bond-bulk']);
      expect(inbox.toIni(), isNot(contains('[bond-prose]')));
      expect(inbox.toIni(), contains('parallel = 2'));

      // And the hash differs, which is what stops a server started under one
      // tier from being adopted by a launch that wants the other.
      final full =
          manifest.forTier(MachineTier.full).toPreset('/tmp/Bond Models');
      expect(inbox.hash, isNot(full.hash));
      expect(full.hash, manifest.toPreset('/tmp/Bond Models').hash);
    });

    test('modelIds are the router ids, in file order', () {
      expect(
        testPreset('/tmp/models').modelIds,
        ['bond-embed', 'bond-bulk', 'bond-prose'],
      );
    });

    test('a resolved manifest writes one section per model it kept', () {
      final inbox =
          testManifest().forTier(MachineTier.inbox).toPreset('/tmp/models');

      expect(inbox.modelIds, ['bond-embed', 'bond-bulk']);
      expect(inbox.missingFiles(), hasLength(2));
    });

    test('modelPath flattens the repo slash to an underscore', () {
      final preset = testPreset('/models');
      final embed = preset.models.first;
      expect(
        preset.modelPath(embed),
        '/models/ggml-org_embeddinggemma-300M-GGUF/'
        'embeddinggemma-300M-Q8_0.gguf',
      );
    });

    test('the hash is stable for one folder and moves with it', () {
      final a = testPreset('/tmp/Bond Models');
      final b = testPreset('/tmp/Bond Models');
      final elsewhere = testPreset('/tmp/Other Models');

      expect(a.hash, b.hash);
      expect(a.hash, hasLength(64));
      // The hash is what says an adopted server is serving the right weights,
      // so a different folder must not hash the same.
      expect(a.hash, isNot(elsewhere.hash));
    });

    test('a changed flag changes the hash', () {
      final preset = testPreset('/tmp/models');
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

      final preset = testPreset(root.path);
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
