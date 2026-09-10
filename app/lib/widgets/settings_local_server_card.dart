import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../services/server/server_state.dart';
import '../theme/tokens.dart';
import 'inline_alert.dart';

/// The Local server card: whether Bond runs the model server, where it
/// listens, where its models are, and what it is doing right now.
///
/// PROP-ONLY, like every other body in Settings: no provider is read here, the
/// host resolves the state and takes every action back as a closure, and the
/// whole card is drivable from a test with a handful of values. A null
/// callback HIDES its control rather than disabling it — the discipline the
/// rest of this screen keeps, so a host that cannot do a thing never offers
/// it.
///
/// It renders as the Models section's header rather than as a section of its
/// own, because the three slots below it are what it serves: read top to
/// bottom, the section says which server is running and then where each model
/// call goes.
class SettingsLocalServerBody extends StatefulWidget {
  /// What the supervisor says, whatever the switch says. The two disagree for
  /// a moment after the switch is flipped, and [summary] is where that is
  /// reconciled.
  final ServerState state;

  final bool managed;
  final int port;

  /// The EFFECTIVE folder — the host has already resolved "the app's own
  /// folder" into a path, so this card never has to know what empty means.
  final String modelsFolder;

  final void Function(bool on) onManagedChanged;
  final void Function(int port) onPortSaved;

  /// Asks the kernel for a port nothing holds. Null takes the button off.
  final Future<int> Function()? onPickFreePort;

  final VoidCallback? onChooseFolder;
  final VoidCallback? onStart;
  final VoidCallback? onStop;
  final VoidCallback? onRestart;
  final VoidCallback? onShowLog;

  /// Phase 4's first-run wizard, from the top. Unwired until it exists.
  final VoidCallback? onSetUpAgain;

  const SettingsLocalServerBody({
    super.key,
    required this.state,
    required this.managed,
    required this.port,
    required this.modelsFolder,
    required this.onManagedChanged,
    required this.onPortSaved,
    this.onPickFreePort,
    this.onChooseFolder,
    this.onStart,
    this.onStop,
    this.onRestart,
    this.onShowLog,
    this.onSetUpAgain,
  });

  static const Key managedKey = ValueKey('local-server-managed');
  static const Key portFieldKey = ValueKey('local-server-port-field');
  static const Key savePortKey = ValueKey('local-server-save-port');
  static const Key pickPortKey = ValueKey('local-server-pick-port');
  static const Key startKey = ValueKey('local-server-start');
  static const Key stopKey = ValueKey('local-server-stop');
  static const Key restartKey = ValueKey('local-server-restart');
  static const Key chooseFolderKey = ValueKey('local-server-choose-folder');
  static const Key showLogKey = ValueKey('local-server-show-log');
  static const Key setUpAgainKey = ValueKey('local-server-set-up-again');

  /// What a port outside this range would cost: below 1024 needs root, and
  /// 65535 is the top of the field.
  static const int minPort = 1024;
  static const int maxPort = 65535;

  static const String portError = 'Use a port between 1024 and 65535';

  /// The one line the collapsed Models section shows for the server.
  ///
  /// Static so the screen can build it without this widget existing — a
  /// collapsed section renders its summary and nothing else.
  ///
  /// The switch WINS over the supervisor's state. Turning the preference off
  /// stops the server asynchronously, and a summary that still said 'Ready'
  /// for that second would be reporting a server the app has already stopped
  /// using.
  static String summary(ServerState state, {required bool managed}) =>
      managed ? state.summary : const ServerDisabled().summary;

  @override
  State<SettingsLocalServerBody> createState() =>
      _SettingsLocalServerBodyState();
}

class _SettingsLocalServerBodyState extends State<SettingsLocalServerBody> {
  late final TextEditingController _port =
      TextEditingController(text: '${widget.port}');

  /// Whether the field holds something the user put there. A stored port that
  /// changes underneath an untouched field should be shown; one that changes
  /// underneath a half-typed number must not eat the typing.
  bool _touched = false;

  /// The switch, held locally so it moves the instant it is tapped rather than
  /// a database round trip later — `_activityLogBody`'s shape exactly.
  late bool _managed = widget.managed;

