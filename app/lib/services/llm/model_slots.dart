import 'package:flutter/foundation.dart' show immutable;

import '../../models/draft_policy.dart';
import 'embeddings_client.dart';

/// Which of the three models a piece of work goes to.
///
/// Since the decision-model round there are three ROLES and one model each:
/// [generative] writes every piece of text (the old fast and prose slots
/// merged into it), [decide] is the fine-tuned classifier that sorts and flags
/// every message, and [embed] writes the vectors. [embed] is deliberately not
/// switchable: stored vectors carry a hardcoded model tag
/// ([EmbeddingsClient.modelTag]), so a swapped embedding model would silently
/// compare vectors from two different spaces.
enum ModelSlot { generative, decide, embed }

/// What an access key with characters no HTTP header can carry says. Never
/// the key itself.
const String accessKeyCharsText =
    'The access key has characters a server cannot accept. Paste it again.';

/// Whether [key] can ride an `Authorization` header: printable ASCII only
/// (0x21 to 0x7E), no spaces, no line breaks, nothing a paste can smuggle in.
bool isUsableAccessKey(String key) =>
    key.isNotEmpty && key.codeUnits.every((c) => c >= 0x21 && c <= 0x7E);

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

  /// Why this target cannot answer right now, as a sentence a person can act
  /// on, or null when it can. Set on a MANAGED target whose model the router
  /// is not serving (a chosen generative model not yet downloaded, a
  /// decision model not yet installed): the client then throws its
  /// not-installed exception WITHOUT a request, so the work PARKS under the
  /// reason `not_installed` rather than
  /// taking the router's 400 for an unknown model, which is fatal.
  final String? unavailable;

  const LlmTarget({
    required this.baseUrl,
    required this.model,
    this.wire,
    this.bearer,
    this.unavailable,
  });

  @override
  bool operator ==(Object other) =>
      other is LlmTarget &&
      other.baseUrl == baseUrl &&
      other.model == model &&
      other.wire == wire &&
      other.bearer == bearer &&
      other.unavailable == unavailable;

  @override
  int get hashCode => Object.hash(baseUrl, model, wire, bearer, unavailable);

  /// Deliberately unchanged, and deliberately incomplete: this string reaches
  /// logs and failure messages, and neither the wire nor — above all — the
  /// bearer belongs in one.
  @override
  String toString() => '$model @ $baseUrl';
}

/// The generative role's compiled defaults (`--dart-define=LLAMA_URL=…`,
/// `LLAMA_MODEL=…`). Moved here from `LlmClient` so this file can build const
/// targets from them without importing upward; `LlmClient.defaultBaseUrl` and
/// friends are now const aliases of these, and every existing reference to
/// those names keeps working.
const String generativeUrlDefault = String.fromEnvironment(
  'LLAMA_URL',
  defaultValue: 'http://localhost:8080/v1/chat/completions',
);
const String generativeModelDefault =
    String.fromEnvironment('LLAMA_MODEL', defaultValue: 'qwen3.8');

const LlmTarget generativeSlotDefault =
    LlmTarget(baseUrl: generativeUrlDefault, model: generativeModelDefault);

/// The decision server's compiled defaults (`--dart-define=DECIDE_URL=…`,
/// `DECIDE_MODEL=…`): the FULL `/v1/embeddings` URL `make decide` serves on
/// :8083, and the name a router would route on. Here rather than in
/// `DecisionClient` for [generativeUrlDefault]'s reason: the prefs compose the
/// hand-servers decision target out of them, and this file may not import the
/// client back. `DecisionClient.defaultBaseUrl` and `defaultModel` are const
/// aliases of these.
const String decideUrlDefault = String.fromEnvironment(
  'DECIDE_URL',
  defaultValue: 'http://127.0.0.1:8083/v1/embeddings',
);
const String decideModelDefault =
    String.fromEnvironment('DECIDE_MODEL', defaultValue: 'bond-decide');

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

/// The decision model's router id: the fine-tuned encoder served as a
/// mean-pooled embedding model beside the other three.
const String routerDecideId = 'bond-decide';

/// The ids of the two targets that run on THIS MAC — the managed router, or
/// the hand-started servers of a `BOND_DEV_HAND_SERVERS` build.
///
/// DERIVED, like every target now: `AppPrefs.generativeSpec` and
/// `AppPrefs.decisionSpec` compose them from the placement and the managed
/// model choice, and nothing stores them.
const String localGenerativeId = 'local-generative';
const String localDecisionId = 'local-decision';

