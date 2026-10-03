import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_paths.dart' show AppPaths;
import '../data/message_store.dart';
import '../models/draft_policy.dart';
import '../models/home_sort.dart';
import '../models/needs_you_sort.dart';
import '../models/people_sort.dart';
import '../services/decision/needs_you_predicate.dart';
import '../services/llm/embeddings_client.dart' show EmbeddingsClient;
import '../services/llm/model_slots.dart';
import '../services/sync_service.dart';
import '../services/token_store.dart';
import 'app_providers.dart';

export '../data/message_store.dart'
    show aboutMeKey, needsYouThresholdKey;

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
/// [LlmWire] ride along for the same reason: the tests and the benches read
/// and write them through this file; no screen does since Round H.
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
  /// The Needs You slider: the cut on the decision model's p(needs_you = yes)
  /// at or above which a message needs the owner (`needsYouAt`). Always
  /// within [NeedsYouTuning.minThreshold]..[NeedsYouTuning.maxThreshold] and
  /// on a [NeedsYouTuning.step] notch. Below it a thread is still in
  /// Conversations: the slider changes what gets promoted, never what exists.
  final double needsYouThreshold;

  /// What the user says about themselves and their role. Written here, read by
  /// the next phase's prompts.
  final String aboutMe;

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
  /// model call choosing two sections of it to read IN FULL before it writes.
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

  /// Whether sending a reply also clears the thread out of Needs You.
  ///
  /// OFF by default, because a sent reply and a cleared thread are two
  /// different claims: an answer that asks a question back is still the
  /// reader's to watch. On, it saves the second keystroke for the owner whose
  /// reply IS the end of the matter. It reads on the one send path both the
  /// thread composer and the in-list box go through, so the two surfaces
  /// cannot disagree about it.
  final bool replySendMarksDone;

  /// When a suggested reply is written without anyone asking for it.
  /// [DraftPolicy.needsYou] by default: the messages the pipeline judged to
  /// need the owner are drafted ahead of time and nothing else is, which is
  /// what keeps a backlog's worth of replies nobody will read out of the prose
  /// server's queue. A user preference, so `wipeAll` leaves it alone exactly as
  /// it leaves [needsYouSort] alone — it says how this person likes the app to
  /// work, not anything about the mailbox that was wiped.
  final DraftPolicy draftPolicy;

  /// Where the GENERATIVE model runs. [defaultModelPlacement] by default,
  /// which is the owner's box in any build compiled with an address for one
  /// and this Mac in every other.
  ///
  /// The key is Round H's `model_placement`, REUSED rather than renamed in the
  /// decision-model round: the one global placement became the generative
  /// role's, because the generative model is the one that ever ran on the box.
  /// [generativePlacement] is the same field under its role's name.
  final ModelPlacement modelPlacement;

  /// The generative remote's address, a chat-completions URL, or EMPTY for
  /// "whatever this build was compiled with" (`$BOND_BOX_URL/prose/…`).
  ///
  /// Round H's `box_big_url`, reused (see [modelPlacement]). Empty is stored
  /// as empty: the compiled address is a fact about the build, and freezing
  /// today's value into the database would make a changed [boxUrlDefault]
  /// invisible to anyone who had once opened the wizard.
  /// [effectiveGenerativeUrl] is the one place that resolves it.
  final String boxBigUrl;

  /// What the generative remote calls its model on the wire, DISCOVERED from
  /// the server's own `/v1/models` rather than typed, or empty to follow the
  /// build's constant ([boxProseModel]).
  final String boxBigModel;

  /// Whether the generative remote's access key is in the keychain (entry
  /// `box-prose`). NOT the key, and NOT persisted: the notifier sets it from
  /// the keychain when the prefetch returns, and it is false until then.
  ///
  /// False-until-answered is deliberate. The prefetch is a round trip that the
  /// first drain can beat, and a derived spec that claimed a bearer it does
  /// not yet hold would send one unauthenticated request per stage.
  final bool boxBigKeyStored;

  /// Which managed generative model this Mac serves: `''` to follow the
  /// hardware tier (the 27B on [MachineTier.full], the 4B on
  /// [MachineTier.inbox]), or [routerProseId] / [routerBulkId]. The 27B on
  /// the inbox tier is refused by [managedGenerativeIdFor] and reads as the
  /// 4B.
  final String generativeManagedModel;

  /// Where the DECISION model runs. [ModelPlacement.local] by default
  /// whatever the build: it reads every message, and a local forward pass
  /// beats any network hop.
  final ModelPlacement decisionPlacement;

  /// The decision remote's address, the FULL `/v1/embeddings` URL, or empty
  /// to follow the build (`$BOND_BOX_URL/decide/v1/embeddings`).
  final String decisionUrl;

  /// What the decision remote calls its model, discovered, or empty for
  /// [boxDecideModel].
  final String decisionModel;

  /// Whether the decision remote's key is in the keychain (entry
  /// `box-decide`). Not persisted, on [boxBigKeyStored]'s rule.
  final bool decisionKeyStored;

  /// The optional cloud-drafts target: a chat-completions URL (or a Bedrock
  /// runtime host) and its discovered model. Empty [cloudDraftsUrl] means no
  /// cloud drafts at all. The ONE place a third-party service may serve, and
  /// it serves `draft_reply` and `draft_improve` only, behind
  /// [cloudDraftsConsent].
  final String cloudDraftsUrl;
  final String cloudDraftsModel;

  /// Whether the cloud-drafts key is in the keychain (entry `cloud-drafts`).
  /// Not persisted, on [boxBigKeyStored]'s rule.
  final bool cloudDraftsKeyStored;

  /// The router ids the managed server's preset actually serves, as the
  /// supervisor last built it, or null before it has built one (read as
  /// "everything is served"). NOT persisted. A managed model the owner chose
  /// that is not on disk is left out of that preset, and a managed target
  /// naming it is marked unavailable ([unavailableFor]) so its role parks
  /// instead of taking the router's fatal 400 for an unknown model.
  final Set<String>? servedManagedIds;

  /// What this Mac can hold, read off its memory. NOT a preference and NOT
  /// persisted: the notifier is told by `setMachineTier`, from the managed
  /// server's preset build and from the placement writers, so resolution
  /// stays synchronous. [MachineTier.full] until told — the never-refuse
  /// rule `machineTierFor` states.
  final MachineTier machineTier;
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
  /// Empty is stored as empty for [boxBigUrl]'s reason: the app's folder is
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
    this.needsYouThreshold = NeedsYouTuning.defaultThreshold,
    this.aboutMe = '',
    this.backendMode = backendModeMcp,
    this.mcpServerUrl = defaultMcpServerUrl,
    this.showActivityLog = false,
    this.contextSelectExpand = true,
    this.storylineNewestFirst = false,
    this.needsYouSort = NeedsYouSort.priority,
    this.replySendMarksDone = false,
    this.draftPolicy = DraftPolicy.needsYou,
    this.modelPlacement = defaultModelPlacement,
    this.boxBigUrl = '',
    this.boxBigModel = '',
    this.boxBigKeyStored = false,
    this.generativeManagedModel = '',
    this.decisionPlacement = ModelPlacement.local,
    this.decisionUrl = '',
    this.decisionModel = '',
    this.decisionKeyStored = false,
    this.cloudDraftsUrl = '',
    this.cloudDraftsModel = '',
    this.cloudDraftsKeyStored = false,
    this.servedManagedIds,
    this.machineTier = MachineTier.full,
    this.processingOn = true,
    this.peopleSort = PeopleSort.recent,
    this.roomSort = RoomSort.newest,
    this.notifyStyle = NotifyStyle.native,
    this.homeSort = HomeSort.newest,
    this.mailLookbackDays = syncFloorDays,
    this.teamsLookbackDays = syncFloorDays,
    this.managedServer = managedServerDefault,
    this.routerPort = defaultRouterPort,
    this.modelsFolder = '',
    this.proseParallel = defaultProseParallel,
    this.cloudDraftsConsent = false,
    this.cloudDraftsStanding = false,
    this.cloudDraftsDailyCap = defaultCloudDraftsDailyCap,
  });

  /// The managed router's origin — one server, every model.
  String get routerBase => 'http://127.0.0.1:$routerPort';

  /// The embedding target the managed router answers on. Same origin as every
  /// other role, different `model` field: llama-server in router mode routes
  /// on the name alone, so the ids in `model_slots.dart` are the whole wiring
  /// between a role and the weights behind it.
  LlmTarget get routerEmbedTarget =>
      LlmTarget(baseUrl: '$routerBase/v1/embeddings', model: routerEmbedId);

  /// Where the embedding client actually POSTs, and what it puts in `model`:
  /// the router's id when the app runs the server, and the literal `'embed'`
  /// llama-server has always ignored when it does not. Never
  /// [EmbeddingsClient.modelTag], the corpus tag stored beside every vector,
  /// which no server serves.
  LlmTarget get embedRequestTarget => managedServer
      ? routerEmbedTarget
      : const LlmTarget(
          baseUrl: EmbeddingsClient.defaultBaseUrl,
          model: EmbeddingsClient.requestModel,
        );

  /// The origin the build was compiled with, as the derived URLs are built
  /// from it. Empty in the test suite and in any build that passed no define.
  static String get _compiledBase => normalizeBoxBaseUrl(boxUrlDefault);

  // ── Generative ─────────────────────────────────────────────────────────

  /// [modelPlacement] under its role's name.
  ModelPlacement get generativePlacement => modelPlacement;

  /// [boxBigUrl] and [boxBigModel] under their role's names: the STORED
  /// values, empty for "follow the build".
  String get generativeUrl => boxBigUrl;
  String get generativeModel => boxBigModel;

  /// The generative remote's address as a request will dial it: the stored
  /// URL when there is one, and the build's own `/prose` derivation otherwise.
  String get effectiveGenerativeUrl => boxBigUrl.isNotEmpty
      ? normalizeBoxBaseUrl(boxBigUrl)
      : (_compiledBase.isEmpty
          ? ''
          : '$_compiledBase/prose/v1/chat/completions');

  /// What the generative remote is asked for: the discovered name, or the
  /// constant the compiled box serves.
  String get effectiveGenerativeModel =>
      boxBigModel.isEmpty ? boxProseModel : boxBigModel;

  /// The managed generative model's router id on this Mac's tier.
  String get managedGenerativeId =>
      managedGenerativeIdFor(machineTier, generativeManagedModel);

  /// Whether [url] may serve a role that reads every message: not a third
  /// party and not the Converse wire. The writers refuse such an address;
  /// this is the belt at resolution, so a hand-edited row cannot route every
  /// message off to a vendor.
  static bool _ownServer(String url) =>
      !isThirdPartyHost(url) && wireForHost(url) != LlmWire.bedrockConverse;

  /// THE generative target — every text stage resolves here (drafts too,
  /// unless [cloudDraftsSpec] takes them).
  ///
  /// Your server when the placement says so and there is an address to dial;
  /// else this Mac: the managed router with the tier's chosen model, or the
  /// hand-started prose server of a `BOND_DEV_HAND_SERVERS` build. The wire is
  /// read off the host.
  ///
  /// The widths are sized to what is known about the server. Message text
  /// runs eight wide on Your server whether or not the address follows the
  /// build: it is the owner's own server either way (a third-party host is
  /// refused for this role), and a server with fewer slots queues the extra
  /// requests rather than failing them. The compiled box
  /// (`tools/inference.sh`) runs its PROSE-ONLY profile at vLLM
  /// `--max-num-seqs 16`, which leaves the rest to the storyline lane; with a
  /// bulk slot (`--bulk-model`) the prose slot has 8 sequences and vLLM
  /// queues the extra requests, their wait counting against the client's
  /// 90 s timeout (`LlmClient.proseTimeout`, every generative stage's). The
  /// bound is conscious: on a one-slot server the eighth text waits about
  /// seven calls, so a server slower than ~11 s per text would time out;
  /// the box is ~4 s. The attachment digests share extraction's eight: they
  /// drain after it on the same lane, one kind at a time. A typed address ran
  /// three wide until the 2026-10-01 replay, where ~730 texts took ~15 min.
  /// Drafts keep the split: four wide on an address that follows the build,
  /// one at a time on a stored one, because drafts stream and a stored
  /// address may be a laptop's one-slot llama-server, which would queue the
  /// rest past the prose client's ceiling. This Mac's server gives message
  /// text its [proseParallel] slots, never fewer than three.
  LlmTargetSpec get generativeSpec {
    final url = effectiveGenerativeUrl;
    if (modelPlacement == ModelPlacement.box &&
        url.isNotEmpty &&
        _ownServer(url)) {
      return LlmTargetSpec(
        id: boxProseId,
        name: boxProseName,
        url: url,
        model: effectiveGenerativeModel,
        wire: wireForHost(url),
        hasBearer: boxBigKeyStored,
        parallel: boxBigUrl.isEmpty ? 4 : 1,
        textParallel: 8,
      );
    }
    if (managedServer) {
      return LlmTargetSpec(
        id: localGenerativeId,
        name: localGenerativeName,
        url: '$routerBase/v1/chat/completions',
        model: managedGenerativeId,
        parallel: proseParallel,
        textParallel: proseParallel < 3 ? 3 : proseParallel,
      );
    }
    return LlmTargetSpec(
      id: localGenerativeId,
      name: localGenerativeName,
      url: generativeUrlDefault,
      model: generativeModelDefault,
      parallel: proseParallel,
      textParallel: proseParallel < 3 ? 3 : proseParallel,
    );
  }

  // ── Decision ───────────────────────────────────────────────────────────

  /// The decision remote's address as a request will dial it: the stored URL,
  /// or the build's own `/decide` derivation.
  String get effectiveDecisionUrl => decisionUrl.isNotEmpty
      ? normalizeBoxBaseUrl(decisionUrl)
      : (_compiledBase.isEmpty ? '' : '$_compiledBase/decide/v1/embeddings');

  /// What the decision remote is asked for.
  String get effectiveDecisionModel =>
      decisionModel.isEmpty ? boxDecideModel : decisionModel;

  /// THE decision target, on [generativeSpec]'s rule: Your server when the
  /// decision placement says so and there is an address; else the managed
  /// router's `/v1/embeddings` under [routerDecideId]; else the hand-started
  /// `make decide` server. The heads always run here, off the local heads
  /// file, whichever server embeds.
  LlmTargetSpec get decisionSpec {
    final url = effectiveDecisionUrl;
    if (decisionPlacement == ModelPlacement.box &&
        url.isNotEmpty &&
        _ownServer(url)) {
      return LlmTargetSpec(
        id: boxDecideId,
        name: boxDecideName,
        url: url,
        model: effectiveDecisionModel,
        wire: wireForHost(url),
        hasBearer: decisionKeyStored,
      );
    }
    if (managedServer) {
      return LlmTargetSpec(
        id: localDecisionId,
        name: localDecisionName,
        url: '$routerBase/v1/embeddings',
        model: routerDecideId,
      );
    }
    return const LlmTargetSpec(
      id: localDecisionId,
      name: localDecisionName,
      url: decideUrlDefault,
      model: decideModelDefault,
    );
  }

  // ── Cloud drafts ───────────────────────────────────────────────────────

  /// The optional cloud-drafts target, or null when none is set (an address
  /// without a model is not a target: a request has to name one).
  LlmTargetSpec? get cloudDraftsSpec {
    final url = normalizeBoxBaseUrl(cloudDraftsUrl);
    if (url.isEmpty || cloudDraftsModel.isEmpty) return null;
    return LlmTargetSpec(
      id: cloudDraftsId,
      name: cloudDraftsName,
      url: url,
      model: cloudDraftsModel,
      wire: wireForHost(url),
      hasBearer: cloudDraftsKeyStored,
    );
  }

  // ── Routing ────────────────────────────────────────────────────────────

  /// The spec a stage will dial — THE ROUTING RULE, with the consent gate
  /// applied.
  ///
  /// `embeddings` is not routed (null). `decision` is [decisionSpec]. The two
  /// draft stages go to [cloudDraftsSpec] when one is set AND it is either
  /// the owner's own host or [cloudDraftsConsent] stands; otherwise, and for
  /// every other stage, [generativeSpec]. Consent is checked HERE rather than
  /// only on the screen that sets it, so prefs restored from a backup or
  /// edited by hand cannot route a draft off this machine on their own.
  LlmTargetSpec? specForStage(String stageId) {
    if (stageId == 'embeddings') return null;
    if (stageId == 'decision') return decisionSpec;
    if (draftStageIds.contains(stageId)) {
      final cloud = cloudDraftsSpec;
      if (cloud != null && (!cloud.isThirdParty || cloudDraftsConsent)) {
        return cloud;
      }
    }
    return generativeSpec;
  }

  /// The sentence a MANAGED target carries when the router is not serving
  /// its model, or null when it is (or when this is not a managed target, or
  /// the served set is not known yet). See [servedManagedIds].
  String? unavailableFor(LlmTargetSpec spec) {
    final served = servedManagedIds;
    if (served == null || !managedServer) return null;
    if (spec.id != localGenerativeId && spec.id != localDecisionId) {
      return null;
    }
    if (served.contains(spec.model)) return null;
    return switch (spec.model) {
      routerDecideId =>
        'The decision model is not installed. Run: make decide-install',
      routerProseId => 'The Qwen3.8 27B is not downloaded on this Mac. Set '
          'up again to download it.',
      routerBulkId => 'The Qwen3 4B is not downloaded on this Mac. Set up '
          'again to download it.',
      final other => 'The model $other is not on this Mac. Set up again to '
          'download it.',
    };
  }

  /// One of the current fixed specs by id, or null when none carries it —
  /// what the composer's `Improved with <name>` reads back off a draft row.
  LlmTargetSpec? specById(String id) {
    for (final spec in [generativeSpec, decisionSpec, cloudDraftsSpec]) {
      if (spec != null && spec.id == id) return spec;
    }
    return null;
  }
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
    double? needsYouThreshold,
    String? aboutMe,
    String? backendMode,
    String? mcpServerUrl,
    bool? showActivityLog,
    bool? contextSelectExpand,
    bool? storylineNewestFirst,
    NeedsYouSort? needsYouSort,
    bool? replySendMarksDone,
    DraftPolicy? draftPolicy,
    ModelPlacement? modelPlacement,
    String? boxBigUrl,
    String? boxBigModel,
    bool? boxBigKeyStored,
    String? generativeManagedModel,
    ModelPlacement? decisionPlacement,
    String? decisionUrl,
    String? decisionModel,
    bool? decisionKeyStored,
    String? cloudDraftsUrl,
    String? cloudDraftsModel,
    bool? cloudDraftsKeyStored,
    Set<String>? servedManagedIds,
    MachineTier? machineTier,
    bool? processingOn,
    PeopleSort? peopleSort,
    RoomSort? roomSort,
    NotifyStyle? notifyStyle,
    HomeSort? homeSort,
    int? mailLookbackDays,
    int? teamsLookbackDays,
    bool? managedServer,
    int? routerPort,
    String? modelsFolder,
    int? proseParallel,
    bool? cloudDraftsConsent,
    bool? cloudDraftsStanding,
    int? cloudDraftsDailyCap,
  }) =>
      AppPrefs(
        needsYouThreshold: needsYouThreshold ?? this.needsYouThreshold,
        aboutMe: aboutMe ?? this.aboutMe,
        backendMode: backendMode ?? this.backendMode,
        mcpServerUrl: mcpServerUrl ?? this.mcpServerUrl,
        showActivityLog: showActivityLog ?? this.showActivityLog,
        contextSelectExpand: contextSelectExpand ?? this.contextSelectExpand,
        storylineNewestFirst:
            storylineNewestFirst ?? this.storylineNewestFirst,
        needsYouSort: needsYouSort ?? this.needsYouSort,
        replySendMarksDone: replySendMarksDone ?? this.replySendMarksDone,
        draftPolicy: draftPolicy ?? this.draftPolicy,
        modelPlacement: modelPlacement ?? this.modelPlacement,
        boxBigUrl: boxBigUrl ?? this.boxBigUrl,
        boxBigModel: boxBigModel ?? this.boxBigModel,
        boxBigKeyStored: boxBigKeyStored ?? this.boxBigKeyStored,
        generativeManagedModel:
            generativeManagedModel ?? this.generativeManagedModel,
        decisionPlacement: decisionPlacement ?? this.decisionPlacement,
        decisionUrl: decisionUrl ?? this.decisionUrl,
        decisionModel: decisionModel ?? this.decisionModel,
        decisionKeyStored: decisionKeyStored ?? this.decisionKeyStored,
        cloudDraftsUrl: cloudDraftsUrl ?? this.cloudDraftsUrl,
        cloudDraftsModel: cloudDraftsModel ?? this.cloudDraftsModel,
        cloudDraftsKeyStored: cloudDraftsKeyStored ?? this.cloudDraftsKeyStored,
        servedManagedIds: servedManagedIds ?? this.servedManagedIds,
        machineTier: machineTier ?? this.machineTier,
        processingOn: processingOn ?? this.processingOn,
        peopleSort: peopleSort ?? this.peopleSort,
        roomSort: roomSort ?? this.roomSort,
        notifyStyle: notifyStyle ?? this.notifyStyle,
        homeSort: homeSort ?? this.homeSort,
        mailLookbackDays: mailLookbackDays ?? this.mailLookbackDays,
        teamsLookbackDays: teamsLookbackDays ?? this.teamsLookbackDays,
        managedServer: managedServer ?? this.managedServer,
        routerPort: routerPort ?? this.routerPort,
        modelsFolder: modelsFolder ?? this.modelsFolder,
        proseParallel: proseParallel ?? this.proseParallel,
        cloudDraftsConsent: cloudDraftsConsent ?? this.cloudDraftsConsent,
        cloudDraftsStanding: cloudDraftsStanding ?? this.cloudDraftsStanding,
        cloudDraftsDailyCap: cloudDraftsDailyCap ?? this.cloudDraftsDailyCap,
      );
}

