import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import '../llm/model_slots.dart';
import '../server/router_preset.dart';

/// Which of the three jobs a checkpoint fills.
///
/// The role and not the checkpoint is what the rest of the app knows about —
/// the same reasoning `routerProseId` and friends record in
/// `model_slots.dart`. A manifest that named two prose models would leave the
/// preset with two sections claiming one id, so [ModelManifest] refuses it.
enum ModelRole { embed, bulk, prose }

ModelRole _roleFrom(String value) => switch (value) {
      'embed' => ModelRole.embed,
      'bulk' => ModelRole.bulk,
      'prose' => ModelRole.prose,
      _ => throw FormatException('manifest: unknown role "$value"'),
    };

String _roleName(ModelRole role) => switch (role) {
      ModelRole.embed => 'embed',
      ModelRole.bulk => 'bulk',
      ModelRole.prose => 'prose',
    };

/// The id the router preset gives each role — `model_slots.dart` owns these
/// strings, and every request the app makes carries one of them.
const Map<ModelRole, String> _idForRole = {
  ModelRole.embed: routerEmbedId,
  ModelRole.bulk: routerBulkId,
  ModelRole.prose: routerProseId,
};

final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');
final RegExp _hex40 = RegExp(r'^[0-9a-f]{40}$');

/// One downloadable checkpoint: what it is, where it comes from, what it must
/// hash to, and the flags the router loads it with.
///
/// Everything the downloader and the preset need about a model sits in ONE
/// record, because they have to agree: the preset points llama-server at a
/// path, and the downloader is what puts a file there. [relativePath] is the
/// single derivation of that path and it repeats [RouterPreset.modelPath]'s
/// rule exactly — the preset owns the folder, this owns the rest.
@immutable
class ModelFile {
  final String id;
  final ModelRole role;
  final String displayName;

  /// The Hugging Face repo, `owner/name`.
  final String repo;

  /// The artefact inside it. Kept apart from [repo] because the resolve URL
  /// wants both halves and so does the on-disk layout.
  final String file;

  /// The repo revision as a COMMIT SHA, never `main`.
  ///
  /// A branch name is a moving target: the file behind `main` can be replaced
  /// upstream, and a download that resolved through it would fetch bytes that
  /// no longer match [sha256] — a checksum failure the user cannot act on and
  /// this app would have caused. Pinning the commit makes the manifest the
  /// only thing that decides which bytes are wanted.
  final String revision;

  final int sizeBytes;

  /// Lower-case hex sha256 of the finished file, from the hub's LFS oid.
  final String sha256;

  /// What the machine needs to have to run it at all — 0 when it always
  /// fits. Phase 4's preflight reads it; nothing here refuses on it.
  final int minRamBytes;

  final String license;
  final String licenseUrl;

  /// The attribution a licence requires to be shown, when it requires one.
  /// Null for the permissive ones, so a screen can skip the line entirely.
  final String? notice;

  /// llama-server's long flags with the leading dashes stripped, the spelling
  /// the preset INI wants. Values are strings because the INI writer prints
  /// them verbatim.
  final Map<String, String> serverArgs;

  const ModelFile({
    required this.id,
    required this.role,
    required this.displayName,
    required this.repo,
    required this.file,
    required this.revision,
    required this.sizeBytes,
    required this.sha256,
    required this.minRamBytes,
    required this.license,
    required this.licenseUrl,
    this.notice,
    this.serverArgs = const {},
  });

  static String _string(Map<String, Object?> json, String field) {
    final value = json[field];
    if (value is! String || value.isEmpty) {
      throw FormatException('manifest: "$field" must be a non-empty string');
    }
    return value;
  }

  static int _int(Map<String, Object?> json, String field) {
    final value = json[field];
    if (value is! num) {
      throw FormatException('manifest: "$field" must be a number');
    }
    return value.toInt();
  }