/// The user-facing names of the five fixed targets. A middle dot rather than
/// a dash, because user-facing strings take no em-dashes.
const String localGenerativeName = 'This Mac · generative';
const String localDecisionName = 'This Mac · decision';
const String boxProseName = 'Your server · generative';
const String boxDecideName = 'Your server · decision';
const String cloudDraftsName = 'Cloud drafts';

/// The optional cloud-drafts target: the ONE place a third-party service may
/// serve, and only `draft_reply` and `draft_improve`, behind the consent.
/// Its id is the keychain entry's too.
const String cloudDraftsId = 'cloud-drafts';

/// Where one role's model runs.
///
/// A machine preference, not a tier read off memory: the same Mac can be
/// pointed at the owner's own server today and at its own models tomorrow,
/// and neither answer is derivable from the hardware. [box] means "Your
/// server" (the word is historical, see app/CLAUDE.md); [local] means this
/// Mac, on the managed router. Two roles carry one each since the
/// decision-model round: `AppPrefs.modelPlacement` is the GENERATIVE
/// placement and `AppPrefs.decisionPlacement` the decision one.
enum ModelPlacement { box, local }

/// Where a fresh install runs its GENERATIVE model: the owner's box when this
/// build was compiled with an address for one, and this Mac otherwise. The
/// decision model defaults to this Mac whatever the build (it reads every
/// message, and a local forward pass beats any network hop).
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
/// The vocabulary the Models page draws its rows in, and since the
/// decision-model round the same partition as [ModelSlot]: one model per role.
///
/// Not `ModelRole`, which `model_manifest.dart` spells for the FILES a machine
/// holds (two of which, the 27B and the 4B, can each fill the generative
/// role). A stage has a STAGE role, a downloaded file has a model role, and a
/// screen that wants both says which it means.
enum StageRole { decision, generative, embed }

/// The two "Your server" targets, by fixed id: the generative remote and the
/// decision remote.
///
/// Fixed rather than generated so that the derived specs and the keychain
/// entries name the same ids. `box-prose` keeps its Round H spelling on
/// purpose: it is the keychain entry an existing install's key already lives
/// under, and reusing it is what spares the upgrade a re-key.
const String boxProseId = 'box-prose';
const String boxDecideId = 'box-decide';

/// What each remote is asked for when no name was discovered: the 27B the
/// compiled box serves under `/prose`, and the decision model under `/decide`.
const String boxProseModel = 'qwen3.8';
const String boxDecideModel = 'bond-decide-mbl-v3';

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
/// page and the role writers: a pasted address arrives with whitespace and often
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
/// `AppPrefsNotifier.useGenerative` refuses on and the forms check before pressing
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

