import 'dart:convert';
import 'dart:io' show File;

import 'package:flutter/foundation.dart' show immutable;
import 'package:path/path.dart' as p;
import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import '../llm/model_slots.dart';
import '../server/router_preset.dart';
import 'download_state.dart' show DownloadLedger;

/// Which job a checkpoint fills — one FILE per role.
///
/// The role and not the checkpoint is what the rest of the app knows about —
/// the same reasoning `routerProseId` and friends record in
/// `model_slots.dart`. A manifest that named two prose models would leave the
/// preset with two sections claiming one id, so [ModelManifest] refuses it.
/// [bulk] (the 4B) and [prose] (the 27B) are the two files that can each fill
/// the GENERATIVE stage role; [decide] is the decision model.
enum ModelRole { embed, bulk, prose, decide }

ModelRole _roleFrom(String value) => switch (value) {
      'embed' => ModelRole.embed,
      'bulk' => ModelRole.bulk,
      'prose' => ModelRole.prose,
      'decide' => ModelRole.decide,
      _ => throw FormatException('manifest: unknown role "$value"'),
    };

String _roleName(ModelRole role) => switch (role) {
      ModelRole.embed => 'embed',
      ModelRole.bulk => 'bulk',
      ModelRole.prose => 'prose',
      ModelRole.decide => 'decide',
    };

/// The id the router preset gives each role — `model_slots.dart` owns these
/// strings, and every request the app makes carries one of them.
const Map<ModelRole, String> _idForRole = {
  ModelRole.embed: routerEmbedId,
  ModelRole.bulk: routerBulkId,
  ModelRole.prose: routerProseId,
  ModelRole.decide: routerDecideId,
};

/// Where a checkpoint's bytes come from: the Hugging Face hub, INSTALLED by
/// hand into the models folder and never downloaded, or the owner's model
/// REGISTRY (Artifactory), which serves a bundle's files at
/// `<registry base>/bundles/<bundle>/<remote file>` behind a bearer token.
const String sourceHf = 'hf';
const String sourceLocal = 'local';
const String sourceArtifactory = 'artifactory';

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

final RegExp _segment = RegExp(r'^[A-Za-z0-9._-]+$');

/// [value] when it can stand as one segment of a registry URL path — letters,
/// digits, `.`, `_`, `-`, and never `.` or `..` — so a bundle or file name
/// can neither change the URL's shape nor walk out of the bundle.
String _checkSegment(String value, String field) {
  if (!_segment.hasMatch(value) || value == '.' || value == '..') {
    throw FormatException(
      'manifest: "$field" must be letters, digits, ".", "_" or "-", and not '
      '"." or "..", not "$value"',
    );
  }
  return value;
}
final RegExp _hex40 = RegExp(r'^[0-9a-f]{40}$');

/// A SECOND file a checkpoint cannot be served without — today the MTP head
/// the prose model drafts with, which `RouterPreset` names as `model-draft`.
///
/// It has no `repo` of its own because it does not have one: the head is
/// published beside the weights it belongs to, which is how llama-server finds
/// it after an `-hf` download, and a sidecar from some other repo would be a
/// different model's draft. It carries its own [revision] all the same, so a
/// head republished on its own is a two-field edit rather than a manifest that
/// lies about which commit the bytes came from.
///
/// It is NOT a fourth [ModelFile]. Every entry in `models` is a section in the
/// preset INI and a role the router serves, and the parser allows exactly one
/// model per role; a draft head is neither. Nesting it here is what keeps
/// `--models-max` and the one-model-per-role rule true while the downloader
/// still fetches two files for one entry.
@immutable
class ModelSidecar {
  /// The artefact inside the PARENT's repo.
  final String file;

  /// The repo revision as a COMMIT SHA, on [ModelFile.revision]'s reasoning.
  final String revision;

  /// Lower-case hex sha256, from the hub's LFS oid.
  final String sha256;

  final int sizeBytes;

  const ModelSidecar({
    required this.file,
    required this.revision,
    required this.sha256,
    required this.sizeBytes,
  });

  /// The same rules [ModelFile.fromJson] applies to its own fields, with the
  /// messages PREFIXED, so a manifest that is wrong about the head says which
  /// half of the entry it is wrong about.
  static String _string(Map<String, Object?> json, String field) {
    final value = json[field];
    if (value is! String || value.isEmpty) {
      throw FormatException(
        'manifest: "sidecar.$field" must be a non-empty string',
      );
    }
    return value;
  }

