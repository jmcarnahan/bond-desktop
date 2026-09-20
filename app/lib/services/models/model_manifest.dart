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

/// The tier ids the `tiers` array may use, spelled exactly as [MachineTier]
/// spells them, so the JSON and the enum cannot drift apart.
MachineTier _tierFrom(String value) {
  for (final tier in MachineTier.values) {
    if (tier.name == value) return tier;
  }
  throw FormatException(
    'manifest: tier "id" "$value" is not a machine tier, expected one of '
    '${MachineTier.values.map((t) => t.name).join(', ')}',
  );
}

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
  /// fits. Nothing refuses on it: which checkpoints a machine takes is the
  /// TIER's answer, and this number is what the wizard's device step quotes
  /// when it says why the writing model is not among them.
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

  /// The same checkpoint with [overrides] merged ONTO [serverArgs] — what a
  /// tier's `serverArgs` block produces on a resolved manifest.
  ///
  /// A merge rather than a replacement, because a tier that narrows the
  /// context has no business restating `load-on-startup`. Returns this file
  /// unchanged when there is nothing to merge, so the resolved view of the
  /// full tier is the manifest itself.
  ModelFile withArgs(Map<String, String>? overrides) {
    if (overrides == null || overrides.isEmpty) return this;
    return ModelFile(
      id: id,
      role: role,
      displayName: displayName,
      repo: repo,
      file: file,
      revision: revision,
      sizeBytes: sizeBytes,
      sha256: sha256,
      minRamBytes: minRamBytes,
      license: license,
      licenseUrl: licenseUrl,
      notice: notice,
      serverArgs: Map.unmodifiable({...serverArgs, ...overrides}),
    );
  }

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

/// One rung of the machine ladder: which checkpoints a machine of this size
/// downloads and starts, and the arguments it loads them with.
///
/// The ids are [ModelFile.id]s from the same manifest, so a tier cannot name a
/// checkpoint this build does not ship, and [serverArgs] holds per-id
/// overrides MERGED onto the entry's own arguments — a tier that only wants a
/// narrower context says so in one line rather than restating the entry.
@immutable
class ManifestTier {
  /// The rung, spelled as [MachineTier] spells it.
  final MachineTier tier;

  /// The memory at which this rung starts. Checked against [fullTierMinBytes]
  /// at parse time, so the JSON and the Dart constant cannot drift.
  final int minRamBytes;

  /// The ids this tier downloads and starts. A resolved manifest keeps
  /// MANIFEST order rather than this list's.
  final List<String> models;

  /// Per-id argument overrides, by [ModelFile.id].
  final Map<String, Map<String, String>> serverArgs;

  const ManifestTier({
    required this.tier,
    required this.minRamBytes,
    required this.models,
    this.serverArgs = const {},
  });

  factory ManifestTier.fromJson(Map<String, Object?> json) {
    final rawId = json['id'];
    if (rawId is! String || rawId.isEmpty) {
      throw const FormatException(
        'manifest: tier "id" must be a non-empty string',
      );
    }
    final tier = _tierFrom(rawId);
    final rawMin = json['minRamBytes'];
    if (rawMin is! num) {
      throw FormatException(
        'manifest: tier "$rawId" must give "minRamBytes" as a number',
      );
    }
    if (rawMin < 0) {
      throw FormatException(
        'manifest: tier "$rawId" has a negative "minRamBytes"',
      );
    }
    final rawModels = json['models'];
    if (rawModels is! List || rawModels.isEmpty) {
      throw FormatException(
        'manifest: tier "$rawId" must give "models" as a non-empty list',
      );
    }
    final models = <String>[];
    for (final entry in rawModels) {
      if (entry is! String || entry.isEmpty) {
        throw FormatException(
          'manifest: tier "$rawId" lists a model that is not an id string',
        );
      }
      if (models.contains(entry)) {
        throw FormatException(
          'manifest: tier "$rawId" lists "$entry" twice',
        );
      }
      models.add(entry);
    }
    final rawArgs = json['serverArgs'];
    if (rawArgs != null && rawArgs is! Map) {
      throw FormatException(
        'manifest: tier "$rawId" has a "serverArgs" that is not an object',
      );
    }
    final serverArgs = <String, Map<String, String>>{};
    if (rawArgs is Map) {
      rawArgs.forEach((id, value) {
        if (value is! Map) {
          throw FormatException(
            'manifest: tier "$rawId" serverArgs."$id" must be an object',
          );
        }
        if (!models.contains('$id')) {
          throw FormatException(
            'manifest: tier "$rawId" overrides serverArgs for "$id", which it '
            'does not list under "models"',
          );
        }
        final args = <String, String>{};
        value.forEach((key, arg) {
          if (arg is! String) {
            throw FormatException(
              'manifest: tier "$rawId" serverArgs."$id"."$key" must be a '
              'string — the INI writer prints it verbatim',
            );
          }
          args['$key'] = arg;
        });
        serverArgs['$id'] = Map.unmodifiable(args);
      });
    }
    return ManifestTier(
      tier: tier,
      minRamBytes: rawMin.toInt(),
      models: List.unmodifiable(models),
      serverArgs: Map.unmodifiable(serverArgs),
    );
  }

