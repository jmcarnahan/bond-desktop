import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_paths.dart' show AppPaths;
import '../data/message_store.dart';
import '../models/draft_policy.dart';
import '../models/home_sort.dart';
import '../models/needs_you_sort.dart';
import '../models/people_sort.dart';
import '../services/attention.dart';
import '../services/llm/embeddings_client.dart' show EmbeddingsClient;
import '../services/llm/model_slots.dart';
import '../services/sync_service.dart';
import '../services/token_store.dart';
import 'app_providers.dart';

export '../data/message_store.dart' show aboutMeKey, needsYouRulesKey;

/// The setter below takes a [NeedsYouSort], so whoever reads this file for the
/// preference has the vocabulary to change it in the same import.
export '../models/needs_you_sort.dart' show NeedsYouSort, NeedsYouSortLabel;

/// When suggested replies are written, for the same reason: the setter below
/// takes a [DraftPolicy] and the settings section that writes it needs the
/// three modes and their labels out of the same import.
export '../models/draft_policy.dart' show DraftPolicy, DraftPolicyLabel;

/// The two People orders, for the same reason: the directory and a person's
/// room read their order from here, and the menus that write it need the
/// vocabulary in the same import.
export '../models/people_sort.dart'
    show PeopleSort, PeopleSortLabel, RoomSort, RoomSortLabel;

/// The Inbox's order and its tile filters, for the same reason again: the
/// feed's notifier reads the stored order out of here, and the sort menu and
/// the tiles that write it need the vocabulary in the same import.
export '../models/home_sort.dart'
    show HomeSort, HomeSortLabel, HomeFilter, HomeFilterLabel;

/// So the settings screen reaches a slot's value and its name through one
/// import — the prefs are where both are composed. [LlmTargetSpec] and
/// [LlmWire] ride along for the same reason: the Targets list reads and writes
/// them through this file.
export '../services/llm/model_slots.dart'
    show LlmTarget, LlmTargetSpec, LlmWire, ModelSlot;

/// Which Microsoft backend the app talks through.
///
/// [backendModeMcp] goes through the Bond MCP server, which holds the Microsoft
/// grant server-side; [backendModeSdk] talks to Microsoft Graph directly from
/// this machine. MCP is the default because it is the only one of the two that
/// needs no build-time configuration — the direct mode cannot sign in at all
/// without `MS_CLIENT_ID` and `MS_TENANT_ID` compiled in.
const String backendModeMcp = 'mcp';
const String backendModeSdk = 'sdk';

/// The deployed platform's `/mcp` URL, compiled in via
/// `--dart-define=BOND_MCP_SERVER_URL=…` (`make app-run` injects it from the
/// MS_ENV file, the same mechanism as the Azure ids). Deliberately NOT a
/// hostname in source: this is a public repository, and which cluster a
/// company runs is environment configuration, not code. Empty means "this
/// build knows no deployed endpoint" — the Deployed preset disappears and the
/// default falls back to the local server.
const String mcpDeployedUrl = String.fromEnvironment('BOND_MCP_SERVER_URL');

/// The endpoint a local bond-mcps `make dev` listens on. A localhost port is
/// topology anyone's checkout shares, not an identity, so it may live in
/// source — unlike the deployed hostname above.
const String mcpLocalUrl = 'http://localhost:18001/mcp';

/// What `mcp_server_url` means when nothing is stored: the deployed platform
/// when the build carries one, else the local server. Lives here because the
/// provider that builds the client and the dialog that offers the choice must
/// agree on the strings.
const String defaultMcpServerUrl =
    mcpDeployedUrl != '' ? mcpDeployedUrl : mcpLocalUrl;

/// How a settled message announces itself: not at all, in the in-app ribbon
/// only, or through the operating system's notification centre.
///
/// [native] does not replace the ribbon, it adds to it. macOS presents no
/// banner while the app is frontmost — which is deliberate, see
/// `LocalDesktopNotifier` — so the ribbon is still what a user looking at the
/// window sees, and it is also the whole answer on a platform with no
/// notification centre this app can reach.
enum NotifyStyle { off, inApp, native }

/// The settings the user controls, held in memory so the widgets that read them
/// rebuild the moment one changes.
///
/// They live in `app_prefs` as TEXT, which is the only shape that table has.
/// Parsing back is this file's job and nobody else's — a threshold is a double
/// everywhere above here.
@immutable
class AppPrefs {
  /// The score a thread must reach to appear in Needs You. Below it, a thread
  /// is still in Conversations — the slider changes what gets promoted, never
  /// what exists.
  final double attentionThreshold;

  /// What the user says about themselves and their role. Written here, read by
  /// the next phase's prompts.
  final String aboutMe;

  /// The user's extra criteria for the needs-you judgement, fed fenced into
  /// `NeedsYouTask` on top of the rules the prompt already carries. Empty is
  /// the normal state: the defaults are meant to work for somebody who never
  /// opens this field.
  final String needsYouRules;

  /// [backendModeMcp] or [backendModeSdk]. Nothing above here parses it: the
  /// providers compare it against those two constants.
  final String backendMode;

  /// The `/mcp` endpoint MCP mode talks to. Read only in MCP mode, but stored
  /// either way so switching back does not lose a hand-typed server.
  final String mcpServerUrl;

  /// Whether the rail offers the activity log. Off by default: what the sync
  /// and the local model did is diagnostic detail, and an inbox that ships
  /// with its own machine-room door open invites reading it instead of the
  /// mail.
  final bool showActivityLog;

  /// Whether a draft that reads a registered directory may spend one extra
  /// fast call choosing two sections of it to read IN FULL before it writes.
  ///
  /// ON by default, unlike most switches here, because the one bounded call
  /// per directory-fed draft IS the feature: six passages of a thousand
  /// characters can miss the one section that carries the number, and a
  /// directory the owner registered and linked is a directory they want read
  /// properly. Off, a reply sees only the nearest passages.
  final bool contextSelectExpand;

  /// Which end of a storyline its spine starts at. Off — oldest first — is how
  /// a storyline reads as a story. Global rather than per storyline because
  /// reading direction is a habit a person has, not a fact about one grouping:
  /// someone who wants the latest at the top wants it everywhere.
  final bool storylineNewestFirst;

  /// How the Needs You pile is ordered, everywhere it is drawn — the rail,
  /// the overview and the row Enter opens. [NeedsYouSort.priority] by default,
  /// because that is the ranking the app is FOR: the reader who wants the
  /// clock instead asks for it once, and gets it in all three places.
  final NeedsYouSort needsYouSort;

  /// When a suggested reply is written without anyone asking for it.
  /// [DraftPolicy.needsYou] by default: the messages the pipeline judged to
  /// need the owner are drafted ahead of time and nothing else is, which is
  /// what keeps a backlog's worth of replies nobody will read out of the prose
  /// server's queue. A user preference, so `wipeAll` leaves it alone exactly as
  /// it leaves [needsYouSort] alone — it says how this person likes the app to
  /// work, not anything about the mailbox that was wiped.
  final DraftPolicy draftPolicy;

  /// Where this install's model work runs. [defaultModelPlacement] by
  /// default, which is the GPU box in any build compiled with an address for
  /// one and this Mac in every other.
  ///
  /// Read by `effectiveTierProvider`, which answers [MachineTier.remote] here
  /// so the manifest resolves to the embedding model alone, by the rail's
  /// parked line, which names the box rather than a local server, and — since
  /// Round H — by [defaultTargetIdForStage], which is what makes the box a
  /// rule rather than a set of rows somebody pressed a button to write.
  final ModelPlacement modelPlacement;

  /// The BIG model's address, a chat-completions URL, or EMPTY for "whatever
  /// this build was compiled with".
  ///
  /// The user-defined placement is two addresses and two model names since
  /// Round H, because the one server we shipped against is not the only shape
  /// a person can have: two llama-servers on two machines are as ordinary as
  /// one router serving both roles under `/prose` and `/bulk`.
  ///
  /// Empty is stored as empty, on [fastLlmUrl]'s rule and for its reason: the
  /// compiled address is a fact about the build, and freezing today's value
  /// into the database would make a changed [boxUrlDefault] invisible to
  /// anyone who had once opened the wizard. [effectiveBoxBigUrl] is the one
  /// place that resolves it.
  final String boxBigUrl;

  /// The SMALL model's address, on [boxBigUrl]'s rule. The same string as
  /// [boxBigUrl] is allowed and ordinary: one server can serve both roles.
  final String boxSmallUrl;

  /// What the big server calls its model on the wire, DISCOVERED from the
  /// server's own `/v1/models` rather than typed, or empty to follow the
  /// build's constant.
  final String boxBigModel;

  /// What the small server calls its model, on [boxBigModel]'s rule.
  final String boxSmallModel;

  /// Whether the box's access key is in the keychain. NOT the key, and NOT
  /// persisted: the notifier sets it from the keychain when the prefetch
  /// returns, and it is false until then.
  ///
  /// False-until-answered is deliberate. The prefetch is a round trip that the
  /// first drain can beat, and a derived spec that claimed a bearer it does
  /// not yet hold would send one unauthenticated request per stage. Honest
  /// here means the spec says `hasBearer: false` inside that window, and the
  /// supervisor's first pump waits for `ready` besides.
  final bool boxKeyStored;

  /// Whether the BIG server's key is in the keychain, and the SMALL server's.
  ///
  /// [boxKeyStored] is either of them, which is what every routing question
  /// asks; these two are what the form's two hints ask, because the addresses
  /// may name two operators and a key for one is never sent to the other.
  /// Neither is persisted, on [boxKeyStored]'s rule.
  final bool boxBigKeyStored;
  final bool boxSmallKeyStored;

  /// Whether the model work runs at all.
  ///
  /// ON by default and REMEMBERED, unlike the session switch it replaced: a
  /// fresh install starts working the moment the wizard finishes, and somebody
  /// who turns it off finds it off after a relaunch. What made it a session
  /// flag was the risk of spending the first minutes on the wrong server, and
  /// the placement rule closes that: the default server is the measured one,
  /// and a missing key or a dead address parks with a sentence rather than
  /// spending attempts.
  final bool processingOn;

  /// How the People directory is ordered. [PeopleSort.recent] by default,
  /// which is the order [peopleRooms] already hands it in: the person who
  /// spoke last is the person most likely to be looked for.
  final PeopleSort peopleSort;

  /// How one person's threads are ordered inside their room.
  /// [RoomSort.newest] by default — a room opens on what just happened, the
  /// way every other list in this app does.
  final RoomSort roomSort;

  /// How a settled message announces itself. [NotifyStyle.native] by default,
  /// unlike every other switch here: the app spends minutes deciding a message
  /// needs the user, and finishing that in silence unless someone goes looking
  /// for a setting would waste the whole point of it.
  final NotifyStyle notifyStyle;

  /// How the Inbox feed is ordered. [HomeSort.newest] by default, which is
  /// the order the store's keyset walk already hands it over in and the order
  /// every other list in this app opens on.
  final HomeSort homeSort;

