import 'dart:io';

import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Makefile and the manifest name the same checkpoints, and nothing joins
/// them but this test.
///
/// Two worlds fetch weights on this project. `make model | fast` hands
/// llama-server a `-hf` repo and the files land in the Hugging Face cache;
/// `make embed | decide` serve the app's own files, which `make embed-fetch |
/// decide-fetch` download from the model registry; the shipped app hands
/// `ModelDownloader` the manifest and they land in the app's models folder.
/// Neither world reads the other's pins, so a bump on one side is invisible
/// on the other — and the Makefile's own comment above `EMBED_PORT` records
/// what that costs: an embedding model left behind produces vectors of the
/// wrong width, silently, and search finds nothing new.
///
/// So this pins the overlap: the repos, the quantisation, the context and the
/// slot counts. A plain `test()` rather than a `testWidgets` one, because it
/// reads two files off disk and builds no widget.
void main() {
  // `flutter test` runs from `app/`, so the Makefile is one level up. A
  // packaging layout that does not carry it is not a failure: there is nothing
  // to compare, and saying so is more useful than a red suite.
  final makefile = File('../Makefile');

  group('the Makefile and the manifest agree', () {
    late Map<String, String> defaults;
    late ModelManifest manifest;
    late ModelManifest full;

    setUp(() {
      defaults = _makeDefaults(makefile.readAsStringSync());
      manifest = ModelManifest.parse(
        File(ModelManifest.assetPath).readAsStringSync(),
      );
      full = manifest.forTier(MachineTier.full);
    });

    /// `<repo>[:<quant>]` against the manifest entry behind [id].
    void namesTheSameCheckpoint(String variable, String id) {
      final value = defaults[variable];
      final model = manifest.byId(id);
      expect(
        value,
        isNotNull,
        reason: '../Makefile has no `$variable ?=` default; '
            'app/assets/models/manifest.json names "$id"',
      );
      final parts = value!.split(':');
      expect(
        parts.first,
        model.repo,
        reason: '$variable in ../Makefile names ${parts.first}; '
            'app/assets/models/manifest.json names ${model.repo} for "$id"',
      );
      if (parts.length > 1) {
        expect(
          model.file.toLowerCase(),
          contains(parts[1].toLowerCase()),
          reason: '$variable in ../Makefile asks for the ${parts[1]} quant; '
              'app/assets/models/manifest.json ships ${model.file} for "$id"',
        );
      } else {
        // A repo that already carries its quantisation in its NAME, which is
        // how a single-quant repo is published and how `FAST_HF` is written.
        // With no `:quant` to compare there was nothing checking the quant at
        // all here, and swapping the manifest's file for another quant out of
        // the same repo stayed green — the two worlds serving different
        // weights under one name, which is the drift this file exists to stop.
        // So the quant is taken off the manifest's FILE and the repo name has
        // to carry it.
        final token = _quant.firstMatch(model.file)?.group(1);
        if (token != null) {
          expect(
            parts.first.toLowerCase(),
            contains(token.toLowerCase()),
            reason: '$variable in ../Makefile names ${parts.first} with no '
                '`:quant`, so the repo name is the only quant it states; '
                'app/assets/models/manifest.json ships ${model.file} for '
                '"$id", which is the $token quant',
          );
        }
      }
    }

    /// A Makefile default against a `serverArgs` value on the FULL tier, which
    /// is the tier the maintainer's machine and every ledger row are on.
    void matchesArg(String variable, String id, String arg) {
      final expected = full.byId(id).serverArgs[arg];
      expect(
        defaults[variable],
        expected,
        reason: '$variable in ../Makefile is ${defaults[variable]}; '
            'app/assets/models/manifest.json gives "$id" $arg = $expected on '
            'the full tier',
      );
    }

    test('the two repos and quants are the same files', () {
      namesTheSameCheckpoint('MODEL_HF', routerProseId);
      namesTheSameCheckpoint('FAST_HF', routerBulkId);
    });

    test('the context and the slots are the same numbers', () {
      // CTX_SIZE is what the bulk server is launched with and what MODEL_CTX
      // defaults to; the full tier gives both chat entries the same `c`.
      matchesArg('CTX_SIZE', routerBulkId, 'c');
      // MODEL_CTX is what the PROSE server is actually launched with
      // (`-c $(MODEL_CTX)` in MODEL_FLAGS), and it is a `?=` of its own: a
      // default that stopped expanding to CTX_SIZE would drift the prose
      // server away from the manifest while every other line here stayed
      // green, which is exactly the silent drift this file exists to stop.
      matchesArg('MODEL_CTX', routerProseId, 'c');
      matchesArg('CTX_SIZE', routerProseId, 'c');
      matchesArg('SLOTS', routerProseId, 'parallel');
      matchesArg('FAST_SLOTS', routerBulkId, 'parallel');
    });

    test('the embed pooling is the same word', () {
      // The Makefile's own comment above `EMBED_PORT` says what a mismatch here
      // costs: pooling is not a taste, it is what the checkpoint was trained
      // for, and the wrong one produces vectors of the wrong shape silently
      // while search quietly finds nothing. Two worlds set it — a launch flag
      // and a `serverArgs` value — and nothing but this compares them.
      final args = defaults['EMBED_ARGS'];
      expect(
        args,
        isNotNull,
        reason: '../Makefile has no `EMBED_ARGS ?=` default to read '
            '--pooling out of',
      );
      final flag = RegExp(r'--pooling\s+(\S+)').firstMatch(args!)?.group(1);
      expect(
        flag,
        full.byId(routerEmbedId).serverArgs['pooling'],
        reason: 'EMBED_ARGS in ../Makefile launches the embedding server with '
            '--pooling $flag; app/assets/models/manifest.json gives the embed '
            'entry pooling = '
            '${full.byId(routerEmbedId).serverArgs['pooling']}',
      );
    });

    test('the prose spec-type is the one the Makefile launches with', () {
      // The manifest carries the flag because it now SHIPS the file the flag
      // needs: the prose entry has an `mtp-…` sidecar, the preset names it as
      // `model-draft`, and the downloader fetches it. `make model` gets the
      // same head from the repo its `-hf` download came from. Two routes to
      // one configuration, and a spec type that differed between them would
      // mean the ledger's rows describe a server nobody runs.
      expect(
        full.byId(routerProseId).serverArgs['spec-type'],
        equals(defaults['SPEC_TYPE']),
        reason: 'SPEC_TYPE in ../Makefile is ${defaults['SPEC_TYPE']}; '
            'app/assets/models/manifest.json gives the prose entry '
            'spec-type = '
            '${full.byId(routerProseId).serverArgs['spec-type']}',
      );
    });

    test('the decision model is the bundle `make decide-fetch` downloads', () {
      // No `-hf` here: the decision model comes from the model registry, so
      // the join is the folder, the file, the quant, the heads, the bundle,
      // the two remote names and the two digests, which is what the app's
      // downloader and `make decide-fetch` both fetch and `make decide`
      // serves.
      final decide = manifest.byId(routerDecideId);
      expect(decide.repo, 'artifactory/bond-decide-mbl-v3swap');
      final dir = defaults['DECIDE_DIR'];
      expect(dir, isNotNull, reason: '../Makefile has no `DECIDE_DIR ?=`');
      expect(
        dir!.split('/').last,
        decide.relativePath.split('/').first,
        reason: 'DECIDE_DIR in ../Makefile installs into ${dir.split('/').last}; '
            'the manifest\'s repo ${decide.repo} is served from '
            '${decide.relativePath.split('/').first}',
      );
      final quant = defaults['DECIDE_QUANT'];
      expect(quant, 'f16');
      final file = defaults['DECIDE_FILE']!
          .replaceAll(r'$(DECIDE_QUANT)', quant!);
      expect(file, decide.file,
          reason: 'DECIDE_FILE in ../Makefile is $file; the manifest ships '
              '${decide.file}');
      expect(_quant.firstMatch(decide.file)?.group(1)?.toLowerCase(), quant);
      expect(defaults['DECIDE_HEADS'], decide.heads!.file);
      expect(defaults['DECIDE_BUNDLE'], decide.bundle,
          reason: 'DECIDE_BUNDLE in ../Makefile is ${defaults['DECIDE_BUNDLE']}; '
              'the manifest fetches bundle ${decide.bundle}');
      expect(defaults['DECIDE_REMOTE_GGUF'], decide.remoteFile);
      expect(defaults['DECIDE_REMOTE_HEADS'], decide.heads!.remoteFile);
      expect(defaults['DECIDE_GGUF_SHA'], decide.sha256,
          reason: 'DECIDE_GGUF_SHA in ../Makefile and the manifest\'s sha256 '
              'pin different bytes');
      expect(defaults['DECIDE_HEADS_SHA'], decide.heads!.sha256,
          reason: 'DECIDE_HEADS_SHA in ../Makefile and the manifest\'s '
              'heads.sha256 pin different bytes');
    });

    test('the embedding model is the bundle `make embed-fetch` downloads', () {
      // No `-hf` here either since the embed-registry round: the embedding
      // model comes from the model registry like the decision model, so the
      // join is the folder, the file, the bundle, the remote name and the
      // digest, which is what the app's downloader and `make embed-fetch`
      // both fetch and `make embed` serves with -m.
      final embed = manifest.byId(routerEmbedId);
      final dir = defaults['EMBED_DIR'];
      expect(dir, isNotNull, reason: '../Makefile has no `EMBED_DIR ?=`');
      expect(
        dir!.split('/').last,
        embed.relativePath.split('/').first,
        reason: 'EMBED_DIR in ../Makefile installs into ${dir.split('/').last}; '
            'the manifest\'s repo ${embed.repo} is served from '
            '${embed.relativePath.split('/').first}',
      );
      expect(defaults['EMBED_FILE'], embed.file,
          reason: 'EMBED_FILE in ../Makefile is ${defaults['EMBED_FILE']}; '
              'the manifest ships ${embed.file}');
      expect(defaults['EMBED_BUNDLE'], embed.bundle,
          reason: 'EMBED_BUNDLE in ../Makefile is ${defaults['EMBED_BUNDLE']}; '
              'the manifest fetches bundle ${embed.bundle}');
      // What `make embed` serves is that folder's file, written as the two
      // variables above so an override of either moves it.
      expect(defaults['EMBED_GGUF'], r'$(EMBED_DIR)/$(EMBED_FILE)');
      expect(defaults['EMBED_REMOTE_GGUF'], embed.remoteFile);
      expect(defaults['EMBED_GGUF_SHA'], embed.sha256,
          reason: 'EMBED_GGUF_SHA in ../Makefile and the manifest\'s sha256 '
              'pin different bytes');
      // The hand server must not default back to Hugging Face: EMBED_HF is
      // an opt-in for a bake-off candidate, and `_makeDefaults` skips an
      // empty default, so absent here means `EMBED_HF ?=` with nothing set.
      expect(defaults['EMBED_HF'], isNull,
          reason: 'EMBED_HF in ../Makefile defaults to '
              '${defaults['EMBED_HF']}; `make embed` would serve that repo '
              'instead of the file the app downloads');
    });

    test('the decision server args are the same set', () {
      // `make decide` launches `--embeddings -ngl 99 $(DECIDE_ARGS)`; the
      // router preset writes the manifest's serverArgs. Pooling, context,
      // batch, ubatch and slots must agree, or the pooled vector the heads
      // read differs between the two worlds.
      final args = defaults['DECIDE_ARGS'];
      expect(args, isNotNull, reason: '../Makefile has no `DECIDE_ARGS ?=`');
      String? flag(String name) =>
          RegExp('(?:^|\\s)$name\\s+(\\S+)').firstMatch(args!)?.group(1);
      final served = full.byId(routerDecideId).serverArgs;
      expect(flag('--pooling'), served['pooling']);
      expect(flag('-c'), served['c']);
      expect(flag('-ub'), served['ub']);
      expect(flag('-b'), served['b']);
      expect(flag('-np'), served['parallel']);
      expect(served['embedding'], 'true');
    });

    test('the inbox tier narrows the bulk server rather than the checkpoint',
        () {
      // The Makefile has one machine's configuration and the manifest has two.
      // The rung below the Makefile's is allowed to differ, and this is what
      // it is allowed to differ IN: the same files, fewer slots.
      final inbox = manifest.forTier(MachineTier.inbox);

      expect(inbox.byId(routerBulkId).repo, manifest.byId(routerBulkId).repo);
      expect(inbox.byId(routerBulkId).file, manifest.byId(routerBulkId).file);
      expect(inbox.byId(routerBulkId).serverArgs['parallel'], '2');
      expect(defaults['FAST_SLOTS'], '4');
    });
  }, skip: _skipReason(makefile));
}