/// One target a stage can resolve to.
///
/// The VALUE routing answers with: `AppPrefs.specForStage` derives one of the
/// five fixed specs per call and nothing stores them. [toJson] and [tryParse]
/// survive for the frozen one-shot migrations that read the legacy
/// `llm_targets` rows. [hasBearer] is a presence flag and nothing more — the
/// secret itself is in the keychain under `llm_target_bearer:<id>`.
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
  /// slots a laptop does not. Clamped 1..8 by [tryParse]; the const
  /// constructor cannot clamp, so a derived spec is trusted the way every
  /// other const value here is.
  final int parallel;

  /// How many message-text calls (extraction, attachment digests) may be in
  /// flight at this target: the fast lane's width, where [parallel] is the
  /// draft lane's. Its own number because the two lanes run side by side on
  /// one server, and the build's box (sixteen sequences in its prose-only
  /// profile) can give the backlog eight while drafts keep theirs. Clamped 1..8 by [tryParse], as [parallel].
  final int textParallel;

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
    this.textParallel = 3,
    this.streams = true,
  });

  /// Whether somebody else's company operates the machine this dials. The
  /// consent rule's whole question — see [thirdPartyHosts].
  bool get isThirdParty =>
      wire == LlmWire.bedrockConverse || isThirdPartyHost(url);

  /// This spec as the value a resolver returns. [bearer] is threaded in by the
  /// notifier from its cache; the spec itself never holds one.
  ///
  /// The OpenAI wire is left NULL rather than stamped, which is what makes a
  /// stage with no stored entry resolve to exactly the [LlmTarget] it resolved
  /// to before routing was data, pinned by `llm_targets_test.dart`. Null
  /// means "follow the client's own wire", every client the app builds is
  /// constructed on the OpenAI one, and
  /// so the two spellings describe the same request. Only the second wire is
  /// worth saying out loud.
  LlmTarget toTarget({String? bearer, String? unavailable}) => LlmTarget(
        baseUrl: url,
        model: model,
        wire: wire == LlmWire.openAi ? null : wire,
        bearer: bearer,
        unavailable: unavailable,
      );

  LlmTargetSpec copyWith({
    String? name,
    String? url,
    String? model,
    LlmWire? wire,
    bool? hasBearer,
    int? parallel,
    int? textParallel,
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
        textParallel: textParallel ?? this.textParallel,
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
        'text_parallel': textParallel,
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
    final textParallel = json['text_parallel'];
    final streams = json['streams'];
    return LlmTargetSpec(
      id: id,
      name: name,
      url: url,
      model: model,
      wire: wire,
      hasBearer: json['bearer'] == true,
      parallel: parallel is int ? parallel.clamp(1, 8) : 1,
      textParallel: textParallel is int ? textParallel.clamp(1, 8) : 3,
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
      other.textParallel == textParallel &&
      other.streams == streams;

  @override
  int get hashCode => Object.hash(
      id, name, url, model, wire, hasBearer, parallel, textParallel, streams);

  @override
  String toString() => '$name: $model @ $url';
}

/// A stage's slot, from [pipelineStages]. [ModelSlot.generative] for an id no
/// row names: every stage that makes a text call is generative, so that is the
/// answer a stray chat stage would have had anyway.
ModelSlot stageSlot(String stageId) {
  for (final stage in pipelineStages) {
    if (stage.id == stageId) return stage.slot;
  }
  return ModelSlot.generative;
}

/// The two stages that write a reply in the owner's name, and the ONE place
/// that pair is named.
///
/// The optional cloud-drafts target routes these two and nothing else, and
/// the consent gate in `AppPrefs.specForStage` is keyed on the same list.
const List<String> draftStageIds = ['draft_reply', 'draft_improve'];

/// Which model does [stageId]'s work, or null for an id no stage table row
/// names. One role per slot since the decision-model round.
StageRole? roleOfStage(String stageId) {
  for (final stage in pipelineStages) {
    if (stage.id != stageId) continue;
    return switch (stage.slot) {
      ModelSlot.generative => StageRole.generative,
      ModelSlot.decide => StageRole.decision,
      ModelSlot.embed => StageRole.embed,
    };
  }
  return null;
}

/// Which managed generative model this Mac serves: [stored] when it names one
/// the [tier] can hold, else the tier's own default.
///
/// [stored] is `AppPrefs.generativeManagedModel`: `''` (follow the hardware),
/// [routerProseId] (the 27B) or [routerBulkId] (the 4B). The 27B on the
/// [MachineTier.inbox] tier is REFUSED here rather than on a screen, because
/// that machine never downloads it and a preset naming it would not start;
/// it falls back to the 4B. Anything unrecognised reads as `''`.
String managedGenerativeIdFor(MachineTier tier, String stored) {
  if (stored == routerBulkId) return routerBulkId;
  if (stored == routerProseId) {
    return tier == MachineTier.full ? routerProseId : routerBulkId;
  }
  return switch (tier) {
    MachineTier.full => routerProseId,
    MachineTier.inbox => routerBulkId,
  };
}

/// One pipeline stage, as the settings screen names it.
///
/// AUTHORED, not derived. The [slot] is the stage's ROLE: every stage
/// resolves a target per call through `stageLlmClientProvider`, and what it
/// resolves to is `AppPrefs.specForStage`, a rule over the role's placement.
/// `model_slots_test.dart` is what keeps this table honest against the
/// handler list.
@immutable
class PipelineStageInfo {
  /// The `schemaName` the task sends, where the stage makes a model call —
  /// which is also what lands in an activity row's `llm_label`.
  final String id;

  final String label;
  final String description;

  /// Which model does this stage's work.
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
/// The `slot` column is each stage's ROLE. Changing one is a row here and an
/// edit to `docs/pipeline/10-model-routing.md`; changing where a role runs on
/// one machine is Settings → Models, and costs no code at all.
///
/// `decision` is FIRST: the decision pass runs on every kept message before
/// any text call. It has no schema of its own (it is an embedding call whose
/// heads run in Dart).
const List<PipelineStageInfo> pipelineStages = [
  PipelineStageInfo(
    id: 'decision',
    label: 'Decision model',
    description: 'Sorts and flags every message',
    slot: ModelSlot.decide,
  ),
  PipelineStageInfo(
    id: 'message_text',
    label: 'Message text',
    description: 'Summary, action items, deadline, topics, project',
    slot: ModelSlot.generative,
  ),
  PipelineStageInfo(
    id: 'attachment_digest',
    label: 'Attachment digest',
    description: 'What an attached document is, and what it asks for',
    slot: ModelSlot.generative,
  ),
  PipelineStageInfo(
    id: 'context_file_digest',
    label: 'Directory file digest',
    description: 'What one file in a registered directory is for, and what '
        'it found',
    slot: ModelSlot.generative,
  ),
  PipelineStageInfo(
    id: 'context_brief',
    label: 'Directory brief',
    description: 'The standing notes and file map of a directory, compiled '
        'for replies',
    slot: ModelSlot.generative,
  ),
  PipelineStageInfo(
    id: 'context_select',
    label: 'Directory section pick',
    description: 'Which two sections of a directory a reply should read in '
        'full',
    slot: ModelSlot.generative,
  ),
  PipelineStageInfo(
    id: 'storyline_name',
    label: 'Storyline naming',
    description: 'The title and summary a group is given',
    slot: ModelSlot.generative,
  ),
  PipelineStageInfo(
    id: 'storyline_refresh',
    label: 'Storyline refresh',
    description: 'Re-reading a group as it grows',
    slot: ModelSlot.generative,
  ),
  PipelineStageInfo(
    id: 'storyline_recap',
    label: 'Storyline recap',
    description: 'Where the story stands right now',
    slot: ModelSlot.generative,
  ),
  PipelineStageInfo(
    id: 'draft_reply',
    label: 'Draft generation',
    description: 'The suggested reply itself',
    slot: ModelSlot.generative,
  ),
  PipelineStageInfo(
    id: 'draft_improve',
    label: 'Improve a draft',
    description: 'A second pass over a suggested reply',
    slot: ModelSlot.generative,
  ),
  // Not in [draftStageIds]: a brief is written FOR the owner, never in their
  // name, so Cloud drafts never sees it (the calendar round's D9).
  PipelineStageInfo(
    id: 'meeting_brief',
    label: 'Meeting brief',
    description: "A brief before a meeting with people you've been writing to",
    slot: ModelSlot.generative,
  ),
  // On demand, not a lane: called from the Day command bar on Enter, and
  // only when the lexicon and the resolvers could not finish the request.
  // Not in [draftStageIds]: it reads the owner's own command and writes
  // nothing in their name, so Cloud drafts never sees it.
  PipelineStageInfo(
    id: 'calendar_intent',
    label: 'Calendar command',
    description: 'Reads a calendar command the rules could not finish',
    slot: ModelSlot.generative,
  ),
  PipelineStageInfo(
    id: 'embeddings',
    label: 'Embeddings and search',
    description: 'Clustering and per-message search vectors',
    slot: ModelSlot.embed,
  ),
];

/// What this Mac can hold, read off its memory alone.
///
/// Two things differ between the machines the ledger has numbers for: whether
/// the writing model (the 27B, 19 GB on disk and 22 GB resident with its MTP
/// head) is downloaded and started at all, and how the 4B's context is split.
/// Everything else runs the same way on 16 GB as on 64 GB. Since the
/// decision-model round the tier constrains the MANAGED generative choice
/// (`managedGenerativeIdFor`): the 27B only on [full]. Where the roles run is
/// the placements' answer, not this one.
enum MachineTier {
  /// The embedding, decision and 4B models, and the 27B. The 64 GB rows of
  /// the ledger are this tier.
  full,

  /// The embedding, decision and 4B models only. The managed generative model
  /// is the 4B, and drafts are on demand rather than prefetched.
  inbox,
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
MachineTier machineTierFor(int memoryBytes) {
  if (memoryBytes <= 0) return MachineTier.full;
  return memoryBytes >= fullTierMinBytes ? MachineTier.full : MachineTier.inbox;
}

/// The draft policy a managed generative model writes.
///
/// The inbox tier drafts on demand: its writer is the 4B, whose drafts the
/// golden set has not judged, and nobody should pay for them unasked. The full
/// tier keeps the shipped default.
DraftPolicy tierDraftPolicy(MachineTier tier) => switch (tier) {
      MachineTier.full => DraftPolicy.needsYou,
      MachineTier.inbox => DraftPolicy.onDemand,
    };
