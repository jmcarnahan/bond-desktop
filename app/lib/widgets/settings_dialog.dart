import 'dart:async';

import 'package:flutter/material.dart';

import '../providers/prefs_provider.dart'
    show
        backendModeMcp,
        backendModeSdk,
        defaultMcpServerUrl,
        mcpDeployedUrl,
        mcpLocalUrl;
import '../theme/tokens.dart';

/// What the LO gets to say about how the inbox behaves, plus what Microsoft
/// has actually let this app do.
///
/// A dialog rather than a settings screen because there is very little in it,
/// and a screen with three things on it reads as a promise of more. It stays a
/// plain [StatefulWidget] over callbacks rather than reaching for the providers
/// itself, so the screen owns the wiring and a test can drive it with nothing
/// but closures.
class SettingsDialog extends StatefulWidget {
  /// Where the Needs You cut sits now, 0..1.
  final double threshold;

  final String aboutMe;

  /// Fired when the user lets go of the slider, not on every pixel of the
  /// drag: each call writes a preference and reloads the list, and doing that
  /// sixty times a second would make the slider feel like it was fighting back.
  final void Function(double value) onThresholdChanged;

  /// Fired once, when the dialog closes. Text is not a thing to save per
  /// keystroke, and there is nothing on screen waiting to read it.
  final void Function(String value) onAboutMeChanged;

  /// Answers "did Microsoft grant this bare scope". Null hides the whole
  /// permissions section, which is what a host with no auth wired wants — and
  /// what MCP mode passes, where [connectionStatus] answers instead.
  final Future<bool> Function(String bareScope)? hasScope;

  /// Starts a fresh sign-in, which is the only way a missing consent is ever
  /// fixed — a refresh cannot add a scope nobody consented to.
  final VoidCallback? onSignInAgain;

  /// Which backend the app is talking through: [backendModeMcp] or
  /// [backendModeSdk].
  final String backendMode;

  /// The `/mcp` endpoint MCP mode talks to.
  final String mcpServerUrl;

  /// The deployed platform's URL, when this build knows one. Empty hides the
  /// Deployed preset — a build with no `BOND_MCP_SERVER_URL` define has no
  /// deployed endpoint to offer. A parameter rather than a direct read of the
  /// compiled constant so tests can exercise the preset without a dart-define.
  final String deployedUrl;

  /// Fired when the user picks the other backend. Null hides the whole
  /// Microsoft-connection section, which is what a host with no switch wired
  /// wants — the same discipline [hasScope] follows.
  ///
  /// The host is expected to CLOSE the dialog on this: switching backends
  /// replaces the session, and every answer already on screen was given by the
  /// one being left behind.
  final void Function(String mode)? onBackendModeChanged;

  final void Function(String url)? onMcpServerUrlChanged;

  /// The platform's own account status, asked once when the dialog opens. Null
  /// in SDK mode, where [hasScope] is the answer instead.
  final Future<Map<String, Object?>?> Function()? connectionStatus;

  /// Sends the user off to connect a Microsoft account to their workspace.
  final VoidCallback? onConnectMicrosoft;

  const SettingsDialog({
    super.key,
    required this.threshold,
    required this.aboutMe,
    required this.onThresholdChanged,
    required this.onAboutMeChanged,
    this.hasScope,
    this.onSignInAgain,
    this.backendMode = backendModeMcp,
    this.mcpServerUrl = defaultMcpServerUrl,
    this.deployedUrl = mcpDeployedUrl,
    this.onBackendModeChanged,
    this.onMcpServerUrlChanged,
    this.connectionStatus,
    this.onConnectMicrosoft,
  });

  /// The three extended permissions, in the order they matter to the LO:
  /// label, the bare scope each one is really asking about, and whether a
  /// fresh sign-in can actually obtain it. Teams cannot — the tenant
  /// admin-gates `Chat.Read`, so the sign-in no longer requests it (see
  /// GraphAuth.pendingAdminScopes) and offering "sign in again" for it would
  /// send the user through a round that cannot deliver.
  static const List<(String, String, bool)> permissions = [
    ('Send mail', 'mail.send', true),
    ('Save drafts', 'mail.readwrite', true),
    ('Teams chats — awaiting admin approval', 'chat.read', false),
  ];

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late double _threshold = widget.threshold.clamp(0.0, 1.0);
  late final TextEditingController _aboutMe =
      TextEditingController(text: widget.aboutMe);

  /// Ten stops. Enough that the slider feels like it has an opinion, few enough
  /// that the same drag lands on the same value twice.
  static const int _divisions = 10;

  /// Asked once, at construction, rather than on every build: a [FutureBuilder]
  /// handed a future built inside `build` re-runs the whole keychain read on
  /// every rebuild, including the ones the slider causes as it is dragged.
  late final Future<List<bool>>? _granted = widget.hasScope == null
      ? null
      : Future.wait([
          for (final (_, scope, _) in SettingsDialog.permissions)
            widget.hasScope!(scope),
        ]);