/// Keys in `app_prefs`. Constants because they are typed in two places — the
/// read below and the tests that assert what landed in the table.
/// [aboutMeKey] lives in `message_store.dart` — `wipeAll` has to clear it and
/// that layer imports nothing above itself — and is re-exported here so this
/// file stays where prefs keys are found. So does [needsYouThresholdKey],
/// which the store reads itself for the extraction claim's order.
const String backendModeKey = 'backend_mode';
const String mcpServerUrlKey = 'mcp_server_url';
const String showActivityLogKey = 'show_activity_log';
const String contextSelectExpandKey = 'context_select_expand';
const String storylineNewestFirstKey = 'storyline_newest_first';
const String needsYouSortKey = 'needs_you_sort';
const String replySendMarksDoneKey = 'reply_send_marks_done';
const String draftPolicyKey = 'suggested_replies';
const String peopleSortKey = 'people_sort';
const String roomSortKey = 'person_room_sort';
const String notifyStyleKey = 'notify_style';
const String homeSortKey = 'home_sort';
const String mailLookbackDaysKey = 'mail_lookback_days';
const String teamsLookbackDaysKey = 'teams_lookback_days';

/// The Day stop's face (`agenda` | `grid`) and the grid's span (`day` |
/// `week`). Read and written by the inbox itself, once at startup and on
/// each press, rather than carried on [AppPrefs]: nothing else reads them,
/// and the enums they name live with the widgets that draw them.
const String dayViewKey = 'day_view';
const String dayGridSpanKey = 'day_grid_span';

