import 'package:flutter/foundation.dart' show immutable;

import '../../models/draft_policy.dart';
import 'embeddings_client.dart';

/// Which of the three local servers a piece of work goes to.
///
/// [embed] is here so the settings screen can DISPLAY it beside the other two.
/// It is deliberately not switchable: stored vectors carry a hardcoded model
/// tag ([EmbeddingsClient.modelTag]), so a swapped embedding model would
/// silently compare vectors from two different spaces.
enum ModelSlot { fast, prose, embed }

/// Which request shape a client puts on the wire.
///
/// Lives HERE rather than beside `LlmClient` because a resolved [LlmTarget]
/// now carries one, and `model_slots.dart` may not import upward — the same
/// cycle the const slot defaults below already work around. `llm_client.dart`
/// re-exports it, so every existing importer reads the same enum from the
/// same place it always did.
enum LlmWire {
  /// OpenAI chat completions: llama-server, oMLX, and Bedrock's
  /// OpenAI-compatible endpoint. The app's own wire.
  openAi,

  /// AWS Bedrock Converse: the only wire Anthropic models are served on
  /// there. A JSON answer is a forced tool call rather than a
  /// `response_format`.
  bedrockConverse,
}

/// Where one slot points and what it calls the model there.
///
/// A value, not a client: it is what a resolver returns and what the prefs
/// compose, and holding it apart from `LlmClient` is what lets the URL and the
/// model name change together, atomically, between two requests.
@immutable
class LlmTarget {
  final String baseUrl;
  final String model;

  /// Which wire this target speaks, or null to follow the client's own.
  ///
  /// Null for every target composed from the two slot prefs, and for every
  /// `const LlmTarget(...)` in the tree — which is why it is optional: a
  /// bench constructs its client on a wire and resolves nothing, and the app
  /// resolves a target whose wire is whatever the user's spec said.
  final LlmWire? wire;

  /// This target's bearer token, or null to follow the client's own.
  ///
  /// A SECRET. It reaches this object from the keychain, goes onto the wire as
  /// the `Authorization` header, and appears nowhere else — not in
  /// [toString], not in an `LlmCallRecord`, not in an exception message, and
  /// never in `app_prefs`.
  final String? bearer;

  const LlmTarget({
    required this.baseUrl,
    required this.model,
    this.wire,
    this.bearer,
  });

  @override
  bool operator ==(Object other) =>
      other is LlmTarget &&
      other.baseUrl == baseUrl &&
      other.model == model &&
      other.wire == wire &&
      other.bearer == bearer;

  @override
  int get hashCode => Object.hash(baseUrl, model, wire, bearer);

  /// Deliberately unchanged, and deliberately incomplete: this string reaches
  /// logs and failure messages, and neither the wire nor — above all — the
  /// bearer belongs in one.
  @override
  String toString() => '$model @ $baseUrl';
}

/// The prose slot's compiled defaults (`--dart-define=LLAMA_URL=…`,
/// `LLAMA_MODEL=…`). Moved here from `LlmClient` so this file can build const
/// targets from them without importing upward; `LlmClient.defaultBaseUrl` and
/// friends are now const aliases of these, and every existing reference to
/// those names keeps working.
const String proseUrlDefault = String.fromEnvironment(
  'LLAMA_URL',
  defaultValue: 'http://localhost:8080/v1/chat/completions',
);
const String proseModelDefault =
    String.fromEnvironment('LLAMA_MODEL', defaultValue: 'qwen3.8');

/// The bulk slot's compiled defaults — its own server (`make fast`), its own
/// name, because an MLX-style runtime routes on the model field.
const String fastUrlDefault = String.fromEnvironment(
  'FAST_LLAMA_URL',
  defaultValue: 'http://localhost:8082/v1/chat/completions',
);
const String fastModelDefault =
    String.fromEnvironment('FAST_LLAMA_MODEL', defaultValue: 'qwen3.8');

const LlmTarget proseSlotDefault =
    LlmTarget(baseUrl: proseUrlDefault, model: proseModelDefault);
const LlmTarget fastSlotDefault =
    LlmTarget(baseUrl: fastUrlDefault, model: fastModelDefault);

/// Display only — nothing resolves through it. The "model" is the corpus tag
/// the vectors were written under, not a name any request carries.
const LlmTarget embedSlotDefault = LlmTarget(
  baseUrl: EmbeddingsClient.defaultBaseUrl,
  model: EmbeddingsClient.modelTag,
);