  /// MCP mode's answer to the same question, and asked once for the same
  /// reason: it is a round trip to the platform, not a local read.
  late final Future<Map<String, Object?>?>? _connection =
      widget.connectionStatus?.call();

  /// Which of the three server choices is showing. Held rather than derived on
  /// every build so that picking "Custom…" keeps the field open while the text
  /// still matches a preset.
  late String _serverPreset = _presetFor(widget.mcpServerUrl);

  late final TextEditingController _serverUrl =
      TextEditingController(text: widget.mcpServerUrl);

  /// The last server actually handed to the host. Pressing Enter both submits
  /// and drops focus, so without this one keystroke would commit twice — and a
  /// commit is a whole session being rebuilt, not a preference being written.
  late String _committedUrl = widget.mcpServerUrl;

  static const String _presetCustom = 'custom';

  String _presetFor(String url) {
    if (url == mcpLocalUrl) return mcpLocalUrl;
    if (widget.deployedUrl.isNotEmpty && url == widget.deployedUrl) {
      return widget.deployedUrl;
    }
    return _presetCustom;
  }

  @override
  void dispose() {
    // On the way out, whichever way the dialog was dismissed — the Done button,
    // the scrim, or Escape. A save wired to the button alone would quietly lose
    // the text of anyone who clicks outside, which is most people.
    //
    // Deferred out of the frame, not called inline: the backend toggle mutates
    // the prefs, which rebuilds the provider graph, which can unmount THIS
    // dialog in the middle of that same build — and a dispose that writes to
    // the notifier inside a locked tree is an exception on every unmount. A
    // microtask rather than a Future so no timer outlives the tree; the text
    // is captured now, before the controller dies under the callback.
    final aboutMe = _aboutMe.text;
    scheduleMicrotask(() => widget.onAboutMeChanged(aboutMe));
    _aboutMe.dispose();
    _serverUrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'How much lands in Needs You',
              style: BondType.body.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: BondSpacing.s4),
            // The direction is the thing worth stating: the slider raises a
            // score threshold, so RIGHT means more mail, and a label-less
            // slider would leave that a coin flip.
            Slider(
              value: 1 - _threshold,
              divisions: _divisions,
              onChanged: (value) => setState(() => _threshold = 1 - value),
              onChangeEnd: (value) => widget.onThresholdChanged(1 - value),
            ),
            // Both halves flex: the labels are long enough relative to the
            // dialog that a fixed Row overflows at the default text scale.
            Row(
              children: [
                Expanded(
                  child: Text('Only the critical', style: BondType.caption),
                ),
                Expanded(
                  child: Text(
                    'Anything plausible',
                    style: BondType.caption,
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
            const SizedBox(height: BondSpacing.s24),
            Text(
              'About me & my role',
              style: BondType.body.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: BondSpacing.s4),
            TextField(
              controller: _aboutMe,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: 'e.g. I am a loan officer; I own rate locks and '
                    'closing dates, my processor handles document chasing.',
              ),
            ),
            ..._connectionSection(),
            ..._permissionsSection(),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }

  /// Which backend the app talks through, and where.
  ///
  /// It sits above the permissions because it decides what those permissions
  /// even mean: in MCP mode they are the workspace's Microsoft grant, and in
  /// SDK mode they are this machine's.
  List<Widget> _connectionSection() {
    final onModeChanged = widget.onBackendModeChanged;
    if (onModeChanged == null) return const [];
    return [
      const SizedBox(height: BondSpacing.s24),
      Text(
        'Microsoft connection',
        style: BondType.body.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: BondSpacing.s8),
      Align(
        alignment: Alignment.centerLeft,
        child: SegmentedButton<String>(
          // No tick on the selected segment: the segment is already filled,
          // and the icon reads as a granted permission next to the rows below.
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: backendModeMcp, label: Text('Bond server')),
            ButtonSegment(value: backendModeSdk, label: Text('This Mac')),
          ],
          selected: {widget.backendMode},
          onSelectionChanged: (selection) => onModeChanged(selection.first),
        ),
      ),
      if (widget.backendMode == backendModeMcp) ..._serverPicker(),
    ];
  }