  factory ModelFile.fromJson(Map<String, Object?> json) {
    final id = _string(json, 'id');
    final role = _roleFrom(_string(json, 'role'));
    final revision = _string(json, 'revision');
    if (!_hex40.hasMatch(revision)) {
      throw FormatException(
        'manifest: "revision" must be a 40-character lower-case commit sha, '
        'not "$revision"',
      );
    }
    final digest = _string(json, 'sha256');
    if (!_hex64.hasMatch(digest)) {
      throw FormatException(
        'manifest: "sha256" must be 64 lower-case hex characters',
      );
    }
    final sizeBytes = _int(json, 'sizeBytes');
    if (sizeBytes <= 0) {
      throw const FormatException('manifest: "sizeBytes" must be positive');
    }
    final minRamBytes = _int(json, 'minRamBytes');
    if (minRamBytes < 0) {
      throw const FormatException('manifest: "minRamBytes" must not be negative');
    }
    final notice = json['notice'];
    if (notice != null && notice is! String) {
      throw const FormatException('manifest: "notice" must be a string or null');
    }
    final args = json['serverArgs'];
    if (args != null && args is! Map) {
      throw const FormatException('manifest: "serverArgs" must be an object');
    }
    final serverArgs = <String, String>{};
    if (args is Map) {
      args.forEach((key, value) {
        if (value is! String) {
          throw FormatException(
            'manifest: "serverArgs.$key" must be a string — the INI writer '
            'prints it verbatim',
          );
        }
        serverArgs['$key'] = value;
      });
    }
    return ModelFile(
      id: id,
      role: role,
      displayName: _string(json, 'displayName'),
      repo: _string(json, 'repo'),
      file: _string(json, 'file'),
      revision: revision,
      sizeBytes: sizeBytes,
      sha256: digest,
      minRamBytes: minRamBytes,
      license: _string(json, 'license'),
      licenseUrl: _string(json, 'licenseUrl'),
      notice: notice as String?,
      serverArgs: Map.unmodifiable(serverArgs),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'role': _roleName(role),
        'displayName': displayName,
        'repo': repo,
        'file': file,
        'revision': revision,
        'sizeBytes': sizeBytes,
        'sha256': sha256,
        'minRamBytes': minRamBytes,
        'license': license,
        'licenseUrl': licenseUrl,
        'notice': notice,
        'serverArgs': serverArgs,
      };

  /// `<repo with '/' → '_'>/<file>` — the same rule as
  /// [RouterPreset.modelPath], one folder per repo so a half-finished
  /// download is obvious to a person looking at the directory.
  String get relativePath => '${repo.replaceAll('/', '_')}/$file';

  /// The hub URL that redirects to the CDN copy of these exact bytes.
  Uri get resolveUri =>
      Uri.parse('https://huggingface.co/$repo/resolve/$revision/$file');

  RouterModelSpec toSpec() =>
      RouterModelSpec(id: id, repo: repo, file: file, args: serverArgs);

  @override
  bool operator ==(Object other) =>
      other is ModelFile &&
      other.id == id &&
      other.role == role &&
      other.displayName == displayName &&
      other.repo == repo &&
      other.file == file &&
      other.revision == revision &&
      other.sizeBytes == sizeBytes &&
      other.sha256 == sha256 &&
      other.minRamBytes == minRamBytes &&
      other.license == license &&
      other.licenseUrl == licenseUrl &&
      other.notice == notice &&
      _sameArgs(other.serverArgs, serverArgs);

  static bool _sameArgs(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        id,
        role,
        displayName,
        repo,
        file,
        revision,
        sizeBytes,
        sha256,
        minRamBytes,
        license,
        licenseUrl,
        notice,
        Object.hashAll([
          for (final key in serverArgs.keys.toList()..sort())
            '$key=${serverArgs[key]}',
        ]),
      );

  @override
  String toString() => 'ModelFile($id, $repo/$file @ '
      '${revision.substring(0, 7)}, $sizeBytes B)';
}

/// Which checkpoints this build downloads, as a committed asset.
///
/// An ASSET rather than a table of Dart constants, and that is the whole
/// point of this file. Bumping a model — a new quantisation, a re-uploaded
/// GGUF, a different 27B — must not need a code change, and the diff of one
/// bump must be legible on its own: three fields in one JSON file, reviewable
/// without reading Dart. It is also the only place the three checkpoints are
/// named, so the preset, the downloader and the licence screen cannot drift
/// apart from each other.
///
/// It is versioned so a future shape change can refuse an old file loudly
/// rather than read half of it.
@immutable
class ModelManifest {
  final int version;

  /// In MANIFEST order, which is the order the INI's sections take.
  final List<ModelFile> models;

  const ModelManifest({required this.version, required this.models});

  static const String assetPath = 'assets/models/manifest.json';

