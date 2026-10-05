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

/// A well-formed sidecar, for the refusals to break one field of at a time.
Map<String, Object?> sidecarJson() => {
      'file': 'mtp-Qwen3.8-27B-Q4_0.gguf',
      'revision': '0669b98607d47046c7c2b3f801011d54a08cfccf',
      'sha256':
          '051a1764cff8c4f3ee6ae8b00593a0364c7539c67fa50ffc58f3f96509fca38e',
      'sizeBytes': 1680271648,
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

/// A HAND-INSTALLED decision model (`source: local`), as an older asset
/// spelled it. The committed asset ships the registry entry now; the local
/// source is still read, and these are its cases.
Map<String, Object?> decideJson() => {
      'id': 'bond-decide',
      'role': 'decide',
      'source': 'local',
      'displayName': 'Bond decision model',
      'repo': 'local/bond-decide',
      'file': 'bond-decide-mbl-v3-f16.gguf',
      'sizeBytes': 791461056,
      'sha256':
          '1c3083e89bb39cf346b4b509ecaf6da1237c4e7b3cde4e92fb7289b816aa4aa5',
      'minRamBytes': 0,
      'license': 'Apache-2.0',
      'licenseUrl': 'https://huggingface.co/answerdotai/ModernBERT-large',
      'notice': null,
      'heads': {
        'file': 'decide-heads.json',
        'sha256':
            '94b60a0b6ccf2c781f85dcdb0b130f41519924a28ae36df642370176cc37ae95',
        'sizeBytes': 1032653,
      },
      'serverArgs': {'embedding': 'true', 'pooling': 'mean'},
    };

/// The registry decision model, as the committed asset spells it.
Map<String, Object?> registryDecideJson() => {
      'id': 'bond-decide',
      'role': 'decide',
      'source': 'artifactory',
      'displayName': 'Bond decision model',
      'repo': 'artifactory/bond-decide-mbl-v3swap',
      'bundle': 'bond-decide-mbl-v3swap',
      'remoteFile': 'model-f16.gguf',
      'file': 'bond-decide-mbl-v3-f16.gguf',
      'sizeBytes': 791461056,
      'sha256':
          'e348ca9117036b8d8c79d93783d74092f5fcd3a8ac06bdc1ea153935243dfa88',
      'minRamBytes': 0,
      'license': 'Apache-2.0',
      'licenseUrl': 'https://huggingface.co/answerdotai/ModernBERT-large',
      'notice': null,
      'heads': {
        'file': 'decide-heads.json',
        'remoteFile': 'heads.json',
        'sha256':
            'a38835a22858b28827561d1b9c85d752d14cb8277dc248699ec82ee82fa7ad72',
        'sizeBytes': 1032653,
      },
      'serverArgs': {'embedding': 'true', 'pooling': 'mean'},
    };

String manifestText(
  List<Map<String, Object?>> models, {
  int version = ModelManifest.manifestVersion,
  List<Map<String, Object?>>? tiers,
}) =>
    jsonEncode({
      'version': version,
      'models': models,
      'tiers': tiers ?? [fullTierJson(), inboxTierJson()],
    });

void main() {
  group('the committed asset', () {
    test('parses, and names the four router ids in file order', () {
      final manifest = realManifest();
      expect(manifest.version, 3);
      expect(manifest.version, ModelManifest.manifestVersion);
      expect(
        [for (final m in manifest.models) m.id],
        [routerEmbedId, routerDecideId, routerBulkId, routerProseId],
      );
    });

    test('the decision model is the v3 swap bundle from the registry, with '
        'its heads as a second download', () {
      final decide = realManifest().byRole(ModelRole.decide);

      expect(decide.id, routerDecideId);
      expect(decide.isRegistry, isTrue);
      expect(decide.isLocal, isFalse);
      expect(decide.gatesSetup, isFalse);
      expect(decide.source, sourceArtifactory);
      expect(decide.repo, 'artifactory/bond-decide-mbl-v3swap');
      expect(decide.bundle, 'bond-decide-mbl-v3swap');
      expect(decide.remoteFile, 'model-f16.gguf');
      expect(decide.revision, '');
      expect(decide.displayName, 'Bond decision model');
      expect(decide.file, 'bond-decide-mbl-v3-f16.gguf');
      expect(decide.sizeBytes, 791461056);
      expect(
        decide.sha256,
        'e348ca9117036b8d8c79d93783d74092f5fcd3a8ac06bdc1ea153935243dfa88',
      );
      expect(decide.heads!.file, 'decide-heads.json');
      expect(decide.heads!.remoteFile, 'heads.json');
      expect(decide.heads!.sizeBytes, 1032653);
      expect(
        decide.heads!.sha256,
        'a38835a22858b28827561d1b9c85d752d14cb8277dc248699ec82ee82fa7ad72',
      );
      // The folder the downloader and `make decide-fetch` write into, with
      // the names the app reads: the heads file's `model` must prefix the
      // GGUF's name, so the bundle's `model-f16.gguf` is renamed on disk.
      expect(decide.relativePath,
          'artifactory_bond-decide-mbl-v3swap/bond-decide-mbl-v3-f16.gguf');
      expect(decide.headsRelativePath,
          'artifactory_bond-decide-mbl-v3swap/decide-heads.json');
      // Both files are downloaded, so both count.
      expect(decide.downloadBytes, 791461056 + 1032653);
      expect(decide.serverArgs, {
        'embedding': 'true',
        'pooling': 'mean',
        'c': '2048',
        'ub': '2048',
        'b': '2048',
        'parallel': '1',
        'load-on-startup': 'true',
      });
    });

    test('a downloaded entry is hf-sourced and carries no heads', () {
      final embed = realManifest().byRole(ModelRole.embed);
      expect(embed.isLocal, isFalse);
      expect(embed.source, sourceHf);
      expect(embed.heads, isNull);
      expect(embed.headsRelativePath, isNull);
    });

    test('a registry entry round-trips through toJson', () {
      final decide = realManifest().byRole(ModelRole.decide);
      final json = decide.toJson();
      final again =
          ModelFile.fromJson(jsonDecode(jsonEncode(json)) as Map<String, Object?>);
      expect(again, decide);
      expect(again.hashCode, decide.hashCode);
      expect(json.containsKey('revision'), isFalse);
      expect(json['source'], 'artifactory');
      expect(json['bundle'], 'bond-decide-mbl-v3swap');
      expect(json['remoteFile'], 'model-f16.gguf');
      expect((json['heads'] as Map)['remoteFile'], 'heads.json');
      // And it is a different entry from the same one without its bundle
      // names, so `==` carries them.
      expect(
        again,
        isNot(ModelFile.fromJson({
          ...registryDecideJson(),
          'remoteFile': 'other.gguf',
        })),
      );
    });

    test('a local entry round-trips through toJson', () {
      final decide = ModelFile.fromJson(decideJson());
      final again =
          ModelFile.fromJson(jsonDecode(jsonEncode(decide.toJson())) as Map<String, Object?>);
      expect(again, decide);
      expect(decide.isLocal, isTrue);
      expect(decide.isRegistry, isFalse);
      expect(decide.gatesSetup, isFalse);
      expect(decide.source, sourceLocal);
      expect(decide.bundle, isNull);
      expect(decide.remoteFile, isNull);
      expect(decide.toJson().containsKey('revision'), isFalse);
      expect(decide.toJson().containsKey('bundle'), isFalse);
      expect(decide.toJson()['source'], 'local');
      // Its folder is `local_<name>`, and it costs no download bytes.
      expect(decide.relativePath,
          'local_bond-decide/bond-decide-mbl-v3-f16.gguf');
      expect(decide.headsRelativePath, 'local_bond-decide/decide-heads.json');
      expect(decide.downloadBytes, 0);
    });

    test('the registry URLs are <base>/bundles/<bundle>/<remote name>, with '
        'or without a trailing slash on the base', () {
      final decide = realManifest().byRole(ModelRole.decide);
      const base = 'https://artifactory.example.com/artifactory/bond-models';
      for (final typed in [base, '$base/', '  $base//  ']) {
        expect(
          decide.registryUri(typed).toString(),
          '$base/bundles/bond-decide-mbl-v3swap/model-f16.gguf',
        );
        expect(
          decide.headsRegistryUri(typed).toString(),
          '$base/bundles/bond-decide-mbl-v3swap/heads.json',
        );
      }
      expect(
        decide.registryUri('http://localhost:18082/artifactory/bond-models/')
            .toString(),
        'http://localhost:18082/artifactory/bond-models/bundles/'
        'bond-decide-mbl-v3swap/model-f16.gguf',
      );
    });

    test('heads without a remote name are asked for by their own name', () {
      final json = registryDecideJson();
      final heads = Map.of(json['heads']! as Map<String, Object?>)
        ..remove('remoteFile');
      final decide = ModelFile.fromJson({...json, 'heads': heads});
      expect(decide.heads!.remoteFile, isNull);
      expect(
        decide.headsRegistryUri('https://artifactory.example.com/r')
            .toString(),
        'https://artifactory.example.com/r/bundles/bond-decide-mbl-v3swap/'
        'decide-heads.json',
      );
      expect((decide.toJson()['heads'] as Map).containsKey('remoteFile'),
          isFalse);
    });

    test('the registry URLs refuse an empty base and a hub entry, and the hub '
        'URLs refuse a registry entry', () {
      final manifest = realManifest();
      final decide = manifest.byRole(ModelRole.decide);
      final embed = manifest.byRole(ModelRole.embed);
      expect(() => decide.registryUri(''), throwsStateError);
      expect(() => decide.registryUri('  /  '), throwsStateError);
      expect(() => decide.headsRegistryUri(''), throwsStateError);
      expect(() => embed.registryUri('https://artifactory.example.com/r'),
          throwsStateError);
      expect(() => embed.headsRegistryUri('https://artifactory.example.com/r'),
          throwsStateError);
      expect(() => decide.resolveUri, throwsStateError);
      expect(() => decide.sidecarResolveUri, throwsStateError);
    });

    test('toString never cuts an empty revision', () {
      final decide = realManifest().byRole(ModelRole.decide);
      expect(decide.revision, '');
      expect(decide.toString, returnsNormally);
      expect('$decide', contains('bond-decide-mbl-v3swap'));
      expect('${ModelFile.fromJson(decideJson())}', contains('local'));
      // A hub entry built in code with no revision does not throw either.
      const bare = ModelFile(
        id: 'bond-embed',
        role: ModelRole.embed,
        displayName: 'Bare',
        repo: 'owner/name',
        file: 'x.gguf',
        revision: '',
        sizeBytes: 1,
        sha256: '',
        minRamBytes: 0,
        license: 'Fictional-1.0',
        licenseUrl: 'https://example.invalid/licence',
      );
      expect(bare.toString, returnsNormally);
    });

    test('the gating view leaves the registry entry out, the downloadable '
        'view keeps it', () {
      final manifest = realManifest();
      expect([for (final m in manifest.gating.models) m.id],
          [routerEmbedId, routerBulkId, routerProseId]);
      expect([for (final m in manifest.downloadable.models) m.id],
          [routerEmbedId, routerDecideId, routerBulkId, routerProseId]);
      // A hand-installed entry is in neither.
      final local = ModelManifest.parse(manifestText(
          [embedJson(), decideJson(), bulkJson(), proseJson()]));
      expect([for (final m in local.gating.models) m.id],
          isNot(contains(routerDecideId)));
      expect([for (final m in local.downloadable.models) m.id],
          isNot(contains(routerDecideId)));
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
      expect(
        manifest.totalBytes,
        639150592 + 791461056 + 1032653 + 4280403520 + 18973870432 +
            1680271648,
      );
    });

    test('the prose entry ships its MTP head, at the parent commit', () {
      final prose = realManifest().byRole(ModelRole.prose);
      final head = prose.sidecar!;

      expect(head.file, 'mtp-Qwen3.8-27B-Q4_0.gguf');
      expect(head.sizeBytes, 1680271648);
      expect(
        head.sha256,
        '051a1764cff8c4f3ee6ae8b00593a0364c7539c67fa50ffc58f3f96509fca38e',
      );
      // ONE commit for both files. The head is only a draft for the weights
      // published beside it, so a sidecar resolved from another revision
      // would be a tokenizer mismatch at startup.
      expect(head.revision, prose.revision);

      // And the flag that needs it travels with it: the manifest may carry
      // `spec-type` only because it now ships the sidecar the flag looks for.
      expect(prose.serverArgs['spec-type'], 'draft-mtp');
    });

    test('a checkpoint with no sidecar answers null for all of it', () {
      final embed = realManifest().byRole(ModelRole.embed);

      expect(embed.sidecar, isNull);
      expect(embed.sidecarRelativePath, isNull);
      expect(embed.sidecarResolveUri, isNull);
      expect(embed.downloadBytes, embed.sizeBytes);
    });

    test('the sidecar path and URI sit in the parent repo, at its revision',
        () {
      final prose = realManifest().byRole(ModelRole.prose);

      expect(
        prose.sidecarRelativePath,
        'ggml-org_Qwen3.8-27B-GGUF/mtp-Qwen3.8-27B-Q4_0.gguf',
      );
      expect(
        prose.sidecarResolveUri.toString(),
        'https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF/resolve/'
        '0669b98607d47046c7c2b3f801011d54a08cfccf/mtp-Qwen3.8-27B-Q4_0.gguf',
      );
      expect(prose.downloadBytes, 18973870432 + 1680271648);
    });

    test('every hub revision is a commit sha, never a branch', () {
      // A registry entry pins its bytes by digest alone and carries none.
      for (final model in realManifest().models) {
        if (model.isLocal || model.isRegistry) continue;
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

    test('toPreset writes the INI Phase 2 wrote, plus the decision model', () {
      // The decide section carries no heads line: the heads run in Dart and
      // llama-server never reads them.
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

[bond-decide]
model = /tmp/Bond Models/artifactory_bond-decide-mbl-v3swap/bond-decide-mbl-v3-f16.gguf
embedding = true
pooling = mean
c = 2048
ub = 2048
b = 2048
parallel = 1
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

    test('every checkpoint names its licence, and none needs a notice', () {
      // All four are Apache-2.0 (the decision model is a fine-tune of
      // ModernBERT-large, Apache-2.0) since the embedding model left
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

    test('the sidecar round-trips, and a different head is a different entry',
        () {
      final prose = realManifest().byRole(ModelRole.prose);

      expect(
        ModelSidecar.fromJson(
          jsonDecode(jsonEncode(prose.sidecar!.toJson()))
              as Map<String, Object?>,
        ),
        prose.sidecar,
      );

      // `==` and `hashCode` have to see it. A build whose manifest bumped
      // only the head would otherwise compare equal to the previous one, and
      // nothing downstream would notice the draft had moved.
      final other = ModelFile(
        id: prose.id,
        role: prose.role,
        displayName: prose.displayName,
        repo: prose.repo,
        file: prose.file,
        revision: prose.revision,
        sizeBytes: prose.sizeBytes,
        sha256: prose.sha256,
        minRamBytes: prose.minRamBytes,
        license: prose.license,
        licenseUrl: prose.licenseUrl,
        serverArgs: prose.serverArgs,
        sidecar: ModelSidecar(
          file: prose.sidecar!.file,
          revision: prose.sidecar!.revision,
          sha256: 'f' * 64,
          sizeBytes: prose.sidecar!.sizeBytes,
        ),
      );
      expect(other, isNot(prose));
      expect(other.hashCode, isNot(prose.hashCode));
    });

    test('a tier override keeps the sidecar it merged onto', () {
      // `withArgs` rebuilds the entry field by field, and a sidecar dropped
      // there would be a preset with no `model-draft` on the very machines a
      // tier narrows.
      final prose = realManifest().byRole(ModelRole.prose);
      final narrowed = prose.withArgs(const {'c': '8192'});

      expect(narrowed.serverArgs['c'], '8192');
      expect(narrowed.sidecar, prose.sidecar);
      expect(narrowed.toSpec().draftFile, 'mtp-Qwen3.8-27B-Q4_0.gguf');
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
          [routerEmbedId, routerDecideId, routerBulkId, routerProseId]);
      expect(full.byRoleOrNull(ModelRole.prose)?.id, routerProseId);
      expect(full.models, manifest.models);
      expect(full.totalBytes, manifest.totalBytes);
    });

    test('the inbox tier drops the writing model and merges its args', () {
      final inbox = realManifest().forTier(MachineTier.inbox);

      expect([for (final m in inbox.models) m.id],
          [routerEmbedId, routerDecideId, routerBulkId]);
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
      expect(inbox.byRole(ModelRole.bulk).id, routerBulkId);
    });

    test('the download total and order follow the tier', () {
      final manifest = realManifest();
      final inbox = manifest.forTier(MachineTier.inbox);

      // The inbox tier never takes the writing model, so it never takes the
      // head either; the decision model is downloaded on both tiers, its
      // GGUF and its heads file.
      expect(inbox.totalBytes, 639150592 + 791461056 + 1032653 + 4280403520);
      expect(
        manifest.totalBytes,
        639150592 + 791461056 + 1032653 + 4280403520 + 18973870432 +
            1680271648,
      );
      expect([for (final m in inbox.downloadable.bySize) m.id],
          [routerEmbedId, routerDecideId, routerBulkId]);
      expect(
        [
          for (final m in manifest.forTier(MachineTier.full).downloadable.bySize)
            m.id,
        ],
        [routerEmbedId, routerDecideId, routerBulkId, routerProseId],
      );
      // And the gating view never holds it, on either tier.
      expect([for (final m in inbox.gating.models) m.id],
          [routerEmbedId, routerBulkId]);
    });

    group('forRoles', () {
      List<String> ids(ModelManifest m) => [for (final f in m.models) f.id];

      test('everything managed on the full tier is the whole tier', () {
        final view = realManifest().forRoles(
          hardwareTier: MachineTier.full,
          decisionManaged: true,
          generativeManagedId: routerProseId,
        );
        expect(ids(view), [routerEmbedId, routerDecideId, routerProseId]);
      });

      test('the 4B on the full tier drops the 27B', () {
        final view = realManifest().forRoles(
          hardwareTier: MachineTier.full,
          decisionManaged: true,
          generativeManagedId: routerBulkId,
        );
        expect(ids(view), [routerEmbedId, routerDecideId, routerBulkId]);
      });

      test('the inbox tier merges its args onto the managed 4B', () {
        final view = realManifest().forRoles(
          hardwareTier: MachineTier.inbox,
          decisionManaged: true,
          generativeManagedId: routerBulkId,
        );
        expect(ids(view), [routerEmbedId, routerDecideId, routerBulkId]);
        expect(view.byId(routerBulkId).serverArgs['parallel'], '2');
      });

      test('the 27B is never served on the inbox tier, whatever is asked', () {
        final view = realManifest().forRoles(
          hardwareTier: MachineTier.inbox,
          decisionManaged: false,
          generativeManagedId: routerProseId,
        );
        expect(ids(view), [routerEmbedId]);
      });

      test('both roles on your server leave the embedding model alone', () {
        final view = realManifest().forRoles(
          hardwareTier: MachineTier.full,
          decisionManaged: false,
          generativeManagedId: null,
        );
        expect(ids(view), [routerEmbedId]);
      });

      test('generative remote, decision here: embed and decide', () {
        final view = realManifest().forRoles(
          hardwareTier: MachineTier.full,
          decisionManaged: true,
          generativeManagedId: null,
        );
        expect(ids(view), [routerEmbedId, routerDecideId]);
        // The download view keeps the registry's decision model; the gating
        // view does not.
        expect(ids(view.downloadable), [routerEmbedId, routerDecideId]);
        expect(ids(view.gating), [routerEmbedId]);
      });
    });

    group('withPresentFiles', () {
      late Directory folder;
      setUp(() => folder = Directory.systemTemp.createTempSync('manifest'));
      tearDown(() => folder.deleteSync(recursive: true));

      void touch(String relative) =>
          File('${folder.path}/$relative')..createSync(recursive: true);

      List<String> kept(ModelManifest manifest) => [
            for (final m in manifest.withPresentFiles(folder.path).models) m.id,
          ];

      test('drops the decision model until both of its files are there', () {
        final manifest = realManifest().forTier(MachineTier.full);
        final decide = manifest.byId(routerDecideId);

        expect(kept(manifest), isNot(contains(routerDecideId)));
        touch(decide.relativePath);
        expect(kept(manifest), isNot(contains(routerDecideId)));
        touch(decide.headsRelativePath!);
        expect(kept(manifest), contains(routerDecideId));
      });

      test('a chosen generative model that was never downloaded leaves the '
          'preset, and embed and decide stay', () {
        // A full Mac that downloaded embed + 27B, then chose the 4B.
        final served = realManifest().forRoles(
          hardwareTier: MachineTier.full,
          decisionManaged: true,
          generativeManagedId: routerBulkId,
        );
        for (final m in served.models) {
          if (m.id == routerBulkId) continue;
          touch(m.relativePath);
          if (m.headsRelativePath case final heads?) touch(heads);
        }

        expect(kept(served), [
          for (final m in served.models)
            if (m.id != routerBulkId) m.id,
        ]);
        expect(kept(served), containsAll([routerEmbedId, routerDecideId]));
        // And the preset built from it names no missing file, so the
        // server's preflight lets the other models start.
        final preset = served.withPresentFiles(folder.path).toPreset(folder.path);
        expect(preset.missingFiles(), isEmpty);

        touch(served.byId(routerBulkId).relativePath);
        expect(kept(served), contains(routerBulkId));
      });

      test('the 27B needs its MTP head too', () {
        final served = realManifest().forRoles(
          hardwareTier: MachineTier.full,
          decisionManaged: false,
          generativeManagedId: routerProseId,
        );
        final prose = served.byId(routerProseId);
        touch(prose.relativePath);
        expect(kept(served), isNot(contains(routerProseId)));
        touch(prose.sidecarRelativePath!);
        expect(kept(served), contains(routerProseId));
      });

      test('the embedding model is kept even when missing, so the preflight '
          'still says so', () {
        final served = realManifest().forRoles(
          hardwareTier: MachineTier.full,
          decisionManaged: false,
          generativeManagedId: null,
        );
        expect(kept(served), [routerEmbedId]);
        expect(
          served.withPresentFiles(folder.path).toPreset(folder.path)
              .missingFiles(),
          isNotEmpty,
        );
      });
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
      const one =
          ModelManifest(version: ModelManifest.manifestVersion, models: []);
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
      'a sidecar sha256 of the wrong length',
      manifestText([
        embedJson(),
        bulkJson(),
        {...proseJson(), 'sidecar': {...sidecarJson(), 'sha256': 'abc123'}},
      ]),
      equals('manifest: "sidecar.sha256" must be 64 lower-case hex '
          'characters'),
    );

    refuses(
      'a sidecar revision that is a branch name',
      manifestText([
        embedJson(),
        bulkJson(),
        {...proseJson(), 'sidecar': {...sidecarJson(), 'revision': 'main'}},
      ]),
      startsWith('manifest: "sidecar.revision" must be a 40-character '
          'lower-case commit sha'),
    );

    refuses(
      'a sidecar with no size',
      manifestText([
        embedJson(),
        bulkJson(),
        {...proseJson(), 'sidecar': {...sidecarJson(), 'sizeBytes': 0}},
      ]),
      equals('manifest: "sidecar.sizeBytes" must be positive'),
    );

    refuses(
      'a sidecar with no file name',
      manifestText([
        embedJson(),
        bulkJson(),
        {...proseJson(), 'sidecar': {...sidecarJson(), 'file': ''}},
      ]),
      equals('manifest: "sidecar.file" must be a non-empty string'),
    );

    refuses(
      'a sidecar that is not an object',
      manifestText([
        embedJson(),
        bulkJson(),
        {...proseJson(), 'sidecar': 'mtp-Qwen3.8-27B-Q4_0.gguf'},
      ]),
      equals('manifest: "sidecar" must be an object or null'),
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
      jsonEncode({'version': ModelManifest.manifestVersion, 'models': models}),
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
          tiers: [
            fullTierJson(),
            fullTierJson(),
            inboxTierJson(),
          ]),
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

    // Every tier must hold the 4B, the one generative model every Mac can
    // run; the full tier is the one a careless edit would drop it from.
    refuses(
      'a full tier without the inbox model',
      manifestText(models, tiers: [
        {
          ...fullTierJson(),
          'models': [routerEmbedId, routerProseId],
        },
        inboxTierJson(),
      ]),
      allOf(contains('full'), contains(routerBulkId)),
    );

    refuses(
      'a local entry outside the local/ repo namespace',
      manifestText([
        ...models,
        {...decideJson(), 'repo': 'someone/bond-decide'},
      ]),
      allOf(contains('local'), contains('someone/bond-decide')),
    );

    refuses(
      'a source this build does not know',
      manifestText([
        ...models,
        {...decideJson(), 'source': 's3'},
      ]),
      allOf(contains('"source"'), contains('artifactory'), contains('s3')),
    );

    refuses(
      'a registry entry outside the artifactory/ repo namespace',
      manifestText([
        ...models,
        {...registryDecideJson(), 'repo': 'bond-decide-mbl-v3swap'},
      ]),
      allOf(contains('artifactory'), contains('bond-decide-mbl-v3swap')),
    );

    refuses(
      'a registry entry with no bundle',
      manifestText([
        ...models,
        Map.of(registryDecideJson())..remove('bundle'),
      ]),
      contains('"bundle"'),
    );

    refuses(
      'a registry entry with an empty bundle',
      manifestText([
        ...models,
        {...registryDecideJson(), 'bundle': ''},
      ]),
      contains('"bundle"'),
    );

    refuses(
      'a registry entry with no remote file',
      manifestText([
        ...models,
        Map.of(registryDecideJson())..remove('remoteFile'),
      ]),
      contains('"remoteFile"'),
    );

    refuses(
      'a registry entry whose revision is not a commit sha',
      manifestText([
        ...models,
        {...registryDecideJson(), 'revision': 'main'},
      ]),
      contains('revision'),
    );

    refuses(
      'a heads record on a Hugging Face entry',
      manifestText([
        {
          ...embedJson(),
          'heads': registryDecideJson()['heads'],
        },
        bulkJson(),
        proseJson(),
      ]),
      allOf(contains('"heads"'), contains('artifactory')),
    );

    for (final bad in ['a/b', 'a b', 'x?y', 'x#y', '..', '.', 'é']) {
      refuses(
        'a registry bundle "$bad"',
        manifestText([
          ...models,
          {
            ...registryDecideJson(),
            'bundle': bad,
            'repo': 'artifactory/$bad',
          },
        ]),
        contains('"bundle"'),
      );
    }

    refuses(
      'a registry remote file that walks out of the bundle',
      manifestText([
        ...models,
        {...registryDecideJson(), 'remoteFile': '../model-f16.gguf'},
      ]),
      contains('"remoteFile"'),
    );

    refuses(
      'a registry remote file of ".."',
      manifestText([
        ...models,
        {...registryDecideJson(), 'remoteFile': '..'},
      ]),
      contains('"remoteFile"'),
    );

    refuses(
      'a heads remote file with a query in it',
      manifestText([
        ...models,
        {
          ...registryDecideJson(),
          'heads': {
            ...(registryDecideJson()['heads']! as Map<String, Object?>),
            'remoteFile': 'heads.json?x=1',
          },
        },
      ]),
      contains('heads.remoteFile'),
    );

    refuses(
      'a sidecar on a registry entry',
      manifestText([
        ...models,
        {...registryDecideJson(), 'sidecar': sidecarJson()},
      ]),
      allOf(contains('artifactory'), contains('sidecar')),
    );

    refuses(
      'a registry repo that is not artifactory/<bundle>',
      manifestText([
        ...models,
        {...registryDecideJson(), 'repo': 'artifactory/another-bundle'},
      ]),
      allOf(contains('artifactory/bond-decide-mbl-v3swap'),
          contains('artifactory/another-bundle')),
    );

    refuses(
      'a heads record with an empty remote file',
      manifestText([
        ...models,
        {
          ...registryDecideJson(),
          'heads': {
            ...(registryDecideJson()['heads']! as Map<String, Object?>),
            'remoteFile': '',
          },
        },
      ]),
      contains('heads.remoteFile'),
    );

    refuses(
      'a downloaded entry with no revision',
      manifestText([
        Map.of(embedJson())..remove('revision'),
        bulkJson(),
        proseJson(),
      ]),
      contains('revision'),
    );

    refuses(
      'a heads record with a bad digest',
      manifestText([
        ...models,
        {
          ...decideJson(),
          'heads': {
            'file': 'decide-heads.json',
            'sha256': 'abc',
            'sizeBytes': 1,
          },
        },
      ]),
      contains('heads.sha256'),
    );

    refuses(
      'two decision models',
      manifestText([...models, decideJson(), decideJson()]),
      anyOf(contains('duplicate'), contains('decide')),
    );
  });

  group('parse accepts', () {
    test('a manifest without a decision model (a build that ships none)', () {
      final manifest = ModelManifest.parse(
        manifestText([embedJson(), bulkJson(), proseJson()]),
      );
      expect(manifest.byRoleOrNull(ModelRole.decide), isNull);
    });

    test('a hand-installed decision model in place of the registry one', () {
      final manifest = ModelManifest.parse(manifestText(
          [embedJson(), decideJson(), bulkJson(), proseJson()]));
      expect(manifest.byRole(ModelRole.decide).isLocal, isTrue);
    });

    test('a bundle on a hub entry is ignored, as every unknown key is', () {
      final embed = ModelFile.fromJson({
        ...embedJson(),
        'bundle': 'x',
        'remoteFile': 'y',
      });
      expect(embed.bundle, isNull);
      expect(embed.remoteFile, isNull);
      expect(embed.isRegistry, isFalse);
      expect(embed.gatesSetup, isTrue);
    });
  });
}