const Map<ModelSlot, LlmTarget> slotDefaults = {
  ModelSlot.fast: fastSlotDefault,
  ModelSlot.prose: proseSlotDefault,
  ModelSlot.embed: embedSlotDefault,
};

/// The ids the router preset gives the three models — the `model` field a
/// request sends when the app runs its own server.
///
/// One llama-server in router mode serves all three, and it routes on the
/// model name alone, so these strings are the whole wiring between a slot and
/// the weights behind it. They are named for the ROLE rather than for the
/// checkpoint (`bond-prose`, not `qwen3.8`) so that swapping which GGUF fills
/// a role is a change to the preset file and to nothing else — no stored
/// target, no request, and no test has to learn the new checkpoint's name.
const String routerProseId = 'bond-prose';
const String routerBulkId = 'bond-bulk';
const String routerEmbedId = 'bond-embed';

/// The id of the built-in target that serves every fast-slot stage by default.
///
/// The two built-ins are DERIVED from the four slot prefs rather than stored
/// in the target list: `local-fast` IS `AppPrefs.fastTarget` and `local-prose`
/// IS `AppPrefs.proseTarget`, so the two slot editors, the managed router's
/// baseline and every test that predates targets keep meaning exactly what
/// they meant. They cannot be added, edited through the target list, or
/// removed.
const String builtInFastId = 'local-fast';
const String builtInProseId = 'local-prose';
const String builtInFastName = 'Local fast';
const String builtInProseName = 'Local prose';

/// Where this install's model work runs.
///
/// A machine preference, not a tier read off memory: the same Mac can be
/// pointed at the shared GPU box today and at its own servers tomorrow, and
/// neither answer is derivable from the hardware. [box] means the inbox and
/// writing stages dial two fixed targets over TLS and only the embedding
/// model runs here; [local] is the shipped default and every stage runs on
/// this Mac.
enum ModelPlacement { box, local }

/// Where a fresh install runs its model work: the shared GPU box when this
/// build was compiled with an address for one, and this Mac otherwise.
///
/// The box is the default because it is the measured best answer for every
/// stage but embeddings, and because a placement nobody has to find is a
/// placement a tester actually uses. A build with no [boxUrlDefault] has no
/// box to name, which includes the test suite and a plain `flutter run`, so
/// there the default stays local.
///
/// `length > 0` rather than `isNotEmpty` for one reason and no other: a
/// constant expression may read a string's length and may not call
/// `isNotEmpty`, and this value has to be const so the prefs default can be
/// one too.
const ModelPlacement defaultModelPlacement =
    boxUrlDefault.length > 0 ? ModelPlacement.box : ModelPlacement.local;

/// Which of the three models a stage's work belongs to.
///
/// The simple Models page asks one question and answers it in three lines,
/// and this is the vocabulary those lines are drawn in. Coarser than
/// [ModelSlot] on purpose: a slot says which local server a stage would dial,
/// a role says which MODEL does the work wherever it runs, which is what
/// lets `storyline_membership` sit on the big model on the box and on the
/// small one here without a fourth name for it.
///
/// Not `ModelRole`, which `model_manifest.dart` already spells
/// `{embed, bulk, prose}` for the three files a machine downloads. The two
/// mean nearly the same thing and cannot be merged: the manifest imports this
/// file, so this file cannot import the manifest's enum back. A stage has a
/// STAGE role, a downloaded file has a model role, and a screen that wants
/// both says which it means.
enum StageRole { big, small, embed }

/// The two targets [ModelPlacement.box] writes, by fixed id.
///
/// Fixed rather than generated so that the two derived specs, the two
/// keychain entries and `usePlacement`'s sweep of the stage entries all name
/// the same pair. The names carry a middle dot rather than a dash because
/// user-facing strings take no em-dashes.
const String boxProseId = 'box-prose';
const String boxBulkId = 'box-bulk';
const String boxProseName = 'Your server · big model';
const String boxBulkName = 'Your server · small model';

/// What each box slot calls its model on the wire: the 27B on the writing
/// slot, the 4B on the inbox slot, as the box's two vLLM servers serve them.
const String boxProseModel = 'qwen3.8';
const String boxBulkModel = 'qwen3-4b';

/// The box address the wizard prefills, compiled in from `.env`'s
/// `BOND_BOX_URL` through the Makefile's `APP_SECRET_DEFINE`.
///
/// Empty in every build that did not pass the define, including the test
/// suite, so a wizard on a plain `flutter run` asks for the address. The
/// access key is NEVER compiled in: it is typed once and lives in the
/// keychain.
const String boxUrlDefault = String.fromEnvironment('BOND_BOX_URL');