  /// Which Bond server to talk to: the two that are worth a preset, and a field
  /// for anything else.
  List<Widget> _serverPicker() {
    return [
      const SizedBox(height: BondSpacing.s12),
      DropdownButtonFormField<String>(
        initialValue: _serverPreset,
        decoration: const InputDecoration(labelText: 'Bond server'),
        items: [
          if (widget.deployedUrl.isNotEmpty)
            DropdownMenuItem(
              value: widget.deployedUrl,
              child: const Text('Deployed'),
            ),
          const DropdownMenuItem(value: mcpLocalUrl, child: Text('Local')),
          const DropdownMenuItem(value: _presetCustom, child: Text('Custom…')),
        ],
        onChanged: (value) {
          if (value == null) return;
          setState(() => _serverPreset = value);
          if (value == _presetCustom) return;
          _serverUrl.text = value;
          _commitServerUrl(value);
        },
      ),
      if (_serverPreset == _presetCustom) ...[
        const SizedBox(height: BondSpacing.s8),
        // Committed on Enter or on the way out of the field, never per
        // keystroke: every commit rebuilds the whole session, and doing that
        // halfway through a typed URL would open a connection per character.
        Focus(
          onFocusChange: (hasFocus) {
            if (!hasFocus) _commitServerUrl(_serverUrl.text);
          },
          child: TextField(
            controller: _serverUrl,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'https://…/mcp',
            ),
            onSubmitted: _commitServerUrl,
          ),
        ),
      ],
    ];
  }

  void _commitServerUrl(String value) {
    if (value == _committedUrl) return;
    _committedUrl = value;
    widget.onMcpServerUrlChanged?.call(value);
  }

  /// What the WORKSPACE'S Microsoft account can do, as the platform reports it.
  ///
  /// A status that could not be read is shown as not connected: this section
  /// reports, and "we could not ask" is closer to nothing-connected than to a
  /// row of ticks nobody verified. The offer beside it is harmless if the
  /// connection was fine.
  List<Widget> _platformPermissions() {
    return [
      const SizedBox(height: BondSpacing.s24),
      Text(
        'Microsoft permissions',
        style: BondType.body.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: BondSpacing.s4),
      FutureBuilder<Map<String, Object?>?>(
        future: _connection,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return Align(
              alignment: Alignment.centerLeft,
              child: Text('Checking…', style: BondType.small),
            );
          }
          final status = snapshot.data;
          if (status == null || status['connected'] != true) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'No Microsoft account is connected to this workspace.',
                  style: BondType.small,
                ),
                if (widget.onConnectMicrosoft != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: widget.onConnectMicrosoft,
                      child: const Text('Connect Microsoft'),
                    ),
                  ),
              ],
            );
          }
          final granted = _grantedScopes(status['scopes']);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (label, scope, _) in SettingsDialog.permissions)
                _permissionRow(label, _holds(granted, scope)),
            ],
          );
        },
      ),
    ];
  }

  static Set<String> _grantedScopes(Object? raw) => {
        for (final scope in raw is List ? raw : const [])
          if (scope is String && scope.isNotEmpty) scope.toLowerCase(),
      };

  /// Whether the connected account holds [scope].
  ///
  /// A connected account with no scopes recorded is a row that predates the
  /// platform storing them; those grants were all mail-only, which is the same
  /// answer `McpAuthSession.hasScope` gives.
  static bool _holds(Set<String> granted, String scope) =>
      granted.isEmpty ? scope.startsWith('mail.') : granted.contains(scope);

  /// What Microsoft actually granted, and the one thing that can change it.
  ///
  /// It reports rather than persuades: a tick or a cross per permission, and
  /// the sign-in offer only when something is missing. A tenant that will not
  /// grant these is a tenant nobody in this dialog can argue with, so nagging
  /// about it every time the dialog opens would be noise.
  List<Widget> _permissionsSection() {
    if (_connection != null) return _platformPermissions();
    final granted = _granted;
    if (granted == null) return const [];
    return [
      const SizedBox(height: BondSpacing.s24),
      Text(
        'Microsoft permissions',
        style: BondType.body.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: BondSpacing.s4),
      FutureBuilder<List<bool>>(
        future: granted,
        builder: (context, snapshot) {
          // Absent an answer, every row reads as not granted — the same thing
          // the composer assumes while it is waiting, so the two never
          // disagree on screen.
          final answers = snapshot.data ??
              List.filled(SettingsDialog.permissions.length, false);
          // Only a scope a fresh sign-in can deliver counts as fixable —
          // an admin-gated row must not turn the offer into a permanent nag.
          var missing = false;
          for (var i = 0; i < SettingsDialog.permissions.length; i++) {
            missing = missing ||
                (SettingsDialog.permissions[i].$3 && !answers[i]);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < SettingsDialog.permissions.length; i++)
                _permissionRow(SettingsDialog.permissions[i].$1, answers[i]),
              if (missing && widget.onSignInAgain != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: widget.onSignInAgain,
                    child: const Text('Sign in again to enable'),
                  ),
                ),
            ],
          );
        },
      ),
    ];
  }

  Widget _permissionRow(String label, bool granted) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            granted ? Icons.check : Icons.close,
            size: 16,
            color: granted ? BondColors.success : BondColors.inkMuted,
          ),
          const SizedBox(width: BondSpacing.s8),
          Expanded(child: Text(label, style: BondType.small)),
        ],
      ),
    );
  }
}