  factory ModelSidecar.fromJson(Map<String, Object?> json) {
    final revision = _string(json, 'revision');
    if (!_hex40.hasMatch(revision)) {
      throw FormatException(
        'manifest: "sidecar.revision" must be a 40-character lower-case '
        'commit sha, not "$revision"',
      );
    }
    final digest = _string(json, 'sha256');
    if (!_hex64.hasMatch(digest)) {
      throw const FormatException(
        'manifest: "sidecar.sha256" must be 64 lower-case hex characters',
      );
    }
    final rawSize = json['sizeBytes'];
    if (rawSize is! num) {
      throw const FormatException('manifest: "sidecar.sizeBytes" must be a '
          'number');
    }
    final sizeBytes = rawSize.toInt();
    if (sizeBytes <= 0) {
      throw const FormatException(
        'manifest: "sidecar.sizeBytes" must be positive',
      );
    }
    return ModelSidecar(
      file: _string(json, 'file'),
      revision: revision,
      sha256: digest,
      sizeBytes: sizeBytes,
    );
  }

  Map<String, Object?> toJson() => {
        'file': file,
        'revision': revision,
        'sha256': sha256,
        'sizeBytes': sizeBytes,
      };

  @override
  bool operator ==(Object other) =>
      other is ModelSidecar &&
      other.file == file &&
      other.revision == revision &&
      other.sha256 == sha256 &&
      other.sizeBytes == sizeBytes;

  @override
  int get hashCode => Object.hash(file, revision, sha256, sizeBytes);

  @override
  String toString() =>
      'ModelSidecar($file @ ${revision.substring(0, 7)}, $sizeBytes B)';
}

/// The decision model's HEADS file: the nine linear heads and temperatures
/// that turn the pooled vector into answers, applied in Dart.
///
/// A sidecar of kind heads, NOT a [ModelSidecar]: `RouterPreset` never
/// names it (it is not a draft model and llama-server never reads it), and it
/// is needed even when a remote server embeds, because the heads run here.
/// For a registry entry the downloader fetches it as the entry's LAST leg,
/// sha-checked and ledgered under `<id>.heads`; for a `source: local` entry
/// it is installed by hand beside the GGUF.
@immutable
class ModelHeads {
  /// The file's name inside the parent's repo folder.
  final String file;

  /// Lower-case hex sha256.
  final String sha256;

  final int sizeBytes;

  /// The file's name in the registry bundle, when it is not [file]: the
  /// bundle says `heads.json`, and on disk it keeps the name the app reads.
  final String? remoteFile;

  const ModelHeads({
    required this.file,
    required this.sha256,
    required this.sizeBytes,
    this.remoteFile,
  });

  factory ModelHeads.fromJson(Map<String, Object?> json) {
    final file = json['file'];
    if (file is! String || file.isEmpty) {
      throw const FormatException(
        'manifest: "heads.file" must be a non-empty string',
      );
    }
    final digest = json['sha256'];
    if (digest is! String || !_hex64.hasMatch(digest)) {
      throw const FormatException(
        'manifest: "heads.sha256" must be 64 lower-case hex characters',
      );
    }
    final size = json['sizeBytes'];
    if (size is! num || size.toInt() <= 0) {
      throw const FormatException(
        'manifest: "heads.sizeBytes" must be a positive number',
      );
    }
    final remote = json['remoteFile'];
    if (remote != null && (remote is! String || remote.isEmpty)) {
      throw const FormatException(
        'manifest: "heads.remoteFile" must be a non-empty string or absent',
      );
    }
    return ModelHeads(
      file: file,
      sha256: digest,
      sizeBytes: size.toInt(),
      remoteFile: remote == null
          ? null
          : _checkSegment(remote as String, 'heads.remoteFile'),
    );
  }

  Map<String, Object?> toJson() => {
        'file': file,
        if (remoteFile != null) 'remoteFile': remoteFile,
        'sha256': sha256,
        'sizeBytes': sizeBytes,
      };

  @override
  bool operator ==(Object other) =>
      other is ModelHeads &&
      other.file == file &&
      other.sha256 == sha256 &&
      other.sizeBytes == sizeBytes &&
      other.remoteFile == remoteFile;

  @override
  int get hashCode => Object.hash(file, sha256, sizeBytes, remoteFile);