  @override
  void didUpdateWidget(SettingsLocalServerBody old) {
    super.didUpdateWidget(old);
    if (old.managed != widget.managed) _managed = widget.managed;
    if (old.port != widget.port && !_touched) {
      _port.text = '${widget.port}';
    }
  }

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  /// What the card reports, with the switch's answer taking precedence — see
  /// [SettingsLocalServerBody.summary].
  ServerState get _effective =>
      _managed ? widget.state : const ServerDisabled();

  /// The typed port, or null when it is not a usable one.
  int? get _typedPort {
    final parsed = int.tryParse(_port.text.trim());
    if (parsed == null) return null;
    if (parsed < SettingsLocalServerBody.minPort) return null;
    if (parsed > SettingsLocalServerBody.maxPort) return null;
    return parsed;
  }

  bool get _portInvalid => _port.text.trim().isNotEmpty && _typedPort == null;

  bool get _canSavePort {
    final typed = _typedPort;
    return typed != null && typed != widget.port;
  }

  @override
  Widget build(BuildContext context) {
    // Every control but the switch is dead while the app is not the one
    // running the server: they all act on a process that does not exist.
    final on = _managed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Local server',
          style: BondType.body.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: BondSpacing.s4),
        SwitchListTile(
          key: SettingsLocalServerBody.managedKey,
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _managed,
          title: Text(
            'Bond runs the model server',
            style: BondType.body.copyWith(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            'One llama-server serves all three models from this Mac. Off, the '
            'app expects servers you started yourself.',
            style: BondType.caption,
          ),
          onChanged: (value) {
            setState(() => _managed = value);
            widget.onManagedChanged(value);
          },
        ),
        const SizedBox(height: BondSpacing.s8),
        ..._statusLines(),
        const SizedBox(height: BondSpacing.s16),
        _portRow(enabled: on),
        const SizedBox(height: BondSpacing.s16),
        _folderRow(enabled: on),
        const SizedBox(height: BondSpacing.s16),
        _buttons(enabled: on),
        const SizedBox(height: BondSpacing.s8),
        Text(
          'Changing the port or the folder restarts the server. Work in '
          'flight parks and resumes when it is back.',
          style: BondType.caption,
        ),
      ],
    );
  }

  /// The state, said once — as an alert where the user has something to do
  /// about it, as plain text where they do not.
  ///
  /// A failure carries the tail of the log with it, because the reason alone
  /// never explains a crash: "exited (code 1)" is the same sentence for a
  /// corrupt model file, a missing backend and a machine too small, and the
  /// last lines the server printed are what tell them apart.
  List<Widget> _statusLines() {
    final state = _effective;
    final text = SettingsLocalServerBody.summary(
      widget.state,
      managed: _managed,
    );
    return [
      switch (state) {
        ServerFailed() || ServerPortInUse() => InlineAlert(
            severity: InlineAlertSeverity.error,
            text: text,
          ),
        ServerStarting() || ServerLoading() => InlineAlert(
            severity: InlineAlertSeverity.attention,
            text: text,
          ),
        _ => Text(text, style: BondType.body),
      },
      if (state is ServerFailed && state.logTail.isNotEmpty) ...[
        const SizedBox(height: BondSpacing.s8),
        Text(_tail(state.logTail), style: BondType.mono),
      ],
      if (state is ServerPortInUse) ...[
        const SizedBox(height: BondSpacing.s4),
        Text(
          'Pick a free port below, or stop the other program.',
          style: BondType.caption,
        ),
      ],
    ];
  }

  /// The last twelve lines. Enough to carry a stack of llama.cpp's own load
  /// errors, short enough that the card is still a card.
  static String _tail(List<String> lines) =>
      lines.length <= 12 ? lines.join('\n') : lines.sublist(lines.length - 12).join('\n');

  Widget _portRow({required bool enabled}) {
    final pick = widget.onPickFreePort;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Port',
          style: BondType.small.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: BondSpacing.s4),
        // Wrap rather than Row: a field and two buttons do not fit the pane at
        // a doubled text scale, and wrapping is the right failure.
        Wrap(
          spacing: BondSpacing.s8,
          runSpacing: BondSpacing.s8,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: [
            SizedBox(
              width: 160,
              child: TextField(
                key: SettingsLocalServerBody.portFieldKey,
                controller: _port,
                enabled: enabled,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: BondType.mono,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  errorText:
                      _portInvalid ? SettingsLocalServerBody.portError : null,
                ),
                onChanged: (_) => setState(() => _touched = true),
              ),
            ),
            if (pick != null)
              OutlinedButton(
                key: SettingsLocalServerBody.pickPortKey,
                onPressed: enabled ? () => unawaited(_pick(pick)) : null,
                child: const Text('Pick a free port'),
              ),
            FilledButton(
              key: SettingsLocalServerBody.savePortKey,
              onPressed:
                  enabled && _canSavePort ? _savePort : null,
              child: const Text('Save port'),
            ),
          ],
        ),
      ],
    );
  }

  /// Fills the field rather than saving: the number the kernel handed back is
  /// a suggestion, and a port that moved without a Save would be a server that
  /// restarted because somebody pressed a button labelled 'Pick'.
  Future<void> _pick(Future<int> Function() pick) async {
    try {
      final port = await pick();
      if (!mounted) return;
      setState(() {
        _port.text = '$port';
        _touched = true;
      });
    } on Object {
      // Nothing to say: the field keeps what it had, and the user can type a
      // number. A diagnostic button that threw a red screen would be worse
      // than one that did nothing.
    }
  }

  void _savePort() {
    final port = _typedPort;
    if (port == null) return;
    setState(() => _touched = false);
    widget.onPortSaved(port);
  }

  Widget _folderRow({required bool enabled}) {
    final choose = widget.onChooseFolder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Models folder',
          style: BondType.small.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: BondSpacing.s4),
        Text(widget.modelsFolder, style: BondType.mono),
        if (choose != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: SettingsLocalServerBody.chooseFolderKey,
              onPressed: enabled ? choose : null,
              child: const Text('Change folder…'),
            ),
          ),
      ],
    );
  }

  /// Which of the three lifecycle buttons this state has a use for.
  ///
  /// Read off [SettingsLocalServerBody.state] — the SUPERVISOR's answer, not
  /// the switch's — so that turning the preference off leaves the controls on
  /// screen, greyed, rather than making the row jump about while the server
  /// stops.
  Widget _buttons({required bool enabled}) {
    final state = widget.state;
    final canStart =
        state is ServerStopped || state is ServerFailed || state is ServerPortInUse;
    final canStop = state is ServerStarting ||
        state is ServerLoading ||
        state is ServerReady;
    final canRestart = state is ServerLoading || state is ServerReady;
    return Wrap(
      spacing: BondSpacing.s8,
      runSpacing: BondSpacing.s8,
      children: [
        if (canStart && widget.onStart != null)
          FilledButton(
            key: SettingsLocalServerBody.startKey,
            onPressed: enabled ? widget.onStart : null,
            child: const Text('Start'),
          ),
        if (canStop && widget.onStop != null)
          OutlinedButton(
            key: SettingsLocalServerBody.stopKey,
            onPressed: enabled ? widget.onStop : null,
            child: const Text('Stop'),
          ),
        if (canRestart && widget.onRestart != null)
          OutlinedButton(
            key: SettingsLocalServerBody.restartKey,
            onPressed: enabled ? widget.onRestart : null,
            child: const Text('Restart'),
          ),
        // Offered in every state, because the log is most wanted in the one
        // the app cannot describe.
        if (widget.onShowLog != null)
          TextButton(
            key: SettingsLocalServerBody.showLogKey,
            onPressed: enabled ? widget.onShowLog : null,
            child: const Text('Show log'),
          ),
        if (widget.onSetUpAgain != null)
          TextButton(
            key: SettingsLocalServerBody.setUpAgainKey,
            onPressed: enabled ? widget.onSetUpAgain : null,
            child: const Text('Set up again'),
          ),
      ],
    );
  }
}