  factory ModelManifest.fromJson(Map<String, Object?> json) {
    final version = json['version'];
    if (version is! num) {
      throw const FormatException('manifest: "version" must be a number');
    }
    if (version.toInt() != 1) {
      throw FormatException(
        'manifest: "version" ${version.toInt()} is not supported (this build '
        'reads version 1)',
      );
    }
    final raw = json['models'];
    if (raw is! List || raw.isEmpty) {
      throw const FormatException('manifest: "models" must be a non-empty list');
    }
    final models = <ModelFile>[];
    for (final entry in raw) {
      if (entry is! Map) {
        throw const FormatException('manifest: "models" must hold objects');
      }
      models.add(ModelFile.fromJson(entry.cast<String, Object?>()));
    }
    final ids = <String>{};
    for (final model in models) {
      if (!ids.add(model.id)) {
        throw FormatException('manifest: duplicate "id" ${model.id}');
      }
    }
    // Exactly one per role: the router routes on the id alone, and the app
    // asks for a role — a second prose model would have no way to be chosen
    // and a missing one would leave a slot pointing at nothing.
    for (final role in ModelRole.values) {
      final forRole = models.where((m) => m.role == role);
      if (forRole.length != 1) {
        throw FormatException(
          'manifest: "role" ${_roleName(role)} appears ${forRole.length} '
          'times, expected exactly once',
        );
      }
      // And it is the id the router routes on. Nothing at runtime consults
      // the role: the preset writes a section per id and every request names
      // one, so a manifest that filled the prose role under another id would
      // leave `routerProseId` pointing at a section that does not exist —
      // an empty answer at the first draft rather than a refusal now.
      final expected = _idForRole[role]!;
      final actual = forRole.first.id;
      if (actual != expected) {
        throw FormatException(
          'manifest: the ${_roleName(role)} model must have id "$expected", '
          'not "$actual"',
        );
      }
    }
    return ModelManifest(
      version: version.toInt(),
      models: List.unmodifiable(models),
    );
  }

  factory ModelManifest.parse(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const FormatException('manifest: the root must be an object');
    }
    return ModelManifest.fromJson(decoded.cast<String, Object?>());
  }

  /// Reads the committed asset. `main()` calls it once, after the binding is
  /// initialised and before `runApp`; a broken asset is a broken build and is
  /// allowed to throw.
  ///
  /// [bundle] is for tests, which have no asset bundle of their own.
  static Future<ModelManifest> load([AssetBundle? bundle]) async =>
      ModelManifest.parse(await (bundle ?? rootBundle).loadString(assetPath));

  Map<String, Object?> toJson() => {
        'version': version,
        'models': [for (final model in models) model.toJson()],
      };

  ModelFile byId(String id) => models.firstWhere(
        (m) => m.id == id,
        orElse: () => throw StateError('manifest: no model with id "$id"'),
      );

  ModelFile byRole(ModelRole role) => models.firstWhere(
        (m) => m.role == role,
        orElse: () =>
            throw StateError('manifest: no model for role ${_roleName(role)}'),
      );

  /// Ascending [ModelFile.sizeBytes] — the order the downloader works in, so
  /// the small models are usable while the large one is still arriving.
  List<ModelFile> get bySize =>
      [...models]..sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));

  int get totalBytes {
    var total = 0;
    for (final model in models) {
      total += model.sizeBytes;
    }
    return total;
  }

  /// The ids the inbox can work with before the prose model lands.
  ///
  /// Triage, extraction and search all run on the embedding and bulk models,
  /// so an install is USEFUL after four gigabytes rather than after
  /// twenty-three — which is what lets Phase 4 open the inbox mid-download.
  Set<String> get usableIds => {
        byRole(ModelRole.embed).id,
        byRole(ModelRole.bulk).id,
      };

  /// The preset the supervisor writes, pointed at [modelsFolder].
  RouterPreset toPreset(String modelsFolder) => RouterPreset(
        modelsFolder: modelsFolder,
        models: [for (final model in models) model.toSpec()],
      );

  @override
  bool operator ==(Object other) =>
      other is ModelManifest &&
      other.version == version &&
      other.models.length == models.length &&
      _sameModels(other.models, models);

  static bool _sameModels(List<ModelFile> a, List<ModelFile> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(version, Object.hashAll(models));

  @override
  String toString() =>
      'ModelManifest(v$version, ${models.map((m) => m.id).join(', ')})';
}