  /// The bulk slot's server and model, or EMPTY for "whatever this build was
  /// compiled with".
  ///
  /// Empty is stored as empty, deliberately unlike [mcpServerUrl] — which
  /// resolves its default at read time. A model default is a fact about the
  /// machine's `local.mk`, and resolving it at read would freeze today's
  /// default into the database: change `FAST_LLAMA_MODEL` and the app would
  /// keep asking for the old name because a settings screen had once been
  /// opened. Empty means "follow the build", and it keeps meaning that.
  final String fastLlmUrl;
  final String fastLlmModel;
  final String proseLlmUrl;
  final String proseLlmModel;

  /// How many days of mail history a sync reaches back for. One per connector,
  /// because the two mailboxes are different sizes and a person who wants a
  /// quarter of email rarely wants a quarter of chat.
  ///
  /// Both default to [syncFloorDays] — Teams' own floor is the same one day,
  /// and its constant is class-static on `TeamsSync`, so naming it here would
  /// drag in that import to say a number this file already has.
  final int mailLookbackDays;
  final int teamsLookbackDays;

  /// Whether the app runs the model server itself, or expects servers the
  /// user started by hand.
  ///
  /// FALSE by default, and that is the whole compatibility story: off, every
  /// target below resolves exactly as it did before this existed, and the
  /// `make model | fast | embed` workflow is untouched. Turning it on is an
  /// opt-in in Settings, and it is what makes the three router targets live.
  ///
  /// NOT STORED since Round H: it defaults to [managedServerDefault], which a
  /// build define decides, and there is no setter and no row. The switch that
  /// wrote one is gone from the Models page, and an engineer who runs the
  /// servers by hand says so with `BOND_DEV_HAND_SERVERS`. It stays a
  /// constructor field so a test can say `AppPrefs(managedServer: false)` and
  /// assert the compiled URLs.
  final bool managedServer;

  /// The port the managed router listens on.
  ///
  /// Stored rather than picked fresh each launch so an adopted server from the
  /// previous run is findable. Since Round H the SUPERVISOR writes it as well:
  /// a launch that finds the port taken moves to a free one and remembers it
  /// here before spawning, so the preference, the pid record and the clients
  /// agree, and the app stays on that port until something moves it again.
  /// No control on screen sets it any more. Clamped to 1024..65535 on both the read
  /// and the write: below 1024 needs root, and a stored value outside the range
  /// would make every start fail with a message about a socket.
  final int routerPort;

  /// Where the GGUF files live, or EMPTY for the app's own folder.
  ///
  /// Empty is stored as empty for [fastLlmUrl]'s reason: the app's folder is
  /// derived from the application support directory at read time, and freezing
  /// today's path into the database would survive a move of the support
  /// directory as a stale absolute path. [effectiveModelsFolder] is the one
  /// place that resolves it.
  final String modelsFolder;

  /// How many drafts may be at the prose server at once.
  ///
  /// The prose slot's WIDTH, not a speed dial: one per slot the server was
  /// started with (`SLOTS` in `local.mk` for llama.cpp, `--max-num-seqs` on
  /// vLLM). A batched decode reads the weights once for the whole batch, so a
  /// second stream is close to free on a server that has a slot for it — and
  /// worth nothing at all on one that does not, where the extra request simply
  /// queues.
  ///
  /// Drafts only. A recap and a refresh both write the storyline they are
  /// about and stay at one, on `WorkHandler.concurrency`'s rule: only
  /// genuinely independent items go wider.
  ///
  /// Machine configuration like [routerPort] and [modelsFolder], so it
  /// survives a `wipeAll` — how many slots this machine's server has is not a
  /// fact about whoever is signed in.
  final int proseParallel;

  /// The targets the user added, and ONLY those.
  ///
  /// The two built-ins are derived — see [fastSpec] and [proseSpec] — so there
  /// is one source of truth for where the local servers are: the four slot
  /// prefs the two editors and the managed router already write. Stored as a
  /// JSON array under [llmTargetsKey]; a row that does not parse is dropped on
  /// the read rather than throwing.
  final List<LlmTargetSpec> targets;

  /// Which target each stage is pointed at — stage id to target id, and only
  /// the entries that are NOT the stage's default.
  ///
  /// Storing non-defaults only is what makes a fresh install byte-identical to
  /// the two-slot app: an absent entry resolves through [stageSlot] to the
  /// built-in the stage always used.
  final Map<String, String> stageTargets;

  /// Whether the owner has acknowledged what a third-party draft target
  /// receives. One acknowledgement for the machine, not one per target: what
  /// it explains is what leaves this computer, and that is the same text
  /// whichever company is on the other end.
  final bool cloudDraftsConsent;

  /// Whether a draft for an urgent message that needs the owner is improved
  /// on the `draft_improve` target without anybody pressing anything.
  ///
  /// Off until somebody turns it on, which is the answer that sends nothing:
  /// the consent above says a third-party target MAY be used, and this says
  /// the app may reach for it on its own.
  final bool cloudDraftsStanding;

  /// How many drafts a day may go to a third-party target, counting the
  /// Improve button, the standing rule above and a draft stage pointed at
  /// one. The ceiling is a spend control, so it stops all three.
  final int cloudDraftsDailyCap;

  /// The cap nobody set. Fifty drafts is a heavy day of asking and a small
  /// bill, which is the balance a default here has to strike.
  static const int defaultCloudDraftsDailyCap = 50;

  /// What [routerPort] means when nothing is stored — llama-server's own
  /// default port, which is also what `make model` uses, so a user who never
  /// touches the field gets the port every doc in this repo names.
  static const int defaultRouterPort = 8080;

  /// One draft at a time until somebody says otherwise: the shipping local
  /// server is started with one slot, and a width the server cannot honour
  /// buys queue-wait rather than throughput.
  static const int defaultProseParallel = 1;

  const AppPrefs({
    this.attentionThreshold = AttentionTuning.defaultThreshold,
    this.aboutMe = '',
    this.needsYouRules = '',
    this.backendMode = backendModeMcp,
    this.mcpServerUrl = defaultMcpServerUrl,
    this.showActivityLog = false,
    this.contextSelectExpand = true,
    this.storylineNewestFirst = false,
    this.needsYouSort = NeedsYouSort.priority,
    this.draftPolicy = DraftPolicy.needsYou,
    this.modelPlacement = defaultModelPlacement,
    this.boxBigUrl = '',
    this.boxSmallUrl = '',
    this.boxBigModel = '',
    this.boxSmallModel = '',
    this.boxKeyStored = false,
    this.boxBigKeyStored = false,
    this.boxSmallKeyStored = false,
    this.processingOn = true,
    this.peopleSort = PeopleSort.recent,
    this.roomSort = RoomSort.newest,
    this.notifyStyle = NotifyStyle.native,
    this.homeSort = HomeSort.newest,
    this.fastLlmUrl = '',
    this.fastLlmModel = '',
    this.proseLlmUrl = '',
    this.proseLlmModel = '',
    this.mailLookbackDays = syncFloorDays,
    this.teamsLookbackDays = syncFloorDays,
    this.managedServer = managedServerDefault,
    this.routerPort = defaultRouterPort,
    this.modelsFolder = '',
    this.proseParallel = defaultProseParallel,
    this.targets = const [],
    this.stageTargets = const {},
    this.cloudDraftsConsent = false,
    this.cloudDraftsStanding = false,
    this.cloudDraftsDailyCap = defaultCloudDraftsDailyCap,
  });

  /// The managed router's origin — one server, three models.
  String get routerBase => 'http://127.0.0.1:$routerPort';

  /// The three targets the managed router answers on. Same origin, different
  /// `model` field: llama-server in router mode routes on the name alone, so
  /// the ids in `model_slots.dart` are the whole wiring between a slot and the
  /// weights behind it.
  LlmTarget get routerProseTarget =>
      LlmTarget(baseUrl: '$routerBase/v1/chat/completions', model: routerProseId);

  LlmTarget get routerBulkTarget =>
      LlmTarget(baseUrl: '$routerBase/v1/chat/completions', model: routerBulkId);

  LlmTarget get routerEmbedTarget =>
      LlmTarget(baseUrl: '$routerBase/v1/embeddings', model: routerEmbedId);

  /// What the bulk client will dial on its next request.
  ///
  /// The router answers only when this slot is on the build's own values. A
  /// stored override is a deliberate act — someone pointed the slot at a
  /// server they run — and turning the managed server on must not silently
  /// take it away from them; clearing the override is what hands the slot back
  /// to the router.
  LlmTarget get fastTarget =>
      managedServer && fastLlmUrl.isEmpty && fastLlmModel.isEmpty
          ? routerBulkTarget
          : LlmTarget(
              baseUrl: fastLlmUrl.isEmpty ? fastUrlDefault : fastLlmUrl,
              model: fastLlmModel.isEmpty ? fastModelDefault : fastLlmModel,
            );

  LlmTarget get proseTarget =>
      managedServer && proseLlmUrl.isEmpty && proseLlmModel.isEmpty
          ? routerProseTarget
          : LlmTarget(
              baseUrl: proseLlmUrl.isEmpty ? proseUrlDefault : proseLlmUrl,
              model: proseLlmModel.isEmpty ? proseModelDefault : proseLlmModel,
            );

  /// One slot's target, for the settings screen's table. [ModelSlot.embed] is
  /// display only — its model is the CORPUS TAG the vectors were written
  /// under, never a name a request carries, which is why the managed answer
  /// here is still a display value and [embedRequestTarget] is the one the
  /// wire uses.
  LlmTarget targetFor(ModelSlot slot) => switch (slot) {
        ModelSlot.fast => fastTarget,
        ModelSlot.prose => proseTarget,
        ModelSlot.embed => managedServer ? routerEmbedTarget : embedSlotDefault,
      };

  /// Where the embedding client actually POSTs, and what it puts in `model`.
  ///
  /// Deliberately NOT `targetFor(ModelSlot.embed)`: the display target's model
  /// is [EmbeddingsClient.modelTag], the corpus tag stored beside every vector,
  /// and sending that to a server would ask for a model no server has. The
  /// request target's model is what the wire carries — the router's id when the
  /// app runs the server, and the literal `'embed'` llama-server has always
  /// ignored when it does not.
  LlmTarget get embedRequestTarget => managedServer
      ? routerEmbedTarget
      : const LlmTarget(
          baseUrl: EmbeddingsClient.defaultBaseUrl,
          model: EmbeddingsClient.requestModel,
        );

  /// What "Default" means for a slot's editor RIGHT NOW: the router target
  /// while the app runs its own server, the compiled default otherwise. The
  /// editor normalises a saved value equal to this back to the empty string,
  /// so pressing Save on an untouched editor keeps the slot following the
  /// router instead of freezing today's port into an override.
  LlmTarget slotBaseline(ModelSlot slot) => switch (slot) {
        ModelSlot.fast => managedServer ? routerBulkTarget : fastSlotDefault,
        ModelSlot.prose => managedServer ? routerProseTarget : proseSlotDefault,
        ModelSlot.embed => managedServer ? routerEmbedTarget : embedSlotDefault,
      };

  /// Whether this slot is on the build's own default — what the screen renders
  /// as "Default" rather than as an override.
  bool isSlotDefault(ModelSlot slot) => switch (slot) {
        ModelSlot.fast => fastLlmUrl.isEmpty && fastLlmModel.isEmpty,
        ModelSlot.prose => proseLlmUrl.isEmpty && proseLlmModel.isEmpty,
        ModelSlot.embed => true,
      };

