import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../services/attention.dart';
import 'app_providers.dart';

export '../data/message_store.dart' show aboutMeKey, needsYouRulesKey;

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

  /// How a settled message announces itself. [NotifyStyle.native] by default,
  /// unlike every other switch here: the app spends minutes deciding a message
  /// needs the user, and finishing that in silence unless someone goes looking
  /// for a setting would waste the whole point of it.
  final NotifyStyle notifyStyle;

  /// Whether the home feed lists the messages the app decided the user does
  /// not need. Off by default — that decision is the product — and the toggle
  /// is what makes it auditable rather than hidden.
  final bool homeShowDropped;

  const AppPrefs({
    this.attentionThreshold = AttentionTuning.defaultThreshold,
    this.aboutMe = '',
    this.needsYouRules = '',
    this.backendMode = backendModeMcp,
    this.mcpServerUrl = defaultMcpServerUrl,
    this.showActivityLog = false,
    this.storylineNewestFirst = false,
    this.notifyStyle = NotifyStyle.native,
    this.homeShowDropped = false,
  });

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
    NotifyStyle? notifyStyle,
    bool? homeShowDropped,
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
        notifyStyle: notifyStyle ?? this.notifyStyle,
        homeShowDropped: homeShowDropped ?? this.homeShowDropped,
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
const String notifyStyleKey = 'notify_style';
const String homeShowDroppedKey = 'home_show_dropped';

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
      // The one setting here that DEFAULTS ON, so its read is the inverse of
      // the two above — see [_style].
      notifyStyle: _style(
        await store.getPref(notifyStyleKey),
        await store.getPref(notifyRibbonKey),
      ),
      homeShowDropped: await store.getPref(homeShowDroppedKey) == 'true',
    );
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

  Future<void> setStorylineNewestFirst(bool value) async {
    state = state.copyWith(storylineNewestFirst: value);
    await _store.setPref(storylineNewestFirstKey, value.toString());
  }

  Future<void> setNotifyStyle(NotifyStyle value) async {
    state = state.copyWith(notifyStyle: value);
    await _store.setPref(notifyStyleKey, _styleName(value));
  }

  Future<void> setHomeShowDropped(bool value) async {
    state = state.copyWith(homeShowDropped: value);
    await _store.setPref(homeShowDroppedKey, value.toString());
  }
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