/// The quantisation token inside a GGUF file name — `Q4_K_M`, `Q8_0`, `IQ4_XS`,
/// `F16`. Wide on purpose: an unmatched name states no quant and is compared
/// on the repo alone, which is what the checkpoints before GGUF quantisation
/// look like.
///
/// LONGEST SPELLING FIRST, and that ordering is the whole check. Dart tries the
/// alternatives left to right at the same position, so a bare `q\d` in front
/// would take `q4` out of `q4_0` and out of `q4_k_m` alike, and a `Q4_0` file
/// would then pass against a `…-Q4_K_M-GGUF` repo name: the same-digit drift,
/// which is the one a reader is least likely to spot by eye.
final RegExp _quant = RegExp(
  r'(q\d_k(?:_[msl])?|q\d_\d|iq\d_\w+|q\d|f16|bf16|mxfp4)',
  caseSensitive: false,
);

/// Null when the Makefile is there, a sentence when it is not.
String? _skipReason(File makefile) => makefile.existsSync()
    ? null
    : '../Makefile is not beside this checkout; nothing to compare';

/// Every `NAME ?= value` default, by name, with a whole-value `$(OTHER)`
/// resolved to that other default.
///
/// `?=` only: a `:=` is derived from one of these and a recipe line is not a
/// default at all. An empty default is left out, because make treats it as
/// unset and so does every reader here. Values are trimmed: make keeps the
/// whitespace before a trailing comment, which is why the Makefile's own
/// comments sit ABOVE their assignment.
///
/// The expansion is deliberately only the WHOLE-value case, `MODEL_CTX ?=
/// $(CTX_SIZE)`, because that is the one shape this file compares against a
/// number. A value with a reference inside it — a URL built out of a port —
/// is left as it was written, and nothing here reads one.
Map<String, String> _makeDefaults(String text) {
  final defaults = <String, String>{};
  // Spaces and tabs around `?=`, never `\s`: `\s` matches a newline, so an
  // EMPTY default (`DRAFT_HF ?=`) swallowed the line under it and recorded
  // that line's text as this variable's value — which also meant the variable
  // on it was never seen at all. `SPEC_TYPE` sits under `DRAFT_HF` and was
  // invisible here until Round G asked the manifest to agree with it.
  final pattern =
      RegExp(r'^([A-Z_][A-Z0-9_]*)[ \t]*\?=[ \t]*(.*)$', multiLine: true);
  for (final match in pattern.allMatches(text)) {
    final value = match.group(2)!.trim();
    if (value.isEmpty) continue;
    defaults[match.group(1)!] = value;
  }
  final whole = RegExp(r'^\$[({]([A-Z_][A-Z0-9_]*)[)}]$');
  for (final name in defaults.keys.toList()) {
    final match = whole.firstMatch(defaults[name]!);
    if (match == null) continue;
    final target = defaults[match.group(1)!];
    if (target != null) defaults[name] = target;
  }
  return defaults;
}