  /// The built-in fast target, as a spec.
  ///
  /// DERIVED from [fastTarget] rather than stored, which is the whole of why
  /// targets-as-data did not fork the model settings: the four slot prefs, the
  /// two slot editors, [slotBaseline] and the managed router all still mean
  /// exactly what they meant, and this is a second view of them.
  LlmTargetSpec get fastSpec => LlmTargetSpec(
        id: builtInFastId,
        name: builtInFastName,
        url: fastTarget.baseUrl,
        model: fastTarget.model,
      );

  /// The built-in prose target, on [fastSpec]'s rule. Its width is
  /// [proseParallel] — the pref the segmented control writes — so a draft
  /// pointed at this target reads the number it always read.
  LlmTargetSpec get proseSpec => LlmTargetSpec(
        id: builtInProseId,
        name: builtInProseName,
        url: proseTarget.baseUrl,
        model: proseTarget.model,
        parallel: proseParallel,
      );

  /// The origin the build was compiled with, as the two derived URLs are
  /// built from it. Empty in the test suite and in any build that passed no
  /// define.
  static String get _compiledBase => normalizeBoxBaseUrl(boxUrlDefault);

  /// The BIG model's address as a request will dial it: the stored URL when
  /// there is one, and the build's own `/prose` derivation otherwise.
  String get effectiveBoxBigUrl => boxBigUrl.isNotEmpty
      ? normalizeBoxBaseUrl(boxBigUrl)
      : (_compiledBase.isEmpty
          ? ''
          : '$_compiledBase/prose/v1/chat/completions');

  /// The SMALL model's address, on [effectiveBoxBigUrl]'s rule and the
  /// build's `/bulk` derivation.
  String get effectiveBoxSmallUrl => boxSmallUrl.isNotEmpty
      ? normalizeBoxBaseUrl(boxSmallUrl)
      : (_compiledBase.isEmpty
          ? ''
          : '$_compiledBase/bulk/v1/chat/completions');

  /// What the big server is asked for, and the small one: the discovered name
  /// when there is one, and the constant the compiled box serves otherwise.
  String get effectiveBoxBigModel =>
      boxBigModel.isEmpty ? boxProseModel : boxBigModel;

  String get effectiveBoxSmallModel =>
      boxSmallModel.isEmpty ? boxBulkModel : boxSmallModel;

  /// Whether this install knows where BOTH models run.
  ///
  /// The whole of what the placement rule needs to know about the
  /// user-defined pair, and both halves of it, because a rule that sent the
  /// big stages to an address and the small ones nowhere would park half the
  /// pipeline. False in the test suite and in any build that passed no define,
  /// which is why [defaultModelPlacement] resolves to this Mac there.
  bool get hasBox =>
      effectiveBoxBigUrl.isNotEmpty && effectiveBoxSmallUrl.isNotEmpty;

  /// The box's inbox target, as a spec.
  ///
  /// DERIVED from the four pair prefs on [fastSpec]'s rule, and that is the
  /// change Round H is: the box used to be two rows in `llm_targets` that a
  /// button wrote, so a fresh install was on this Mac until somebody found the
  /// button. One address in, two targets out, nothing stored.
  ///
  /// The width is four only for an address that FOLLOWS THE BUILD: the
  /// compiled box is two vLLM servers started with four sequences each, which
  /// is a fact about that machine. A stored address is one request at a time,
  /// because a one-slot llama-server queues the other three past the prose
  /// client's ninety-second ceiling and reads as a server that is broken.
  ///
  /// The WIRE is read off the host, so a Bedrock endpoint typed into the form
  /// speaks Converse without anybody choosing a protocol; [hasBearer] follows
  /// [boxKeyStored] and is honest about the window before the keychain has
  /// answered.
  LlmTargetSpec get boxBulkSpec => LlmTargetSpec(
        id: boxBulkId,
        name: boxBulkName,
        url: effectiveBoxSmallUrl,
        model: effectiveBoxSmallModel,
        wire: wireForHost(effectiveBoxSmallUrl),
        hasBearer: boxKeyStored,
        parallel: boxSmallUrl.isEmpty ? 4 : 1,
      );

  /// The box's writing target, on [boxBulkSpec]'s rule.
  LlmTargetSpec get boxProseSpec => LlmTargetSpec(
        id: boxProseId,
        name: boxProseName,
        url: effectiveBoxBigUrl,
        model: effectiveBoxBigModel,
        wire: wireForHost(effectiveBoxBigUrl),
        hasBearer: boxKeyStored,
        parallel: boxBigUrl.isEmpty ? 4 : 1,
      );

  /// Every target a stage may be pointed at: the two built-ins, the box's two
  /// when there is an address for them, and the ones the user added.
  List<LlmTargetSpec> get allTargets => [
        fastSpec,
        proseSpec,
        if (hasBox) ...[boxBulkSpec, boxProseSpec],
        ...targets,
      ];

  /// One target by id, or null when nothing carries it.
  LlmTargetSpec? specById(String id) {
    for (final spec in allTargets) {
      if (spec.id == id) return spec;
    }
    return null;
  }

  /// Where a stage goes when nothing is stored for it — the placement rule,
  /// read through this install's address and placement.
  ///
  /// The one door between [placementDefaultTargetId] and everything that asks
  /// a routing question, so that the rule is stated once and the three methods
  /// that mean "equal to the default, so store nothing" all mean the same
  /// thing by it.
  String? defaultTargetIdForStage(String stageId) => placementDefaultTargetId(
        placement: modelPlacement,
        hasBox: hasBox,
        stageId: stageId,
      );

  /// Which target id a stage resolves to: the stored entry when it names a
  /// target that still exists, and the placement's default otherwise.
  ///
  /// Null for `embeddings`, which is not routed at all, and for an optional
  /// stage with no valid entry — that is what "the feature is off" looks like
  /// in the data.
  String? targetIdForStage(String stageId) {
    final stored = stageTargets[stageId];
    if (stored != null && specById(stored) != null) return stored;
    return defaultTargetIdForStage(stageId);
  }

  /// The spec a stage will dial, with the consent rule applied.
  ///
  /// A THIRD-PARTY target on either drafting stage without
  /// [cloudDraftsConsent] resolves to [draftFallbackSpec] instead — the two
  /// stages whose prompt carries the message, the thread tail and whatever the
  /// directories contributed. Consent is checked HERE rather than only on the
  /// screen that sets it so that a stage map restored from a backup, or edited
  /// by hand, cannot route a draft off this machine on its own. Never null for
  /// a chat stage.
  LlmTargetSpec? specForStage(String stageId) {
    final id = targetIdForStage(stageId);
    if (id == null) return null;
    final spec = specById(id);
    if (spec == null) return null;
    final gated = draftStageIds.contains(stageId);
    if (gated && spec.isThirdParty && !cloudDraftsConsent) {
      return draftFallbackSpec;
    }
    return spec;
  }

  /// Where a gated draft goes instead: the box's writing target on the box,
  /// and the built-in prose target here.
  ///
  /// It FOLLOWS THE PLACEMENT, which it did not before Round H. A box install
  /// that withdrew cloud-drafts consent used to have its drafts fall back to a
  /// local port with no server behind it, and the lane parked. The fallback
  /// has to be somewhere the work can actually run.
  ///
  /// And never to a THIRD PARTY. A big address under Bedrock or a vendor is
  /// exactly what the consent gate refused, so falling back onto it would send
  /// the draft to the operator the owner declined; this Mac's own prose target
  /// is the honest answer there.
  LlmTargetSpec get draftFallbackSpec =>
      modelPlacement == ModelPlacement.box &&
              hasBox &&
              !boxProseSpec.isThirdParty
          ? boxProseSpec
          : proseSpec;

  /// The folder the router is pointed at: the user's choice, or the app's own
  /// `models/` under Application Support when they have not made one.
  String effectiveModelsFolder(AppPaths paths) =>
      modelsFolder.isEmpty ? paths.models.path : modelsFolder;

  /// Whether the in-app ribbon runs. It does in BOTH remaining modes — it is
  /// the whole of in-app mode and the frontmost fallback of native mode — so
  /// the only question it has to ask is "not off", and every existing reader of
  /// this name keeps working unchanged.
  bool get notifyRibbon => notifyStyle != NotifyStyle.off;

  AppPrefs copyWith({
    double? attentionThreshold,
    String? aboutMe,
    String? needsYouRules,
    String? backendMode,
    String? mcpServerUrl,
    bool? showActivityLog,
    bool? contextSelectExpand,
    bool? storylineNewestFirst,
    NeedsYouSort? needsYouSort,
    DraftPolicy? draftPolicy,
    ModelPlacement? modelPlacement,
    String? boxBigUrl,
    String? boxSmallUrl,
    String? boxBigModel,
    String? boxSmallModel,
    bool? boxKeyStored,
    bool? boxBigKeyStored,
    bool? boxSmallKeyStored,
    bool? processingOn,
    PeopleSort? peopleSort,
    RoomSort? roomSort,
    NotifyStyle? notifyStyle,
    HomeSort? homeSort,
    String? fastLlmUrl,
    String? fastLlmModel,
    String? proseLlmUrl,
    String? proseLlmModel,
    int? mailLookbackDays,
    int? teamsLookbackDays,
    bool? managedServer,
    int? routerPort,
    String? modelsFolder,
    int? proseParallel,
    List<LlmTargetSpec>? targets,
    Map<String, String>? stageTargets,
    bool? cloudDraftsConsent,
    bool? cloudDraftsStanding,
    int? cloudDraftsDailyCap,
  }) =>
      AppPrefs(
        attentionThreshold: attentionThreshold ?? this.attentionThreshold,
        aboutMe: aboutMe ?? this.aboutMe,
        needsYouRules: needsYouRules ?? this.needsYouRules,
        backendMode: backendMode ?? this.backendMode,
        mcpServerUrl: mcpServerUrl ?? this.mcpServerUrl,
        showActivityLog: showActivityLog ?? this.showActivityLog,
        contextSelectExpand: contextSelectExpand ?? this.contextSelectExpand,
        storylineNewestFirst:
            storylineNewestFirst ?? this.storylineNewestFirst,
        needsYouSort: needsYouSort ?? this.needsYouSort,
        draftPolicy: draftPolicy ?? this.draftPolicy,
        modelPlacement: modelPlacement ?? this.modelPlacement,
        boxBigUrl: boxBigUrl ?? this.boxBigUrl,
        boxSmallUrl: boxSmallUrl ?? this.boxSmallUrl,
        boxBigModel: boxBigModel ?? this.boxBigModel,
        boxSmallModel: boxSmallModel ?? this.boxSmallModel,
        boxKeyStored: boxKeyStored ?? this.boxKeyStored,
        boxBigKeyStored: boxBigKeyStored ?? this.boxBigKeyStored,
        boxSmallKeyStored: boxSmallKeyStored ?? this.boxSmallKeyStored,
        processingOn: processingOn ?? this.processingOn,
        peopleSort: peopleSort ?? this.peopleSort,
        roomSort: roomSort ?? this.roomSort,
        notifyStyle: notifyStyle ?? this.notifyStyle,
        homeSort: homeSort ?? this.homeSort,
        fastLlmUrl: fastLlmUrl ?? this.fastLlmUrl,
        fastLlmModel: fastLlmModel ?? this.fastLlmModel,
        proseLlmUrl: proseLlmUrl ?? this.proseLlmUrl,
        proseLlmModel: proseLlmModel ?? this.proseLlmModel,
        mailLookbackDays: mailLookbackDays ?? this.mailLookbackDays,
        teamsLookbackDays: teamsLookbackDays ?? this.teamsLookbackDays,
        managedServer: managedServer ?? this.managedServer,
        routerPort: routerPort ?? this.routerPort,
        modelsFolder: modelsFolder ?? this.modelsFolder,
        proseParallel: proseParallel ?? this.proseParallel,
        targets: targets ?? this.targets,
        stageTargets: stageTargets ?? this.stageTargets,
        cloudDraftsConsent: cloudDraftsConsent ?? this.cloudDraftsConsent,
        cloudDraftsStanding: cloudDraftsStanding ?? this.cloudDraftsStanding,
        cloudDraftsDailyCap: cloudDraftsDailyCap ?? this.cloudDraftsDailyCap,
      );
}