/// A typed box address as the two completions URLs are built from it: trimmed,
/// and with every trailing slash gone.
///
/// One function rather than the same two lines in the wizard, the Settings
/// page and `useBox`: a pasted address arrives with whitespace and often
/// with a slash, and three copies of the strip is three places for
/// `https://box.example.com//prose/v1/chat/completions` to come from. Returns
/// the empty string for an empty input, which is what both callers read as
/// "nothing typed yet".
String normalizeBoxBaseUrl(String raw) {
  var base = raw.trim();
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  return base;
}

/// The box ORIGIN behind a stored [boxProseId] target's URL, or the empty
/// string when [url] is not one this app wrote.
///
/// Whether [base], already through [normalizeBoxBaseUrl], is an origin the
/// box can be dialled at: an http or https scheme and a host. The ONE rule
/// `AppPrefsNotifier.setBoxServers` refuses on and the forms check before pressing
/// it, so a refusal is a sentence on the page rather than an error thrown past
/// a fire-and-forget Save.
bool isBoxOrigin(String base) {
  final origin = Uri.tryParse(base);
  return origin != null &&
      (origin.scheme == 'http' || origin.scheme == 'https') &&
      origin.host.isNotEmpty;
}

/// [normalizeBoxBaseUrl] read backwards, and the reason it is a function: the
/// Settings pane prefills its address field from the pair already stored so
/// that somebody whose access key was rotated types the key alone, and
/// re-deriving the origin by hand is how the two halves of one recipe drift.
String boxBaseFromProseUrl(String url) {
  const suffix = '/prose/v1/chat/completions';
  return url.endsWith(suffix)
      ? url.substring(0, url.length - suffix.length)
      : '';
}

/// `localhost:8082` out of a full completions URL — the part a person reads
/// to tell two servers apart, without the `/v1/chat/completions` every one
/// of them ends in.
///
/// A URL that does not parse is returned WHOLE. Something typed into the
/// field is still the answer to "where does this point", and hiding it
/// behind a blank would leave the summary lying about a slot that is
/// genuinely misconfigured.
String hostPort(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return url;
  return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
}

/// Whether [url] names this machine, by the three spellings a person types.
///
/// The Models page asks it before saying an access key is needed: a server
/// somebody runs on their own Mac needs none, and telling them to paste one
/// would be an instruction with nothing to follow it. It is NOT a test of who
/// operates the server — [isThirdPartyHost] answers that, and deliberately
/// reads nothing into loopback, because the shared box arrives over an `ssh`
/// tunnel at `localhost:18100`.
bool isLoopbackHost(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  return host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '::1' ||
      host == '[::1]';
}

/// Hosts whose operator is a third party: a target here on `draft_reply` or
/// `draft_improve` needs the one-time consent (decision 9).
///
/// Loopback is NOT a signal in either direction. The GPU box arrives over an
/// `ssh` tunnel at `localhost:18100`, so "not loopback" would miss it, and a
/// Bedrock endpoint proxied onto loopback would read as local. What this list
/// answers is narrower and honest: whose machine is on the other end.
///
/// `amazonaws.com` as a whole is NOT here. The shared GPU box is an EC2
/// instance this install's owner rents, pays for and runs, reached under a
/// Route 53 name or an EC2 public name; sending mail to it is not sending
/// mail to a vendor. Bedrock IS a vendor and is matched by its own hostname
/// shape in [isThirdPartyHost].
const Set<String> thirdPartyHosts = {
  'anthropic.com',
  'openai.com',
  'deepseek.com',
};

/// Whether [url]'s host is a Bedrock runtime host, one of [thirdPartyHosts],
/// or a subdomain of one.
///
/// A URL that does not parse is NOT third party: an unparseable target cannot
/// be dialled at all, and treating it as cloud would put a consent screen in
/// front of a typo.
bool isThirdPartyHost(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase();
  if (host == null || host.isEmpty) return false;
  // `bedrock-runtime.<region>.amazonaws.com`, and nothing else under AWS: the
  // shared GPU box is an EC2 instance this install's owner rents and runs.
  if (host.startsWith('bedrock') && host.endsWith('.amazonaws.com')) {
    return true;
  }
  for (final domain in thirdPartyHosts) {
    if (host == domain || host.endsWith('.$domain')) return true;
  }
  return false;
}

