import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_paths.dart' show AppPaths;
import '../data/message_store.dart';
import '../models/home_sort.dart';
import '../models/needs_you_sort.dart';
import '../models/people_sort.dart';
import '../services/attention.dart';
import '../services/llm/embeddings_client.dart' show EmbeddingsClient;
import '../services/llm/model_slots.dart';
import '../services/sync_service.dart';
import 'app_providers.dart';

export '../data/message_store.dart' show aboutMeKey, needsYouRulesKey;

/// The setter below takes a [NeedsYouSort], so whoever reads this file for the
/// preference has the vocabulary to change it in the same import.
export '../models/needs_you_sort.dart' show NeedsYouSort, NeedsYouSortLabel;

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
/// import — the prefs are where both are composed.
export '../services/llm/model_slots.dart' show LlmTarget, ModelSlot;

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
  /// Both default to [syncFloorDays] — Teams' own floor is the same seven days,
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
  /// Like [routerPort] and [modelsFolder] it survives a `wipeAll` — that
  /// deletes only the keys it names, and none of these three is mailbox data:
  /// which server this machine runs is a fact about the machine, not about
  /// whoever is signed in.
  final bool managedServer;

  /// The port the managed router listens on.
  ///
  /// Stored rather than picked fresh each launch so an adopted server from the
  /// previous run is findable, and so a user who moved off a port another
  /// program wanted keeps that choice. Clamped to 1024..65535 on both the read
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

  /// What [routerPort] means when nothing is stored — llama-server's own
  /// default port, which is also what `make model` uses, so a user who never
  /// touches the field gets the port every doc in this repo names.
  static const int defaultRouterPort = 8080;

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
    this.managedServer = false,
    this.routerPort = defaultRouterPort,
    this.modelsFolder = '',
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

/// The managed server's three keys. Not in `wipeAll`'s list, deliberately:
/// see [AppPrefs.managedServer].
const String managedServerKey = 'managed_server';
const String routerPortKey = 'router_port';
const String modelsFolderKey = 'models_folder';

/// The switch [notifyStyleKey] replaced. Still read — and only read — so an
/// install that had turned the ribbon off stays quiet across the upgrade
/// instead of being handed OS notifications it never asked for.
const String notifyRibbonKey = 'notify_ribbon';

class AppPrefsNotifier extends StateNotifier<AppPrefs> {
  final MessageStore _store;

  /// Completes when the stored settings have replaced the defaults this
  /// notifier starts on. Already complete when [initial] was supplied.
  late final Future<void> ready;

  /// [initial] is what `main()` read before the first frame, and passing it is
  /// what keeps the app from starting on the defaults: every backend provider
  /// watches [backendMode], so a frame of "MCP" under a stored SDK setting
  /// would build — and immediately dispose — the wrong session.
  ///
  /// Without it the settings arrive one microtask later and [ready] is how a
  /// caller waits for them.
  AppPrefsNotifier(this._store, {AppPrefs? initial})
      : super(initial ?? const AppPrefs()) {
    ready = initial != null ? Future.value() : _load();
  }

  Future<void> _load() async {
    final prefs = await read(_store);
    if (!mounted) return;
    state = prefs;
  }

