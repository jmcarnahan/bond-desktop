import 'dart:async';

import 'package:flutter/material.dart';

import '../providers/prefs_provider.dart'
    show backendModeMcp, backendModeSdk, mcpLocalUrl;
import '../services/backend/backend_types.dart' show AuthException;
import '../theme/tokens.dart';
import 'chips.dart';
import 'inline_alert.dart';
import 'settings_section.dart';

/// The three extended permissions, in the order they matter to the user:
/// label, the bare scope each one is really asking about, and whether a
/// fresh sign-in can actually obtain it. Teams cannot via a direct-Graph
/// sign-in — the SDK path still leaves `Chat.Read` out of its request (see
/// GraphAuth.pendingAdminScopes), and in MCP mode the grant arrives through
/// a platform-side Microsoft reconnect, not this app's sign-in — so
/// offering "sign in again" for it would send the user through a round
/// that cannot deliver.
const List<(String, String, bool)> microsoftPermissions = [
  ('Send mail', 'mail.send', true),
  ('Save drafts', 'mail.readwrite', true),
  ('Teams chats', 'chat.read', false),
];

/// Which backend the app talks through, where, who is signed in to it, and
/// what that grant covers — as one section of the settings screen.
///
/// Its own widget rather than another handful of private methods on the
/// screen, which was already sixteen hundred lines. This section owns the most
/// state on that screen — a backend mode, a server preset and field, three
/// held futures, a session snapshot and its generation counter, a sign-in flag
/// and an error — and nothing outside it reads any of that. Its collapsed
/// summary is built from the same state, so the state lives with the summary
/// rather than a screen away from it.
///
/// The screen keeps every wire and stays prop-only; this widget is prop-only
/// too, reaching for no providers itself, so a test can drive the whole
/// section with nothing but closures.
class MicrosoftConnectionSection extends StatefulWidget {
  /// The section's name, as the screen's open-set and every test spell it.
  /// A constant rather than a literal in two files, because the string is
  /// both the heading and the key the toggle is found by.
  static const String title = 'Microsoft connection';

  /// Whether the screen currently has this section open. The screen owns the
  /// open-set — see the [SettingsSection] doc — so this arrives as a prop.
  final bool expanded;

  /// Fired by the section's own Expand/Collapse, for the screen to record.
  final VoidCallback onToggle;

  /// Which backend the app is talking through: [backendModeMcp] or
  /// [backendModeSdk].
  final String backendMode;

  /// The `/mcp` endpoint MCP mode talks to.
  final String mcpServerUrl;

  /// The deployed platform's URL, when this build knows one. Empty hides the
  /// Deployed preset — a build with no `BOND_MCP_SERVER_URL` define has no
  /// deployed endpoint to offer.
  final String deployedUrl;

  /// Answers "did Microsoft grant this bare scope". Null leaves the permissions
  /// rows out of the section, which is what a host with no auth wired wants —
  /// and what MCP mode passes, where [connectionStatus] answers instead.
  final Future<bool> Function(String bareScope)? hasScope;

  /// Starts a fresh sign-in, which is the only way a missing consent is ever
  /// fixed — a refresh cannot add a scope nobody consented to.
  final VoidCallback? onSignInAgain;

  /// Fired when the user picks the other backend. Null hides the mode segments
  /// alone: the section still renders for a host that wired only the status,
  /// the scopes or the sign-in.
  ///
  /// The screen stays PUT across this: the host swaps the session underneath
  /// and the block below re-asks, so the user sees what their own click did
  /// rather than having to come back to find out.
  final void Function(String mode)? onBackendModeChanged;

  final void Function(String url)? onMcpServerUrlChanged;

  /// The platform's own account status, asked once when the screen opens. Null
  /// in SDK mode, where [hasScope] is the answer instead.
  final Future<Map<String, Object?>?> Function()? connectionStatus;

  /// Sends the user off to connect a Microsoft account to their workspace.
  final VoidCallback? onConnectMicrosoft;

  /// Whether the SELECTED target — this backend, at this server — already has
  /// a session. Asked at every re-ask rather than passed as a value, because
  /// the toggle and the server picker both change what "the target" means
  /// while the screen is open. Null keeps the pre-session-block behaviour, for
  /// hosts that wire no sign-in.
  final Future<bool> Function()? isTargetSignedIn;