/// The managed server's two remaining keys. Not in `wipeAll`'s list,
/// deliberately: which server this machine runs is a fact about the machine.
/// Whether the app runs one at all is no longer stored — see
/// [AppPrefs.managedServer] and `managedServerDefault`.
const String routerPortKey = 'router_port';
const String modelsFolderKey = 'models_folder';

/// How wide the prose server was started. Not in `wipeAll`'s list for the
/// three keys above's reason — see [AppPrefs.proseParallel].
const String proseParallelKey = 'prose_parallel';

/// Two INERT keys since the decision-model round, kept only for the frozen
/// one-shots below that still read them: [llmTargetsKey] (a JSON array of
/// user-added [LlmTargetSpec]s) and [stageTargetsKey] (a JSON object of stage
/// id to target id). Nothing routes through either any more.
const String llmTargetsKey = 'llm_targets';
const String stageTargetsKey = 'stage_targets';

/// Machine configuration and out of `wipeAll`'s list: how much this machine
/// may send elsewhere is not a fact about whoever is signed in. The string
/// `'true'` or nothing.
const String cloudDraftsConsentKey = 'cloud_drafts_consent';

/// Where the GENERATIVE model runs — `ModelPlacement.name`. Round H's global
/// placement key, reused for the generative role.
///
/// Machine configuration like the keys above and out of `wipeAll`'s list for
/// their reason: whether this Mac reaches the owner's server is not a fact
/// about whoever is signed in. Every model-routing key below is the same.
const String modelPlacementKey = 'model_placement';

