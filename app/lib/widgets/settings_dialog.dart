import 'dart:async';

import 'package:flutter/material.dart';

import '../providers/prefs_provider.dart'
    show
        backendModeMcp,
        backendModeSdk,
        defaultMcpServerUrl,
        mcpDeployedUrl,
        mcpLocalUrl;
import '../services/backend/backend_types.dart' show AuthException;
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
  /// The dialog stays OPEN across this: the host swaps the session underneath
  /// and the block below re-asks, so the user sees what their own click did
  /// rather than having to reopen to find out.
  final void Function(String mode)? onBackendModeChanged;

  final void Function(String url)? onMcpServerUrlChanged;

  /// The platform's own account status, asked once when the dialog opens. Null
  /// in SDK mode, where [hasScope] is the answer instead.
  final Future<Map<String, Object?>?> Function()? connectionStatus;

  /// Sends the user off to connect a Microsoft account to their workspace.
  final VoidCallback? onConnectMicrosoft;

  /// Whether the SELECTED target — this backend, at this server — already has
  /// a session. Asked at every re-ask rather than passed as a value, because
  /// the toggle and the server picker both change what "the target" means
  /// while the dialog is open. Null keeps the pre-session-block behaviour, for
  /// hosts that wire no sign-in.
  final Future<bool> Function()? isTargetSignedIn;

  /// Who the target is signed in as, asked only when it is. Null means the
  /// session cannot say — the block then reports the state without the name
  /// rather than guessing one.
  final Future<String?> Function()? targetAccountLabel;

  /// Runs the sign-in for the SELECTED target, in place. This is where a
  /// session is started now: the gate in front of the app only decides at
  /// launch, so a target with no session is a thing to fix here rather than a
  /// reason to swap the screen out from under this dialog.
  ///
  /// It is expected to throw [AuthException] on failure — a denied consent, a
  /// busy loopback port — whose message is already written for a person and is
  /// shown inline beneath the button. Null hides the session block entirely.
  final Future<void> Function()? onSignIn;

  /// Ends the session for the selected target and nothing else. Deliberately
  /// narrower than the rail's Sign out, which also wipes this machine's copy
  /// of the mail: leaving one server is not "remove this account from this
  /// Mac", and the [IdentityGuard] wipes on the next sign-in anyway if the
  /// identity actually changed.
  final Future<void> Function()? onSignOutOfServer;

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
    this.isTargetSignedIn,
    this.targetAccountLabel,
    this.onSignIn,
    this.onSignOutOfServer,
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

  /// Which backend the dialog is showing. Starts as what the host passed and
  /// follows the toggle WITHOUT the dialog closing: the permissions below
  /// answer for whichever backend is selected, and making the user close and
  /// reopen to see the switch take was a bug, not a design.
  late String _backendMode = widget.backendMode;

  /// Asked when the connection changes, never on every build: a
  /// [FutureBuilder] handed a future built inside `build` re-runs the whole
  /// read on every rebuild, including the ones the slider causes as it is
  /// dragged. Refreshed by [_refreshPermissions] — the toggle, a preset pick,
  /// and a committed custom URL all change what the answers below mean.
  Future<List<bool>>? _granted;
  Future<Map<String, Object?>?>? _connection;

  /// Whether the selected target has a session, and who it belongs to. Null
  /// when the host wired no [SettingsDialog.isTargetSignedIn] — the dialog
  /// then behaves exactly as it did before the session block existed.
  Future<({bool signedIn, String? label})>? _session;

  /// True while a sign-in started from this dialog is out in the browser. The
  /// button is the only thing that can start one, so it is also the only thing
  /// that has to be disabled.
  bool _signingIn = false;

  /// Whatever the last sign-in or sign-out attempt said went wrong, shown
  /// under the button and cleared by the next attempt. Inline rather than a
  /// snack bar: the failure belongs beside the control that caused it, and the
  /// user is about to press it again.
  String? _sessionError;

  @override
  void initState() {
    super.initState();
    _askPermissions();
  }

  void _askPermissions() {
    // Only the source the selected backend will DISPLAY is asked: querying
    // the platform while showing This Mac would be network chatter, and
    // vice versa a wasted keychain read. A host that wires only hasScope
    // keeps the static table whatever the mode says — that is also what the
    // pre-switch dialogs did.
    final wantsPlatform =
        _backendMode == backendModeMcp && widget.connectionStatus != null;
    final askSession = widget.isTargetSignedIn;
    final session = askSession == null ? null : _readSession(askSession);
    _session = session;
    // The status probe hangs off the session answer rather than racing it: a
    // server that is about to 401 has nothing to report, and asking it anyway
    // would spend a round trip to render "did not answer" at a user whose real
    // problem — no session here yet — the block above already names.
    _connection = !wantsPlatform
        ? null
        : session == null
            ? widget.connectionStatus!.call()
            : session.then(
                (state) =>
                    state.signedIn ? widget.connectionStatus!.call() : null,
              );
    _granted = wantsPlatform || widget.hasScope == null
        ? null
        : Future.wait([
            for (final (_, scope, _) in SettingsDialog.permissions)
              widget.hasScope!(scope),
          ]);
  }

  /// Who the selected target is signed in as, in one answer. The label is only
  /// asked for when there is a session to name, because a host with none has
  /// nobody to name and the ask would be a wasted read.
  Future<({bool signedIn, String? label})> _readSession(
    Future<bool> Function() isSignedIn,
  ) async {
    if (!await isSignedIn()) return (signedIn: false, label: null);
    return (signedIn: true, label: await widget.targetAccountLabel?.call());
  }

  /// Re-asks whichever source answers the permissions section.
  ///
  /// Both closures read the CURRENT backend at call time, so calling this
  /// right after a mode or server commit picks up the session the host just
  /// rebuilt — which is the entire point.
  void _refreshPermissions() => setState(_askPermissions);

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
          selected: {_backendMode},
          // The dialog stays OPEN across the switch: the host swaps the
          // session underneath, and the re-ask below renders the new
          // backend's answers in place. Closing here made the user reopen
          // to learn what their own click did.
          onSelectionChanged: (selection) {
            setState(() => _backendMode = selection.first);
            onModeChanged(selection.first);
            _refreshPermissions();
          },
        ),
      ),
      if (_backendMode == backendModeMcp) ..._serverPicker(),
      ..._sessionBlock(),
    ];
  }

  /// Whether the selected target has a session, and the two buttons that
  /// change that.
  ///
  /// It serves BOTH backends and sits directly under the thing that chooses
  /// the target, because that is the question the choice raises: a user who has
  /// just pointed the app at another server wants to know whether they are
  /// signed in to it, and if not, to fix that here. The gate in front of the
  /// app decides at launch only, so this is the one place a session is started
  /// or ended without the whole screen changing underneath.
  List<Widget> _sessionBlock() {
    if (widget.onSignIn == null) return const [];
    return [
      const SizedBox(height: BondSpacing.s12),
      FutureBuilder<({bool signedIn, String? label})>(
        future: _session,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Align(
              alignment: Alignment.centerLeft,
              child: Text('Checking…', style: BondType.small),
            );
          }
          // A read that threw is reported as no session: the sign-in offer is
          // the recoverable answer, and claiming a session nobody verified
          // would put the user in front of a wall of 401s instead.
          final state = snapshot.data;
          final label = state?.label;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                state?.signedIn != true
                    ? 'Not signed in to this server.'
                    : label == null
                        ? 'Signed in.'
                        : 'Signed in as $label.',
                style: BondType.small,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: state?.signedIn == true
                    ? _signOutButton()
                    : _signInButton(),
              ),
              ..._sessionErrorSlot(),
            ],
          );
        },
      ),
    ];
  }

  Widget _signInButton() {
    return FilledButton(
      onPressed: _signingIn ? null : () => unawaited(_signIn()),
      child: _signingIn
          ? const SizedBox(
              height: 16,
              width: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('Sign in…'),
    );
  }

  Widget _signOutButton() {
    if (widget.onSignOutOfServer == null) return const SizedBox.shrink();
    return TextButton(
      onPressed: () => unawaited(_signOutOfServer()),
      child: const Text('Sign out of this server'),
    );
  }

  List<Widget> _sessionErrorSlot() {
    final error = _sessionError;
    if (error == null) return const [];
    return [
      const SizedBox(height: BondSpacing.s4),
      Text(error, style: BondType.small.copyWith(color: BondColors.error)),
    ];
  }

  /// Signs in to the selected target without leaving the dialog.
  ///
  /// Nothing here is allowed to escape as an unhandled async error: this runs
  /// off a button press with no one awaiting it, so a failure that is not
  /// caught lands in the zone instead of on screen. Every setState after the
  /// await is mounted-guarded — the dialog lives in the root overlay and can
  /// outlive the host that opened it.
  Future<void> _signIn() async {
    final signIn = widget.onSignIn;
    if (signIn == null) return;
    setState(() {
      _signingIn = true;
      _sessionError = null;
    });
    try {
      await signIn();
      if (!mounted) return;
      setState(() => _signingIn = false);
      // A session that did not exist a moment ago is the premise of every
      // answer below it, so all of them are asked again rather than assumed.
      _refreshPermissions();
    } on AuthException catch (e) {
      // Every message in AuthException is already written for a person; a
      // denied consent and a busy loopback port both land here.
      if (!mounted) return;
      setState(() {
        _signingIn = false;
        _sessionError = e.message;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _signingIn = false;
        _sessionError = 'Sign-in failed.';
      });
    }
  }

  Future<void> _signOutOfServer() async {
    final signOut = widget.onSignOutOfServer;
    if (signOut == null) return;
    setState(() => _sessionError = null);
    try {
      await signOut();
      if (!mounted) return;
      _refreshPermissions();
    } on Object {
      if (!mounted) return;
      setState(() => _sessionError = 'Sign-out failed.');
    }
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
    // A committed server IS a new connection — the rows below must answer
    // for it, not for the one just left.
    _refreshPermissions();
  }

  /// What the WORKSPACE'S Microsoft account can do, as the platform reports it.
  ///
  /// A status that could not be read is shown as not connected: this section
  /// reports, and "we could not ask" is closer to nothing-connected than to a
  /// row of ticks nobody verified. The offer beside it is harmless if the
  /// connection was fine.
  ///
  /// The whole section waits on the session above it and disappears when there
  /// is none: everything below is the WORKSPACE'S grant, which a server that
  /// will not talk to us has not told us about. The session block is the state
  /// display in that case, and a second one saying less would only compete.
  List<Widget> _platformPermissions() {
    final session = _session;
    return [
      FutureBuilder<({bool signedIn, String? label})>(
        future: session,
        builder: (context, snapshot) {
          if (session != null &&
              (snapshot.connectionState != ConnectionState.done ||
                  snapshot.data?.signedIn != true)) {
            return const SizedBox.shrink();
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: BondSpacing.s24),
              Text(
                'Microsoft permissions',
                style: BondType.body.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: BondSpacing.s4),
              _platformStatus(),
            ],
          );
        },
      ),
    ];
  }

  Widget _platformStatus() {
    return FutureBuilder<Map<String, Object?>?>(
      future: _connection,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Align(
            alignment: Alignment.centerLeft,
            child: Text('Checking…', style: BondType.small),
          );
        }
        final status = snapshot.data;
        if (status == null) {
          // The question went UNANSWERED — which is not the same claim as
          // "nothing is connected". With the session block above answering
          // for the session, the remaining cause is a server that is signed
          // in to but cannot be reached, and offering Connect Microsoft on
          // top of that would be a button with nowhere to send anyone.
          return Text(
            'This server did not answer — it may be unreachable.',
            style: BondType.small,
          );
        }
        if (status['connected'] != true) {
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
    );
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
    // Routed on the mode the dialog is SHOWING, not on which closures the
    // host wired: with the toggle live inside the open dialog, both sources
    // can be wired and the selected backend decides which one answers.
    // [_askPermissions] holds the matching rule — exactly one future exists.
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
              // Suppressed once a session block is on screen: its Sign in… is
              // the same action in its proper place, and two sign-in buttons
              // in one dialog is one too many. The parameter stays for hosts
              // that wire only it.
              if (missing &&
                  widget.onSignInAgain != null &&
                  widget.onSignIn == null)
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
