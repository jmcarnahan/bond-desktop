import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../models/needs_you_sort.dart';
import '../services/attention.dart';
import '../services/llm/model_slots.dart';
import '../services/sync_service.dart';
import 'app_providers.dart';

export '../data/message_store.dart' show aboutMeKey, needsYouRulesKey;

/// The setter below takes a [NeedsYouSort], so whoever reads this file for the
/// preference has the vocabulary to change it in the same import.
export '../models/needs_you_sort.dart' show NeedsYouSort, NeedsYouSortLabel;

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

  /// How a settled message announces itself. [NotifyStyle.native] by default,
  /// unlike every other switch here: the app spends minutes deciding a message
  /// needs the user, and finishing that in silence unless someone goes looking
  /// for a setting would waste the whole point of it.
  final NotifyStyle notifyStyle;

  /// Whether the home feed lists the messages the app decided the user does
  /// not need. Off by default — that decision is the product — and the toggle
  /// is what makes it auditable rather than hidden.
  final bool homeShowDropped;

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
  /// Both default to [syncFloorDays] — Teams' own floor is the same fourteen
  /// days, and its constant is class-static on `TeamsSync`, so naming it here
  /// would drag in that import to say a number this file already has.
  final int mailLookbackDays;
  final int teamsLookbackDays;

  const AppPrefs({
    this.attentionThreshold = AttentionTuning.defaultThreshold,
    this.aboutMe = '',
    this.needsYouRules = '',
    this.backendMode = backendModeMcp,
    this.mcpServerUrl = defaultMcpServerUrl,
    this.showActivityLog = false,
    this.storylineNewestFirst = false,
    this.needsYouSort = NeedsYouSort.priority,
    this.notifyStyle = NotifyStyle.native,
    this.homeShowDropped = false,
    this.fastLlmUrl = '',
    this.fastLlmModel = '',
    this.proseLlmUrl = '',
    this.proseLlmModel = '',
    this.mailLookbackDays = syncFloorDays,
    this.teamsLookbackDays = syncFloorDays,
  });

  /// What the bulk client will dial on its next request.
  LlmTarget get fastTarget => LlmTarget(
        baseUrl: fastLlmUrl.isEmpty ? fastUrlDefault : fastLlmUrl,
        model: fastLlmModel.isEmpty ? fastModelDefault : fastLlmModel,
      );

  LlmTarget get proseTarget => LlmTarget(
        baseUrl: proseLlmUrl.isEmpty ? proseUrlDefault : proseLlmUrl,
        model: proseLlmModel.isEmpty ? proseModelDefault : proseLlmModel,
      );

  /// One slot's target, for the settings screen's table. [ModelSlot.embed] is
  /// display only — it always answers the compiled default.
  LlmTarget targetFor(ModelSlot slot) => switch (slot) {
        ModelSlot.fast => fastTarget,
        ModelSlot.prose => proseTarget,
        ModelSlot.embed => embedSlotDefault,
      };

  /// Whether this slot is on the build's own default — what the screen renders
  /// as "Default" rather than as an override.
  bool isSlotDefault(ModelSlot slot) => switch (slot) {
        ModelSlot.fast => fastLlmUrl.isEmpty && fastLlmModel.isEmpty,
        ModelSlot.prose => proseLlmUrl.isEmpty && proseLlmModel.isEmpty,
        ModelSlot.embed => true,
      };

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
    bool? storylineNewestFirst,
    NeedsYouSort? needsYouSort,
    NotifyStyle? notifyStyle,
    bool? homeShowDropped,
    String? fastLlmUrl,
    String? fastLlmModel,
    String? proseLlmUrl,
    String? proseLlmModel,
    int? mailLookbackDays,
    int? teamsLookbackDays,
  }) =>
      AppPrefs(
        attentionThreshold: attentionThreshold ?? this.attentionThreshold,
        aboutMe: aboutMe ?? this.aboutMe,
        needsYouRules: needsYouRules ?? this.needsYouRules,
        backendMode: backendMode ?? this.backendMode,
        mcpServerUrl: mcpServerUrl ?? this.mcpServerUrl,
        showActivityLog: showActivityLog ?? this.showActivityLog,
        storylineNewestFirst:
            storylineNewestFirst ?? this.storylineNewestFirst,
        needsYouSort: needsYouSort ?? this.needsYouSort,
        notifyStyle: notifyStyle ?? this.notifyStyle,
        homeShowDropped: homeShowDropped ?? this.homeShowDropped,
        fastLlmUrl: fastLlmUrl ?? this.fastLlmUrl,
        fastLlmModel: fastLlmModel ?? this.fastLlmModel,
        proseLlmUrl: proseLlmUrl ?? this.proseLlmUrl,
        proseLlmModel: proseLlmModel ?? this.proseLlmModel,
        mailLookbackDays: mailLookbackDays ?? this.mailLookbackDays,
        teamsLookbackDays: teamsLookbackDays ?? this.teamsLookbackDays,
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
const String storylineNewestFirstKey = 'storyline_newest_first';
const String needsYouSortKey = 'needs_you_sort';
const String notifyStyleKey = 'notify_style';
const String homeShowDroppedKey = 'home_show_dropped';
const String fastLlmUrlKey = 'fast_llm_url';
const String fastLlmModelKey = 'fast_llm_model';
const String proseLlmUrlKey = 'prose_llm_url';
const String proseLlmModelKey = 'prose_llm_model';
const String mailLookbackDaysKey = 'mail_lookback_days';
const String teamsLookbackDaysKey = 'teams_lookback_days';

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
      storylineNewestFirst:
          await store.getPref(storylineNewestFirstKey) == 'true',
      needsYouSort: _needsYouSort(await store.getPref(needsYouSortKey)),
      // The one setting here that DEFAULTS ON, so its read is the inverse of
      // the two above — see [_style].
      notifyStyle: _style(
        await store.getPref(notifyStyleKey),
        await store.getPref(notifyRibbonKey),
      ),
      homeShowDropped: await store.getPref(homeShowDroppedKey) == 'true',
      fastLlmUrl: _slotValue(await store.getPref(fastLlmUrlKey)),
      fastLlmModel: _slotValue(await store.getPref(fastLlmModelKey)),
      proseLlmUrl: _slotValue(await store.getPref(proseLlmUrlKey)),
      proseLlmModel: _slotValue(await store.getPref(proseLlmModelKey)),
      mailLookbackDays: _lookback(await store.getPref(mailLookbackDaysKey)),
      teamsLookbackDays: _lookback(await store.getPref(teamsLookbackDaysKey)),
    );
  }

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

  Future<void> setNotifyStyle(NotifyStyle value) async {
    state = state.copyWith(notifyStyle: value);
    await _store.setPref(notifyStyleKey, _styleName(value));
  }

  Future<void> setHomeShowDropped(bool value) async {
    state = state.copyWith(homeShowDropped: value);
    await _store.setPref(homeShowDroppedKey, value.toString());
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

  /// Back to the build's defaults for one slot.
  Future<void> clearSlotTarget(ModelSlot slot) => switch (slot) {
        ModelSlot.fast => setFastLlmTarget(url: '', model: ''),
        ModelSlot.prose => setProseLlmTarget(url: '', model: ''),
        ModelSlot.embed => Future<void>.value(),
      };
}

/// What `main()` read from the database before the first frame, or null where
/// nothing preloaded them — see [AppPrefsNotifier]'s constructor.
final initialAppPrefsProvider = Provider<AppPrefs?>((ref) => null);

final appPrefsProvider = StateNotifierProvider<AppPrefsNotifier, AppPrefs>(
  (ref) => AppPrefsNotifier(
    ref.watch(messageStoreProvider),
    initial: ref.watch(initialAppPrefsProvider),
  ),
);
