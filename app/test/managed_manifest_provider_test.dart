import 'dart:io';

import 'package:bond_inbox/data/app_paths.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:bond_inbox/services/system/system_info.dart' show HardwareInfo;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/fake_system_info.dart';
import 'fixtures/memory_token_store.dart';
import 'fixtures/test_db.dart';
import 'fixtures/test_manifest.dart';

/// What this Mac SERVES under the two role placements, and the preset the
/// supervisor builds from it.
///
/// A plain `test`: the preset build stats real files.
void main() {
  late BondDatabase db;
  late Directory support;

  setUp(() async {
    db = testDb();
    support = await Directory.systemTemp.createTemp('managed-manifest');
  });

  tearDown(() async {
    await db.close();
    await support.delete(recursive: true);
  });

  final manifest = testManifest(withDecide: true);

  ProviderContainer containerFor(
    AppPrefs prefs, {
    int memoryBytes = 64 * 1024 * 1024 * 1024,
  }) {
    final system = FakeSystemInfo()
      ..hardwareInfo = HardwareInfo(
        chip: 'Apple M2 Max',
        memoryBytes: memoryBytes,
        appleSilicon: true,
        rosetta: false,
        osVersion: '15.6',
      );
    final made = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      appPathsProvider.overrideWithValue(AppPaths(support)),
      modelManifestProvider.overrideWithValue(manifest),
      systemInfoProvider.overrideWithValue(system),
      appPrefsProvider.overrideWith(
        (ref) => AppPrefsNotifier(
          MessageStore(db),
          initial: prefs,
          tokens: MemoryTokenStore(),
        ),
      ),
    ]);
    addTearDown(made.dispose);
    return made;
  }

  Future<List<String>> served(ProviderContainer container) async => [
        for (final m
            in (await container.read(managedManifestProvider.future)).models)
          m.id,
      ];

  test('everything managed on a full Mac: embed, decide and the 27B', () async {
    expect(await served(containerFor(const AppPrefs())),
        [routerEmbedId, routerDecideId, routerProseId]);
  });

  test('a small Mac serves the 4B', () async {
    expect(
      await served(containerFor(
        const AppPrefs(),
        memoryBytes: 16 * 1024 * 1024 * 1024,
      )),
      [routerEmbedId, routerDecideId, routerBulkId],
    );
  });

  test('a role on your server leaves this Mac\'s set', () async {
    expect(
      await served(containerFor(const AppPrefs(
        modelPlacement: ModelPlacement.box,
        boxBigUrl: 'https://box.example.com/prose/v1/chat/completions',
      ))),
      [routerEmbedId, routerDecideId],
    );
    expect(
      await served(containerFor(const AppPrefs(
        decisionPlacement: ModelPlacement.box,
        decisionUrl: 'https://box.example.com/decide/v1/embeddings',
      ))),
      [routerEmbedId, routerProseId],
    );
  });

  test('a placement with no address to dial keeps its model here', () async {
    expect(
      await served(containerFor(const AppPrefs(
        modelPlacement: ModelPlacement.box,
        decisionPlacement: ModelPlacement.box,
      ))),
      [routerEmbedId, routerDecideId, routerProseId],
    );
  });

  test('the supervisor\'s preset teaches the prefs the tier, and leaves out a '
      'decision model that is not installed', () async {
    final container = containerFor(
      const AppPrefs(),
      memoryBytes: 16 * 1024 * 1024 * 1024,
    );
    final supervisor = container.read(modelServerSupervisorProvider);
    expect(container.read(appPrefsProvider).machineTier, MachineTier.full);

    var preset = await supervisor.buildPreset();

    // The tier reached the prefs, so the managed generative target asks the
    // router for the model this preset actually serves.
    expect(container.read(appPrefsProvider).machineTier, MachineTier.inbox);
    expect(container.read(appPrefsProvider).generativeSpec.model, routerBulkId);
    // Not installed: left out, so its absence cannot stop the other models.
    expect(preset.modelIds, [routerEmbedId, routerBulkId]);

    final folder = p.join(support.path, 'models');
    final decide = manifest.byRole(ModelRole.decide);
    for (final relative in [decide.relativePath, decide.headsRelativePath!]) {
      final file = File(p.join(folder, relative));
      await file.parent.create(recursive: true);
      await file.writeAsString('x');
    }

    preset = await supervisor.buildPreset();
    expect(preset.modelIds, [routerEmbedId, routerDecideId, routerBulkId]);
    // The heads never enter the INI.
    expect(preset.toIni(), isNot(contains('decide-heads.json')));
  });
}