/// The generative remote: a chat-completions URL and the model name
/// discovered behind it, each empty for "follow the build". Round H's
/// big-model keys, reused.
const String boxBigUrlKey = 'box_big_url';
const String boxBigModelKey = 'box_big_model';

/// Round H's SMALL-model keys. Inert since the decision-model round (the
/// small model's work went to the decision model and the one generative
/// model), and kept only because two one-shots read them: `_splitBoxServers`
/// (frozen) and `_deriveModelRoles`.
const String boxSmallUrlKey = 'box_small_url';
const String boxSmallModelKey = 'box_small_model';

/// The managed generative model: `''`, `bond-prose` or `bond-bulk`.
const String generativeManagedModelKey = 'generative_managed_model';

/// The decision role: its placement (`ModelPlacement.name`, absent =
/// local), its remote `/v1/embeddings` URL and discovered model (each empty
/// for "follow the build").
const String decisionPlacementKey = 'decision_placement';
const String decisionUrlKey = 'decision_url';
const String decisionModelKey = 'decision_model';

/// The optional cloud-drafts target's URL and discovered model. Empty URL =
/// no cloud drafts.
const String cloudDraftsUrlKey = 'cloud_drafts_url';
const String cloudDraftsModelKey = 'cloud_drafts_model';

/// The ONE origin the Round H URLs replaced, kept for the two migrations
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

/// The one-shot flag over the decision-model round's role split, written by
/// [AppPrefsNotifier.read] through `_deriveModelRoles`.
///
/// Three kinds of value. Absent: not run. [modelRolesDoneValue] (`'1'`):
/// done. A PENDING value, [modelRolesPendingPrefix] followed by the keychain
/// moves still owed, comma-separated in the order they run:
/// [modelRolesMoveProseToCloud] (the vendor key under `box-prose` becomes the
/// cloud-drafts key), [modelRolesDropProse] (the vendor key is deleted) and
/// [modelRolesMoveBulkToProse] (the owner's own small-server key becomes the
/// generative key). The pending value is written BEFORE the preferences move,
/// so a crash between the two re-runs only the keychain half; each move
/// advances the value only after a read-back confirms it; and while any move
/// is owed the notifier attaches no `box-prose` token at all. A PLAIN pref on
/// [boxTargetsDerivedKey]'s rule.
const String modelRolesDerivedKey = 'model_roles_derived';
const String modelRolesDoneValue = '1';
const String modelRolesPendingPrefix = 'pending:';
const String modelRolesMoveProseToCloud = 'prose>cloud';
const String modelRolesDropProse = 'prose>x';
const String modelRolesMoveBulkToProse = 'bulk>prose';

/// Whether [flag] says keychain moves are still owed.
bool modelRolesPending(String? flag) =>
    flag != null && flag.startsWith(modelRolesPendingPrefix);

/// Where the generative role lands after a third-party big address.
enum GenerativeAfterVendor {
  /// The owner's own stored small server becomes the generative remote, or
  /// the box's `/prose` slot beside it when it was the `/bulk` one.
  small,

  /// The small server followed the build: the generative remote follows the
  /// build's `/prose` too (`box_big_url` emptied, the placement kept).
  followBuild,

  /// Nothing of the owner's to dial: the generative model comes home.
  local,
}

/// What `_deriveModelRoles` does to a Round H install whose big address is a
/// third party. A value, so the decision is a PURE function
/// ([planModelRoles]) a test can drive with any compiled address.
@immutable
class ModelRolesPlan {
  /// Whether the vendor address becomes the cloud-drafts target.
  final bool adoptCloud;
  final GenerativeAfterVendor generative;

  /// The keychain moves owed, in order.
  final List<String> moves;

  /// The generative remote's address under [GenerativeAfterVendor.small]:
  /// the stored small server's, or its `/prose` sibling when it was a box's
  /// `/bulk` slot. Empty under the other two.
  final String generativeUrl;

  const ModelRolesPlan({
    required this.adoptCloud,
    required this.generative,
    required this.moves,
    this.generativeUrl = '',
  });
}

/// The role split's decision, or null when [bigUrl] is not a third party
/// (every other shape is a no-op: the keys were reused).
///
/// A vendor big address is ADOPTED as cloud drafts only when the owner was
/// actually using it and had agreed to it: the effective generative
/// [placement] was the box, [consent] stood, and a model name had been
/// discovered. Anything else is an address the owner walked away from, and
/// it is dropped along with its key rather than turned into a live target.
/// The generative role then goes to the owner's own stored small server (its
/// `/prose` sibling when that server was a box's `/bulk` slot), else follows
/// the build when the small server did ([compiledBase] non-empty and no small
/// address stored), else comes home to this Mac.
ModelRolesPlan? planModelRoles({
  required String bigUrl,
  required String bigModel,
  required String smallUrl,
  required ModelPlacement placement,
  required bool consent,
  required String compiledBase,
}) {
  bool ownServer(String url) =>
      !isThirdPartyHost(url) && wireForHost(url) != LlmWire.bedrockConverse;
  if (bigUrl.isEmpty || ownServer(bigUrl)) return null;
  final adopt =
      placement == ModelPlacement.box && consent && bigModel.isNotEmpty;
  final small = normalizeBoxBaseUrl(smallUrl);
  final GenerativeAfterVendor generative;
  if (small.isNotEmpty && isBoxOrigin(small) && ownServer(small)) {
    generative = GenerativeAfterVendor.small;
  } else if (small.isEmpty && compiledBase.isNotEmpty) {
    generative = GenerativeAfterVendor.followBuild;
  } else {
    generative = GenerativeAfterVendor.local;
  }
  return ModelRolesPlan(
    adoptCloud: adopt,
    generative: generative,
    // Round H wrote a box's small server as its `/bulk` slot, which serves
    // the 4B, and a stored address is one wide: the one generative model
    // would be the box's smallest, one message at a time. The `/prose` slot
    // beside it is the box's 27B, and the same key opens both.
    generativeUrl: generative != GenerativeAfterVendor.small
        ? ''
        : small.endsWith(_bulkCompletions)
            ? '${small.substring(0, small.length - _bulkCompletions.length)}'
                '/prose/v1/chat/completions'
            : small,
    moves: [
      adopt ? modelRolesMoveProseToCloud : modelRolesDropProse,
      if (generative != GenerativeAfterVendor.local) modelRolesMoveBulkToProse,
    ],
  );
}