  Map<String, Object?> toJson() => {
        'id': tier.name,
        'minRamBytes': minRamBytes,
        'models': models,
        if (serverArgs.isNotEmpty) 'serverArgs': serverArgs,
      };

  @override
  bool operator ==(Object other) =>
      other is ManifestTier &&
      other.tier == tier &&
      other.minRamBytes == minRamBytes &&
      other.models.length == models.length &&
      _sameIds(other.models, models) &&
      _sameOverrides(other.serverArgs, serverArgs);

  /// INDEX-WISE, as [ModelManifest] compares its models, because [hashCode]
  /// hashes this list in order: a set-wise `==` would call two tiers equal
  /// that hash differently.
  static bool _sameIds(List<String> a, List<String> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameOverrides(
    Map<String, Map<String, String>> a,
    Map<String, Map<String, String>> b,
  ) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null || other.length != entry.value.length) return false;
      for (final arg in entry.value.entries) {
        if (other[arg.key] != arg.value) return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        tier,
        minRamBytes,
        Object.hashAll(models),
        Object.hashAll([
          for (final id in serverArgs.keys.toList()..sort())
            '$id:${_argsKey(serverArgs[id]!)}',
        ]),
      );

  /// One override map as a stable string, keys sorted — a map has no hash of
  /// its own that two equal maps agree on.
  static String _argsKey(Map<String, String> args) => [
        for (final key in args.keys.toList()..sort()) '$key=${args[key]}',
      ].join(',');

  @override
  String toString() =>
      'ManifestTier(${tier.name}, >= $minRamBytes B, ${models.join(', ')})';
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
/// It is versioned so a shape change can refuse an old file loudly rather
/// than read half of it. Version 2 added [tiers]; version 1 is refused.
///
/// TWO VIEWS of the same class. The one `main()` loads is the MASTER list:
/// every checkpoint this build knows, exactly one per role. [forTier] returns
/// a RESOLVED view holding only the checkpoints one machine wants, with that
/// tier's argument overrides merged in — and a resolved view may be missing
/// the prose model, which is the whole point. Everything downstream of the
/// wizard's device step reads the resolved view; [byRoleOrNull] is how a
/// caller asks for a role that a resolved view is allowed not to have.
@immutable
class ModelManifest {
  final int version;

  /// In MANIFEST order, which is the order the INI's sections take.
  final List<ModelFile> models;

  /// The machine ladder, one entry per [MachineTier]. Empty on a manifest
  /// built in code rather than parsed, which is what a test fixture of one
  /// model is; [forTier] then answers with the whole list.
  final List<ManifestTier> tiers;

  const ModelManifest({
    required this.version,
    required this.models,
    this.tiers = const [],
  });

  static const String assetPath = 'assets/models/manifest.json';