/// Which wire a server at [url] speaks, read off its HOST alone.
///
/// The user-defined pair carries no wire of its own: a person types an
/// address and the app works out the rest, which is the whole of decision 16.
/// A Bedrock runtime host is the one shape that is not OpenAI-compatible, and
/// it is recognised here by exactly the rule [isThirdPartyHost] uses for it,
/// so an address cannot be third party by one test and OpenAI by the other.
LlmWire wireForHost(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host.startsWith('bedrock') && host.endsWith('.amazonaws.com')) {
    return LlmWire.bedrockConverse;
  }
  return LlmWire.openAi;
}

/// `--dart-define=BOND_DEV_HAND_SERVERS=1` leaves the servers to the
/// developer.
///
/// The BUILD says whether this app runs its own llama-server, on
/// `SetupGate.skipDefine`'s precedent and for its reason: an engineer who runs
/// `make model fast embed` by hand has their models in the Homebrew cache and
/// their servers already up, and that is a fact about their checkout rather
/// than a preference anybody else should be shown. Round H took the switch off
/// the Models page, so this is the only door left.
const String handServersDefine =
    String.fromEnvironment('BOND_DEV_HAND_SERVERS');

/// Whether this build leaves the servers to the developer.
///
/// Any value but the three ways a build script says no turns it on, exactly as
/// `SetupGate.skipsSetup` reads its own define — somebody who wrote `=0` to
/// turn it back off gets the app's own server rather than the opposite of what
/// they typed. `length > 0` rather than `isNotEmpty` because a constant
/// expression may read a string's length and may not call a getter on it,
/// which is [defaultModelPlacement]'s rule and its reason.
const bool handServersBuild = handServersDefine.length > 0 &&
    handServersDefine != '0' &&
    handServersDefine != 'false' &&
    handServersDefine != 'no';

/// What `AppPrefs.managedServer` is when nothing says otherwise: the app runs
/// its own server, unless the build above says the developer does.
///
/// A CONSTANT rather than a stored preference since Round H. What made it a
/// preference was a switch on the Models page, and the page asks one question
/// now: where the models run. Every shipped build answers true here.
const bool managedServerDefault = !handServersBuild;

/// One target the user can point a stage at.
///
/// The DATA behind routing: a list of these lives in the `llm_targets` pref
/// and `stage_targets` maps a stage id onto one of their ids. [hasBearer] is a
/// presence flag and nothing more — the secret itself is in the keychain under
/// `llm_target_bearer:<id>`, and this object is JSON that lands in a database
/// table.
@immutable
class LlmTargetSpec {
  /// Stable for the life of the target: the stage map points at it, the
  /// keychain entry is keyed on it, and [copyWith] cannot change it.
  final String id;

  /// What the user called it. Shown in the picker and, in Phase 4, on the
  /// composer's Improve button.
  final String name;

  final String url;
  final String model;

  final LlmWire wire;

  /// Whether a bearer token is stored for this target. NOT the token: see the
  /// class doc.
  final bool hasBearer;

  /// How many requests of one kind may be in flight at this target. The prose
  /// server's width, per target rather than per app — a GPU-served box has
  /// slots a laptop does not. Clamped 1..8 by [tryParse] and by
  /// `AppPrefsNotifier.upsertTarget`; the const constructor cannot clamp, so a
  /// hand-built spec is trusted the way every other const value here is.
  final int parallel;

  /// Whether a draft at this target may stream. False for a wire with nothing
  /// to stream, and for a server that answers a streamed request badly.
  final bool streams;

  const LlmTargetSpec({
    required this.id,
    required this.name,
    required this.url,
    required this.model,
    this.wire = LlmWire.openAi,
    this.hasBearer = false,
    this.parallel = 1,
    this.streams = true,
  });

  bool get isBuiltIn => id == builtInFastId || id == builtInProseId;

  /// Whether this is one of the two targets the GPU box placement derives
  /// from the stored address.
  ///
  /// Beside [isBuiltIn] rather than folded into it, because the two words
  /// mean different things: a built-in is edited in the two slot editors and
  /// says so on its row, and a box target is edited by changing the one
  /// address. Widening [isBuiltIn] would put "Edited above, under Fast and
  /// Prose" under a row no editor above it reaches.
  bool get isBox => id == boxProseId || id == boxBulkId;

  /// Whether this target is DERIVED rather than stored, by either route.
  ///
  /// The question every caller that guards a write actually has: a derived
  /// spec has no row in `llm_targets` to update, so this flag is what
  /// `upsertTarget` and `removeTarget` guard on, and both refuse it; the
  /// Drafts-in-flight control writes the slot pref instead of the spec.
  bool get isFixed => isBuiltIn || isBox;

  /// Whether somebody else's company operates the machine this dials. The
  /// consent rule's whole question — see [thirdPartyHosts].
  bool get isThirdParty =>
      wire == LlmWire.bedrockConverse || isThirdPartyHost(url);