/// The box's `/bulk` slot's completions path, which [planModelRoles] turns
/// into its `/prose` sibling.
const String _bulkCompletions = '/bulk/v1/chat/completions';

/// Round H's small-model keychain id, which only `_deriveModelRoles` still
/// names: it is where an existing install's small-server key lives.
const String legacyBoxBulkId = 'box-bulk';

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
    // parallel. With [initial] supplied the load already happened in
    // `main()`, which has no token store, so the one keychain step the
    // role-split migration may still owe is finished here instead — and
    // before the prefetch, so the cache never holds a token under the id it
    // is about to leave.
    ready = (initial != null
            ? finishModelRoles(_store, _tokens)
            : _load())
        .then((_) => _loadBearers());
  }

  Future<void> _load() async {
    final prefs = await read(_store, tokens: _tokens);
    if (!mounted) return;
    // The machine tier is not stored; a load must not reset one already
    // learned.
    state = prefs.copyWith(machineTier: state.machineTier);
  }

  /// Fills the bearer cache from the keychain, once, and records which of
  /// the three keyed targets have one.
  ///
  /// A no-op with no keychain. Guarded whole: a keychain that refuses costs
  /// the header on the next request — one 401 the user can see and act on —
  /// and never the launch. The three ids are asked for UNCONDITIONALLY,
  /// because the derived specs have no stored row to carry a presence flag
  /// on: the keychain is the only thing that knows.
  Future<void> _loadBearers() async {
    final tokens = _tokens;
    if (tokens == null) return;
    // While the role split still owes keychain moves, `box-prose` may hold a
    // VENDOR's key; the generative remote goes keyless (a 401 park the owner
    // can fix) rather than send it to the owner's server.
    var pending = true;
    try {
      pending = modelRolesPending(await _store.getPref(modelRolesDerivedKey));
    } catch (_) {}
    for (final id in [
      if (!pending) boxProseId,
      boxDecideId,
      cloudDraftsId,
    ]) {
      // The try sits INSIDE the loop: one key the keychain refuses costs that
      // one target its header, not every target after it.
      try {
        final value = await tokens.read('$llmTargetBearerKeyPrefix$id');
        if (value != null && value.isNotEmpty) _bearers[id] = value;
      } catch (_) {
        // Deliberately silent and deliberately broad: see the doc above. The
        // exception carries a key name and nothing else worth a log line.
      }
    }
    // The flags move only now, which is what makes the window honest: until
    // this line every derived spec has said `hasBearer: false`.
    if (!mounted) return;
    state = state.copyWith(
      boxBigKeyStored: _bearers.containsKey(boxProseId),
      decisionKeyStored: _bearers.containsKey(boxDecideId),
      cloudDraftsKeyStored: _bearers.containsKey(cloudDraftsId),
    );
  }

  /// Where a stage's next request goes, bearer included.
  ///
  /// The one resolver `stageLlmClientProvider` and the decision client call,
  /// at the top of every request. Synchronous by construction — the token is
  /// already in [_bearers] — because it runs on a drain's hot path.
  /// `embeddings` has no spec and answers the embedding request target.
  LlmTarget targetForStage(String stageId) {
    final spec = state.specForStage(stageId);
    if (spec == null) return state.embedRequestTarget;
    return spec.toTarget(
      bearer: spec.hasBearer ? _bearers[spec.id] : null,
      unavailable: state.unavailableFor(spec),
    );
  }

  /// One target's stored token, or null when there is none.
  ///
  /// The ONLY door onto [_bearers] besides [targetForStage], and it exists
  /// for exactly two callers, both through `storedBearer`: the role rows'
  /// **Check** and the form's **Connect**, which must reach a keyed endpoint
  /// rather than report its 401. One token, by id, for one request.
  /// What comes back never enters widget state, a `ProbeStatus`, a log line,
  /// an activity row or a test expectation. Null when nothing is stored and
  /// in every build with no keychain, which is every `flutter test` that
  /// hands this notifier a `MemoryTokenStore` it never wrote to.
  String? bearerFor(String targetId) => _bearers[targetId];

  /// Reads every setting once. A stored value that does not parse —
  /// hand-edited, or written by a build that meant something else by the key —
  /// falls back to the default rather than throwing: a bad preference must not
  /// be able to stop the app from starting.
  ///
  /// [tokens] is the keychain, for the one migration step that moves a
  /// token. `main()`'s preload passes none, and the notifier finishes that
  /// step on its own load — see [modelRolesDerivedKey].
  static Future<AppPrefs> read(MessageStore store, {TokenStore? tokens}) async {
    // The FOUR one-shots, in this order and no other. The Round G derive
    // needs the old `box-prose` row and writes [boxUrlKey]; the split reads
    // what it wrote; the clear runs after both, because both can leave stage
    // entries behind; the role split runs last, over the URLs the split
    // wrote.
    await _deriveBoxTargets(store);
    await _splitBoxServers(store);
    await _clearStageTargets(store);
    await _deriveModelRoles(store, tokens);
    return AppPrefs(
      needsYouThreshold:
          parseNeedsYouThreshold(await store.getPref(needsYouThresholdKey)),
      aboutMe: await store.getPref(aboutMeKey) ?? '',
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
      // Only 'true' is on: this one CLEARS a thread out of the pile, so
      // anything unreadable leaves it off rather than dismissing mail the
      // reader never agreed to have dismissed.
      replySendMarksDone:
          await store.getPref(replySendMarksDoneKey) == 'true',
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
      boxBigModel: _slotValue(await store.getPref(boxBigModelKey)),
      generativeManagedModel:
          _slotValue(await store.getPref(generativeManagedModelKey)),
      decisionPlacement: _enumOrDefault(
        ModelPlacement.values,
        await store.getPref(decisionPlacementKey),
        ModelPlacement.local,
      ),
      decisionUrl: _slotValue(await store.getPref(decisionUrlKey)),
      decisionModel: _slotValue(await store.getPref(decisionModelKey)),
      cloudDraftsUrl: _slotValue(await store.getPref(cloudDraftsUrlKey)),
      cloudDraftsModel: _slotValue(await store.getPref(cloudDraftsModelKey)),
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
      mailLookbackDays: _lookback(await store.getPref(mailLookbackDaysKey)),
      teamsLookbackDays: _lookback(await store.getPref(teamsLookbackDaysKey)),
      routerPort: _routerPort(await store.getPref(routerPortKey)),
      modelsFolder: _slotValue(await store.getPref(modelsFolderKey)),
      proseParallel: _proseParallel(await store.getPref(proseParallelKey)),
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
  /// would have appeared twice in the target list Round H showed, and its
  /// stage picker asserted on a duplicate dropdown value. This lifts the origin out of the writing
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
        // Round G's two box ids, spelled out: this one-shot is frozen
        // history, and the "Your server" pair has been `box-prose` and
        // `box-decide` since the decision-model round.
        if (spec.id != boxProseId && spec.id != legacyBoxBulkId) {
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

  /// Splits Round H's big/small pair into the decision-model round's roles.
  /// Runs at most once per install, and is a NO-OP for every shape but one.
  ///
  /// The keys were REUSED (the plan's R1): `model_placement`, `box_big_url`,
  /// `box_big_model` and the `box-prose` keychain entry already mean the
  /// generative remote, so an install that followed the build, or that named
  /// its own big server, needs nothing. The one shape that does is a
  /// THIRD-PARTY big address (a vendor host or the Converse wire): the
  /// generative model reads every message and may not run there.
  /// [planModelRoles] decides what happens to it; see there.
  ///
  /// ORDER: the pending flag (naming the keychain moves owed) is written
  /// FIRST and the preferences after it, so a crash between the two leaves a
  /// flag that re-runs only the keychain half, never the preference moves.
  /// The keychain half is [finishModelRoles], which needs a token store.
  static Future<void> _deriveModelRoles(
    MessageStore store,
    TokenStore? tokens,
  ) async {
    final flag = await store.getPref(modelRolesDerivedKey);
    if (flag == modelRolesDoneValue) return;
    if (!modelRolesPending(flag)) {
      final big = _slotValue(await store.getPref(boxBigUrlKey));
      final bigModel = _slotValue(await store.getPref(boxBigModelKey));
      final plan = planModelRoles(
        bigUrl: big,
        bigModel: bigModel,
        smallUrl: _slotValue(await store.getPref(boxSmallUrlKey)),
        placement: _enumOrDefault(
          ModelPlacement.values,
          await store.getPref(modelPlacementKey),
          defaultModelPlacement,
        ),
        consent: await store.getPref(cloudDraftsConsentKey) == 'true',
        compiledBase: normalizeBoxBaseUrl(boxUrlDefault),
      );
      if (plan == null) {
        await store.setPref(modelRolesDerivedKey, modelRolesDoneValue);
        return;
      }
      await store.setPref(
        modelRolesDerivedKey,
        '$modelRolesPendingPrefix${plan.moves.join(',')}',
      );
      if (plan.adoptCloud) {
        await store.setPref(cloudDraftsUrlKey, normalizeBoxBaseUrl(big));
        await store.setPref(cloudDraftsModelKey, bigModel);
      }
      switch (plan.generative) {
        case GenerativeAfterVendor.small:
          final small = normalizeBoxBaseUrl(
            _slotValue(await store.getPref(boxSmallUrlKey)),
          );
          await store.setPref(boxBigUrlKey, plan.generativeUrl);
          // The small server's discovered name goes with its own address
          // only: the `/prose` sibling serves another model, so its name is
          // left to the build's constant until a Connect discovers it.
          await store.setPref(
            boxBigModelKey,
            plan.generativeUrl == small
                ? _slotValue(await store.getPref(boxSmallModelKey))
                : '',
          );
        case GenerativeAfterVendor.followBuild:
          await store.setPref(boxBigUrlKey, '');
          await store.setPref(boxBigModelKey, '');
        case GenerativeAfterVendor.local:
          await store.setPref(boxBigUrlKey, '');
          await store.setPref(boxBigModelKey, '');
          await store.setPref(modelPlacementKey, ModelPlacement.local.name);
      }
    }
    await finishModelRoles(store, tokens);
  }

  /// The keychain half of [_deriveModelRoles]: runs the moves a pending
  /// [modelRolesDerivedKey] names, in order, advancing the flag after each
  /// one only when a read-back confirms it, and marking the migration done
  /// when none is left. A no-op without a token store and on any flag that is
  /// not pending.
  ///
  /// NEVER throws and never logs: a keychain that refuses leaves the flag
  /// pending, the notifier then attaches no `box-prose` token (a 401 park the
  /// owner can fix), and the next launch tries again. Every move is safe to
  /// repeat, because the flag only ever advances past a move that verified.
  static Future<void> finishModelRoles(
    MessageStore store,
    TokenStore? tokens,
  ) async {
    if (tokens == null) return;
    try {
      final flag = await store.getPref(modelRolesDerivedKey);
      if (!modelRolesPending(flag)) return;
      final moves = flag!
          .substring(modelRolesPendingPrefix.length)
          .split(',')
          .where((m) => m.isNotEmpty)
          .toList();
      while (moves.isNotEmpty) {
        if (!await _runMove(tokens, moves.first)) return;
        moves.removeAt(0);
        await store.setPref(
          modelRolesDerivedKey,
          moves.isEmpty
              ? modelRolesDoneValue
              : '$modelRolesPendingPrefix${moves.join(',')}',
        );
      }
    } catch (_) {
      // Silent on the bearer rules: the flag stays where it last verified.
    }
  }

  /// One keychain move, then its read-back. True only when `box-prose`
  /// holds exactly what the move meant it to: nothing after a prose move, the
  /// owner's own small-server key (or nothing, when there was none left to
  /// move) after the bulk move. An unknown move word is refused.
  static Future<bool> _runMove(TokenStore tokens, String move) async {
    const prose = '$llmTargetBearerKeyPrefix$boxProseId';
    switch (move) {
      case modelRolesMoveProseToCloud:
      case modelRolesDropProse:
        final value = await tokens.read(prose);
        if (move == modelRolesMoveProseToCloud &&
            value != null &&
            value.isNotEmpty) {
          try {
            await tokens.write(
              '$llmTargetBearerKeyPrefix$cloudDraftsId',
              value,
            );
          } catch (_) {
            // The key is lost rather than left where the next id would send
            // it: the delete below still runs.
          }
        }
        await tokens.write(prose, null);
        final after = await tokens.read(prose);
        return after == null || after.isEmpty;
      case modelRolesMoveBulkToProse:
        const bulk = '$llmTargetBearerKeyPrefix$legacyBoxBulkId';
        final value = await tokens.read(bulk);
        // Already moved on an earlier run (the prose move before this one
        // verified `box-prose` empty, so whatever it holds now came from
        // here), or there was never a small-server key.
        if (value == null || value.isEmpty) return true;
        await tokens.write(prose, value);
        try {
          await tokens.write(bulk, null);
        } catch (_) {
          // A leftover `box-bulk` entry is read by nothing.
        }
        return await tokens.read(prose) == value;
    }
    return false;
  }

  /// A stored cap, or fifty. [_proseParallel]'s rule and its reason: a number
  /// nothing wrote, or one somebody typed into the table by hand, must not be
  /// able to uncap what leaves this machine.
  static int _cloudDraftsDailyCap(String? raw) => clampCloudDraftsDailyCap(
        int.tryParse(raw ?? '') ?? AppPrefs.defaultCloudDraftsDailyCap,
      );

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

  /// The Needs You slider's writer. Clamped to the slider's range and rounded
  /// to its notch ([normalizeNeedsYouThreshold]), so what is stored is exactly
  /// a number the slider can show, and a value that somehow arrived from
  /// outside it cannot make Needs You permanently empty.
  ///
  /// State first, then the write — the reverse of the order this had while the
  /// store was synchronous. Everything on screen reads the state, and making a
  /// slider wait a round trip on the database before it moves would be a frame
  /// of lag on the one control whose whole point is watching the list change
  /// under it. The returned future is the write; the setters below are the
  /// same shape.
  Future<void> setNeedsYouThreshold(double value) async {
    final normalized = normalizeNeedsYouThreshold(value);
    state = state.copyWith(needsYouThreshold: normalized);
    await _store.setPref(needsYouThresholdKey, normalized.toString());
  }

  Future<void> setAboutMe(String value) async {
    state = state.copyWith(aboutMe: value);
    await _store.setPref(aboutMeKey, value);
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

  Future<void> setReplySendMarksDone(bool value) async {
    state = state.copyWith(replySendMarksDone: value);
    await _store.setPref(replySendMarksDoneKey, value.toString());
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

  /// Records where the GENERATIVE model runs. State first and the write after
  /// it, like every setter here. The role writers below call it; nothing else
  /// should, because a placement moved alone skips the draft policy.
  Future<void> setModelPlacement(ModelPlacement value) async {
    state = state.copyWith(modelPlacement: value);
    await _store.setPref(modelPlacementKey, value.name);
  }

  /// Tells the prefs which router ids the managed server's preset serves.
  /// NOT persisted. Called by the supervisor's preset build every time it
  /// builds one. A no-op when unchanged.
  void setServedManagedIds(Set<String> ids) {
    if (!mounted) return;
    final current = state.servedManagedIds;
    if (current != null &&
        current.length == ids.length &&
        current.containsAll(ids)) {
      return;
    }
    state = state.copyWith(servedManagedIds: Set.unmodifiable(ids));
  }

  /// Tells the prefs what this Mac can hold. NOT persisted: the tier is read
  /// off the hardware on every launch (see [AppPrefs.machineTier]). Called
  /// by the managed server's preset build, which precedes every managed
  /// request, and by the generative writer. A no-op when unchanged.
  void setMachineTier(MachineTier tier) {
    if (!mounted || state.machineTier == tier) return;
    state = state.copyWith(machineTier: tier);
  }

  /// The sentence both role writers throw on a third-party address.
  static const String generativeThirdPartyRefusal =
      'the generative model reads every message; a third-party service can '
      'serve cloud drafts only';
  static const String decisionThirdPartyRefusal =
      'the decision model reads every message; it runs on this Mac or a '
      'server of your own';

  /// Points the GENERATIVE role somewhere: this Mac (optionally choosing the
  /// managed model) or the owner's own server (URL, discovered model, key).
  ///
  /// Everything is validated BEFORE anything is written, so a refusal leaves
  /// the install exactly as it was. Throws [ArgumentError] on a URL that is
  /// not an http or https origin, on a third-party host or the Converse wire
  /// ([generativeThirdPartyRefusal]: the generative model reads every
  /// message), and on a managed model that is not one of the two router ids.
  ///
  /// What is STORED is the empty string wherever the value equals what this
  /// build already derives, which is [AppPrefs.boxBigUrl]'s whole meaning. A
  /// null [url] or [model] keeps what is stored; a blank [key] keeps the
  /// stored token, so a Connect with the field empty cannot replace a good
  /// key with nothing — UNLESS [clearKey] says the address moved to another
  /// host, when the old host's token is forgotten ([clearRoleKey]) rather
  /// than sent to a machine it was never meant for.
  ///
  /// Then the placement, the tier, and the draft policy: on this Mac the
  /// 4B's drafts are the tier's policy (on demand on the inbox tier), the 27B
  /// and a remote keep the shipped default.
  Future<void> useGenerative({
    required ModelPlacement placement,
    String? managedModel,
    String? url,
    String? model,
    String? key,
    bool clearKey = false,
    required MachineTier hardwareTier,
  }) async {
    String? storedUrl;
    if (placement == ModelPlacement.box && url != null) {
      final clean = normalizeBoxBaseUrl(url);
      if (!isBoxOrigin(clean)) {
        throw ArgumentError.value(clean, 'url', 'must be an http or https URL');
      }
      if (!AppPrefs._ownServer(clean)) {
        throw ArgumentError.value(clean, 'url', generativeThirdPartyRefusal);
      }
      final compiled = normalizeBoxBaseUrl(boxUrlDefault);
      storedUrl =
          compiled.isNotEmpty && clean == '$compiled/prose/v1/chat/completions'
              ? ''
              : clean;
    }
    if (managedModel != null &&
        managedModel != '' &&
        managedModel != routerProseId &&
        managedModel != routerBulkId) {
      throw ArgumentError.value(
        managedModel,
        'managedModel',
        'must be $routerProseId or $routerBulkId',
      );
    }

    String? storedModel;
    if (placement == ModelPlacement.box && model != null) {
      final trimmed = model.trim();
      storedModel = trimmed == boxProseModel ? '' : trimmed;
    }
    if (placement == ModelPlacement.box) {
      // The keychain FIRST, then the key, the address and the model in ONE
      // state step: a request resolved in between must never pair the old
      // host's token with the new host (or the new token with the old).
      final move = await _keychainFirst(
        boxProseId,
        key,
        clearKey: clearKey,
        flagged: state.boxBigKeyStored,
      );
      _applyKeyCache(boxProseId, move);
      state = state.copyWith(
        boxBigUrl: storedUrl,
        boxBigModel: storedModel,
        boxBigKeyStored: move.flag,
      );
      if (storedUrl != null) await _store.setPref(boxBigUrlKey, storedUrl);
      if (storedModel != null) {
        await _store.setPref(boxBigModelKey, storedModel);
      }
      // A key typed for the generative remote REPLACES whatever the role
      // split still owed under `box-prose`, so nothing is left to move.
      if (move.token case final typed?) await _settleModelRoles(typed);
    }
    if (managedModel != null) {
      state = state.copyWith(generativeManagedModel: managedModel);
      await _store.setPref(generativeManagedModelKey, managedModel);
    }
    setMachineTier(hardwareTier);
    await setModelPlacement(placement);
    if (placement == ModelPlacement.local) {
      final managedId =
          managedGenerativeIdFor(hardwareTier, state.generativeManagedModel);
      await setDraftPolicy(
        managedId == routerBulkId
            ? tierDraftPolicy(hardwareTier)
            : DraftPolicy.needsYou,
      );
    } else {
      // A remote runs whatever writing model its owner chose, and the box the
      // ledger measured is the 27B, so prefetched drafts are worth their cost.
      await setDraftPolicy(DraftPolicy.needsYou);
    }
  }

  /// Points the DECISION role somewhere: this Mac, or the owner's own server
  /// (its full `/v1/embeddings` URL, discovered model, key). The same
  /// validate-then-write shape and refusals as [useGenerative], with
  /// [decisionThirdPartyRefusal]. The heads still run here from the local
  /// heads file whichever server embeds.
  Future<void> useDecision({
    required ModelPlacement placement,
    String? url,
    String? model,
    String? key,
    bool clearKey = false,
  }) async {
    String? storedUrl;
    if (placement == ModelPlacement.box && url != null) {
      final clean = normalizeBoxBaseUrl(url);
      if (!isBoxOrigin(clean)) {
        throw ArgumentError.value(clean, 'url', 'must be an http or https URL');
      }
      if (!AppPrefs._ownServer(clean)) {
        throw ArgumentError.value(clean, 'url', decisionThirdPartyRefusal);
      }
      final compiled = normalizeBoxBaseUrl(boxUrlDefault);
      storedUrl =
          compiled.isNotEmpty && clean == '$compiled/decide/v1/embeddings'
              ? ''
              : clean;
    }
    String? storedModel;
    if (placement == ModelPlacement.box && model != null) {
      final trimmed = model.trim();
      storedModel = trimmed == boxDecideModel ? '' : trimmed;
    }
    if (placement == ModelPlacement.box) {
      // Keychain first, then one state step: [useGenerative]'s rule.
      final move = await _keychainFirst(
        boxDecideId,
        key,
        clearKey: clearKey,
        flagged: state.decisionKeyStored,
      );
      _applyKeyCache(boxDecideId, move);
      state = state.copyWith(
        decisionUrl: storedUrl,
        decisionModel: storedModel,
        decisionKeyStored: move.flag,
      );
      if (storedUrl != null) await _store.setPref(decisionUrlKey, storedUrl);
      if (storedModel != null) {
        await _store.setPref(decisionModelKey, storedModel);
      }
    }
    state = state.copyWith(decisionPlacement: placement);
    await _store.setPref(decisionPlacementKey, placement.name);
  }

  /// Sets the optional cloud-drafts target: the one place a third-party
  /// service may serve, and only the two draft stages.
  ///
  /// Throws [ArgumentError] on a URL that is not an http or https origin, and
  /// on a third-party host or the Converse wire while
  /// [AppPrefs.cloudDraftsConsent] is false: the consent pane records the
  /// acknowledgement FIRST, and this is the last line behind it. The owner's
  /// own server needs no consent. A blank [key] keeps the stored token.
  Future<void> useCloudDrafts({
    required String url,
    required String model,
    String? key,
    bool clearKey = false,
  }) async {
    final clean = normalizeBoxBaseUrl(url);
    if (!isBoxOrigin(clean)) {
      throw ArgumentError.value(clean, 'url', 'must be an http or https URL');
    }
    if (!AppPrefs._ownServer(clean) && !state.cloudDraftsConsent) {
      throw ArgumentError.value(
        clean,
        'url',
        'a third-party service needs cloud drafts consent first',
      );
    }
    final trimmed = model.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(model, 'model', 'must name a model');
    }
    // Keychain first, then one state step: [useGenerative]'s rule.
    final move = await _keychainFirst(
      cloudDraftsId,
      key,
      clearKey: clearKey,
      flagged: state.cloudDraftsKeyStored,
    );
    _applyKeyCache(cloudDraftsId, move);
    state = state.copyWith(
      cloudDraftsUrl: clean,
      cloudDraftsModel: trimmed,
      cloudDraftsKeyStored: move.flag,
    );
    await _store.setPref(cloudDraftsUrlKey, clean);
    await _store.setPref(cloudDraftsModelKey, trimmed);
  }

  /// Forgets the cloud-drafts target: its address, its model and its token.
  /// The draft stages go back to the generative model at once. The consent is
  /// the caller's to withdraw (Stop cloud drafts does both).
  Future<void> clearCloudDrafts() async {
    state = state.copyWith(
      cloudDraftsUrl: '',
      cloudDraftsModel: '',
      cloudDraftsKeyStored: false,
    );
    await _store.setPref(cloudDraftsUrlKey, '');
    await _store.setPref(cloudDraftsModelKey, '');
    _bearers.remove(cloudDraftsId);
    await _writeToken('$llmTargetBearerKeyPrefix$cloudDraftsId', null);
  }

  /// Marks the role split done if it was pending, after the owner typed a
  /// generative key over whatever it still owed. Its token moves are
  /// abandoned: `box-prose` now holds the owner's own key. Silent.
  ///
  /// ONLY once a read-back shows [typed] really is what the keychain holds
  /// under `box-prose`. [_writeToken] swallows a refusal, and a keychain that
  /// refused the migration's delete is exactly the one likely to refuse this
  /// write too: settling then would leave the VENDOR key under `box-prose`
  /// with the flag done, and the next launch would attach it to the owner's
  /// own server. Unsettled, the typed key still works for this session from
  /// the cache, and the next launch retries the moves.
  Future<void> _settleModelRoles(String typed) async {
    final tokens = _tokens;
    if (tokens == null) return;
    try {
      if (!modelRolesPending(await _store.getPref(modelRolesDerivedKey))) {
        return;
      }
      final stored =
          await tokens.read('$llmTargetBearerKeyPrefix$boxProseId');
      if (stored != typed) return;
      await _store.setPref(modelRolesDerivedKey, modelRolesDoneValue);
    } catch (_) {}
  }

  /// The keychain half of a role write, done BEFORE anything a request can
  /// read moves: a typed [key] is written, or, with [clearKey] and a blank
  /// field, the stored one is deleted (only when there is one, on
  /// [clearRoleKey]'s no-op rule). What it returns is applied to the cache
  /// ([_applyKeyCache]) and the flag in the SAME synchronous step as the
  /// address, so no request resolves a new host with an old token.
  ///
  /// [flag] is the presence flag to write: true for a stored token, false
  /// for a cleared one, null for "unchanged".
  Future<({String? token, bool clear, bool? flag})> _keychainFirst(
    String id,
    String? key, {
    required bool clearKey,
    required bool flagged,
  }) async {
    final token = key?.trim() ?? '';
    // Refused before the keychain is touched, and never quoted: a key with a
    // line break or a character outside printable ASCII is not a header any
    // server accepts, and stored it would park every request on it.
    if (token.isNotEmpty && !isUsableAccessKey(token)) {
      throw ArgumentError(accessKeyCharsText);
    }
    if (token.isNotEmpty) {
      await _writeToken('$llmTargetBearerKeyPrefix$id', token);
      return (token: token, clear: false, flag: true);
    }
    if (clearKey && (flagged || _bearers.containsKey(id))) {
      await _writeToken('$llmTargetBearerKeyPrefix$id', null);
      return (token: null, clear: true, flag: false);
    }
    return (token: null, clear: false, flag: null);
  }

  /// The cache half of [_keychainFirst]'s answer. Synchronous, and called
  /// right before the one `state` write it belongs with.
  void _applyKeyCache(
    String id,
    ({String? token, bool clear, bool? flag}) move,
  ) {
    if (move.token case final token?) {
      _bearers[id] = token;
    } else if (move.clear) {
      _bearers.remove(id);
    }
  }

  /// Forgets one role's access key: [boxProseId] (the generative remote),
  /// [boxDecideId] (the decision remote) or [cloudDraftsId]. The keychain
  /// entry, the cache and the presence flag all go.
  ///
  /// A no-op when there is nothing to forget, which is every install that
  /// never typed one. Not an optimisation: a keychain write is a platform
  /// channel round trip, and making the first run take one to delete nothing
  /// is how a wizard step stops advancing within the pumps its test gives
  /// it. Decided from the cache and the flag, not the keychain, and NOT
  /// behind `ready`.
  Future<void> clearRoleKey(String id) async {
    final flagged = switch (id) {
      boxProseId => state.boxBigKeyStored,
      boxDecideId => state.decisionKeyStored,
      cloudDraftsId => state.cloudDraftsKeyStored,
      _ => throw ArgumentError.value(id, 'id', 'not a role key'),
    };
    if (!flagged && !_bearers.containsKey(id)) return;
    _bearers.remove(id);
    await _writeToken('$llmTargetBearerKeyPrefix$id', null);
    state = switch (id) {
      boxProseId => state.copyWith(boxBigKeyStored: false),
      boxDecideId => state.copyWith(decisionKeyStored: false),
      _ => state.copyWith(cloudDraftsKeyStored: false),
    };
  }

  /// Remembers whether model work runs. State first and the write after it,
  /// like every setter here.
  Future<void> setProcessingOn(bool value) async {
    state = state.copyWith(processingOn: value);
    await _store.setPref(processingOnKey, value.toString());
  }

  /// Records that the owner has read what a third-party draft target
  /// receives. Until it is true, [AppPrefs.specForStage] sends both drafting
  /// stages to the generative model instead of a third-party cloud target.
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

  /// Points the downloader and the router at a folder. Empty means the app's
  /// own — see [AppPrefs.effectiveModelsFolder]. Trimmed on the way in as well
  /// as on the way out, for [_slotValue]'s reason: a path with a trailing
  /// newline is a directory that does not exist.
  Future<void> setModelsFolder(String value) async {
    final clean = value.trim();
    state = state.copyWith(modelsFolder: clean);
    await _store.setPref(modelsFolderKey, clean);
  }
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