  /// The only shape this build reads. Bumped when the file's shape changes,
  /// which is what lets an older app refuse a newer manifest loudly.
  static const int manifestVersion = 2;

  factory ModelManifest.fromJson(Map<String, Object?> json) {
    final version = json['version'];
    if (version is! num) {
      throw const FormatException('manifest: "version" must be a number');
    }
    if (version.toInt() != manifestVersion) {
      throw FormatException(
        'manifest: "version" ${version.toInt()} is not supported (this build '
        'reads version $manifestVersion)',
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
    final tiers = _tiersFromJson(json['tiers'], models);
    return ModelManifest(
      version: version.toInt(),
      models: List.unmodifiable(models),
      tiers: tiers,
    );
  }

  /// The `tiers` array, checked against the models beside it.
  ///
  /// Five things have to hold, and each of them is a machine that would
  /// otherwise fail later and further away: every [MachineTier] is named
  /// exactly once (a tier with no entry is a Mac the wizard cannot answer
  /// for); every id a tier lists exists (a preset pointing at a section with
  /// no file); the embedding and inbox models are in every tier (the two the
  /// app cannot work without, and `usableIds` says so); the ladder starts at
  /// zero (no machine falls between two rungs); and the top rung starts
  /// exactly at [fullTierMinBytes], so this file and `model_slots.dart`
  /// cannot drift apart about where the writing model begins.
  static List<ManifestTier> _tiersFromJson(
    Object? raw,
    List<ModelFile> models,
  ) {
    if (raw is! List || raw.isEmpty) {
      throw const FormatException('manifest: "tiers" must be a non-empty list');
    }
    final tiers = <ManifestTier>[];
    for (final entry in raw) {
      if (entry is! Map) {
        throw const FormatException('manifest: "tiers" must hold objects');
      }
      tiers.add(ManifestTier.fromJson(entry.cast<String, Object?>()));
    }
    final seen = <MachineTier>{};
    for (final tier in tiers) {
      if (!seen.add(tier.tier)) {
        throw FormatException('manifest: duplicate tier "${tier.tier.name}"');
      }
    }
    for (final expected in MachineTier.values) {
      if (!seen.contains(expected)) {
        throw FormatException(
          'manifest: "tiers" names no "${expected.name}" tier',
        );
      }
    }
    final ids = {for (final model in models) model.id};
    for (final tier in tiers) {
      for (final id in tier.models) {
        if (!ids.contains(id)) {
          throw FormatException(
            'manifest: tier "${tier.tier.name}" lists "$id", which is not a '
            'model in this manifest',
          );
        }
      }
      // Every tier serves the embedding model, because vectors are written on
      // this Mac whatever the placement. Only the memory rungs must also serve
      // the bulk model: the remote tier's inbox stages are on the box.
      final roles = tier.tier == MachineTier.remote
          ? const [ModelRole.embed]
          : const [ModelRole.embed, ModelRole.bulk];
      for (final role in roles) {
        final required = _idForRole[role]!;
        if (!tier.models.contains(required)) {
          throw FormatException(
            'manifest: tier "${tier.tier.name}" must list the '
            '${_roleName(role)} model "$required"',
          );
        }
      }
    }
    for (final tier in tiers) {
      if (tier.tier == MachineTier.remote && tier.minRamBytes != 0) {
        throw FormatException(
          'manifest: the "${MachineTier.remote.name}" tier is a placement '
          'rather than a memory rung and must have "minRamBytes" 0, not '
          '${tier.minRamBytes}',
        );
      }
    }
    // The ladder is the MEMORY rungs alone. With the remote tier in it there
    // would be two rungs at zero bytes, an unstable sort would pick either as
    // the lowest, and the message below would name the wrong tier.
    final ladder = [
      for (final tier in tiers)
        if (tier.tier != MachineTier.remote) tier,
    ]..sort((a, b) => a.minRamBytes.compareTo(b.minRamBytes));
    if (ladder.first.minRamBytes != 0) {
      throw FormatException(
        'manifest: the lowest tier "${ladder.first.tier.name}" must have '
        '"minRamBytes" 0, not ${ladder.first.minRamBytes}',
      );
    }
    final top = ladder.last;
    if (top.tier != MachineTier.full || top.minRamBytes != fullTierMinBytes) {
      throw FormatException(
        'manifest: the "${MachineTier.full.name}" tier must have '
        '"minRamBytes" $fullTierMinBytes, the fullTierMinBytes this build was '
        'compiled with, not ${top.minRamBytes} on "${top.tier.name}"',
      );
    }
    return List.unmodifiable(tiers);
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
        'tiers': [for (final tier in tiers) tier.toJson()],
      };

  ModelFile byId(String id) => models.firstWhere(
        (m) => m.id == id,
        orElse: () => throw StateError('manifest: no model with id "$id"'),
      );

  /// The checkpoint filling [role], or null when this manifest has none.
  ///
  /// A MASTER manifest always has all three; a view from [forTier] may not,
  /// and the inbox tier deliberately does not have a prose model. Every
  /// caller that can be handed a resolved view asks through this one.
  ModelFile? byRoleOrNull(ModelRole role) {
    for (final model in models) {
      if (model.role == role) return model;
    }
    return null;
  }

  /// The checkpoint filling [role]. THROWS when there is none, so it is for
  /// the master manifest and for the two roles every tier carries; a caller
  /// holding a resolved view wants [byRoleOrNull].
  ModelFile byRole(ModelRole role) =>
      byRoleOrNull(role) ??
      (throw StateError('manifest: no model for role ${_roleName(role)}'));

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

  /// The two smallest ids — the embedding and bulk models, INFORMATIONAL.
  ///
  /// Nothing gates on this set. The wizard's Continue and
  /// `ModelServerSupervisor._launch` both wait for every file the RESOLVED
  /// manifest names, because the preset names every file and the server
  /// refuses to start with one of them missing. It is here for a screen that
  /// wants to say which models the inbox itself leans on, and for the
  /// downloader's smallest-first order.
  ///
  /// A MASTER-manifest read: it asks for the bulk model, which a
  /// [MachineTier.remote] view does not carry, so it throws on one. Nothing in
  /// `lib/` calls it.
  Set<String> get usableIds => {
        byRole(ModelRole.embed).id,
        byRole(ModelRole.bulk).id,
      };

  /// This manifest as [tier] wants it: only that tier's checkpoints, with its
  /// argument overrides merged onto each entry.
  ///
  /// The RESOLVED view is what the wizard's rows and total, the disk
  /// preflight, the download run, the ledger check and the preset are all
  /// built from, so a Mac under [fullTierMinBytes] downloads two files rather
  /// than three, starts two servers rather than three, and is never asked for
  /// a file its tier never wanted. The one-per-role rule is a MASTER-list
  /// rule and is not re-applied here: an inbox view has no prose model by
  /// design.
  ///
  /// A manifest with no [tiers] — one built in code rather than parsed —
  /// resolves to itself, so a fixture of one model needs no ladder.
  ModelManifest forTier(MachineTier tier) {
    if (tiers.isEmpty) return this;
    ManifestTier? spec;
    for (final candidate in tiers) {
      if (candidate.tier == tier) spec = candidate;
    }
    if (spec == null) {
      throw StateError('manifest: no tier "${tier.name}"');
    }
    final wanted = spec.models.toSet();
    return ModelManifest(
      version: version,
      models: List.unmodifiable([
        for (final model in models)
          if (wanted.contains(model.id))
            model.withArgs(spec.serverArgs[model.id]),
      ]),
      tiers: tiers,
    );
  }

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
      _sameModels(other.models, models) &&
      other.tiers.length == tiers.length &&
      _sameTiers(other.tiers, tiers);

  static bool _sameModels(List<ModelFile> a, List<ModelFile> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameTiers(List<ManifestTier> a, List<ManifestTier> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(version, Object.hashAll(models), Object.hashAll(tiers));

  @override
  String toString() =>
      'ModelManifest(v$version, ${models.map((m) => m.id).join(', ')})';
}