  @override
  String toString() => 'ModelHeads($file, $sizeBytes B)';
}

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

  /// The Hugging Face repo, `owner/name`; `local/<name>` for a hand-installed
  /// entry and `artifactory/<bundle>` for a registry one, whose prefixes keep
  /// their folders apart from every downloaded repo's.
  final String repo;

  /// The artefact inside it. Kept apart from [repo] because the resolve URL
  /// wants both halves and so does the on-disk layout.
  final String file;

  /// The repo revision as a COMMIT SHA, never `main`. EMPTY for a
  /// `source: local` entry, which has no repo to pin, and optional for a
  /// registry entry, whose bytes [sha256] pins on its own.
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

  /// The second file this checkpoint is served with, or null for the ones
  /// that are a single GGUF. See [ModelSidecar] for why it is nested here
  /// rather than being a fourth entry in `models`.
  final ModelSidecar? sidecar;

  /// [sourceHf] (the default), [sourceLocal] or [sourceArtifactory]. A
  /// local entry is installed by hand, never downloaded: its repo is
  /// `local/<name>`, it has no revision, it costs no download bytes, and the
  /// ledger never records it — whether it is installed is whether its files
  /// are on disk. A registry entry is downloaded like a hub one, from
  /// [registryUri], and the ledger records each of its files.
  final String source;

  /// The decision model's heads file, or null for every other entry.
  final ModelHeads? heads;

  /// The registry bundle this entry's files are published in, for a
  /// [sourceArtifactory] entry; null for every other source.
  final String? bundle;

  /// The weights' name inside [bundle] (`model-f16.gguf`). On disk the file
  /// keeps [file], the name the heads file's `model` must prefix. Null for
  /// every non-registry entry.
  final String? remoteFile;

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
    this.sidecar,
    this.source = sourceHf,
    this.heads,
    this.bundle,
    this.remoteFile,
  });

  /// Whether this entry is installed by hand rather than downloaded.
  bool get isLocal => source == sourceLocal;

  /// Whether this entry is downloaded from the model registry.
  bool get isRegistry => source == sourceArtifactory;

  /// Whether a missing or stale copy of this entry sends a finished install
  /// back through the wizard: Hugging Face entries only. Decision D7: a
  /// registry file is best-effort, because its address is set in Settings,
  /// which the wizard cannot reach, so it never reopens or blocks the wizard.
  bool get gatesSetup => source == sourceHf;

  static String _string(Map<String, Object?> json, String field) {
    final value = json[field];
    if (value is! String || value.isEmpty) {
      throw FormatException('manifest: "$field" must be a non-empty string');
    }
    return value;
  }

  /// A non-empty string that is safe as ONE segment of a registry URL path.
  static String _pathSegment(Map<String, Object?> json, String field) =>
      _checkSegment(_string(json, field), field);

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
    final rawSource = json['source'] ?? sourceHf;
    if (rawSource != sourceHf &&
        rawSource != sourceLocal &&
        rawSource != sourceArtifactory) {
      throw FormatException(
        'manifest: "source" must be "$sourceHf", "$sourceLocal" or '
        '"$sourceArtifactory", not "$rawSource"',
      );
    }
    final source = rawSource as String;
    final local = source == sourceLocal;
    final registry = source == sourceArtifactory;
    final repo = _string(json, 'repo');
    // A local entry has no hub repo, and the `local/` prefix is what keeps its
    // folder (`local_<name>`) from ever colliding with a downloaded one.
    if (local && !repo.startsWith('local/')) {
      throw FormatException(
        'manifest: a "source": "local" entry must have a "repo" of '
        '"local/<name>", not "$repo"',
      );
    }
    // The same rule for a registry entry's folder (`artifactory_<bundle>`).
    if (registry && !repo.startsWith('artifactory/')) {
      throw FormatException(
        'manifest: a "source": "artifactory" entry must have a "repo" of '
        '"artifactory/<bundle>", not "$repo"',
      );
    }
    final String revision;
    if ((local || registry) && json['revision'] == null) {
      revision = '';
    } else {
      revision = _string(json, 'revision');
      if (!_hex40.hasMatch(revision)) {
        throw FormatException(
          'manifest: "revision" must be a 40-character lower-case commit sha, '
          'not "$revision"',
        );
      }
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
    final rawSidecar = json['sidecar'];
    if (rawSidecar != null && rawSidecar is! Map) {
      throw const FormatException(
        'manifest: "sidecar" must be an object or null',
      );
    }
    final rawHeads = json['heads'];
    if (rawHeads != null && rawHeads is! Map) {
      throw const FormatException('manifest: "heads" must be an object or null');
    }
    // A heads file belongs to a registry entry, which downloads it as a leg
    // of its own, or to a hand-installed one. A hub entry has no way to fetch
    // one, and an entry that named it could never be current.
    if (rawHeads != null && !registry && !local) {
      throw const FormatException(
        'manifest: "heads" belongs to a "source": "artifactory" or "local" '
        'entry, not a Hugging Face one',
      );
    }
    // The registry's leg list is the weights and the heads: a sidecar has no
    // registry address to come from.
    if (registry && rawSidecar != null) {
      throw const FormatException(
        'manifest: a "source": "artifactory" entry cannot carry a "sidecar"',
      );
    }
    // Where the registry publishes the bytes. Not read on any other source,
    // the way every key this parser does not know is ignored.
    final bundle = registry ? _pathSegment(json, 'bundle') : null;
    final remoteFile = registry ? _pathSegment(json, 'remoteFile') : null;
    if (registry && repo != 'artifactory/$bundle') {
      throw FormatException(
        'manifest: a "source": "artifactory" entry must have the "repo" '
        '"artifactory/$bundle", not "$repo"',
      );
    }
    return ModelFile(
      id: id,
      role: role,
      displayName: _string(json, 'displayName'),
      repo: repo,
      file: _string(json, 'file'),
      revision: revision,
      sizeBytes: sizeBytes,
      sha256: digest,
      minRamBytes: minRamBytes,
      license: _string(json, 'license'),
      licenseUrl: _string(json, 'licenseUrl'),
      notice: notice as String?,
      serverArgs: Map.unmodifiable(serverArgs),
      sidecar: rawSidecar is Map
          ? ModelSidecar.fromJson(rawSidecar.cast<String, Object?>())
          : null,
      source: source,
      heads: rawHeads is Map
          ? ModelHeads.fromJson(rawHeads.cast<String, Object?>())
          : null,
      bundle: bundle,
      remoteFile: remoteFile,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'role': _roleName(role),
        if (source != sourceHf) 'source': source,
        'displayName': displayName,
        'repo': repo,
        if (bundle != null) 'bundle': bundle,
        if (remoteFile != null) 'remoteFile': remoteFile,
        'file': file,
        if (revision.isNotEmpty) 'revision': revision,
        'sizeBytes': sizeBytes,
        'sha256': sha256,
        'minRamBytes': minRamBytes,
        'license': license,
        'licenseUrl': licenseUrl,
        'notice': notice,
        'serverArgs': serverArgs,
        'sidecar': sidecar?.toJson(),
        if (heads != null) 'heads': heads!.toJson(),
      };

  /// `<repo with '/' → '_'>/<file>` — the same rule as
  /// [RouterPreset.modelPath], one folder per repo so a half-finished
  /// download is obvious to a person looking at the directory.
  String get relativePath => '${repo.replaceAll('/', '_')}/$file';

  /// The hub URL that redirects to the CDN copy of these exact bytes. Hugging
  /// Face's alone: a registry entry is fetched from [registryUri].
  Uri get resolveUri {
    if (isRegistry) {
      throw StateError('manifest: $id is a registry entry, use registryUri');
    }
    return Uri.parse('https://huggingface.co/$repo/resolve/$revision/$file');
  }

  /// The registry URL of this entry's weights,
  /// `<base>/bundles/<bundle>/<remoteFile>`, with [base] trimmed and its
  /// trailing slashes dropped (`normalizeBoxBaseUrl`). Throws [StateError]
  /// on a non-registry entry or an empty base.
  Uri registryUri(String base) => _registryUri(base, remoteFile);

  /// The registry URL of the heads file, by [registryUri]'s rule, or null
  /// for a registry entry without one. The bundle's name for it
  /// ([ModelHeads.remoteFile]) when it has one, else its name on disk.
  Uri? headsRegistryUri(String base) {
    if (!isRegistry) {
      throw StateError('manifest: $id is not a registry entry');
    }
    final h = heads;
    if (h == null) return null;
    return _registryUri(base, h.remoteFile ?? h.file);
  }

  Uri _registryUri(String base, String? name) {
    if (!isRegistry || bundle == null || name == null) {
      throw StateError('manifest: $id is not a registry entry');
    }
    final root = normalizeBoxBaseUrl(base);
    if (root.isEmpty) {
      throw StateError('manifest: no registry address for $id');
    }
    return Uri.parse('$root/bundles/$bundle/$name');
  }

  /// The sidecar's path, by the same two rules, in the PARENT's repo folder —
  /// null when there is no sidecar. One folder per repo means the head lands
  /// beside the weights it belongs to, which is also where the preset's
  /// `model-draft` points.
  String? get sidecarRelativePath {
    final head = sidecar;
    if (head == null) return null;
    return '${repo.replaceAll('/', '_')}/${head.file}';
  }

  /// The hub URL for the sidecar's bytes, at the SIDECAR's revision.
  Uri? get sidecarResolveUri {
    if (isRegistry) {
      throw StateError('manifest: $id is a registry entry, use registryUri');
    }
    final head = sidecar;
    if (head == null) return null;
    return Uri.parse(
      'https://huggingface.co/$repo/resolve/${head.revision}/${head.file}',
    );
  }

  /// Where the heads file lands, in the parent's repo folder, or null for an
  /// entry without one.
  String? get headsRelativePath {
    final h = heads;
    if (h == null) return null;
    return '${repo.replaceAll('/', '_')}/${h.file}';
  }

  /// Every byte this entry costs a download — the weights and the sidecar,
  /// and for a registry entry the heads file too, its last leg. What the
  /// wizard's total, the disk preflight and one progress bar all count,
  /// because one entry is one row on the screen whatever it fetches. ZERO for
  /// a local entry, which is never downloaded.
  int get downloadBytes {
    if (isLocal) return 0;
    final weights = sizeBytes + (sidecar?.sizeBytes ?? 0);
    return isRegistry ? weights + (heads?.sizeBytes ?? 0) : weights;
  }

  RouterModelSpec toSpec() => RouterModelSpec(
        id: id,
        repo: repo,
        file: file,
        draftFile: sidecar?.file,
        args: serverArgs,
      );

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
      sidecar: sidecar,
      source: source,
      heads: heads,
      bundle: bundle,
      remoteFile: remoteFile,
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
      other.sidecar == sidecar &&
      other.source == source &&
      other.heads == heads &&
      other.bundle == bundle &&
      other.remoteFile == remoteFile &&
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
        sidecar,
        source,
        heads,
        bundle,
        remoteFile,
        Object.hashAll([
          for (final key in serverArgs.keys.toList()..sort())
            '$key=${serverArgs[key]}',
        ]),
      );

  @override
  String toString() => 'ModelFile($id, $repo/$file @ $_pin, $sizeBytes B)';

  /// What the entry is pinned at, for [toString]: never a substring of an
  /// empty revision, which a registry entry usually has.
  String get _pin {
    if (isLocal) return 'local';
    if (isRegistry) return 'bundle $bundle';
    return revision.length > 7 ? revision.substring(0, 7) : revision;
  }
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
/// than read half of it. Version 2 added [tiers], version 3 the registry
/// source (`artifactory`); older versions are refused.
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
  static const int manifestVersion = 3;

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
    //
    // The decision model is the one role that may be ABSENT: a build that
    // ships none simply has no managed decision model (the decision pass
    // parks). At most once all
    // the same, for the router's reason.
    for (final role in ModelRole.values) {
      final forRole = models.where((m) => m.role == role);
      if (role == ModelRole.decide && forRole.isEmpty) continue;
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
  /// no file); the embedding and 4B models are in every tier (the embedding
  /// model always runs here, and the 4B is the generative model every Mac can
  /// hold); the ladder starts at
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
      // Every tier holds the embedding model, because vectors are written on
      // this Mac whatever the placements, and the 4B, the one generative model
      // every Mac can run.
      for (final role in const [ModelRole.embed, ModelRole.bulk]) {
        final required = _idForRole[role]!;
        if (!tier.models.contains(required)) {
          throw FormatException(
            'manifest: tier "${tier.tier.name}" must list the '
            '${_roleName(role)} model "$required"',
          );
        }
      }
    }
    final ladder = [...tiers]
      ..sort((a, b) => a.minRamBytes.compareTo(b.minRamBytes));
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

  /// Every byte this manifest asks the network for, sidecars included — the
  /// number the wizard quotes and the disk preflight budgets against. A
  /// sidecar is not a row of its own anywhere, so it must not be a total of
  /// its own either.
  int get totalBytes {
    var total = 0;
    for (final model in models) {
      total += model.downloadBytes;
    }
    return total;
  }

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

  /// What this Mac SERVES under the role placements: the embedding model,
  /// the decision model when it runs here, and the managed generative model
  /// when that runs here — out of [hardwareTier]'s view, with its argument
  /// overrides merged as [forTier] merges them.
  ///
  /// [generativeManagedId] is the router id of the managed generative model
  /// (`bond-prose` or `bond-bulk`), or null when the generative model runs on
  /// the owner's server. An id the tier does not hold is simply absent: the
  /// caller resolved it through `managedGenerativeIdFor`, which never answers
  /// the 27B on the inbox tier.
  ModelManifest forRoles({
    required MachineTier hardwareTier,
    required bool decisionManaged,
    required String? generativeManagedId,
  }) {
    final view = forTier(hardwareTier);
    return ModelManifest(
      version: version,
      models: List.unmodifiable([
        for (final model in view.models)
          if (model.role == ModelRole.embed ||
              (decisionManaged && model.role == ModelRole.decide) ||
              (generativeManagedId != null && model.id == generativeManagedId))
            model,
      ]),
      tiers: tiers,
    );
  }

  /// The entries this build DOWNLOADS: every one but the `source: local`
  /// ones, so a registry entry is here. The wizard's rows and total, the disk
  /// preflight and the download run read this view, so a hand-installed
  /// model never shows a bar that cannot move.
  ModelManifest get downloadable => ModelManifest(
        version: version,
        models: List.unmodifiable([
          for (final model in models)
            if (!model.isLocal) model,
        ]),
        tiers: tiers,
      );

  /// The entries that GATE setup, [ModelFile.gatesSetup]: the Hugging Face
  /// ones. What the wizard gate's ledger check reads. Decision D7: a
  /// registry file is best-effort, so a missing or failed one never reopens
  /// or blocks the wizard; its role parks on its own reason instead.
  ModelManifest get gating => ModelManifest(
        version: version,
        models: List.unmodifiable([
          for (final model in models)
            if (model.gatesSetup) model,
        ]),
        tiers: tiers,
      );

  /// This manifest without the entries whose files are not all in
  /// [modelsFolder] (the GGUF, the MTP sidecar and the heads file, whichever
  /// the entry has), or that [ledger] does not call current for a REGISTRY
  /// entry ([DownloadLedger.servable]), EXCEPT the embedding model.
  ///
  /// What the managed server's preset is built from. The server refuses to
  /// start with a file the preset names missing, and one missing model must
  /// not take the others down with it: a decision model not yet installed by
  /// hand, or a generative model the owner chose that was never downloaded
  /// (the 4B on a full Mac, since only the chosen one is fetched), leaves the
  /// preset and that role parks on its own reason while the rest run. The
  /// next `ensurePreset` after the file lands sees a new hash and restarts.
  /// A registry entry whose files are here but whose ledger rows are not
  /// current (a pair half replaced, a Download again under way or failed) is
  /// left out exactly as a missing file is, and joins when the model
  /// ensurer's pass makes it current.
  ///
  /// The embedding model is KEPT whatever the disk says: every stage needs
  /// it, and a router started without it would look healthy while nothing
  /// could work. Left in, its absence fails the start with the preflight's
  /// own `Model files are missing` sentence, which is the true report.
  ModelManifest withPresentFiles(String modelsFolder, DownloadLedger ledger) =>
      ModelManifest(
        version: version,
        models: List.unmodifiable([
          for (final model in models)
            if (model.role == ModelRole.embed ||
                ledger.servable(model, modelsFolder))
              model,
        ]),
        tiers: tiers,
      );

  /// Whether every file [model] needs is in [modelsFolder]: the weights, the
  /// MTP sidecar when it has one, and the heads file when it has one.
  static bool filesPresent(ModelFile model, String modelsFolder) {
    bool at(String? relative) =>
        relative == null || File(p.join(modelsFolder, relative)).existsSync();
    return at(model.relativePath) &&
        at(model.sidecarRelativePath) &&
        at(model.headsRelativePath);
  }

  /// Whether a `source: local` entry's files are all in [modelsFolder].
  static bool localInstalled(ModelFile model, String modelsFolder) =>
      filesPresent(model, modelsFolder);

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