/// Keys in `app_prefs`. Constants because they are typed in two places — the
/// read below and the tests that assert what landed in the table.
/// [aboutMeKey] lives in `message_store.dart` — `wipeAll` has to clear it and
/// that layer imports nothing above itself — and is re-exported here so this
/// file stays where prefs keys are found.
const String attentionThresholdKey = 'attention_threshold';
const String backendModeKey = 'backend_mode';
const String mcpServerUrlKey = 'mcp_server_url';
const String showActivityLogKey = 'show_activity_log';
const String contextSelectExpandKey = 'context_select_expand';
const String storylineNewestFirstKey = 'storyline_newest_first';
const String needsYouSortKey = 'needs_you_sort';
const String draftPolicyKey = 'suggested_replies';
const String peopleSortKey = 'people_sort';
const String roomSortKey = 'person_room_sort';
const String notifyStyleKey = 'notify_style';
const String homeSortKey = 'home_sort';
const String fastLlmUrlKey = 'fast_llm_url';
const String fastLlmModelKey = 'fast_llm_model';
const String proseLlmUrlKey = 'prose_llm_url';
const String proseLlmModelKey = 'prose_llm_model';
const String mailLookbackDaysKey = 'mail_lookback_days';
const String teamsLookbackDaysKey = 'teams_lookback_days';

/// The managed server's two remaining keys. Not in `wipeAll`'s list,
/// deliberately: which server this machine runs is a fact about the machine.
/// Whether the app runs one at all is no longer stored — see
/// [AppPrefs.managedServer] and `managedServerDefault`.
const String routerPortKey = 'router_port';
const String modelsFolderKey = 'models_folder';

/// How wide the prose server was started. Not in `wipeAll`'s list for the
/// three keys above's reason — see [AppPrefs.proseParallel].
const String proseParallelKey = 'prose_parallel';

/// The three routing keys. Machine configuration like the four above and out
/// of `wipeAll`'s list for their reason: which servers this machine can reach
/// is not a fact about whoever is signed in.
///
/// [llmTargetsKey] is a JSON array of user-added [LlmTargetSpec]s;
/// [stageTargetsKey] a JSON object of stage id to target id, non-defaults
/// only; [cloudDraftsConsentKey] the string `'true'` or nothing.
const String llmTargetsKey = 'llm_targets';
const String stageTargetsKey = 'stage_targets';
const String cloudDraftsConsentKey = 'cloud_drafts_consent';

/// Where this install's model work runs — `ModelPlacement.name`.
///
/// Machine configuration like the three keys above and out of `wipeAll`'s list
/// for their reason: whether this Mac reaches the shared GPU box is not a fact
/// about whoever is signed in.
const String modelPlacementKey = 'model_placement';

/// The user-defined pair: two chat-completions URLs and the two model names
/// discovered behind them, each empty for "follow the build". Machine
/// configuration like [modelPlacementKey] beside them and out of `wipeAll`'s
/// list for its reason.
const String boxBigUrlKey = 'box_big_url';
const String boxSmallUrlKey = 'box_small_url';
const String boxBigModelKey = 'box_big_model';
const String boxSmallModelKey = 'box_small_model';

/// The ONE origin the four keys above replaced, kept for the two migrations
/// that read it and written by nothing. Round G stored the box as an origin
/// and derived both URLs from it; Round H splits it in two.
const String boxUrlKey = 'box_url';

/// Whether model work runs. Machine configuration on the same rule: a person
/// who stood the models down did so about this Mac, not about the mailbox.
const String processingOnKey = 'processing_on';

/// The one-shot flag over the Round G box rows, written once by
/// [AppPrefsNotifier.read] after it has lifted a stored pair into
/// [boxUrlKey].
///
/// A PLAIN pref and deliberately NOT in `MessageStore.derivedOneShotPrefs`:
/// that list is what `wipeAll` and `clearDerived` delete so a walk runs again
/// over a corpus they emptied, and this flag guards no corpus. A wipe leaves
/// no stored rows to migrate, so re-running it would be work over nothing.
const String boxTargetsDerivedKey = 'box_targets_derived';

/// The one-shot flag over the [boxUrlKey] split, written once by
/// [AppPrefsNotifier.read] after it has turned a stored origin into the two
/// URLs the pair is made of now.
///
/// A PLAIN pref on [boxTargetsDerivedKey]'s rule and for its reason: it guards
/// no corpus, and a wipe leaves no address to split.
const String boxServersDerivedKey = 'box_servers_derived';

/// The one-shot flag over the per-step picks, written once by
/// [AppPrefsNotifier.read] after it has emptied [stageTargetsKey].
///
/// Round H deleted the stage picker, and a pick stored by the screen that is
/// gone would route a stage somewhere nothing on screen could show. The
/// `llm_targets` rows are left where they are: with no entry naming one they
/// are inert, and deleting them would ask for a keychain sweep for no visible
/// payoff. A PLAIN pref on [boxTargetsDerivedKey]'s rule.
const String stageTargetsClearedKey = 'stage_targets_cleared';

/// The two cloud-draft rules the consent stands in front of. Machine
/// configuration like the three keys above and out of `wipeAll`'s list for
/// their reason: how much this machine may send elsewhere is not a fact about
/// whoever is signed in.
///
/// [cloudDraftsStandingKey] is the string `'true'` or nothing;
/// [cloudDraftsDailyCapKey] an integer written as a string.
const String cloudDraftsStandingKey = 'cloud_drafts_standing';
const String cloudDraftsDailyCapKey = 'cloud_drafts_daily_cap';

/// Where a target's bearer token lives: the KEYCHAIN, under this prefix and
/// the target's id. Never `app_prefs` — the table is read by anything with the
/// database file, and a token is the one thing here that is a credential.
const String llmTargetBearerKeyPrefix = 'llm_target_bearer:';

/// The switch [notifyStyleKey] replaced. Still read — and only read — so an
/// install that had turned the ribbon off stays quiet across the upgrade
/// instead of being handed OS notifications it never asked for.
const String notifyRibbonKey = 'notify_ribbon';

class AppPrefsNotifier extends StateNotifier<AppPrefs> {
  final MessageStore _store;

  /// Where a target's bearer token is kept. Null in a build with no keychain
  /// behind it — every test that does not pass one, and that is deliberate:
  /// `flutter_secure_storage` throws `MissingPluginException` under
  /// `flutter test`, which [SecureTokenStore] does not catch.
  final TokenStore? _tokens;

  /// The tokens themselves, by target id. A PRIVATE cache on the notifier and
  /// nowhere else: the resolver that builds a request's target is synchronous
  /// and the keychain is not, so the token has to already be in hand when a
  /// drain asks. Never rendered, never copied into [state], never written to
  /// `app_prefs`.
  final Map<String, String> _bearers = {};

  /// Completes when the stored settings have replaced the defaults this
  /// notifier starts on, AND the bearer prefetch has run. Already complete
  /// when [initial] was supplied and nothing has a token.
  late final Future<void> ready;

  /// [initial] is what `main()` read before the first frame, and passing it is
  /// what keeps the app from starting on the defaults: every backend provider
  /// watches [backendMode], so a frame of "MCP" under a stored SDK setting
  /// would build — and immediately dispose — the wrong session.
  ///
  /// Without it the settings arrive one microtask later and [ready] is how a
  /// caller waits for them.
  ///
  /// [tokens] is the keychain. Optional because most callers have no target
  /// with a bearer and every one under `flutter test` has no keychain at all.
  AppPrefsNotifier(this._store, {AppPrefs? initial, TokenStore? tokens})
      // A named parameter cannot be an initializing formal for a private
      // field, which is the same reason `StorylineService` carries this
      // ignore.
      // ignore: prefer_initializing_formals
      : _tokens = tokens,
        super(initial ?? const AppPrefs()) {
    // The load FIRST and the prefetch after it, in that order and not in
    // parallel: the prefetch reads `state.targets` to know which ids have a
    // token, and a `Future.wait` of the two would run it against the defaults.
    ready = (initial != null ? Future<void>.value() : _load())
        .then((_) => _loadBearers());
  }

  Future<void> _load() async {
    final prefs = await read(_store);
    if (!mounted) return;
    state = prefs;
  }

  /// Fills the bearer cache from the keychain, once, and records whether the
  /// box's key is among what came back.
  ///
  /// A no-op with no keychain. Guarded whole: a keychain that refuses costs
  /// the header on the next request — one 401 the user can see and act on —
  /// and never the launch.
  ///
  /// The two box ids are asked for UNCONDITIONALLY, unlike the stored rows,
  /// because the derived specs have no row to carry a presence flag on: the
  /// keychain is the only thing that knows, and a miss is one absent entry the
  /// per-id try already swallows.
  Future<void> _loadBearers() async {
    final tokens = _tokens;
    if (tokens == null) return;
    final wanted = <String>{
      for (final spec in state.targets)
        if (spec.hasBearer) spec.id,
      boxProseId,
      boxBulkId,
    };
    for (final id in wanted) {
      // The try sits INSIDE the loop: one key the keychain refuses costs that
      // one target its header, not every target after it in the list.
      try {
        final value = await tokens.read('$llmTargetBearerKeyPrefix$id');
        if (value != null && value.isNotEmpty) _bearers[id] = value;
      } catch (_) {
        // Deliberately silent and deliberately broad: see the doc above. The
        // exception carries a key name and nothing else worth a log line.
      }
    }
    // The flags move only now, which is what makes the window honest: until
    // this line every derived box spec has said `hasBearer: false`. Either
    // entry counts for [AppPrefs.boxKeyStored], because a keychain that kept
    // one and lost the other still holds a key; the two per-id flags are what
    // the form's hints read, since the two addresses may name two operators.
    if (!mounted) return;
    final big = _bearers.containsKey(boxProseId);
    final small = _bearers.containsKey(boxBulkId);
    state = state.copyWith(
      boxKeyStored: big || small,
      boxBigKeyStored: big,
      boxSmallKeyStored: small,
    );
  }

  /// Where a stage's next request goes, bearer included.
  ///
  /// The one resolver `stageLlmClientProvider` calls, at the top of every
  /// request. Synchronous by construction — the token is already in
  /// [_bearers] — because it runs on a drain's hot path.
  LlmTarget targetForStage(String stageId) {
    final spec = state.specForStage(stageId);
    if (spec == null) return state.targetFor(stageSlot(stageId));
    return spec.toTarget(bearer: spec.hasBearer ? _bearers[spec.id] : null);
  }