  /// Who the target is signed in as, asked only when it is. Null means the
  /// session cannot say — the block then reports the state without the name
  /// rather than guessing one.
  final Future<String?> Function()? targetAccountLabel;

  /// Runs the sign-in for the SELECTED target, in place. This is where a
  /// session is started now: the gate in front of the app only decides at
  /// launch, so a target with no session is a thing to fix here rather than a
  /// reason to swap the screen out from under this pane.
  ///
  /// It is expected to throw [AuthException] on failure — a denied consent, a
  /// busy loopback port — whose message is already written for a person and is
  /// shown inline beneath the button. Null hides the session block entirely.
  final Future<void> Function()? onSignIn;

  /// Ends the session for the selected target and nothing else. Deliberately
  /// narrower than the rail's Sign out, which also wipes this machine's copy
  /// of the mail: leaving one server is not "remove this account from this
  /// device", and the identity guard wipes on the next sign-in anyway if the
  /// identity actually changed.
  final Future<void> Function()? onSignOutOfServer;

  const MicrosoftConnectionSection({
    super.key,
    required this.expanded,
    required this.onToggle,
    required this.backendMode,
    required this.mcpServerUrl,
    required this.deployedUrl,
    this.hasScope,
    this.onSignInAgain,
    this.onBackendModeChanged,
    this.onMcpServerUrlChanged,
    this.connectionStatus,
    this.onConnectMicrosoft,
    this.isTargetSignedIn,
    this.targetAccountLabel,
    this.onSignIn,
    this.onSignOutOfServer,
  });

  /// Whether a host has wired enough for this section to exist at all.
  ///
  /// It answers for THREE different wirings, and must render for any of them:
  /// the mode switch, the platform status, and the static keychain table. A
  /// host that wires only `hasScope` — which is what the permissions tests do
  /// — still gets its rows.
  ///
  /// Static so the screen can decide whether to build the widget without
  /// building it first: a section whose wiring is absent is absent, and that
  /// verdict belongs beside the props it is made of.
  static bool isWired({
    required void Function(String mode)? onBackendModeChanged,
    required Future<Map<String, Object?>?> Function()? connectionStatus,
    required Future<bool> Function(String bareScope)? hasScope,
    required Future<void> Function()? onSignIn,
  }) =>
      onBackendModeChanged != null ||
      connectionStatus != null ||
      hasScope != null ||
      onSignIn != null;

  @override
  MicrosoftConnectionSectionState createState() =>
      MicrosoftConnectionSectionState();
}

/// Public, not private, for exactly one reason: the screen has to reach
/// [commitPendingServerUrl] through a [GlobalKey] from its own Back and Home
/// handlers.
///
/// Those two clicks take the custom server URL field off the screen without
/// ever moving focus, and this state is the only thing that knows whether the
/// field is showing and what is in it. A private state class would leave the
/// screen with no way to ask, and a typed URL would vanish on the way out.
class MicrosoftConnectionSectionState extends State<MicrosoftConnectionSection> {
  /// Which backend the screen is showing. Starts as what the host passed and
  /// follows the toggle in place: the permissions below answer for whichever
  /// backend is selected, and making the user leave and come back to see the
  /// switch take was a bug, not a design.
  late String _backendMode = widget.backendMode;

  /// Asked when the connection changes, never on every build: a
  /// [FutureBuilder] handed a future built inside `build` re-runs the whole
  /// read on every rebuild, including the ones the slider causes as it is
  /// dragged. Refreshed by [_refreshPermissions] — the toggle, a preset pick,
  /// and a committed custom URL all change what the answers below mean.
  Future<List<bool>>? _granted;
  Future<Map<String, Object?>?>? _connection;

  /// Whether the selected target has a session, and who it belongs to. Null
  /// when the host wired no [MicrosoftConnectionSection.isTargetSignedIn] —
  /// the screen then behaves exactly as it did before the session block
  /// existed.
  Future<({bool signedIn, String? label})>? _session;

  /// True while a sign-in started from this screen is out in the browser. The
  /// button is the only thing that can start one, so it is also the only thing
  /// that has to be disabled.
  bool _signingIn = false;

