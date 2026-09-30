import 'package:bond_inbox/models/draft_policy.dart';
import 'package:bond_inbox/services/llm/attachment_digest_task.dart';
import 'package:bond_inbox/services/llm/context_brief_task.dart';
import 'package:bond_inbox/services/llm/context_digest_task.dart';
import 'package:bond_inbox/services/llm/context_select_task.dart';
import 'package:bond_inbox/services/llm/draft_task.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/message_text_task.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/llm/storyline_tasks.dart';
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
      const MessageTextTask().schemaName,
      const AttachmentDigestTask().schemaName,
      const ContextDigestTask().schemaName,
      const ContextBriefTask().schemaName,
      const ContextSelectTask().schemaName,
      const NameStorylineTask().schemaName,
      const RefineStorylineTask().schemaName,
      const StorylineRecapTask().schemaName,
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
      // The decision model sends no chat schema either: it is an embedding
      // call whose heads run in Dart.
      if (stage.slot == ModelSlot.decide) {
        expect(stage.id, 'decision');
        continue;
      }
      // `draft_improve` runs another stage's task — it sends `DraftTask` —
      // so it is a routing destination without a schema of its own, and the
      // second exception this containment allows.
      if (stage.id == 'draft_improve') continue;
      expect(names, contains(stage.id), reason: stage.id);
    }

    // And the exemption is not a hole anybody can widen quietly: exactly one
    // row has no task of its own, and a second one has to be argued for here.
    expect(
      {
        for (final stage in pipelineStages)
          if (stage.slot == ModelSlot.generative &&
              !names.contains(stage.id))
            stage.id,
      },
      {'draft_improve'},
    );
  });

  test('each stage names the role that does its work', () {
    Set<String> idsOn(ModelSlot slot) => {
          for (final stage in pipelineStages)
            if (stage.slot == slot) stage.id,
        };

    // Literals, not a derivation: moving a stage between roles must force an
    // edit here, and therefore an edit to docs/pipeline/10-model-routing.md.
    // Every text stage is the ONE generative model since the decision-model
    // round (the fast and prose slots merged), and the decision model is a
    // role of its own.
    expect(idsOn(ModelSlot.generative), {
      'message_text',
      'attachment_digest',
      'context_file_digest',
      'context_brief',
      'context_select',
      'storyline_name',
      'storyline_refresh',
      'storyline_recap',
      'draft_reply',
      'draft_improve',
    });
    expect(idsOn(ModelSlot.decide), {'decision'});
    expect(idsOn(ModelSlot.embed), {'embeddings'});
  });

  test('no reply-decision row: the decision model answers it at triage', () {
    final ids = [for (final stage in pipelineStages) stage.id];
    expect(ids, isNot(contains('reply_decision')));
    expect(ids, containsAll(['draft_reply', 'draft_improve']));
  });

  test('one text row per message, where triage and extraction were', () {
    final ids = [for (final stage in pipelineStages) stage.id];
    expect(ids, isNot(contains('triage')));
    expect(ids, isNot(contains('extraction')));
    final text = pipelineStages.singleWhere((s) => s.id == 'message_text');
    expect(text.label, 'Message text');
    expect(text.description,
        'Summary, action items, deadline, topics, project');
    expect(text.slot, ModelSlot.generative);
  });

  test('the decision row comes first, and has no schema of its own', () {
    // It runs on every kept message before any text call.
    final first = pipelineStages.first;
    expect(first.id, 'decision');
    expect(first.label, 'Decision model');
    expect(first.description, 'Sorts and flags every message');
    expect(first.slot, ModelSlot.decide);
    expect(taskSchemaNames(), isNot(contains('decision')));
  });

  test('stageSlot answers the table, and generative for anything else', () {
    for (final stage in pipelineStages) {
      expect(stageSlot(stage.id), stage.slot, reason: stage.id);
    }

    // An id no row names is a text stage, not a throw: this runs on a
    // drain's hot path, and every text stage is generative anyway.
    expect(stageSlot('nope'), ModelSlot.generative);
    // No row is optional any more: `draft_improve` was the one that was, and
    // its entry was the feature being on, which the stage picker's deletion
    // would have made unreachable.
    expect(pipelineStages.where((stage) => stage.optional), isEmpty);
  });

  test('a stage names the model that does its work, one role per slot', () {
    for (final stage in pipelineStages) {
      final expected = switch (stage.slot) {
        ModelSlot.generative => StageRole.generative,
        ModelSlot.decide => StageRole.decision,
        ModelSlot.embed => StageRole.embed,
      };
      expect(roleOfStage(stage.id), expected, reason: stage.id);
    }
    // Storyline membership is the decision model's `member_of`, not a stage
    // of its own: no language model is asked whether a thread belongs.
    expect(roleOfStage('storyline_membership'), isNull);
    expect(roleOfStage('decision'), StageRole.decision);
    expect(roleOfStage('embeddings'), StageRole.embed);
    // An id the stage table does not name has no role at all.
    expect(roleOfStage('nope'), isNull);
  });

  test('the drafting stages are every stage that writes in the owner\'s name',
      () {
    // The closed pair the cloud-drafts target routes and the consent gate
    // asks about. Named once so a third drafting stage is not several things
    // to remember.
    expect(draftStageIds, ['draft_reply', 'draft_improve']);
    for (final id in draftStageIds) {
      expect(pipelineStages.map((s) => s.id), contains(id));
      expect(stageSlot(id), ModelSlot.generative);
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

    // The id never moves, which is what the keychain entry is keyed on.
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

  test('the compiled defaults are the clients\' constants', () {
    expect(generativeSlotDefault.baseUrl, LlmClient.defaultBaseUrl);
    expect(generativeSlotDefault.model, LlmClient.defaultModel);
    // The hand-started `make decide` server, as `DecisionClient` names it.
    expect(decideUrlDefault, 'http://127.0.0.1:8083/v1/embeddings');
    expect(decideModelDefault, 'bond-decide');
    expect(routerDecideId, 'bond-decide');
    expect(EmbeddingsClient.modelTag, isNotEmpty);
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

    test('the draft policy follows the tier', () {
      expect(tierDraftPolicy(MachineTier.full), DraftPolicy.needsYou);
      expect(tierDraftPolicy(MachineTier.inbox), DraftPolicy.onDemand);
      expect(MachineTier.values, [MachineTier.full, MachineTier.inbox]);
    });

    test('the managed generative model is the tier\'s unless one was chosen',
        () {
      // '' follows the hardware.
      expect(managedGenerativeIdFor(MachineTier.full, ''), routerProseId);
      expect(managedGenerativeIdFor(MachineTier.inbox, ''), routerBulkId);
      // The 4B may be chosen anywhere.
      expect(managedGenerativeIdFor(MachineTier.full, routerBulkId),
          routerBulkId);
      expect(managedGenerativeIdFor(MachineTier.inbox, routerBulkId),
          routerBulkId);
      // The 27B only where the tier holds it: refused on the inbox tier.
      expect(managedGenerativeIdFor(MachineTier.full, routerProseId),
          routerProseId);
      expect(managedGenerativeIdFor(MachineTier.inbox, routerProseId),
          routerBulkId);
      // Anything else reads as ''.
      expect(managedGenerativeIdFor(MachineTier.full, 'bond-embed'),
          routerProseId);
      expect(managedGenerativeIdFor(MachineTier.inbox, 'nonsense'),
          routerBulkId);
    });

    test('a build with no compiled address defaults to this Mac', () {
      // `defaultModelPlacement` is const-evaluated from `boxUrlDefault`, which
      // is empty under `flutter test`, so the whole suite runs local unless a
      // test says otherwise.
      expect(defaultModelPlacement, ModelPlacement.local);
      // And it is genuinely const: this list would not compile otherwise, and
      // `AppPrefs`'s default parameter could not name it.
      const placements = [defaultModelPlacement];
      expect(placements, [ModelPlacement.local]);
    });

    test('the fixed target constants are the ids, names and models the '
        'derived specs carry', () {
      expect(boxProseId, 'box-prose');
      expect(boxDecideId, 'box-decide');
      expect(cloudDraftsId, 'cloud-drafts');
      expect(localGenerativeId, 'local-generative');
      expect(localDecisionId, 'local-decision');
      expect(boxProseModel, 'qwen3.8');
      expect(boxDecideModel, 'bond-decide-mbl-v3');
      expect(localGenerativeName, 'This Mac · generative');
      expect(boxProseName, 'Your server · generative');
      expect(localDecisionName, 'This Mac · decision');
      expect(boxDecideName, 'Your server · decision');
      expect(cloudDraftsName, 'Cloud drafts');
      // User-facing, so no em-dash and no parenthetical.
      for (final name in [
        localGenerativeName,
        boxProseName,
        localDecisionName,
        boxDecideName,
        cloudDraftsName,
      ]) {
        expect(name, isNot(contains('—')));
        expect(name, isNot(contains('(')));
      }
      // Empty in every build that did not pass the define, which is the test
      // suite: the wizard then asks for the address.
      expect(boxUrlDefault, isEmpty);
    });

    test('a typed box address is trimmed and loses every trailing slash', () {
      // One function rather than the same two lines in the wizard, the
      // Settings page and the role writers: three copies of the strip is three
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

    test('the stored writing URL gives its origin back', () {
      // The same recipe backwards, so Settings can prefill the address for
      // somebody whose access key was rotated and let them type the key alone.
      expect(
        boxBaseFromProseUrl('https://box.example.com/prose/v1/chat/completions'),
        'https://box.example.com',
      );
      // Anything this app did not write gives nothing: a bulk URL, a target
      // somebody added by hand, an empty string.
      expect(
        boxBaseFromProseUrl('https://box.example.com/bulk/v1/chat/completions'),
        isEmpty,
      );
      expect(boxBaseFromProseUrl('http://127.0.0.1:8080/v1/chat/completions'),
          isEmpty);
      expect(boxBaseFromProseUrl(''), isEmpty);
    });
  });
}