  /// One target's stored token, or null when there is none.
  ///
  /// The ONLY door onto [_bearers] besides [targetForStage], and it exists
  /// for exactly one caller: **Check server**, which must reach a keyed
  /// endpoint rather than report its 401. One token, by id, for one request.
  /// What comes back never enters widget state, a `ProbeStatus`, a log line,
  /// an activity row or a test expectation. Null when nothing is stored and
  /// in every build with no keychain, which is every `flutter test` that
  /// hands this notifier a `MemoryTokenStore` it never wrote to.
  String? bearerFor(String targetId) => _bearers[targetId];

  /// Reads every setting once. A stored value that does not parse —
  /// hand-edited, or written by a build that meant something else by the key —
  /// falls back to the default rather than throwing: a bad preference must not
  /// be able to stop the app from starting.
  static Future<AppPrefs> read(MessageStore store) async {
    // The THREE one-shots, in this order and no other. The Round G derive
    // needs the old `box-prose` row and writes [boxUrlKey]; the split reads
    // what it wrote; the clear runs last, because both of the others can leave
    // stage entries behind and the clear is what empties the lot.
    await _deriveBoxTargets(store);
    await _splitBoxServers(store);
    await _clearStageTargets(store);
    final raw = await store.getPref(attentionThresholdKey);
    return AppPrefs(
      attentionThreshold: (raw == null ? null : double.tryParse(raw)) ??
          AttentionTuning.defaultThreshold,
      aboutMe: await store.getPref(aboutMeKey) ?? '',
      needsYouRules: await store.getPref(needsYouRulesKey) ?? '',
      backendMode: _mode(await store.getPref(backendModeKey)),
      mcpServerUrl: _serverUrl(await store.getPref(mcpServerUrlKey)),
      // Anything that is not the string this notifier writes reads as off,
      // an absent key included — which is the state every install starts in.
      showActivityLog: await store.getPref(showActivityLogKey) == 'true',
      // Defaults ON, so the read is the inverse of the one above: only the
      // one spelling this notifier writes reads as off. An absent key, a
      // hand-edited value, a string from a build that meant something else —
      // all of them leave the feature on, which is the state a fresh install
      // wants.
      contextSelectExpand:
          await store.getPref(contextSelectExpandKey) != 'false',
      storylineNewestFirst:
          await store.getPref(storylineNewestFirstKey) == 'true',
      needsYouSort: _enumOrDefault(
        NeedsYouSort.values,
        await store.getPref(needsYouSortKey),
        NeedsYouSort.priority,
      ),
      draftPolicy: _enumOrDefault(
        DraftPolicy.values,
        await store.getPref(draftPolicyKey),
        DraftPolicy.needsYou,
      ),
      modelPlacement: _enumOrDefault(
        ModelPlacement.values,
        await store.getPref(modelPlacementKey),
        defaultModelPlacement,
      ),
      boxBigUrl: _slotValue(await store.getPref(boxBigUrlKey)),
      boxSmallUrl: _slotValue(await store.getPref(boxSmallUrlKey)),
      boxBigModel: _slotValue(await store.getPref(boxBigModelKey)),
      boxSmallModel: _slotValue(await store.getPref(boxSmallModelKey)),
      // Defaults ON, so the read is [contextSelectExpand]'s inverse: only the
      // one spelling the setter writes reads as off, and an absent key leaves
      // a fresh install working.
      processingOn: await store.getPref(processingOnKey) != 'false',
      peopleSort: _enumOrDefault(
        PeopleSort.values,
        await store.getPref(peopleSortKey),
        PeopleSort.recent,
      ),
      roomSort: _enumOrDefault(
        RoomSort.values,
        await store.getPref(roomSortKey),
        RoomSort.newest,
      ),
      // The one setting here that DEFAULTS ON, so its read is the inverse of
      // the two above — see [_style].
      notifyStyle: _style(
        await store.getPref(notifyStyleKey),
        await store.getPref(notifyRibbonKey),
      ),
      homeSort: _enumOrDefault(
        HomeSort.values,
        await store.getPref(homeSortKey),
        HomeSort.newest,
      ),
      fastLlmUrl: _slotValue(await store.getPref(fastLlmUrlKey)),
      fastLlmModel: _slotValue(await store.getPref(fastLlmModelKey)),
      proseLlmUrl: _slotValue(await store.getPref(proseLlmUrlKey)),
      proseLlmModel: _slotValue(await store.getPref(proseLlmModelKey)),
      mailLookbackDays: _lookback(await store.getPref(mailLookbackDaysKey)),
      teamsLookbackDays: _lookback(await store.getPref(teamsLookbackDaysKey)),
      routerPort: _routerPort(await store.getPref(routerPortKey)),
      modelsFolder: _slotValue(await store.getPref(modelsFolderKey)),
      proseParallel: _proseParallel(await store.getPref(proseParallelKey)),
      targets: _targets(await store.getPref(llmTargetsKey)),
      stageTargets: _stageTargets(await store.getPref(stageTargetsKey)),
      cloudDraftsConsent:
          await store.getPref(cloudDraftsConsentKey) == 'true',
      // Only the string this notifier writes reads as on, on the rule every
      // boolean above follows: the standing rule sends drafts off this
      // machine by itself, so anything unrecognised has to leave it off.
      cloudDraftsStanding:
          await store.getPref(cloudDraftsStandingKey) == 'true',
      cloudDraftsDailyCap:
          _cloudDraftsDailyCap(await store.getPref(cloudDraftsDailyCapKey)),
    );
  }

  /// Turns a Round G install's two stored box rows into the one address the
  /// placement rule derives them from. Runs at most once per install.
  ///
  /// Round G adopted the box by WRITING two `llm_targets` rows and fifteen
  /// `stage_targets` entries. Round H derives both from [boxUrlKey] and the
  /// placement, so a surviving pair would shadow the derived specs: the id
  /// would appear twice in [AppPrefs.allTargets] and the stage picker asserts
  /// on a duplicate dropdown value. This lifts the origin out of the writing
  /// row, drops the pair, and drops every stage entry that now equals what the
  /// rule answers anyway — a hand-picked target is not one of those and
  /// survives.
  ///
  /// The KEYCHAIN is untouched: the two entries are still keyed
  /// `llm_target_bearer:box-prose` and `:box-bulk`, which is exactly what the
  /// derived specs ask for, so nobody has to type the key again.
  ///
  /// The only writer in this otherwise read-only path, and it is here rather
  /// than at a call site because every door onto the prefs goes through
  /// [read]: `main()` before the first frame, the notifier's own load, and the
  /// tests. There is no other hook.
  static Future<void> _deriveBoxTargets(MessageStore store) async {
    if (await store.getPref(boxTargetsDerivedKey) == '1') return;
    final decoded = _json(await store.getPref(llmTargetsKey));
    if (decoded is List) {
      final kept = <Map<String, Object?>>[];
      var base = '';
      var found = false;
      for (final row in decoded) {
        final spec = LlmTargetSpec.tryParse(row);
        if (spec == null) {
          // A row this build cannot read is kept VERBATIM rather than dropped:
          // this is a migration of the two box rows, not a cleanup of the
          // list, and a newer build's row is not ours to lose.
          if (row is Map<String, Object?>) kept.add(row);
          continue;
        }
        if (!spec.isBox) {
          kept.add(spec.toJson());
          continue;
        }
        found = true;
        if (spec.id == boxProseId) base = boxBaseFromProseUrl(spec.url);
      }
      if (found) {
        // Only when it differs from what this build already carries: storing
        // the compiled address would freeze today's define into the database,
        // which is the thing [AppPrefs.boxBigUrl]'s empty means to avoid.
        if (base.isNotEmpty && base != normalizeBoxBaseUrl(boxUrlDefault)) {
          await store.setPref(boxUrlKey, base);
        }
        await store.setPref(llmTargetsKey, jsonEncode(kept));
        // The fifteen entries the Round G adopt wrote are not dropped here any
        // more: [_clearStageTargets] runs straight after this in the same
        // `read` and empties the map whole, so a narrower drop would be work
        // the next statement undoes.
      }
    }
    await store.setPref(boxTargetsDerivedKey, '1');
  }


  /// Turns a stored box ORIGIN into the two addresses the pair is made of.
  /// Runs at most once per install.
  ///
  /// Round G, and part one of Round H, kept one origin and derived
  /// `/prose/v1/chat/completions` and `/bulk/v1/chat/completions` from it.
  /// Part two lets a person name two servers, so the derivation moves out of
  /// the getters and into the data: the origin is split here, once, and
  /// [boxUrlKey] is emptied so nothing reads it again.
  ///
  /// A NO-OP for every install that followed the build, which is every install
  /// that never typed an address: there is nothing stored to split, and the
  /// two getters go on deriving from the compiled default exactly as before.
  static Future<void> _splitBoxServers(MessageStore store) async {
    if (await store.getPref(boxServersDerivedKey) == '1') return;
    final stored = _slotValue(await store.getPref(boxUrlKey));
    if (stored.isNotEmpty) {
      final base = normalizeBoxBaseUrl(stored);
      await store.setPref(boxBigUrlKey, '$base/prose/v1/chat/completions');
      await store.setPref(boxSmallUrlKey, '$base/bulk/v1/chat/completions');
      // Emptied rather than dropped: `app_prefs` has no delete a reader above
      // here can call, and an empty value is exactly what every reader of this
      // table means by absent.
      await store.setPref(boxUrlKey, '');
    }
    await store.setPref(boxServersDerivedKey, '1');
  }

  /// Empties the per-step picks, once.
  ///
  /// The stage picker was the only way to write one and Round H deleted it, so
  /// a surviving entry would send a stage to a server no screen in the app
  /// mentions — and outrank the placement rule while doing it. The user's own
  /// `llm_targets` rows are deliberately left alone: nothing points at them
  /// any more, which makes them inert rather than wrong.
  static Future<void> _clearStageTargets(MessageStore store) async {
    if (await store.getPref(stageTargetsClearedKey) == '1') return;
    // Emptied only when there is something to empty, so a fresh install
    // writes the flag and nothing else.
    if ((await store.getPref(stageTargetsKey) ?? '').isNotEmpty) {
      await store.setPref(stageTargetsKey, '');
    }
    await store.setPref(stageTargetsClearedKey, '1');
  }

  /// A stored cap, or fifty. [_proseParallel]'s rule and its reason: a number
  /// nothing wrote, or one somebody typed into the table by hand, must not be
  /// able to uncap what leaves this machine.
  static int _cloudDraftsDailyCap(String? raw) => clampCloudDraftsDailyCap(
        int.tryParse(raw ?? '') ?? AppPrefs.defaultCloudDraftsDailyCap,
      );