  /// This spec as the value a resolver returns. [bearer] is threaded in by the
  /// notifier from its cache; the spec itself never holds one.
  ///
  /// The OpenAI wire is left NULL rather than stamped, which is what makes a
  /// stage with no stored entry resolve to exactly the [LlmTarget] it resolved
  /// to before routing was data — `targetForStage('triage') == fastTarget`,
  /// pinned by `llm_targets_test.dart`. Null means "follow the client's own
  /// wire", every client the app builds is constructed on the OpenAI one, and
  /// so the two spellings describe the same request. Only the second wire is
  /// worth saying out loud.
  LlmTarget toTarget({String? bearer}) => LlmTarget(
        baseUrl: url,
        model: model,
        wire: wire == LlmWire.openAi ? null : wire,
        bearer: bearer,
      );

  LlmTargetSpec copyWith({
    String? name,
    String? url,
    String? model,
    LlmWire? wire,
    bool? hasBearer,
    int? parallel,
    bool? streams,
  }) =>
      LlmTargetSpec(
        // Never the id: the stage map and the keychain entry are keyed on it.
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        model: model ?? this.model,
        wire: wire ?? this.wire,
        hasBearer: hasBearer ?? this.hasBearer,
        parallel: parallel ?? this.parallel,
        streams: streams ?? this.streams,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'model': model,
        'wire': wire.name,
        // A BOOLEAN, always. The token is in the keychain.
        'bearer': hasBearer,
        'parallel': parallel,
        'streams': streams,
      };

