import 'package:bond_inbox/models/draft_policy.dart';
import 'package:bond_inbox/services/llm/attachment_digest_task.dart';
import 'package:bond_inbox/services/llm/context_brief_task.dart';
import 'package:bond_inbox/services/llm/context_digest_task.dart';
import 'package:bond_inbox/services/llm/context_select_task.dart';
import 'package:bond_inbox/services/llm/draft_task.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/extract_task.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/llm/needs_you_task.dart';
import 'package:bond_inbox/services/llm/reply_decision_task.dart';
import 'package:bond_inbox/services/llm/storyline_tasks.dart';
import 'package:bond_inbox/services/llm/triage_task.dart';
import 'package:flutter_test/flutter_test.dart';

/// The authored stage table, held against the pipeline it claims to describe.
///
/// The table is what every stage's DEFAULT target is read off, and what the
/// settings screen lists. These tests are the only thing keeping it honest: a
/// task shipped without a row, a row for a stage that no longer runs, a stage
/// quietly moved between slots, or a preset that names a stage the table does
/// not, all fail here rather than in a screen nobody re-reads.

/// The `schemaName` of every task that makes a model call, built from real
/// instances so a renamed schema fails this file rather than drifting.
Set<String> taskSchemaNames() => {
      const TriageTask().schemaName,
      const NeedsYouTask().schemaName,
      const ExtractTask().schemaName,
      const AttachmentDigestTask().schemaName,
      const ContextDigestTask().schemaName,
      const ContextBriefTask().schemaName,
      const ContextSelectTask().schemaName,
      const ConfirmMembershipTask().schemaName,
      const GroupThreadsTask().schemaName,
      const NameStorylineTask().schemaName,
      const RefineStorylineTask().schemaName,
      const StorylineRecapTask().schemaName,
      const ReplyDecisionTask().schemaName,
      const DraftTask().schemaName,
    };