  /// The stored target list, or none of it.
  ///
  /// Every layer is forgiving on its own terms, and none of them throws: text
  /// that is not JSON, or JSON that is not an array, reads as no targets at
  /// all; a row [LlmTargetSpec.tryParse] refuses is dropped and the rest
  /// survive; a row claiming a BUILT-IN id is dropped because those two are
  /// derived and a stored copy would shadow the live slot prefs; and a
  /// duplicate id keeps the first, because the alternative is two rows one
  /// stage map entry cannot choose between.
  ///
  /// A row claiming a BOX id is dropped for the built-ins' reason, and it is
  /// the belt to [_deriveBoxTargets]' braces: a pair that survived the
  /// migration — restored from a backup, or written by a build in between —
  /// would put the same id in [AppPrefs.allTargets] twice, and the stage
  /// picker asserts on a duplicate dropdown value.
  static List<LlmTargetSpec> _targets(String? raw) {
    final decoded = _json(raw);
    if (decoded is! List) return const [];
    final seen = <String>{};
    final specs = <LlmTargetSpec>[];
    for (final row in decoded) {
      final spec = LlmTargetSpec.tryParse(row);
      if (spec == null || spec.isFixed) continue;
      if (!seen.add(spec.id)) continue;
      specs.add(spec);
    }
    return specs;
  }

  /// The stored stage map, on [_targets]' rule: not an object reads as empty,
  /// and an entry whose value is not a string is dropped. An entry naming a
  /// target that no longer exists is NOT dropped here — it is ignored by
  /// [AppPrefs.targetIdForStage] instead, so removing a target and putting it
  /// back does not silently lose where it was pointed.
  static Map<String, String> _stageTargets(String? raw) {
    final decoded = _json(raw);
    if (decoded is! Map) return const {};
    final map = <String, String>{};
    decoded.forEach((key, value) {
      if (key is String && value is String) map[key] = value;
    });
    return map;
  }

  /// Decoded JSON, or null for anything that is not.
  static Object? _json(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }

  /// A stored port, or the default. Unparseable is the default and
  /// out-of-range is clamped into it, on [_lookback]'s rule and for the same
  /// reason: a bad number here would make every start fail on a socket, and a
  /// preference must not be able to do that.

  static int _routerPort(String? raw) =>
      clampRouterPort(int.tryParse(raw ?? '') ?? AppPrefs.defaultRouterPort);

  /// A stored width, or one. [_routerPort]'s rule and its reason: a number
  /// nothing wrote, or one somebody typed into the database by hand, must not
  /// be able to put sixty requests in front of a one-slot server.
  static int _proseParallel(String? raw) => clampProseParallel(
        int.tryParse(raw ?? '') ?? AppPrefs.defaultProseParallel,
      );

  /// A stored lookback, or the default. Unparseable is the default and
  /// out-of-range is the nearest end of the range: this number decides how far
  /// a sync reaches, and neither a blank window nor a thrown exception is a
  /// state the sync can do anything with.
  static int _lookback(String? raw) =>
      clampLookbackDays(int.tryParse(raw ?? '') ?? syncFloorDays);

  /// Absent, blank, or whitespace all mean the same thing — follow the build.
  /// Trimmed on the way in as well as on the way out, because a URL with a
  /// trailing newline is a `SocketException` nobody can read.
  static String _slotValue(String? raw) => raw?.trim() ?? '';

  /// A stored enum, or [fallback]. The rule every enum preference here obeys,
  /// written once.
  ///
  /// ONLY a spelling this notifier wrote is honoured — the setters below all
  /// store `value.name`, so that is the one spelling there is. An absent key,
  /// a value somebody hand-edited into the table, or a name a later build
  /// stopped using all read as [fallback], which is the state every fresh
  /// install is in: the Needs You pile ranks by priority, People reads by
  /// recency, a room and the Inbox open on what just happened, and replies are
  /// drafted for the messages that need the owner. A preference must never be
  /// able to throw on the first frame of the screen that reads it.
  static T _enumOrDefault<T extends Enum>(
    Iterable<T> values,
    String? raw,
    T fallback,
  ) {
    for (final option in values) {
      if (option.name == raw) return option;
    }
    return fallback;
  }

  /// The stored style, or what the switch it replaced said, or on.
  ///
  /// Anything this notifier did not write falls through to [legacyRibbon],
  /// which is the only place a decision to be silent could have been recorded:
  /// a stored `'false'` there means the user asked for quiet and still gets it.
  /// Everything else — an absent key, a hand-edited value, a fresh install —
  /// reads as [NotifyStyle.native], because the state every install starts in
  /// is "tell me".
  static NotifyStyle _style(String? raw, String? legacyRibbon) =>
      switch (raw) {
        'off' => NotifyStyle.off,
        'in_app' => NotifyStyle.inApp,
        'native' => NotifyStyle.native,
        _ => legacyRibbon == 'false' ? NotifyStyle.off : NotifyStyle.native,
      };

  /// The stored spelling of each style. Written here, parsed by [_style], and
  /// never seen above this file — everything else compares [NotifyStyle]s.
  static String _styleName(NotifyStyle value) => switch (value) {
        NotifyStyle.off => 'off',
        NotifyStyle.inApp => 'in_app',
        NotifyStyle.native => 'native',
      };

  /// Anything that is not the direct-Graph mode reads as MCP — including an
  /// unset key, which is the state every existing install is in.
  static String _mode(String? raw) =>
      raw == backendModeSdk ? backendModeSdk : backendModeMcp;

  /// An empty server is the default one. A user who clears the field is
  /// asking for the default back, not for a client pointed at nothing.
  static String _serverUrl(String? raw) {
    final trimmed = raw?.trim();
    return trimmed == null || trimmed.isEmpty ? defaultMcpServerUrl : trimmed;
  }

  /// Clamped to the slider's own range, so a value that somehow arrived from
  /// outside it cannot make Needs You permanently empty.
  ///
  /// State first, then the write — the reverse of the order this had while the
  /// store was synchronous. Everything on screen reads the state, and making a
  /// slider wait a round trip on the database before it moves would be a frame
  /// of lag on the one control whose whole point is watching the list change
  /// under it. The returned future is the write; the setters below are the
  /// same shape.
  Future<void> setAttentionThreshold(double value) async {
    final clamped = value.clamp(0.0, 1.0);
    state = state.copyWith(attentionThreshold: clamped);
    await _store.setPref(attentionThresholdKey, clamped.toString());
  }

  Future<void> setAboutMe(String value) async {
    state = state.copyWith(aboutMe: value);
    await _store.setPref(aboutMeKey, value);
  }

  /// Stored VERBATIM — the pane trims before it calls, and trimming again here
  /// would mean the text in the field and the text the model reads are not the
  /// same string.
  Future<void> setNeedsYouRules(String value) async {
    state = state.copyWith(needsYouRules: value);
    await _store.setPref(needsYouRulesKey, value);
  }

  /// Switches which backend the app talks through.
  ///
  /// The state change is the whole mechanism: the session and both backend
  /// providers watch this field, so setting it rebuilds every one of them and
  /// whatever was built on top.
  Future<void> setBackendMode(String value) async {
    final mode = _mode(value);
    state = state.copyWith(backendMode: mode);
    await _store.setPref(backendModeKey, mode);
  }

  Future<void> setMcpServerUrl(String value) async {
    final url = _serverUrl(value);
    state = state.copyWith(mcpServerUrl: url);
    await _store.setPref(mcpServerUrlKey, url);
  }

  Future<void> setShowActivityLog(bool value) async {
    state = state.copyWith(showActivityLog: value);
    await _store.setPref(showActivityLogKey, value.toString());
  }

  /// Whether a directory-fed draft may read two sections in full first.
  Future<void> setContextSelectExpand(bool value) async {
    state = state.copyWith(contextSelectExpand: value);
    await _store.setPref(contextSelectExpandKey, value.toString());
  }

  Future<void> setStorylineNewestFirst(bool value) async {
    state = state.copyWith(storylineNewestFirst: value);
    await _store.setPref(storylineNewestFirstKey, value.toString());
  }

  /// Orders the Needs You pile, in all three places it is drawn. Written as
  /// the enum's own name, which is what [_enumOrDefault] parses back.
  Future<void> setNeedsYouSort(NeedsYouSort value) async {
    state = state.copyWith(needsYouSort: value);
    await _store.setPref(needsYouSortKey, value.name);
  }

  /// When suggested replies are written without anyone asking. Written as the
  /// enum's own name, which is what [_enumOrDefault] parses back.
  Future<void> setDraftPolicy(DraftPolicy value) async {
    state = state.copyWith(draftPolicy: value);
    await _store.setPref(draftPolicyKey, value.name);
  }

  /// Orders the People directory. Written as the enum's own name, which is
  /// what [_enumOrDefault] parses back.
  Future<void> setPeopleSort(PeopleSort value) async {
    state = state.copyWith(peopleSort: value);
    await _store.setPref(peopleSortKey, value.name);
  }

  /// Orders the threads inside every person's room — one habit, not a setting
  /// per colleague.
  Future<void> setRoomSort(RoomSort value) async {
    state = state.copyWith(roomSort: value);
    await _store.setPref(roomSortKey, value.name);
  }

  Future<void> setNotifyStyle(NotifyStyle value) async {
    state = state.copyWith(notifyStyle: value);
    await _store.setPref(notifyStyleKey, _styleName(value));
  }

  /// Orders the Inbox feed. Written as the enum's own name, which is what
  /// [_enumOrDefault] parses back.
  Future<void> setHomeSort(HomeSort value) async {
    state = state.copyWith(homeSort: value);
    await _store.setPref(homeSortKey, value.name);
  }

  /// Points the bulk slot somewhere. Empty for either field means the compiled
  /// default; the pair is set together so no request can ever see half a move.
  ///
  /// State first, then the writes — the order every setter here uses.
  Future<void> setFastLlmTarget({
    required String url,
    required String model,
  }) async {
    final cleanUrl = url.trim();
    final cleanModel = model.trim();
    state = state.copyWith(fastLlmUrl: cleanUrl, fastLlmModel: cleanModel);
    await _store.setPref(fastLlmUrlKey, cleanUrl);
    await _store.setPref(fastLlmModelKey, cleanModel);
  }

  Future<void> setProseLlmTarget({
    required String url,
    required String model,
  }) async {
    final cleanUrl = url.trim();
    final cleanModel = model.trim();
    state = state.copyWith(proseLlmUrl: cleanUrl, proseLlmModel: cleanModel);
    await _store.setPref(proseLlmUrlKey, cleanUrl);
    await _store.setPref(proseLlmModelKey, cleanModel);
  }

  /// How far back each connector reaches. Clamped on the way in as well as on
  /// the way out — [_lookback] guards the read, and this guards a caller that
  /// hands over a number no control on screen could have produced.
  ///
  /// State first, then the write, like every setter above.
  Future<void> setMailLookbackDays(int value) async {
    final clamped = clampLookbackDays(value);
    state = state.copyWith(mailLookbackDays: clamped);
    await _store.setPref(mailLookbackDaysKey, clamped.toString());
  }

  Future<void> setTeamsLookbackDays(int value) async {
    final clamped = clampLookbackDays(value);
    state = state.copyWith(teamsLookbackDays: clamped);
    await _store.setPref(teamsLookbackDaysKey, clamped.toString());
  }

  /// Moves the managed router's port. Clamped on the way in as well as on the
  /// way out — [_routerPort] guards the read, and this guards a caller that
  /// hands over a number no control on screen could have produced.
  Future<void> setRouterPort(int value) async {
    final clamped = clampRouterPort(value);
    state = state.copyWith(routerPort: clamped);
    await _store.setPref(routerPortKey, clamped.toString());
  }

