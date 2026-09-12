import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// An asset bundle with exactly one asset in it.
///
/// `CachingAssetBundle` gives `loadString` for free once `load` answers
/// bytes, which is the only method a manifest read needs. A test binary has
/// no `rootBundle` worth speaking of, so this is how [ModelManifest.load] is
/// exercised at all.
class _FileBundle extends CachingAssetBundle {
  _FileBundle(this.bytes);

  final List<int> bytes;
  final List<String> asked = [];

  @override
  Future<ByteData> load(String key) async {
    asked.add(key);
    return ByteData.view(Uint8List.fromList(bytes).buffer);
  }
}

/// The committed asset, read as a plain file — `flutter test` runs from
/// `app/`, so no bundle and no binding are needed to check the real thing.
ModelManifest realManifest() => ModelManifest.parse(
      File(ModelManifest.assetPath).readAsStringSync(),
    );

Map<String, Object?> embedJson() => {
      'id': 'bond-embed',
      'role': 'embed',
      'displayName': 'EmbeddingGemma 300M',
      'repo': 'ggml-org/embeddinggemma-300M-GGUF',
      'file': 'embeddinggemma-300M-Q8_0.gguf',
      'revision': '0f741b5a6585bd53aeb15cd1372c56f2a0f65e12',
      'sizeBytes': 333590944,
      'sha256':
          'b5ce9d77a3fc4b3b39ccb5643c36777911cc4eb46a66962eadfa3f5f60490d63',
      'minRamBytes': 0,
      'license': 'Gemma Terms of Use',
      'licenseUrl': 'https://ai.google.dev/gemma/terms',
      'notice': null,
      'serverArgs': {'embedding': 'true'},
    };

Map<String, Object?> bulkJson() => {
      ...embedJson(),
      'id': 'bond-bulk',
      'role': 'bulk',
      'serverArgs': {'c': '32768'},
    };

Map<String, Object?> proseJson() => {
      ...embedJson(),
      'id': 'bond-prose',
      'role': 'prose',
      'serverArgs': {'c': '32768'},
    };

String manifestText(List<Map<String, Object?>> models, {int version = 1}) =>
    jsonEncode({'version': version, 'models': models});