void main() {
  test('every stage that dials a model is in the table', () {
    final ids = pipelineStages.map((stage) => stage.id).toList();

    for (final name in taskSchemaNames()) {
      expect(ids.where((id) => id == name), hasLength(1), reason: name);
    }
  });

  test('the table has no stage the pipeline does not run', () {
    final names = taskSchemaNames();

    for (final stage in pipelineStages) {
      // Embeddings send no chat schema — they are the one row with no task
      // behind them.
      if (stage.slot == ModelSlot.embed) {
        expect(stage.id, 'embeddings');
        continue;
      }
      // An OPTIONAL stage runs another stage's task — `draft_improve` sends
      // `DraftTask` — so it is a routing destination without a schema of
      // its own, and the second exception this containment allows.
      if (stage.optional) continue;
      expect(names, contains(stage.id), reason: stage.id);
    }

    // And the exemption is not a hole anybody can widen quietly: exactly one
    // row is optional today, and a second one has to be argued for here.
    expect(
      {
        for (final stage in pipelineStages)
          if (stage.optional) stage.id,
      },
      {'draft_improve'},
    );
  });

  test('each stage names the slot it defaults to', () {
    Set<String> idsOn(ModelSlot slot) => {
          for (final stage in pipelineStages)
            if (stage.slot == slot) stage.id,
        };

    // Literals, not a derivation: moving a stage between slots must force an
    // edit here, and therefore an edit to docs/pipeline/10-model-routing.md.
    // These are the DEFAULTS now — where a stage goes on one machine is a
    // `stage_targets` entry, which `llm_targets_test.dart` covers.
    expect(idsOn(ModelSlot.fast), {
      'triage',
      'needs_you',
      'extraction',
      'attachment_digest',
      'context_file_digest',
      'context_brief',
      'context_select',
      'storyline_membership',
    });
    expect(idsOn(ModelSlot.prose), {
      'storyline_group',
      'storyline_name',
      'storyline_refresh',
      'storyline_recap',
      'reply_decision',
      'draft_reply',
      'draft_improve',
    });
    expect(idsOn(ModelSlot.embed), {'embeddings'});
  });

  test('stageSlot answers the table, and fast for anything else', () {
    for (final stage in pipelineStages) {
      expect(stageSlot(stage.id), stage.slot, reason: stage.id);
    }

    // An id no row names is the cheap slot, not a throw: this runs on a
    // drain's hot path, and a stray stage id must cost a request on the small
    // server rather than the item.
    expect(stageSlot('nope'), ModelSlot.fast);
    expect(stageIsOptional('draft_improve'), isTrue);
    expect(stageIsOptional('draft_reply'), isFalse);
    expect(stageIsOptional('nope'), isFalse);
  });

  test('a slot names its built-in target, and embeddings name none', () {
    expect(defaultTargetIdFor(ModelSlot.fast), builtInFastId);
    expect(defaultTargetIdFor(ModelSlot.prose), builtInProseId);
    // Not a default but a bug in the caller: embeddings are not routed at
    // all, because a vector carries the tag of the model that wrote it.
    expect(() => defaultTargetIdFor(ModelSlot.embed), throwsArgumentError);
  });

  test('the three presets are the stage table, not a second copy of it', () {
    Set<String> idsOn(ModelSlot slot) => {
          for (final stage in pipelineStages)
            if (stage.slot == slot && !stage.optional) stage.id,
        };

    expect(proseStageIds.toSet(), idsOn(ModelSlot.prose));
    expect(bulkStageIds.toSet(), idsOn(ModelSlot.fast));
    expect(confirmStageIds, ['storyline_membership']);

    for (final preset in [proseStageIds, confirmStageIds, bulkStageIds]) {
      // No duplicates, and neither of the two rows a preset must never write:
      // `embeddings` is not routed, and `draft_improve` is the one stage a
      // person turns on deliberately.
      expect(preset.toSet(), hasLength(preset.length));
      expect(preset, isNot(contains('embeddings')));
      expect(preset, isNot(contains('draft_improve')));
      for (final id in preset) {
        expect(pipelineStages.map((s) => s.id), contains(id));
      }
    }
  });

  test('a third-party host is Bedrock and the three vendors', () {
    expect(isThirdPartyHost('https://bedrock-runtime.us-east-2.amazonaws.com/x'),
        isTrue);
    expect(isThirdPartyHost('https://api.anthropic.com/v1'), isTrue);
    expect(isThirdPartyHost('https://api.openai.com/v1'), isTrue);
    expect(isThirdPartyHost('https://api.deepseek.com/v1'), isTrue);

    // AWS as a whole is NOT a vendor here, and this is the point of the rule.
    // The shared GPU box is an EC2 instance this install's owner rents, pays
    // for and runs, whether it is reached by a Route 53 name or by the public
    // name AWS gave it. Mail going there is not mail going to a company.
    expect(
      isThirdPartyHost('https://box.example.com/prose/v1/chat/completions'),
      isFalse,
    );
    expect(
      isThirdPartyHost(
        'https://ec2-1-2-3-4.us-east-2.compute.amazonaws.com/prose/v1/chat/'
        'completions',
      ),
      isFalse,
    );
    expect(isThirdPartyHost('https://s3.amazonaws.com/x'), isFalse);
    // The prefix is not enough on its own: `bedrock` has to be under AWS.
    expect(isThirdPartyHost('https://notbedrock.example.com/v1'), isFalse);

    // Loopback is NOT a signal: the GPU box arrives on an `ssh` tunnel, so a
    // rule of "not loopback" would miss it and one of "loopback is safe"
    // would wave it through. What this answers is whose machine it is.
    expect(isThirdPartyHost('http://localhost:18100/v1/chat/completions'),
        isFalse);
    expect(isThirdPartyHost('http://127.0.0.1:8080/v1/chat/completions'),
        isFalse);
    expect(isThirdPartyHost('http://box.example.com:8000/v1'), isFalse);
    // A URL nobody can dial is not a cloud target: treating it as one would
    // put a consent screen in front of a typo.
    expect(isThirdPartyHost('not a url'), isFalse);
    expect(isThirdPartyHost(''), isFalse);
  });

  test('a spec round-trips its JSON, and refuses a broken row', () {
    const spec = LlmTargetSpec(
      id: 'gpu-1',
      name: 'GPU box',
      url: 'http://localhost:18100/v1/chat/completions',
      model: 'qwen3.8',
      hasBearer: true,
      parallel: 4,
      streams: false,
    );

    expect(LlmTargetSpec.tryParse(spec.toJson()), spec);
    // The presence flag and NEVER the token — the JSON lands in a database
    // table that anything with the file can read.
    expect(spec.toJson()['bearer'], isTrue);

    expect(LlmTargetSpec.tryParse(null), isNull);
    expect(LlmTargetSpec.tryParse('a string'), isNull);
    expect(
      LlmTargetSpec.tryParse(
        {'name': 'n', 'url': 'http://example.com', 'model': 'm'},
      ),
      isNull,
    );

    final defaulted = LlmTargetSpec.tryParse({
      'id': 'x',
      'name': 'n',
      'url': 'http://example.com/v1/chat/completions',
      'model': 'm',
      'wire': 'a wire nobody ships',
      'parallel': 99,
      'streams': 'yes please',
    })!;
    expect(defaulted.wire, LlmWire.openAi);
    expect(defaulted.parallel, 8);
    expect(defaulted.streams, isTrue);
    expect(defaulted.hasBearer, isFalse);

    expect(
      LlmTargetSpec.tryParse({
        'id': 'x',
        'name': 'n',
        'url': 'http://example.com/v1',
        'model': 'm',
        'parallel': 0,
      })!.parallel,
      1,
    );
  });

  test('a spec says who operates the machine behind it', () {
    const local = LlmTargetSpec(
      id: 'box',
      name: 'Box',
      url: 'http://localhost:18100/v1/chat/completions',
      model: 'qwen3.8',
    );
    expect(local.isThirdParty, isFalse);
    expect(local.isBuiltIn, isFalse);

    // The wire alone is enough: Converse is only served by one company.
    expect(local.copyWith(wire: LlmWire.bedrockConverse).isThirdParty, isTrue);
    expect(
      const LlmTargetSpec(
        id: 'b',
        name: 'B',
        url: 'https://bedrock-runtime.us-east-2.amazonaws.com',
        model: 'us.anthropic.claude-opus-5',
      ).isThirdParty,
      isTrue,
    );

    // The wire outranks the host in the other direction too: a Converse spec
    // on the box's own hostname is still third party, because Converse is
    // served by one company wherever the URL points.
    expect(
      const LlmTargetSpec(
        id: 'box-converse',
        name: 'Box on Converse',
        url: 'https://box.example.com/prose/v1/chat/completions',
        model: 'us.anthropic.claude-opus-5',
        wire: LlmWire.bedrockConverse,
      ).isThirdParty,
      isTrue,
    );

    // The id never moves, which is what the stage map and the keychain entry
    // are keyed on.
    expect(local.copyWith(name: 'Renamed').id, 'box');
  });

  test('ids are unique and labels are non-empty', () {
    final ids = pipelineStages.map((stage) => stage.id).toList();
    expect(ids.toSet(), hasLength(ids.length));

    for (final stage in pipelineStages) {
      expect(stage.label, isNotEmpty, reason: stage.id);
      expect(stage.description, isNotEmpty, reason: stage.id);
    }
  });

  test('the slot defaults are the compiled constants', () {
    expect(fastSlotDefault.baseUrl, LlmClient.fastBaseUrl);
    expect(fastSlotDefault.model, LlmClient.fastModel);
    expect(proseSlotDefault.baseUrl, LlmClient.defaultBaseUrl);
    expect(proseSlotDefault.model, LlmClient.defaultModel);
    expect(embedSlotDefault.baseUrl, EmbeddingsClient.defaultBaseUrl);
    expect(embedSlotDefault.model, EmbeddingsClient.modelTag);

    // Two servers is the point — one slot accidentally aliasing the other
    // would route every label back onto the 27B.
    expect(fastSlotDefault, isNot(proseSlotDefault));
    expect(slotDefaults[ModelSlot.fast], fastSlotDefault);
    expect(slotDefaults[ModelSlot.prose], proseSlotDefault);
    expect(slotDefaults[ModelSlot.embed], embedSlotDefault);
  });

  group('the machine tier', () {
    const gib = 1024 * 1024 * 1024;

    test('is read off memory alone, and unknown memory never refuses', () {
      expect(machineTierFor(0), MachineTier.full);
      expect(machineTierFor(-1), MachineTier.full);
      expect(machineTierFor(8 * gib), MachineTier.inbox);
      expect(machineTierFor(16 * gib), MachineTier.inbox);
      expect(machineTierFor(36 * gib), MachineTier.inbox);
      expect(machineTierFor(40 * gib), MachineTier.full);
      expect(machineTierFor(48 * gib), MachineTier.full);
      expect(machineTierFor(64 * gib), MachineTier.full);
      expect(fullTierMinBytes, 40 * gib);
      expect(measuredFloorBytes, 16 * gib);
    });

    test('never answers remote, at any byte count', () {
      // The remote tier is a PLACEMENT. Nothing about a machine's memory can
      // say whether its owner points it at the shared GPU box, and a reading
      // of the hardware that answered it would be inventing that fact.
      for (final bytes in [-1, 0, 1, 8 * gib, 16 * gib, 40 * gib, 512 * gib]) {
        expect(machineTierFor(bytes), isNot(MachineTier.remote),
            reason: '$bytes');
      }
    });

    test('the full tier writes nothing, so a fresh install stays as it was',
        () {
      expect(tierStageDefaults(MachineTier.full), isEmpty);
      expect(tierDraftPolicy(MachineTier.full), DraftPolicy.needsYou);
    });

    test('the inbox tier points every prose-slot stage at the fast built-in',
        () {
      final map = tierStageDefaults(MachineTier.inbox);
      expect(map.keys.toSet(), proseStageIds.toSet());
      expect(map.length, 6);
      expect(map.values.toSet(), {builtInFastId});
      expect(map.containsKey('draft_improve'), isFalse);
      expect(map.containsKey('storyline_membership'), isFalse);
      for (final id in bulkStageIds) {
        expect(map.containsKey(id), isFalse, reason: id);
      }
      expect(tierDraftPolicy(MachineTier.inbox), DraftPolicy.onDemand);
    });

    test('the remote tier writes no stage, so it cannot widen what a tier '
        'clears', () {
      // `applyTierDefaults` builds its governed set from the UNION of every
      // tier's keys, so a stage named here would be cleared on a machine that
      // has never seen the box. `adoptBox` owns the box's stage map, and this
      // is what keeps the two from fighting.
      expect(tierStageDefaults(MachineTier.remote), isEmpty);
      expect(tierDraftPolicy(MachineTier.remote), DraftPolicy.needsYou);
    });

    test('the box constants are the ids, names and models adoptBox writes',
        () {
      expect(boxProseId, 'box-prose');
      expect(boxBulkId, 'box-bulk');
      expect(boxProseModel, 'qwen3.8');
      expect(boxBulkModel, 'qwen3-4b');
      // User-facing, so no em-dash and no parenthetical.
      for (final name in [boxProseName, boxBulkName]) {
        expect(name, isNot(contains('—')));
        expect(name, isNot(contains('(')));
      }
      // Empty in every build that did not pass the define, which is the test
      // suite: the wizard then asks for the address.
      expect(boxUrlDefault, isEmpty);
    });

    test('a typed box address is trimmed and loses every trailing slash', () {
      // One function rather than the same two lines in the wizard, the
      // Settings pane and `adoptBox`: three copies of the strip is three
      // places for `https://box.example.com//prose/…` to come from.
      expect(normalizeBoxBaseUrl('  https://box.example.com/  '),
          'https://box.example.com');
      expect(normalizeBoxBaseUrl('https://box.example.com///'),
          'https://box.example.com');
      expect(normalizeBoxBaseUrl('https://box.example.com'),
          'https://box.example.com');
      // Empty in, empty out: what both callers read as "nothing typed yet".
      expect(normalizeBoxBaseUrl('   '), isEmpty);
      expect(normalizeBoxBaseUrl('///'), isEmpty);
    });
  });
}