  /// Moves how many drafts may be in flight at the prose server.
  ///
  /// Clamped on the way in as well as on the way out, exactly as
  /// [setRouterPort] is: the segmented control offers 1 / 2 / 4 / 8, and this
  /// guards a caller that hands over a number no control on screen could have
  /// produced.
  ///
  /// State first, then the write, like every setter above — and the state is
  /// the whole mechanism: `DraftHandler.concurrency` reads this through a
  /// closure at every launch decision, so a change moves the next draft rather
  /// than the next launch.
  Future<void> setProseParallel(int value) async {
    final clamped = clampProseParallel(value);
    state = state.copyWith(proseParallel: clamped);
    await _store.setPref(proseParallelKey, clamped.toString());
  }

  /// Adds a target, or replaces the one with the same id.
  ///
  /// [bearer] is the only way a token is ever written, and it goes to the
  /// KEYCHAIN and the in-memory cache — never to `app_prefs`, where the spec's
  /// `bearer` field is a boolean saying only that one exists. The three cases:
  /// a non-null [bearer] stores it and sets the flag; a null [bearer] on a
  /// spec that claims none deletes whatever was there, which is how a token is
  /// cleared; and a null [bearer] on a spec that claims one KEEPS the stored
  /// token, which is what an edit of the name or the model has to do — the
  /// screen shows "set" and cannot show the secret back, so it cannot resend
  /// it either.
  ///
  /// The keychain first and the pref after it, because a spec that claims a
  /// token the keychain refused would send an unauthenticated request every
  /// time. Throws on a DERIVED id: the two built-ins come from the slot prefs
  /// and are edited through the slot editors, and the two box targets come
  /// from [boxUrlKey] and are edited by changing that one address.
  Future<void> upsertTarget(LlmTargetSpec spec, {String? bearer}) async {
    if (spec.isFixed) {
      throw ArgumentError.value(
        spec.id,
        'spec.id',
        'the derived targets are not rows: edit the slot prefs or the box '
            'address',
      );
    }
    final key = '$llmTargetBearerKeyPrefix${spec.id}';
    var hasBearer = spec.hasBearer;
    if (bearer != null) {
      hasBearer = true;
      _bearers[spec.id] = bearer;
      await _writeToken(key, bearer);
    } else if (!spec.hasBearer) {
      _bearers.remove(spec.id);
      await _writeToken(key, null);
    }

    final stored = spec.copyWith(
      hasBearer: hasBearer,
      parallel: clampProseParallel(spec.parallel),
    );
    final targets = [
      for (final existing in state.targets)
        if (existing.id == stored.id) stored else existing,
    ];
    if (!targets.any((t) => t.id == stored.id)) targets.add(stored);

    state = state.copyWith(targets: targets);
    await _writeTargets(targets);
  }

  /// Forgets a target: its token, its row, and every stage pointed at it.
  ///
  /// The stage entries go in the SAME write rather than being left to resolve
  /// as defaults, because a stale entry would silently re-point those stages
  /// the day somebody added a target with the same id back.
  ///
  /// A no-op for a DERIVED id — neither the two built-ins nor the two box
  /// targets are rows, so there is nothing to remove — and for an id nothing
  /// carries.
  Future<void> removeTarget(String id) async {
    if (id == builtInFastId || id == builtInProseId) return;
    if (id == boxProseId || id == boxBulkId) return;
    if (!state.targets.any((spec) => spec.id == id)) return;

    _bearers.remove(id);
    await _writeToken('$llmTargetBearerKeyPrefix$id', null);

    final targets = [
      for (final spec in state.targets)
        if (spec.id != id) spec,
    ];
    final stageTargets = {
      for (final entry in state.stageTargets.entries)
        if (entry.value != id) entry.key: entry.value,
    };
    state = state.copyWith(targets: targets, stageTargets: stageTargets);
    await _writeTargets(targets);
    await _writeStageTargets(stageTargets);
  }

  /// Points one stage at one target.
  ///
  /// Writing the stage's own DEFAULT removes the entry instead of storing it,
  /// so the map holds non-defaults only and a fresh install stays empty.
  ///
  /// A no-op for an unknown target id and for `embeddings`, which is not
  /// routed at all.
  Future<void> setStageTarget(String stageId, String targetId) async {
    if (stageId == 'embeddings') return;
    if (state.specById(targetId) == null) return;

    // The PLACEMENT's default, not the slot's: on the box, picking `box-bulk`
    // for the storyline confirm is a real override and has to be stored,
    // while picking `box-prose` there is the rule and stores nothing.
    final isDefault = targetId == state.defaultTargetIdForStage(stageId);
    if (isDefault) return clearStageTarget(stageId);

    if (state.stageTargets[stageId] == targetId) return;
    final map = {...state.stageTargets, stageId: targetId};
    state = state.copyWith(stageTargets: map);
    await _writeStageTargets(map);
  }

  /// Puts a stage back on its default target.
  Future<void> clearStageTarget(String stageId) async {
    if (!state.stageTargets.containsKey(stageId)) return;
    final map = {...state.stageTargets}..remove(stageId);
    state = state.copyWith(stageTargets: map);
    await _writeStageTargets(map);
  }

  /// Points whole groups of stages at one target, the way the add screen's
  /// three checkboxes do.
  ///
  /// One state write and one pref write for the lot: a preset that wrote each
  /// stage separately would put a dozen rebuilds and a dozen round trips
  /// behind one tick. [proseStageIds], [confirmStageIds] and [bulkStageIds]
  /// are the sets, and `model_slots_test` pins them against `pipelineStages`.
  ///
  /// A preset onto a THIRD-PARTY target skips the two draft stages until the
  /// consent stands. [AppPrefs.specForStage] would gate those back to the
  /// local prose target anyway, but only until consent was granted for some
  /// other reason — and at that moment drafts would start leaving the machine
  /// from a stage nobody was asked about. Writing nothing is what keeps the
  /// acknowledgement about the stage it was given for.
  Future<void> applyPreset({
    required String targetId,
    bool prose = false,
    bool confirm = false,
    bool bulk = false,
  }) async {
    final target = state.specById(targetId);
    if (target == null) return;
    final skipDrafts = target.isThirdParty && !state.cloudDraftsConsent;
    final map = {...state.stageTargets};
    for (final stageId in [
      if (prose) ...proseStageIds,
      if (confirm) ...confirmStageIds,
      if (bulk) ...bulkStageIds,
    ]) {
      // Untouched, not cleared: a stage the user pointed somewhere by hand is
      // theirs, and a preset that silently reset it would be a second
      // surprise on top of the one this guard exists to prevent.
      if (skipDrafts && draftStageIds.contains(stageId)) continue;
      // The placement's default, on [setStageTarget]'s rule and for its
      // reason.
      final isDefault = targetId == state.defaultTargetIdForStage(stageId);
      if (isDefault) {
        map.remove(stageId);
      } else {
        map[stageId] = targetId;
      }
    }
    if (_sameMap(map, state.stageTargets)) return;
    state = state.copyWith(stageTargets: map);
    await _writeStageTargets(map);
  }

  /// Writes what this Mac can actually run: the tier's stage picks and its
  /// draft policy, in one press or at the end of the wizard.
  ///
  /// The stages a tier governs are the ones ANY tier names, so moving between
  /// tiers is symmetric: [MachineTier.inbox] points the six prose-slot stages
  /// at the built-in fast target, and [MachineTier.full] puts those same six
  /// back on their own default, which by [setStageTarget]'s rule REMOVES the
  /// entry rather than storing it. A fresh install on a big Mac therefore
  /// keeps an empty `stage_targets`, which is the invariant
  /// `10-model-routing.md` states and `llm_targets_test` pins.
  ///
  /// It overwrites a pick the owner made on one of those six: the button's
  /// caption says which stages it rewrites, and nothing is destroyed because
  /// any stage can be re-picked from the same section. The bulk stages, the
  /// confirm stage, the targets themselves, the consent and the bearers are
  /// all untouched. `draft_improve` is one of the seven prose stages since
  /// Round H, so the inbox tier moves it onto the small model with the rest of
  /// them. Calling it twice changes nothing.
  Future<void> applyTierDefaults(MachineTier tier) async {
    // [MachineTier.remote] is a PLACEMENT, and [usePlacement] owns its stage
    // map. Falling through would clear every governed stage back to a local
    // built-in, because `wanted[stageId]` is null for all of them there — the
    // box's picks would be undone by the very call meant to leave them alone.
    if (tier == MachineTier.remote) return;
    final wanted = tierStageDefaults(tier);
    final governed = <String>{
      for (final other in MachineTier.values) ...tierStageDefaults(other).keys,
    };
    final map = {...state.stageTargets};
    for (final stageId in governed) {
      final slot = stageSlot(stageId);
      if (slot == ModelSlot.embed) continue;
      // The SLOT's default and deliberately not the placement's, unlike
      // [setStageTarget] and [applyPreset]: this method runs only on the local
      // placement, and reading the placement's default here would have it
      // remove box entries it was never meant to see.
      final fallback = defaultTargetIdFor(slot);
      final targetId = wanted[stageId] ?? fallback;
      if (targetId == fallback) {
        map.remove(stageId);
      } else {
        map[stageId] = targetId;
      }
    }
    if (!_sameMap(map, state.stageTargets)) {
      state = state.copyWith(stageTargets: map);
      await _writeStageTargets(map);
    }
    await setDraftPolicy(tierDraftPolicy(tier));
  }

  /// Records where this install's model work runs. State first and the write
  /// after it, like every setter here.
  Future<void> setModelPlacement(ModelPlacement value) async {
    state = state.copyWith(modelPlacement: value);
    await _store.setPref(modelPlacementKey, value.name);
  }

  /// Records where the two models run: two addresses and the two model names
  /// discovered behind them. Empty is not an answer for either address.
  ///
  /// What is STORED is the empty string wherever the value equals what this
  /// build already derives, which is [AppPrefs.boxBigUrl]'s whole meaning: an
  /// install that agrees with its build follows the build, and a changed
  /// define reaches it.
  ///
  /// Throws [ArgumentError] on an address that is not an http or https URL,
  /// and on a big address whose host belongs to a third party while
  /// [AppPrefs.cloudDraftsConsent] is false. The form in front of this one
  /// refuses both before the press arrives; the guards are a last line, and
  /// what they stop is a target nothing can dial and drafts leaving this
  /// machine for an operator nobody agreed to.
  Future<void> setBoxServers({
    required String bigUrl,
    required String smallUrl,
    required String bigModel,
    required String smallModel,
  }) async {
    final big = normalizeBoxBaseUrl(bigUrl);
    final small = normalizeBoxBaseUrl(smallUrl);
    for (final url in [big, small]) {
      if (!isBoxOrigin(url)) {
        throw ArgumentError.value(url, 'url', 'must be an http or https URL');
      }
    }
    if (isThirdPartyHost(big) && !state.cloudDraftsConsent) {
      throw ArgumentError.value(
        big,
        'bigUrl',
        'a third-party server needs cloud drafts consent first',
      );
    }
    final compiled = normalizeBoxBaseUrl(boxUrlDefault);
    final storedBig =
        big == '$compiled/prose/v1/chat/completions' && compiled.isNotEmpty
            ? ''
            : big;
    final storedSmall =
        small == '$compiled/bulk/v1/chat/completions' && compiled.isNotEmpty
            ? ''
            : small;
    final storedBigModel = bigModel.trim() == boxProseModel ? '' : bigModel.trim();
    final storedSmallModel =
        smallModel.trim() == boxBulkModel ? '' : smallModel.trim();
    state = state.copyWith(
      boxBigUrl: storedBig,
      boxSmallUrl: storedSmall,
      boxBigModel: storedBigModel,
      boxSmallModel: storedSmallModel,
    );
    await _store.setPref(boxBigUrlKey, storedBig);
    await _store.setPref(boxSmallUrlKey, storedSmall);
    await _store.setPref(boxBigModelKey, storedBigModel);
    await _store.setPref(boxSmallModelKey, storedSmallModel);
  }

