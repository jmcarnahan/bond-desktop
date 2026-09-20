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
      'displayName': 'Qwen3 Embedding 0.6B',
      'repo': 'Qwen/Qwen3-Embedding-0.6B-GGUF',
      'file': 'Qwen3-Embedding-0.6B-Q8_0.gguf',
      'revision': '370f27d7550e0def9b39c1f16d3fbaa13aa67728',
      'sizeBytes': 639150592,
      'sha256':
          '06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439',
      'minRamBytes': 0,
      'license': 'Apache-2.0',
      'licenseUrl': 'https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF',
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

Map<String, Object?> fullTierJson() => {
      'id': 'full',
      'minRamBytes': fullTierMinBytes,
      'models': [routerEmbedId, routerBulkId, routerProseId],
    };

Map<String, Object?> inboxTierJson() => {
      'id': 'inbox',
      'minRamBytes': 0,
      'models': [routerEmbedId, routerBulkId],
      'serverArgs': {
        routerBulkId: {'c': '16384', 'parallel': '2'},
      },
    };

String manifestText(
  List<Map<String, Object?>> models, {
  int version = 2,
  List<Map<String, Object?>>? tiers,
}) =>
    jsonEncode({
      'version': version,
      'models': models,
      'tiers': tiers ?? [fullTierJson(), inboxTierJson()],
    });