  /// Reads every setting once. A stored value that does not parse —
  /// hand-edited, or written by a build that meant something else by the key —
  /// falls back to the default rather than throwing: a bad preference must not
  /// be able to stop the app from starting.
  static Future<AppPrefs> read(MessageStore store) async {
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
      needsYouSort: _needsYouSort(await store.getPref(needsYouSortKey)),
      peopleSort: _peopleSort(await store.getPref(peopleSortKey)),
      roomSort: _roomSort(await store.getPref(roomSortKey)),
      // The one setting here that DEFAULTS ON, so its read is the inverse of
      // the two above — see [_style].
      notifyStyle: _style(
        await store.getPref(notifyStyleKey),
        await store.getPref(notifyRibbonKey),
      ),
      homeSort: _homeSort(await store.getPref(homeSortKey)),
      fastLlmUrl: _slotValue(await store.getPref(fastLlmUrlKey)),
      fastLlmModel: _slotValue(await store.getPref(fastLlmModelKey)),
      proseLlmUrl: _slotValue(await store.getPref(proseLlmUrlKey)),
      proseLlmModel: _slotValue(await store.getPref(proseLlmModelKey)),
      mailLookbackDays: _lookback(await store.getPref(mailLookbackDaysKey)),
      teamsLookbackDays: _lookback(await store.getPref(teamsLookbackDaysKey)),
      // Only the string this notifier writes reads as on — an absent key, a
      // hand-edited value, a build that meant something else — all of them
      // leave the app expecting hand-started servers, which is the state every
      // existing install is in.
      managedServer: await store.getPref(managedServerKey) == 'true',
      routerPort: _routerPort(await store.getPref(routerPortKey)),
      modelsFolder: _slotValue(await store.getPref(modelsFolderKey)),
    );
  }

  /// A stored port, or the default. Unparseable is the default and
  /// out-of-range is clamped into it, on [_lookback]'s rule and for the same
  /// reason: a bad number here would make every start fail on a socket, and a
  /// preference must not be able to do that.

  static int _routerPort(String? raw) =>
      clampRouterPort(int.tryParse(raw ?? '') ?? AppPrefs.defaultRouterPort);

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

  /// The stored order, or the ranking. Only the one spelling this notifier
  /// writes reads as the clock — an absent key, a hand-edited value, or a name
  /// a later build stopped using all leave the reader on the priority order
  /// the app decides, which is the state every install starts in.
  static NeedsYouSort _needsYouSort(String? raw) =>
      raw == NeedsYouSort.newest.name
          ? NeedsYouSort.newest
          : NeedsYouSort.priority;

  /// The stored People order, or recency. Anything this notifier did not write
  /// — an absent key, a hand-edited value, a name a later build stopped using
  /// — leaves the reader on the order every install starts in, rather than
  /// throwing on the first frame of the People stop.
  static PeopleSort _peopleSort(String? raw) {
    for (final option in PeopleSort.values) {
      if (option.name == raw) return option;
    }
    return PeopleSort.recent;
  }

  /// The stored room order, or newest first. [_peopleSort]'s rule exactly.
  static RoomSort _roomSort(String? raw) =>
      raw == RoomSort.oldest.name ? RoomSort.oldest : RoomSort.newest;

  /// The stored Inbox order, or newest first. [_roomSort]'s rule exactly: only
  /// the one spelling this notifier writes reads as oldest, so an absent key
  /// or a hand-edited value leaves the reader on the order every install
  /// starts in rather than throwing on the Inbox's first frame.
  static HomeSort _homeSort(String? raw) =>
      raw == HomeSort.oldest.name ? HomeSort.oldest : HomeSort.newest;

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
  /// the enum's own name, which is what [_needsYouSort] parses back.
  Future<void> setNeedsYouSort(NeedsYouSort value) async {
    state = state.copyWith(needsYouSort: value);
    await _store.setPref(needsYouSortKey, value.name);
  }

  /// Orders the People directory. Written as the enum's own name, which is
  /// what [_peopleSort] parses back.
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
  /// [_homeSort] parses back.
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

  /// Whether the app runs the model server itself.
  ///
  /// The state change is the whole mechanism for the TARGETS — every one of
  /// them is composed above from this flag — but starting or stopping the
  /// process is the caller's job, not this notifier's: prefs know nothing
  /// about a supervisor, and the screen that flips this switch is the one
  /// place that can also say "and start it".
  ///
  /// State first, then the write, like every setter above.
  Future<void> setManagedServer(bool value) async {
    state = state.copyWith(managedServer: value);
    await _store.setPref(managedServerKey, value.toString());
  }

  /// Moves the managed router's port. Clamped on the way in as well as on the
  /// way out — [_routerPort] guards the read, and this guards a caller that
  /// hands over a number no control on screen could have produced.
  Future<void> setRouterPort(int value) async {
    final clamped = clampRouterPort(value);
    state = state.copyWith(routerPort: clamped);
    await _store.setPref(routerPortKey, clamped.toString());
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

/// What `main()` read from the database before the first frame, or null where
/// nothing preloaded them — see [AppPrefsNotifier]'s constructor.
final initialAppPrefsProvider = Provider<AppPrefs?>((ref) => null);

final appPrefsProvider = StateNotifierProvider<AppPrefsNotifier, AppPrefs>(
  (ref) => AppPrefsNotifier(
    ref.watch(messageStoreProvider),
    initial: ref.watch(initialAppPrefsProvider),
  ),
);