  /// Puts an access key in the keychain, PER SERVER.
  ///
  /// A SECRET: it reaches the keychain, the private bearer cache and the
  /// `Authorization` header, and nothing else. What [state] gains is three
  /// booleans.
  ///
  /// One token per id, because the two addresses may name two operators and a
  /// key for one must never be sent to the other. The form passes the same
  /// token twice when the two addresses share a host, which is the ordinary
  /// case: one server serving both roles under two path prefixes.
  ///
  /// A no-op on an omitted or empty token, so a Connect with a blank field
  /// cannot replace a good key with nothing.
  Future<void> setBoxKey({String? big, String? small}) async {
    var bigStored = state.boxBigKeyStored;
    var smallStored = state.boxSmallKeyStored;
    for (final entry in [(boxProseId, big), (boxBulkId, small)]) {
      final token = entry.$2?.trim() ?? '';
      if (token.isEmpty) continue;
      _bearers[entry.$1] = token;
      await _writeToken('$llmTargetBearerKeyPrefix${entry.$1}', token);
      if (entry.$1 == boxProseId) {
        bigStored = true;
      } else {
        smallStored = true;
      }
    }
    state = state.copyWith(
      boxKeyStored: bigStored || smallStored,
      boxBigKeyStored: bigStored,
      boxSmallKeyStored: smallStored,
    );
  }

  /// Forgets the box's key, both entries at once.
  ///
  /// A no-op when there is nothing to forget, which is every install that
  /// never typed one. Not an optimisation: a keychain write is a platform
  /// channel round trip, and making the first run take two of them to delete
  /// nothing is how a wizard step stops advancing within the pumps its test
  /// gives it.
  Future<void> clearBoxKey() async {
    final stored = state.boxKeyStored ||
        _bearers.containsKey(boxProseId) ||
        _bearers.containsKey(boxBulkId);
    // Decided from the cache, not the keychain, and NOT behind `ready`: a
    // clear that lands before the prefetch returns would keep a stored key,
    // but the only caller that early is code, never a button, and waiting for
    // `ready` here holds the wizard's This Mac choice behind the whole prefs
    // load, which is dozens of store reads. The cache is the honest answer
    // for every press a person can make.
    if (!stored) return;
    for (final id in [boxProseId, boxBulkId]) {
      _bearers.remove(id);
      await _writeToken('$llmTargetBearerKeyPrefix$id', null);
    }
    state = state.copyWith(
      boxKeyStored: false,
      boxBigKeyStored: false,
      boxSmallKeyStored: false,
    );
  }

  /// Remembers whether model work runs. State first and the write after it,
  /// like every setter here.
  Future<void> setProcessingOn(bool value) async {
    state = state.copyWith(processingOn: value);
    await _store.setPref(processingOnKey, value.toString());
  }

  /// Moves this install between the two placements, and clears out the stage
  /// entries the app itself wrote.
  ///
  /// The placement is a RULE since Round H, so moving it re-answers every
  /// stage that has no entry of its own. What would spoil that is a stored
  /// entry the app wrote under the old placement: it outranks the rule, so a
  /// machine that had been on the box would keep dialling it stage by stage.
  ///
  /// An entry is dropped exactly when its value is one the app itself could
  /// have written: either box id, the slot's own built-in, or what the inbox
  /// tier writes (the box rule's own answers are the two box ids, so they
  /// need no clause of their own). A hand-picked `local-prose` on a bulk stage
  /// is in none of those and survives, as does every user target — those are
  /// choices somebody made, and a placement switch is not permission to undo
  /// them.
  ///
  /// [hardwareTier] is what THIS MAC could run, never the effective tier: on
  /// the way back to local the tier's own picks are applied, and the effective
  /// tier reads [MachineTier.remote] right up until the placement moves.
  Future<void> usePlacement(
    ModelPlacement placement, {
    required MachineTier hardwareTier,
  }) async {
    await setModelPlacement(placement);

    final inboxTier = tierStageDefaults(MachineTier.inbox);
    final kept = <String, String>{};
    state.stageTargets.forEach((stageId, targetId) {
      final slot = stageSlot(stageId);
      final appWrote = targetId == boxBulkId ||
          targetId == boxProseId ||
          (slot != ModelSlot.embed && targetId == defaultTargetIdFor(slot)) ||
          targetId == inboxTier[stageId];
      if (!appWrote) kept[stageId] = targetId;
    });
    if (!_sameMap(kept, state.stageTargets)) {
      state = state.copyWith(stageTargets: kept);
      await _writeStageTargets(kept);
    }

    if (placement == ModelPlacement.local) {
      await applyTierDefaults(hardwareTier);
    } else {
      // The box runs the writing model the ledger measured, so prefetched
      // drafts are worth their cost there whatever this Mac could manage.
      await setDraftPolicy(DraftPolicy.needsYou);
    }
  }

  /// Points this install at the servers a person named: the two addresses,
  /// the two discovered model names, a key for each server where one was
  /// typed, and the placement.
  ///
  /// Preference writes and a keychain pair, and NOT atomic — it cannot be. A
  /// throw partway leaves an address with no placement rather than a corrupt
  /// install, and calling it again repairs that, because every step here is
  /// idempotent.
  ///
  /// The two keys are optional so that somebody changing only an address keeps
  /// the key they already stored; the door in front of this one decides which
  /// of those two things is happening.
  Future<void> useBox({
    required String bigUrl,
    required String smallUrl,
    required String bigModel,
    required String smallModel,
    String? bigKey,
    String? smallKey,
    required MachineTier hardwareTier,
  }) async {
    await setBoxServers(
      bigUrl: bigUrl,
      smallUrl: smallUrl,
      bigModel: bigModel,
      smallModel: smallModel,
    );
    await setBoxKey(big: bigKey, small: smallKey);
    await usePlacement(ModelPlacement.box, hardwareTier: hardwareTier);
  }

  /// Records that the owner has read what a third-party draft target
  /// receives. Until it is true, [AppPrefs.specForStage] sends both drafting
  /// stages to [AppPrefs.draftFallbackSpec] instead.
  Future<void> setCloudDraftsConsent(bool value) async {
    state = state.copyWith(cloudDraftsConsent: value);
    await _store.setPref(cloudDraftsConsentKey, value.toString());
  }

  /// Turns the standing rule on or off.
  ///
  /// State first and the write after it, like every setter here. The draft
  /// handler reads this through a closure at the moment a draft is written,
  /// so a flip moves the NEXT draft rather than the next relaunch.
  Future<void> setCloudDraftsStanding(bool value) async {
    state = state.copyWith(cloudDraftsStanding: value);
    await _store.setPref(cloudDraftsStandingKey, value.toString());
  }

  /// Moves how many drafts a day may leave for a third-party target.
  ///
  /// Clamped on the way in as well as on the way out, exactly as
  /// [setProseParallel] is: the field takes digits and this guards a caller
  /// that hands over a number no control on screen could have produced.
  Future<void> setCloudDraftsDailyCap(int value) async {
    final clamped = clampCloudDraftsDailyCap(value);
    state = state.copyWith(cloudDraftsDailyCap: clamped);
    await _store.setPref(cloudDraftsDailyCapKey, clamped.toString());
  }

  Future<void> _writeTargets(List<LlmTargetSpec> targets) => _store.setPref(
        llmTargetsKey,
        jsonEncode([for (final spec in targets) spec.toJson()]),
      );

  Future<void> _writeStageTargets(Map<String, String> map) =>
      _store.setPref(stageTargetsKey, jsonEncode(map));

  /// One keychain write, guarded on [_loadBearers]' rule and for its reason: a
  /// refusal costs the header on the next request, never the spec — which is
  /// written either way, so the target still appears in the list and the user
  /// can see that it is the token that did not stick.
  Future<void> _writeToken(String key, String? value) async {
    final tokens = _tokens;
    if (tokens == null) return;
    try {
      await tokens.write(key, value);
    } catch (_) {
      // Silent and broad: see [_loadBearers].
    }
  }

  static bool _sameMap(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// Points the downloader and the router at a folder. Empty means the app's
  /// own — see [AppPrefs.effectiveModelsFolder]. Trimmed on the way in as well
  /// as on the way out, for [_slotValue]'s reason: a path with a trailing
  /// newline is a directory that does not exist.
  Future<void> setModelsFolder(String value) async {
    final clean = value.trim();
    state = state.copyWith(modelsFolder: clean);
    await _store.setPref(modelsFolderKey, clean);
  }

  /// Back to the build's defaults for one slot.
  Future<void> clearSlotTarget(ModelSlot slot) => switch (slot) {
        ModelSlot.fast => setFastLlmTarget(url: '', model: ''),
        ModelSlot.prose => setProseLlmTarget(url: '', model: ''),
        ModelSlot.embed => Future<void>.value(),
      };
}

/// The range a port may be in: below 1024 wants root, and 65535 is the top of
/// the field. A free function beside the keys, on `clampLookbackDays`'s
/// precedent, so the read, the setter and the settings screen's validation all
/// mean the same thing by "a usable port".
int clampRouterPort(int value) => value.clamp(1024, 65535);

/// How wide the prose lane may be: at least one request, and never more than
/// eight. A free function beside [clampRouterPort], on its precedent, so the
/// read, the setter and the settings control all mean the same thing by "a
/// usable width". Eight is the top because past it a single draft's own
/// latency — which is what the person waiting cares about — grows faster than
/// the batch is worth.
int clampProseParallel(int value) => value.clamp(1, 8);

/// How many drafts a day may leave for a third-party target: at least one, and
/// never more than a thousand. A free function beside [clampProseParallel], on
/// its precedent, so the read, the setter and the settings field all mean the
/// same thing by "a usable cap". Zero is excluded deliberately — a cap of none
/// is what pointing the stage nowhere already says, and a field that could be
/// emptied into silence would be a second off switch nobody looked for.
int clampCloudDraftsDailyCap(int value) => value.clamp(1, 1000);

/// What `main()` read from the database before the first frame, or null where
/// nothing preloaded them — see [AppPrefsNotifier]'s constructor.
final initialAppPrefsProvider = Provider<AppPrefs?>((ref) => null);

final appPrefsProvider = StateNotifierProvider<AppPrefsNotifier, AppPrefs>(
  (ref) => AppPrefsNotifier(
    ref.watch(messageStoreProvider),
    initial: ref.watch(initialAppPrefsProvider),
    // The real keychain, constructed const exactly as `graph_auth.dart` and
    // `mcp_auth.dart` construct theirs. A test builds this notifier itself and
    // passes an in-memory store, because the plugin behind this one throws
    // under `flutter test`.
    tokens: const SecureTokenStore(),
  ),
);