  /// Whatever the last sign-in or sign-out attempt said went wrong, shown
  /// under the button and cleared by the next attempt. Inline rather than a
  /// snack bar: the failure belongs beside the control that caused it, and the
  /// user is about to press it again.
  String? _sessionError;

  /// Which of the three server choices is showing. Held rather than derived on
  /// every build so that picking "Custom…" keeps the field open while the text
  /// still matches a preset.
  late String _serverPreset = _presetFor(widget.mcpServerUrl);

  late final TextEditingController _serverUrl = TextEditingController(
    text: widget.mcpServerUrl,
  );

  /// The last server actually handed to the host. Pressing Enter both submits
  /// and drops focus, so without this one keystroke would commit twice — and a
  /// commit is a whole session being rebuilt, not a preference being written.
  late String _committedUrl = widget.mcpServerUrl;

  static const String _presetCustom = 'custom';

  /// The session answer as a VALUE, for the collapsed summary. The body reads
  /// [_session] through a [FutureBuilder] as before; this is the same answer
  /// resolved once so a one-line string can be built synchronously.
  ({bool signedIn, String? label})? _sessionSnapshot;
  bool _sessionPending = false;

  /// Which ask the snapshot belongs to. A re-ask started while the previous one
  /// is in flight must not be overwritten by the older answer landing second —
  /// the toggle and the server picker both re-ask, and a user can click them
  /// faster than a round trip.
  int _askGeneration = 0;

  @override
  void initState() {
    super.initState();
    _askPermissions();
  }

  @override
  void dispose() {
    _serverUrl.dispose();
    super.dispose();
  }

