import 'dart:io';

import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Makefile and the manifest name the same checkpoints, and nothing joins
/// them but this test.
///
/// Two worlds fetch weights on this project. `make model | fast | embed` hands
/// llama-server a `-hf` repo and the files land in the Hugging Face cache; the
/// shipped app hands `ModelDownloader` the manifest and they land in the app's
/// models folder. Neither reads the other, so a bump on one side is invisible
/// on the other — and the Makefile's own comment above `EMBED_HF` records what
/// that costs: an embedding model left behind produces vectors of the wrong
/// width, silently, and search finds nothing new.
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

    test('the three repos and quants are the same files', () {
      namesTheSameCheckpoint('MODEL_HF', routerProseId);
      namesTheSameCheckpoint('FAST_HF', routerBulkId);
      namesTheSameCheckpoint('EMBED_HF', routerEmbedId);
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

    test('the prose spec-type agrees, or the manifest carries none', () {
      // `--spec-type` is a plain long flag, so the preset INI could carry it
      // as `spec-type = draft-mtp`. It deliberately does not: the managed
      // server is pointed at a local path rather than a repo, and llama-server
      // resolves the MTP head from the repo the `-hf` download came from, so
      // there would be no sidecar for it to load. Either the manifest stays
      // silent about speculation, or it says exactly what `make model`
      // launches with — a third answer is the drift this file exists to stop.
      expect(
        full.byId(routerProseId).serverArgs['spec-type'],
        anyOf(isNull, equals(defaults['SPEC_TYPE'])),
        reason: 'SPEC_TYPE in ../Makefile is ${defaults['SPEC_TYPE']}; '
            'app/assets/models/manifest.json gives the prose entry '
            'spec-type = '
            '${full.byId(routerProseId).serverArgs['spec-type']}',
      );
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
  final pattern = RegExp(r'^([A-Z_][A-Z0-9_]*)\s*\?=\s*(.*)$', multiLine: true);
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