void main() {
  group('the committed asset', () {
    test('parses, and names the three router ids in file order', () {
      final manifest = realManifest();
      expect(manifest.version, 1);
      expect(
        [for (final m in manifest.models) m.id],
        [routerEmbedId, routerBulkId, routerProseId],
      );
    });

    test('carries the measured sizes and digests', () {
      final manifest = realManifest();

      expect(manifest.byId(routerEmbedId).sizeBytes, 333590944);
      expect(
        manifest.byId(routerEmbedId).sha256,
        'b5ce9d77a3fc4b3b39ccb5643c36777911cc4eb46a66962eadfa3f5f60490d63',
      );
      expect(manifest.byId(routerBulkId).sizeBytes, 4280403520);
      expect(
        manifest.byId(routerBulkId).sha256,
        'ae916ede1c010a26955ee8ae2e908bf8815a3f135ec860439ab924701c69d5f1',
      );
      expect(manifest.byId(routerProseId).sizeBytes, 18973870432);
      expect(
        manifest.byId(routerProseId).sha256,
        '31629f53165ab6a7dad8c9847dcfd1fdf55829dac1e6e748f4a68581b0033d34',
      );
      expect(manifest.totalBytes, 333590944 + 4280403520 + 18973870432);
    });

    test('every revision is a commit sha, never a branch', () {
      for (final model in realManifest().models) {
        expect(model.revision, isNot('main'));
        expect(model.revision, matches(RegExp(r'^[0-9a-f]{40}$')));
      }
    });

    test('the file order is smallest first, which is the download order', () {
      final manifest = realManifest();
      expect(
        [for (final m in manifest.bySize) m.id],
        [for (final m in manifest.models) m.id],
      );
    });

    test('the inbox is usable on the two small models', () {
      expect(realManifest().usableIds, {routerEmbedId, routerBulkId});
    });

    test('resolveUri pins the commit, not main', () {
      expect(
        realManifest().byRole(ModelRole.embed).resolveUri.toString(),
        'https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF/resolve/'
        '0f741b5a6585bd53aeb15cd1372c56f2a0f65e12/'
        'embeddinggemma-300M-Q8_0.gguf',
      );
    });

    test('relativePath flattens the repo slash, as the preset does', () {
      expect(
        realManifest().byRole(ModelRole.prose).relativePath,
        'ggml-org_Qwen3.8-27B-GGUF/Qwen3.8-27B-Q4_K_M.gguf',
      );
    });

    test('toSpec carries the server args verbatim', () {
      final spec = realManifest().byRole(ModelRole.bulk).toSpec();
      expect(spec.id, routerBulkId);
      expect(spec.repo, 'ggml-org/Qwen3-4B-Instruct-2507-Q8_0-GGUF');
      expect(spec.args,
          {'c': '32768', 'parallel': '4', 'load-on-startup': 'true'});
    });

    test('toPreset writes the INI Phase 2 wrote', () {
      expect(realManifest().toPreset('/tmp/Bond Models').toIni(), '''
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

    test('the embedding model carries its licence notice', () {
      final embed = realManifest().byRole(ModelRole.embed);
      expect(embed.license, 'Gemma Terms of Use');
      expect(embed.licenseUrl, 'https://ai.google.dev/gemma/terms');
      expect(embed.notice, contains('Gemma Terms of Use'));
      // The permissive ones have nothing to show, and a screen must be able
      // to tell that from an empty string.
      expect(realManifest().byRole(ModelRole.bulk).notice, isNull);
    });

    test('toJson round-trips to an equal manifest', () {
      final manifest = realManifest();
      expect(ModelManifest.parse(jsonEncode(manifest.toJson())), manifest);
    });
  });

  group('load', () {
    test('reads the asset path through the bundle', () async {
      final bytes = File(ModelManifest.assetPath).readAsBytesSync();
      final bundle = _FileBundle(bytes);

      final manifest = await ModelManifest.load(bundle);

      expect(bundle.asked, contains('assets/models/manifest.json'));
      expect(manifest, realManifest());
    });
  });

  group('lookups', () {
    test('byId and byRole find, and say so when they cannot', () {
      final manifest = realManifest();
      expect(manifest.byId(routerProseId).role, ModelRole.prose);
      expect(manifest.byRole(ModelRole.bulk).id, routerBulkId);
      expect(() => manifest.byId('bond-nothing'), throwsStateError);
    });
  });

  group('parse refuses', () {
    void refuses(String name, String text, Matcher message) {
      test(name, () {
        expect(
          () => ModelManifest.parse(text),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', message)),
        );
      });
    }

    refuses(
      'a missing sha256',
      manifestText([
        Map.of(embedJson())..remove('sha256'),
        bulkJson(),
        proseJson(),
      ]),
      contains('sha256'),
    );

    refuses(
      'a sha256 of the wrong length',
      manifestText([
        {...embedJson(), 'sha256': 'abc123'},
        bulkJson(),
        proseJson(),
      ]),
      contains('sha256'),
    );

    refuses(
      'an upper-case sha256',
      manifestText([
        {
          ...embedJson(),
          'sha256':
              'B5CE9D77A3FC4B3B39CCB5643C36777911CC4EB46A66962EADFA3F5F60490D63',
        },
        bulkJson(),
        proseJson(),
      ]),
      contains('sha256'),
    );

    refuses(
      'a revision that is a branch name',
      manifestText([
        {...embedJson(), 'revision': 'main'},
        bulkJson(),
        proseJson(),
      ]),
      contains('revision'),
    );

    refuses(
      'a zero size',
      manifestText([
        {...embedJson(), 'sizeBytes': 0},
        bulkJson(),
        proseJson(),
      ]),
      contains('sizeBytes'),
    );

    refuses(
      'a duplicate id',
      manifestText([
        embedJson(),
        {...bulkJson(), 'id': 'bond-embed'},
        proseJson(),
      ]),
      contains('id'),
    );

    refuses(
      'two models for one role',
      manifestText([
        embedJson(),
        {...bulkJson(), 'role': 'embed'},
        proseJson(),
      ]),
      contains('role'),
    );

    refuses(
      'a role nothing serves',
      manifestText([
        {...embedJson(), 'role': 'summariser'},
        bulkJson(),
        proseJson(),
      ]),
      contains('role'),
    );

    refuses(
      'a version this build does not read',
      manifestText([embedJson(), bulkJson(), proseJson()], version: 2),
      contains('version'),
    );

    // The role is not what anything routes on: the preset writes a section
    // per id and every request names one, so a role filled under another id
    // would leave the slot pointing at a section that does not exist.
    refuses(
      'an embed model under another id',
      manifestText([
        {...embedJson(), 'id': 'bond-embeddings'},
        bulkJson(),
        proseJson(),
      ]),
      allOf(contains('embed'), contains(routerEmbedId)),
    );

    refuses(
      'a bulk model under another id',
      manifestText([
        embedJson(),
        {...bulkJson(), 'id': 'bond-fast'},
        proseJson(),
      ]),
      allOf(contains('bulk'), contains(routerBulkId)),
    );

    refuses(
      'a prose model under another id',
      manifestText([
        embedJson(),
        bulkJson(),
        {...proseJson(), 'id': 'bond-writer'},
      ]),
      allOf(contains('prose'), contains(routerProseId)),
    );

    refuses(
      'a serverArgs value that is not a string',
      manifestText([
        {
          ...embedJson(),
          'serverArgs': {'parallel': 4},
        },
        bulkJson(),
        proseJson(),
      ]),
      contains('serverArgs.parallel'),
    );
  });
}