  void _askPermissions() {
    // Only the source the selected backend will DISPLAY is asked: querying
    // the platform while showing This device would be network chatter, and
    // vice versa a wasted keychain read. A host that wires only hasScope
    // keeps the static table whatever the mode says.
    final wantsPlatform =
        _backendMode == backendModeMcp && widget.connectionStatus != null;
    final askSession = widget.isTargetSignedIn;
    final session = askSession == null ? null : _readSession(askSession);
    _session = session;

    // The same answer, kept as a value so the collapsed summary can be a plain
    // string. A FutureBuilder in the section header would re-ask on every
    // rebuild — the exact bug the held futures above exist to avoid.
    final generation = ++_askGeneration;
    _sessionSnapshot = null;
    _sessionPending = session != null;
    session
        ?.then((state) {
          if (!mounted || generation != _askGeneration) return;
          setState(() {
            _sessionSnapshot = state;
            _sessionPending = false;
          });
        })
        // A read that threw is reported as no session, exactly as the body
        // already reports it — and never as an unhandled async error.
        .onError((_, _) {
          if (!mounted || generation != _askGeneration) return;
          setState(() {
            _sessionSnapshot = null;
            _sessionPending = false;
          });
        });

    // The status probe hangs off the session answer rather than racing it: a
    // server that is about to 401 has nothing to report, and asking it anyway
    // would spend a round trip to render "did not answer" at a user whose real
    // problem — no session here yet — the block above already names.
    _connection = !wantsPlatform
        ? null
        : session == null
        ? widget.connectionStatus!.call()
        : session.then(
            (state) => state.signedIn ? widget.connectionStatus!.call() : null,
          );
    _granted = wantsPlatform || widget.hasScope == null
        ? null
        : Future.wait([
            for (final (_, scope, _) in microsoftPermissions)
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

  String _presetFor(String url) {
    if (url == mcpLocalUrl) return mcpLocalUrl;
    if (widget.deployedUrl.isNotEmpty && url == widget.deployedUrl) {
      return widget.deployedUrl;
    }
    return _presetCustom;
  }

  /// Commits whatever is in the custom server field, if that field is on
  /// screen at all.
  ///
  /// [Focus.onFocusChange] covers a user who moves to another control and
  /// leaves the field behind. It does NOT cover the field being removed from
  /// the tree — Flutter fires no unfocus on dispose, measured, not assumed —
  /// and every way out of this screen removes it. So the three clicks that do
  /// that (Back, Home, and collapsing the section) call this first, while they
  /// are still ordinary event handlers and a provider write is legal. Doing it
  /// in `dispose` instead would put that write inside the frame that is
  /// unmounting the tree, which is the hazard the old dialog's dispose-time
  /// save had to defer out of.
  void commitPendingServerUrl() {
    if (_backendMode != backendModeMcp) return;
    if (_serverPreset != _presetCustom) return;
    _commitServerUrl(_serverUrl.text);
  }

  @override
  Widget build(BuildContext context) => SettingsSection(
    title: MicrosoftConnectionSection.title,
    summary: _connectionSummary(),
    expanded: widget.expanded,
    // Collapsing takes the custom server field off the screen without ever
    // moving focus, so the commit has to happen here — the third of the three
    // clicks that do, and the only one this widget owns. Back and Home are
    // the screen's, and reach [commitPendingServerUrl] through a GlobalKey.
    onToggle: () {
      if (widget.expanded) commitPendingServerUrl();
      widget.onToggle();
    },
    body: _connectionBody(),
  );

  String _connectionSummary() {
    final parts = <String>[
      _backendMode == backendModeMcp ? 'MCP' : 'This device',
      if (_backendMode == backendModeMcp) _presetLabel(),
      if (_sessionPending)
        'Checking…'
      else if (_sessionSnapshot?.signedIn != true)
        'Not signed in'
      else if (_sessionSnapshot?.label case final label?)
        'Signed in as $label'
      else
        'Signed in',
    ];
    return parts.join(' · ');
  }

  String _presetLabel() => switch (_serverPreset) {
    mcpLocalUrl => 'Local',
    _presetCustom => 'Custom',
    _ => 'Deployed',
  };

  /// Which backend the app talks through, where, who is signed in to it, and
  /// what that grant covers.
  ///
  /// The permissions fold in at the bottom rather than sitting in a section of
  /// their own: they are a report about this connection, and a person reading
  /// them has just read which server they belong to.
  Widget _connectionBody() {
    final onModeChanged = widget.onBackendModeChanged;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onModeChanged != null)
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<String>(
              // No tick on the selected segment: the segment is already filled,
              // and the icon reads as a granted permission next to the rows
              // below.
              showSelectedIcon: false,
              segments: const [
                // Renamed: 'Bond server' collided with the dropdown label right
                // under it, and 'This Mac' named the wrong thing on a machine
                // that is not one.
                ButtonSegment(value: backendModeMcp, label: Text('MCP')),
                ButtonSegment(
                  value: backendModeSdk,
                  label: Text('This device'),
                ),
              ],
              selected: {_backendMode},
              // The screen stays PUT across the switch: the host swaps the
              // session underneath, and the re-ask below renders the new
              // backend's answers in place.
              onSelectionChanged: (selection) {
                setState(() => _backendMode = selection.first);
                onModeChanged(selection.first);
                _refreshPermissions();
              },
            ),
          ),
        if (_backendMode == backendModeMcp) ..._serverPicker(),
        ..._sessionBlock(),
        ..._permissionsSection(),
      ],
    );
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
          final signedIn = state?.signedIn == true;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  // The chip carries the state at a glance; the sentence beside
                  // it carries the detail. Together they are the same claim the
                  // collapsed summary makes one line up.
                  BondChip.semantic(
                    signedIn ? 'Signed in' : 'Not signed in',
                    signedIn ? BondTone.success : BondTone.neutral,
                  ),
                  const SizedBox(width: BondSpacing.s8),
                  Expanded(
                    child: Text(
                      !signedIn
                          ? 'Not signed in to this server.'
                          : label == null
                          ? 'Signed in.'
                          : 'Signed in as $label.',
                      style: BondType.small,
                    ),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: signedIn ? _signOutButton() : _signInButton(),
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
      const SizedBox(height: BondSpacing.s8),
      InlineAlert(severity: InlineAlertSeverity.error, text: error),
    ];
  }

  /// Signs in to the selected target without leaving the screen.
  ///
  /// Nothing here is allowed to escape as an unhandled async error: this runs
  /// off a button press with no one awaiting it, so a failure that is not
  /// caught lands in the zone instead of on screen. Every setState after the
  /// await is mounted-guarded — a sign-in is out in the browser for as long as
  /// the user takes, and Back can come first.
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

  /// Which MCP server to talk to: the two that are worth a preset, and a field
  /// for anything else.
  List<Widget> _serverPicker() {
    return [
      const SizedBox(height: BondSpacing.s12),
      DropdownButtonFormField<String>(
        initialValue: _serverPreset,
        decoration: const InputDecoration(labelText: 'MCP server'),
        items: [
          // Only when it is a DISTINCT URL: pointing the deployed define at the
          // local endpoint (BOND_MCP_SERVER_URL=http://localhost:18001/mcp) makes
          // this item's value equal the Local item's below, and two dropdown
          // items sharing one value trips DropdownButton's "exactly one" assert.
          if (widget.deployedUrl.isNotEmpty && widget.deployedUrl != mcpLocalUrl)
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
        //
        // With no Done button on a screen, "the way out of the field" is now
        // collapsing the section, tapping another control, or leaving by the
        // back arrow — all of which move focus, and all of which therefore
        // commit. Keep the Focus node; onTapOutside would not cover the last.
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
  /// A status that could not be read is shown as not connected: this block
  /// reports, and "we could not ask" is closer to nothing-connected than to a
  /// row of ticks nobody verified. The offer beside it is harmless if the
  /// connection was fine.
  ///
  /// The whole block waits on the session above it and disappears when there
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
              // A sub-heading inside a section body now, so it is deliberately
              // smaller than the section titles it sits under. The string is
              // unchanged.
              Text(
                'Microsoft permissions',
                style: BondType.small.copyWith(fontWeight: FontWeight.w600),
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
            for (final (label, scope, _) in microsoftPermissions)
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

  /// Which granted scope stands in for a scope this screen asks about — the
  /// same two pairs `McpAuthSession._subsumedBy` holds, for the same reason:
  /// Microsoft's consent hierarchy makes the ReadWrite grant include Read,
  /// and the platform's admin grant for Teams is `Chat.ReadWrite` while the
  /// row here asks the read-only question. The two matchers must agree or the
  /// screen contradicts the Teams pill it sits on top of.
  static const Map<String, Set<String>> _subsumedBy = {
    'mail.read': {'mail.readwrite'},
    'chat.read': {'chat.readwrite'},
  };

  /// Whether the connected account holds [scope].
  ///
  /// A connected account with no scopes recorded is a row that predates the
  /// platform storing them; those grants were all mail-only, which is the same
  /// answer `McpAuthSession.hasScope` gives.
  static bool _holds(Set<String> granted, String scope) {
    if (granted.isEmpty) return scope.startsWith('mail.');
    return granted.contains(scope) ||
        (_subsumedBy[scope]?.any(granted.contains) ?? false);
  }

  /// What Microsoft actually granted, and the one thing that can change it.
  ///
  /// It reports rather than persuades: a tick or a cross per permission, and
  /// the sign-in offer only when something is missing. A tenant that will not
  /// grant these is a tenant nobody on this screen can argue with, so nagging
  /// about it every time Settings opens would be noise.
  List<Widget> _permissionsSection() {
    // Routed on the mode the screen is SHOWING, not on which closures the
    // host wired: with the toggle live inside the open section, both sources
    // can be wired and the selected backend decides which one answers.
    // [_askPermissions] holds the matching rule — exactly one future exists.
    if (_connection != null) return _platformPermissions();
    final granted = _granted;
    if (granted == null) return const [];
    return [
      const SizedBox(height: BondSpacing.s24),
      Text(
        'Microsoft permissions',
        style: BondType.small.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: BondSpacing.s4),
      FutureBuilder<List<bool>>(
        future: granted,
        builder: (context, snapshot) {
          // Absent an answer, every row reads as not granted — the same thing
          // the composer assumes while it is waiting, so the two never
          // disagree on screen.
          final answers =
              snapshot.data ?? List.filled(microsoftPermissions.length, false);
          // Only a scope a fresh sign-in can deliver counts as fixable —
          // an admin-gated row must not turn the offer into a permanent nag.
          var missing = false;
          for (var i = 0; i < microsoftPermissions.length; i++) {
            missing = missing || (microsoftPermissions[i].$3 && !answers[i]);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < microsoftPermissions.length; i++)
                _permissionRow(microsoftPermissions[i].$1, answers[i]),
              // Suppressed once a session block is on screen: its Sign in… is
              // the same action in its proper place, and two sign-in buttons
              // in one section is one too many. The parameter stays for hosts
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