void main() {
  group('the committed asset', () {
    test('parses, and names the three router ids in file order', () {
      final manifest = realManifest();
      expect(manifest.version, 2);
      expect(
        [for (final m in manifest.models) m.id],
        [routerEmbedId, routerBulkId, routerProseId],
      );
    });

    test('carries the measured sizes and digests', () {
      final manifest = realManifest();

      expect(manifest.byId(routerEmbedId).sizeBytes, 639150592);
      expect(
        manifest.byId(routerEmbedId).sha256,
        '06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439',
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
      expect(manifest.totalBytes, 639150592 + 4280403520 + 18973870432);
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
        'https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/'
        '370f27d7550e0def9b39c1f16d3fbaa13aa67728/'
        'Qwen3-Embedding-0.6B-Q8_0.gguf',
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
          {'c': '16384', 'parallel': '4', 'load-on-startup': 'true'});
    });

    test('toPreset writes the INI Phase 2 wrote', () {
      expect(realManifest().toPreset('/tmp/Bond Models').toIni(), '''
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
c = 16384
parallel = 1
load-on-startup = true
''');
    });

    test('every checkpoint names its licence, and none needs a notice', () {
      // All three are Apache-2.0 since the embedding model left
      // EmbeddingGemma on 2026-09-19; the Gemma Terms of Use went with it.
      // `notice` stays a field rather than being dropped: it is what the
      // first-run screen renders under a checkpoint whose licence has to be
      // shown, and the next non-permissive model would want it back.
      for (final model in realManifest().models) {
        expect(model.license, 'Apache-2.0', reason: model.id);
        expect(model.licenseUrl, startsWith('https://huggingface.co/'));
        // Null and not an empty string: a screen must be able to skip the
        // line entirely rather than render a blank one.
        expect(model.notice, isNull, reason: model.id);
      }
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

  group('tiers', () {
    test('the committed asset declares both rungs, at the compiled floors',
        () {
      final manifest = realManifest();

      expect([for (final t in manifest.tiers) t.tier],
          [MachineTier.full, MachineTier.inbox]);
      expect(
        {for (final t in manifest.tiers) t.tier: t.minRamBytes},
        {MachineTier.full: fullTierMinBytes, MachineTier.inbox: 0},
      );
    });

    test('the full tier resolves to the manifest itself', () {
      final manifest = realManifest();
      final full = manifest.forTier(MachineTier.full);

      expect([for (final m in full.models) m.id],
          [routerEmbedId, routerBulkId, routerProseId]);
      expect(full.byRoleOrNull(ModelRole.prose)?.id, routerProseId);
      expect(full.models, manifest.models);
      expect(full.totalBytes, manifest.totalBytes);
    });

    test('the inbox tier drops the writing model and merges its args', () {
      final inbox = realManifest().forTier(MachineTier.inbox);

      expect([for (final m in inbox.models) m.id],
          [routerEmbedId, routerBulkId]);
      // Merged ONTO the entry's own arguments: `parallel` is halved, `c`
      // restated and `load-on-startup` survives untouched.
      expect(inbox.byId(routerBulkId).serverArgs,
          {'c': '16384', 'parallel': '2', 'load-on-startup': 'true'});
      // The embedding model is in every tier and is not overridden.
      expect(inbox.byId(routerEmbedId).serverArgs,
          realManifest().byId(routerEmbedId).serverArgs);
    });

    test('a resolved view without prose answers null, and throws on byRole',
        () {
      final inbox = realManifest().forTier(MachineTier.inbox);

      expect(inbox.byRoleOrNull(ModelRole.prose), isNull);
      expect(() => inbox.byRole(ModelRole.prose), throwsStateError);
      // The two every tier carries are still there, by role and by id.
      expect(inbox.byRole(ModelRole.embed).id, routerEmbedId);
      expect(inbox.usableIds, {routerEmbedId, routerBulkId});
    });

    test('the download total and order follow the tier', () {
      final manifest = realManifest();
      final inbox = manifest.forTier(MachineTier.inbox);

      expect(inbox.totalBytes, 639150592 + 4280403520);
      expect(manifest.totalBytes, 639150592 + 4280403520 + 18973870432);
      expect([for (final m in inbox.bySize) m.id],
          [routerEmbedId, routerBulkId]);
      expect(
        [for (final m in manifest.forTier(MachineTier.full).bySize) m.id],
        [routerEmbedId, routerBulkId, routerProseId],
      );
    });

    test('two tiers that are equal hash the same', () {
      // `==` and `hashCode` have to agree about ORDER, because the hash is
      // over the id list in order. A set-wise `==` would call these two equal
      // and hash them differently, and `ModelManifest.hashCode` inherits it.
      const forwards = ManifestTier(
        tier: MachineTier.inbox,
        minRamBytes: 0,
        models: [routerEmbedId, routerBulkId],
      );
      const backwards = ManifestTier(
        tier: MachineTier.inbox,
        minRamBytes: 0,
        models: [routerBulkId, routerEmbedId],
      );
      const same = ManifestTier(
        tier: MachineTier.inbox,
        minRamBytes: 0,
        models: [routerEmbedId, routerBulkId],
      );

      expect(forwards, same);
      expect(forwards.hashCode, same.hashCode);
      expect(forwards, isNot(backwards));
      // The contract, stated the way it is broken: equal implies same hash.
      for (final pair in [
        [forwards, same],
        [forwards, backwards],
      ]) {
        if (pair[0] == pair[1]) {
          expect(pair[0].hashCode, pair[1].hashCode);
        }
      }
    });

    test('a manifest with no tiers resolves to itself', () {
      // What a fixture of one model is, and what `manifestFor` builds.
      const one = ModelManifest(version: 2, models: []);
      expect(identical(one.forTier(MachineTier.inbox), one), isTrue);
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
      manifestText([embedJson(), bulkJson(), proseJson()], version: 1),
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

    final models = [embedJson(), bulkJson(), proseJson()];

    refuses(
      'no tiers at all',
      jsonEncode({'version': 2, 'models': models}),
      contains('tiers'),
    );

    refuses(
      'a tier naming a model this build does not ship',
      manifestText(models, tiers: [
        {
          ...fullTierJson(),
          'models': [routerEmbedId, routerBulkId, 'bond-writer'],
        },
        inboxTierJson(),
      ]),
      allOf(contains('full'), contains('bond-writer')),
    );

    refuses(
      'a tier without the embedding model',
      manifestText(models, tiers: [
        fullTierJson(),
        {
          ...inboxTierJson(),
          'models': [routerBulkId],
          'serverArgs': <String, Object?>{},
        },
      ]),
      allOf(contains('inbox'), contains(routerEmbedId)),
    );

    refuses(
      'a tier without the inbox model',
      manifestText(models, tiers: [
        fullTierJson(),
        {
          ...inboxTierJson(),
          'models': [routerEmbedId],
          'serverArgs': <String, Object?>{},
        },
      ]),
      allOf(contains('inbox'), contains(routerBulkId)),
    );

    refuses(
      'the same tier twice',
      manifestText(models,
          tiers: [fullTierJson(), fullTierJson(), inboxTierJson()]),
      contains('duplicate tier'),
    );

    refuses(
      'a tier id that is not a machine tier',
      manifestText(models, tiers: [
        fullTierJson(),
        {...inboxTierJson(), 'id': 'tiny'},
      ]),
      allOf(contains('tiny'), contains('machine tier')),
    );

    refuses(
      'a ladder missing a rung this build knows',
      manifestText(models, tiers: [fullTierJson()]),
      contains('inbox'),
    );

    // The JSON and `fullTierMinBytes` cannot drift: the floor is compiled in,
    // and a manifest that says another number is refused at parse time rather
    // than putting a Mac on the wrong rung.
    refuses(
      'a full tier that starts somewhere else',
      manifestText(models, tiers: [
        {...fullTierJson(), 'minRamBytes': 34359738368},
        inboxTierJson(),
      ]),
      allOf(contains('full'), contains('$fullTierMinBytes')),
    );

    refuses(
      'a ladder that does not start at zero',
      manifestText(models, tiers: [
        fullTierJson(),
        {...inboxTierJson(), 'minRamBytes': 8589934592},
      ]),
      allOf(contains('inbox'), contains('minRamBytes')),
    );

    refuses(
      'a tier overriding args for a model it does not list',
      manifestText(models, tiers: [
        fullTierJson(),
        {
          ...inboxTierJson(),
          'serverArgs': {
            routerProseId: {'c': '4096'},
          },
        },
      ]),
      allOf(contains('inbox'), contains(routerProseId)),
    );
  });
}