  /// One stored row, or null when it is not one.
  ///
  /// Never throws, on `AppPrefsNotifier.read`'s rule: a row somebody
  /// hand-edited into the table, or one written by a build that meant
  /// something else, is DROPPED. The four identifying fields must be non-empty
  /// strings; everything else falls back to its default, because a target with
  /// a URL and a model can still be dialled while a wire nobody recognises
  /// cannot be guessed at.
  static LlmTargetSpec? tryParse(Object? json) {
    if (json is! Map) return null;
    String? text(String key) {
      final value = json[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    final id = text('id');
    final name = text('name');
    final url = text('url');
    final model = text('model');
    if (id == null || name == null || url == null || model == null) return null;

    final wireName = json['wire'];
    var wire = LlmWire.openAi;
    for (final option in LlmWire.values) {
      if (option.name == wireName) wire = option;
    }

    final parallel = json['parallel'];
    final streams = json['streams'];
    return LlmTargetSpec(
      id: id,
      name: name,
      url: url,
      model: model,
      wire: wire,
      hasBearer: json['bearer'] == true,
      parallel: parallel is int ? parallel.clamp(1, 8) : 1,
      streams: streams is bool ? streams : true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LlmTargetSpec &&
      other.id == id &&
      other.name == name &&
      other.url == url &&
      other.model == model &&
      other.wire == wire &&
      other.hasBearer == hasBearer &&
      other.parallel == parallel &&
      other.streams == streams;

  @override
  int get hashCode =>
      Object.hash(id, name, url, model, wire, hasBearer, parallel, streams);

  @override
  String toString() => '$name: $model @ $url';
}

/// Which built-in target a slot's stages resolve to when nothing is stored.
///
/// [ModelSlot.embed] throws rather than answering: embeddings are not routed
/// at all — their vectors carry a corpus tag, and a swapped model would
/// compare two different spaces — so asking is a bug in the caller, not a
/// question with a sensible default.
String defaultTargetIdFor(ModelSlot slot) => switch (slot) {
      ModelSlot.fast => builtInFastId,
      ModelSlot.prose => builtInProseId,
      ModelSlot.embed =>
        throw ArgumentError('embeddings are not routed to a target'),
    };

/// A stage's DEFAULT slot, from [pipelineStages]. [ModelSlot.fast] for an id
/// no row names, which is the cheap slot and the one a stray id costs least on.
ModelSlot stageSlot(String stageId) {
  for (final stage in pipelineStages) {
    if (stage.id == stageId) return stage.slot;
  }
  return ModelSlot.fast;
}

/// The stages the **Use for prose stages** preset writes — every prose-slot
/// row in the stage table.
///
/// `storyline_group` is in it on purpose: it is a prose-slot stage, dark today
/// behind `StorylineTuning.groupingMode`, and a user who points prose at a box
/// should have it follow rather than be left behind the day the mode flips.
/// `draft_improve` joined it in Round H: it used to be the one stage a person
/// turned on by picking a target for it, and with the stage picker gone that
/// would have made it a feature nothing could reach. It is a prose stage like
/// the five above it now, and the consent gate still keeps both drafting
/// stages off a third-party target nobody agreed to.
const List<String> proseStageIds = [
  'storyline_group',
  'storyline_name',
  'storyline_refresh',
  'storyline_recap',
  'reply_decision',
  'draft_reply',
  'draft_improve',
];

/// The two stages that write a reply in the owner's name, and the ONE place
/// that pair is named.
///
/// Not a preset — `draft_improve` is in none — but the same closed set of two
/// is what four places ask about: the consent gate in `specForStage`, the
/// stages `applyPreset` skips when consent is missing, the picker's gated note
/// and the picker's consent prompt. Written out at each of them, a third
/// drafting stage would have to be remembered four times.
const List<String> draftStageIds = ['draft_reply', 'draft_improve'];

/// The stages **Use for storyline confirm** writes. One stage, and the one
/// Round D measured a 27B worth pointing at.
const List<String> confirmStageIds = ['storyline_membership'];

/// The stages **Use for all bulk stages** writes — every fast-slot row.
const List<String> bulkStageIds = [
  'triage',
  'needs_you',
  'extraction',
  'attachment_digest',
  'context_file_digest',
  'context_brief',
  'context_select',
  'storyline_membership',
];

/// The stages the BIG model does on the box: every prose-slot stage the
/// presets name, plus the storyline confirm.
///
/// The confirm is a fast-slot stage everywhere else and the one exception the
/// placement rule carries, because Round D and Round G both measured the 27B
/// worth its cost there and the box has the 27B sitting idle between drafts.
/// Built from [proseStageIds] so it cannot drift from the stage table, and
/// pinned against `pipelineStages` in `model_slots_test` the way the presets
/// are.
const List<String> bigModelStageIds = [...proseStageIds, 'storyline_membership'];

/// The stages the SMALL model does: the bulk set with the confirm taken out.
///
/// Written out rather than computed, because a const list may spread and may
/// not loop. `model_slots_test` pins it as exactly [bulkStageIds] minus
/// `storyline_membership`, which is what keeps the two halves of the rule
/// covering every stage exactly once.
const List<String> smallModelStageIds = [
  'triage',
  'needs_you',
  'extraction',
  'attachment_digest',
  'context_file_digest',
  'context_brief',
  'context_select',
];

/// Which model does [stageId]'s work, or null for an id no stage table row
/// names.
///
/// The three-role view of the stage table, for the page that shows one line
/// per role. `draft_improve` is [StageRole.big] like the stage it improves on:
/// the role is about which model writes, and a second pass over a reply is
/// written by the same model that wrote the first.
StageRole? roleOfStage(String stageId) {
  for (final stage in pipelineStages) {
    if (stage.id != stageId) continue;
    if (stage.slot == ModelSlot.embed) return StageRole.embed;
    if (stage.slot == ModelSlot.prose || bigModelStageIds.contains(stageId)) {
      return StageRole.big;
    }
    return StageRole.small;
  }
  return null;
}

/// Which target [stageId] resolves to when nothing is stored for it — THE
/// PLACEMENT RULE.
///
/// The one function that says where a stage goes by default, and the reason
/// the GPU box can be the default with nothing written to the database: on
/// [ModelPlacement.box] with an address to dial, the big stages answer
/// [boxProseId] and the small ones [boxBulkId], and everywhere else the answer
/// is the slot's built-in exactly as it was before placements existed.
///
/// Null where there is no default to give: `embeddings` is the one stage that
/// is not routed at all. [hasBox] is passed rather than read, because the
/// address lives in the prefs and this file may not import upward.
String? placementDefaultTargetId({
  required ModelPlacement placement,
  required bool hasBox,
  required String stageId,
}) {
  final slot = stageSlot(stageId);
  if (slot == ModelSlot.embed) return null;
  if (placement == ModelPlacement.box && hasBox) {
    if (bigModelStageIds.contains(stageId)) return boxProseId;
    if (smallModelStageIds.contains(stageId)) return boxBulkId;
    // An id no role list names is an id no stage table row names either, and
    // [stageSlot] has already answered fast for it. It falls through to the
    // built-in rather than to a box target, which is the cheap wrong answer
    // rather than the expensive one.
  }
  return defaultTargetIdFor(slot);
}

/// One pipeline stage, as the settings screen names it.
///
/// AUTHORED, not derived, and since Round E the [slot] is the stage's DEFAULT
/// rather than its wiring: every stage resolves a target per call through
/// `stageLlmClientProvider`, and what it resolves to is the `stage_targets`
/// entry when there is one and the slot's built-in target — `Local fast` or
/// `Local prose` — when there is not. This table is what the settings screen
/// lists and what the defaults are read off, and `model_slots_test.dart` is
/// what keeps it honest against the handler list.
@immutable
class PipelineStageInfo {
  /// The `schemaName` the task sends, where the stage makes a model call —
  /// which is also what lands in an activity row's `llm_label`.
  final String id;

  final String label;
  final String description;

  /// The target this stage resolves to when `stage_targets` names none.
  final ModelSlot slot;

  /// Whether the stage has NO target until the user picks one.
  ///
  /// NO ROW SETS IT since Round H. `draft_improve` was the one that did, and
  /// its entry was the feature being on; with the stage picker gone the only
  /// way to write one went too, so Improve a draft is a prose stage like the
  /// rest and is routed by the rule. The field stays, with no member and
  /// nothing branching on it, because a future stage that is genuinely off
  /// until somebody asks for it would want exactly this, and
  /// `model_slots_test` pins that no current row sets it.
  final bool optional;

  const PipelineStageInfo({
    required this.id,
    required this.label,
    required this.description,
    required this.slot,
    this.optional = false,
  });
}

/// Every stage that dials a model, in pipeline order — the order of
/// `docs/pipeline/README.md`'s stage table.
///
/// The `slot` column is each stage's DEFAULT target. Changing a default is a
/// row here and an edit to `docs/pipeline/10-model-routing.md`; changing where
/// a stage goes on one machine is Settings → Models, and costs no code at all.
const List<PipelineStageInfo> pipelineStages = [
  PipelineStageInfo(
    id: 'triage',
    label: 'Triage',
    description: 'Urgency, category, summary, action items',
    slot: ModelSlot.fast,
  ),
  PipelineStageInfo(
    id: 'needs_you',
    label: 'Needs-you verdict',
    description: 'Whether a message wants the owner',
    slot: ModelSlot.fast,
  ),
  PipelineStageInfo(
    id: 'extraction',
    label: 'Extraction',
    description: 'Evidence, topics, people, intent, importance',
    slot: ModelSlot.fast,
  ),
  PipelineStageInfo(
    id: 'attachment_digest',
    label: 'Attachment digest',
    description: 'What an attached document is, and what it asks for',
    slot: ModelSlot.fast,
  ),
  PipelineStageInfo(
    id: 'context_file_digest',
    label: 'Directory file digest',
    description: 'What one file in a registered directory is for, and what '
        'it found',
    slot: ModelSlot.fast,
  ),
  PipelineStageInfo(
    id: 'context_brief',
    label: 'Directory brief',
    description: 'The standing notes and file map of a directory, compiled '
        'for replies',
    slot: ModelSlot.fast,
  ),
  PipelineStageInfo(
    id: 'context_select',
    label: 'Directory section pick',
    description: 'Which two sections of a directory a reply should read in '
        'full',
    slot: ModelSlot.fast,
  ),
  PipelineStageInfo(
    id: 'storyline_membership',
    label: 'Storyline membership',
    description: 'Whether a thread belongs to a storyline',
    slot: ModelSlot.fast,
  ),
  PipelineStageInfo(
    id: 'storyline_group',
    label: 'Storyline grouping',
    description: 'Which threads in a neighbourhood are one project or event',
    slot: ModelSlot.prose,
  ),
  PipelineStageInfo(
    id: 'storyline_name',
    label: 'Storyline naming',
    description: 'The title and summary a group is given',
    slot: ModelSlot.prose,
  ),
  PipelineStageInfo(
    id: 'storyline_refresh',
    label: 'Storyline refresh',
    description: 'Re-reading a group as it grows',
    slot: ModelSlot.prose,
  ),
  PipelineStageInfo(
    id: 'storyline_recap',
    label: 'Storyline recap',
    description: 'Where the story stands right now',
    slot: ModelSlot.prose,
  ),
  PipelineStageInfo(
    id: 'reply_decision',
    label: 'Reply decision',
    description: 'Whether a message needs an answer at all',
    slot: ModelSlot.prose,
  ),
  PipelineStageInfo(
    id: 'draft_reply',
    label: 'Draft generation',
    description: 'The suggested reply itself',
    slot: ModelSlot.prose,
  ),
  PipelineStageInfo(
    id: 'draft_improve',
    label: 'Improve a draft',
    description: 'A second pass over a suggested reply, on the big model',
    slot: ModelSlot.prose,
  ),
  PipelineStageInfo(
    id: 'embeddings',
    label: 'Embeddings and search',
    description: 'Clustering and per-message search vectors',
    slot: ModelSlot.embed,
  ),
];

/// What this Mac runs.
///
/// Two of the three are read off memory alone, because two things differ between the machines the ledger has
/// numbers for: whether the writing model (the 27B, 19 GB on disk and 22 GB
/// resident with its MTP head) is downloaded and started at all, and how the
/// inbox model's context is split. Everything else — the embedding model, the
/// 4B, the search corpora, sync — runs the same way on 16 GB as on 64 GB.
/// A third memory tier for 8 GB machines is a measured row in
/// `docs/model-bakeoff.md` and not shipped: one more checkpoint to pin and no
/// machine to test it on. [remote] is a third VALUE but not a third rung: it
/// is what [ModelPlacement.box] resolves to.
enum MachineTier {
  /// The embedding model, the inbox model and the writing model, all local.
  /// The 64 GB rows of the ledger are this tier.
  full,

  /// The embedding model and the inbox model only. The writing stages run on
  /// the inbox model unless the install is pointed at the user's own servers,
  /// and drafts are on demand rather than prefetched.
  inbox,

  /// The embedding model alone: every other stage is on the shared GPU box.
  ///
  /// NOT a memory rung. [machineTierFor] never returns it at any byte count;
  /// it is what `effectiveTierProvider` answers under
  /// [ModelPlacement.box], and it is here rather than in a second enum
  /// because `ModelManifest.forTier` is keyed on this one and a parallel
  /// resolution API would touch the same consumers twice.
  remote,
}

/// The memory at or above which the writing model is downloaded and started.
///
/// 40 GiB: a 48 GB Mac is in, a 36 GB Mac is out. The three servers hold
/// about 26.4 GB resident together at 16K context (round 0's sizes, MTP on),
/// which leaves a 36 GB machine no room for the app and the system, and
/// leaves a 48 GB machine the same headroom the 64 GB rows had spare.
const int fullTierMinBytes = 40 * 1024 * 1024 * 1024;

/// The smallest memory the golden set was measured on. Below it the inbox
/// tier still runs, and the wizard says triage will be slower than measured.
const int measuredFloorBytes = 16 * 1024 * 1024 * 1024;

/// The tier for a machine reporting [memoryBytes] of physical memory.
///
/// Unknown memory (zero or less, which is what `flutter test` and a build
/// without the system channel answer) is [MachineTier.full]: nothing is
/// refused for a fact the app could not read, the same rule
/// `HardwareInfo.unknown` states.
///
/// Never [MachineTier.remote] at any byte count: that tier is a placement,
/// not a reading of this machine.
MachineTier machineTierFor(int memoryBytes) {
  if (memoryBytes <= 0) return MachineTier.full;
  return memoryBytes >= fullTierMinBytes ? MachineTier.full : MachineTier.inbox;
}

/// The stage → target entries a tier writes, keyed by stage id.
///
/// [MachineTier.full] writes nothing: the compiled defaults ARE that tier, so
/// a fresh 64 GB install keeps an empty `stage_targets` and stays
/// byte-identical to the two-slot app. [MachineTier.inbox] points every
/// prose-slot stage at the built-in fast target, so nothing parks on a machine
/// with no prose server; built from [proseStageIds] so it cannot drift from the
/// stage table, `draft_improve` included since Round H made it a prose stage
/// like the others. The confirm and the bulk stages already default to the
/// fast target.
///
/// [MachineTier.remote] writes nothing, and MUST stay empty: `applyTierDefaults`
/// builds its `governed` set from the union of every tier's keys, so a stage
/// named here would widen what `applyTierDefaults(full)` clears on a machine
/// that never saw the box.
Map<String, String> tierStageDefaults(MachineTier tier) => switch (tier) {
      MachineTier.full => const {},
      MachineTier.inbox => {for (final id in proseStageIds) id: builtInFastId},
      MachineTier.remote => const {},
    };

/// The draft policy a tier writes.
///
/// The inbox tier drafts on demand: its writer is the 4B, whose drafts the
/// golden set has not judged, and nobody should pay for them unasked. The full
/// tier keeps the shipped default.
/// [MachineTier.remote] drafts on the box's 27B, which is the writing model
/// the ledger measured, so it keeps the shipped default.
DraftPolicy tierDraftPolicy(MachineTier tier) => switch (tier) {
      MachineTier.full => DraftPolicy.needsYou,
      MachineTier.inbox => DraftPolicy.onDemand,
      MachineTier.remote => DraftPolicy.needsYou,
    };
