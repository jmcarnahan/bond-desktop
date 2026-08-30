import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../services/attention.dart';
import 'app_providers.dart';

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

/// The settings the LO controls, held in memory so the widgets that read them
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

  /// What the LO says about themselves and their role. Written here, read by
  /// the next phase's prompts.
  final String aboutMe;

  /// [backendModeMcp] or [backendModeSdk]. Nothing above here parses it: the
  /// providers compare it against those two constants.
  final String backendMode;

  /// The `/mcp` endpoint MCP mode talks to. Read only in MCP mode, but stored
  /// either way so switching back does not lose a hand-typed server.
  final String mcpServerUrl;

  const AppPrefs({
    this.attentionThreshold = AttentionTuning.defaultThreshold,
    this.aboutMe = '',
    this.backendMode = backendModeMcp,
    this.mcpServerUrl = defaultMcpServerUrl,
  });

  AppPrefs copyWith({
    double? attentionThreshold,
    String? aboutMe,
    String? backendMode,
    String? mcpServerUrl,
  }) =>
      AppPrefs(
        attentionThreshold: attentionThreshold ?? this.attentionThreshold,
        aboutMe: aboutMe ?? this.aboutMe,
        backendMode: backendMode ?? this.backendMode,
        mcpServerUrl: mcpServerUrl ?? this.mcpServerUrl,
      );
}

/// Keys in `app_prefs`. Constants because they are typed in two places — the
/// read below and the tests that assert what landed in the table.
const String attentionThresholdKey = 'attention_threshold';
const String aboutMeKey = 'about_me';
const String backendModeKey = 'backend_mode';
const String mcpServerUrlKey = 'mcp_server_url';

class AppPrefsNotifier extends StateNotifier<AppPrefs> {
  final MessageStore _store;

  AppPrefsNotifier(this._store) : super(_read(_store));

  /// Reads every setting once, at construction. A stored value that does not
  /// parse — hand-edited, or written by a build that meant something else by
  /// the key — falls back to the default rather than throwing: a bad
  /// preference must not be able to stop the app from starting.
  static AppPrefs _read(MessageStore store) {
    final raw = store.getPref(attentionThresholdKey);
    return AppPrefs(
      attentionThreshold: (raw == null ? null : double.tryParse(raw)) ??
          AttentionTuning.defaultThreshold,
      aboutMe: store.getPref(aboutMeKey) ?? '',
      backendMode: _mode(store.getPref(backendModeKey)),
      mcpServerUrl: _serverUrl(store.getPref(mcpServerUrlKey)),
    );
  }

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
  void setAttentionThreshold(double value) {
    final clamped = value.clamp(0.0, 1.0);
    _store.setPref(attentionThresholdKey, clamped.toString());
    state = state.copyWith(attentionThreshold: clamped);
  }

  void setAboutMe(String value) {
    _store.setPref(aboutMeKey, value);
    state = state.copyWith(aboutMe: value);
  }

  /// Switches which backend the app talks through.
  ///
  /// The state change is the whole mechanism: the session and both backend
  /// providers watch this field, so setting it rebuilds every one of them and
  /// whatever was built on top.
  void setBackendMode(String value) {
    final mode = _mode(value);
    _store.setPref(backendModeKey, mode);
    state = state.copyWith(backendMode: mode);
  }

  void setMcpServerUrl(String value) {
    final url = _serverUrl(value);
    _store.setPref(mcpServerUrlKey, url);
    state = state.copyWith(mcpServerUrl: url);
  }
}

final appPrefsProvider = StateNotifierProvider<AppPrefsNotifier, AppPrefs>(
  (ref) => AppPrefsNotifier(ref.watch(messageStoreProvider)),
);
