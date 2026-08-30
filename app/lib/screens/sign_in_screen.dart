import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/app_providers.dart';
import '../providers/prefs_provider.dart';
import '../services/backend/backend_types.dart';
import '../theme/tokens.dart';

/// The gate in front of the inbox: one button that hands off to the system
/// browser and waits for the loopback redirect to come back.
///
/// In MCP mode there can be a SECOND step. Signing in to the Bond workspace and
/// connecting a Microsoft account are two different grants held in two
/// different places, and a user who has done the first but not the second is
/// signed in with nothing to read. That case is the only reason this screen has
/// more than one state — an existing remote user signs in once and never sees
/// it.
class SignInScreen extends ConsumerStatefulWidget {
  /// Fired once tokens are stored, so the gate above can swap in the inbox.
  final VoidCallback onSignedIn;

  const SignInScreen({super.key, required this.onSignedIn});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen>
    with WidgetsBindingObserver {
  bool _busy = false;
  String? _error;

  /// True once the platform has said the workspace has no Microsoft account
  /// connected — the one thing this screen's second step can fix.
  bool _connectNeeded = false;

  /// Where to send the user to connect, asked once when the step appears.
  /// Resolving to null means the server offers no connect flow at all, which
  /// is the local dev server's answer and is why the button can be disabled.
  Future<String?>? _connectUrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The connect step happens in a browser, so coming back to this window is
  /// the app's best signal that it is worth asking again. Silent: a probe that
  /// still says "not connected" is the state already on screen, and announcing
  /// it every time the user tabs past would be a scold.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _connectNeeded) {
      unawaited(_recheckConnection(announce: false));
    }
  }

  bool get _mcpMode =>
      ref.read(appPrefsProvider).backendMode == backendModeMcp;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = ref.read(authSessionProvider);
      await session.signIn();
      if (!mounted) return;
      // Only MCP mode has a second grant to ask about. In SDK mode the sign-in
      // IS the Microsoft consent, and asking again would cost a round trip to
      // learn what the sign-in just settled.
      if (_mcpMode && await session.needsReconsent) {
        if (!mounted) return;
        setState(() {
          _connectNeeded = true;
          _connectUrl = ref.read(mcpStackProvider).auth.microsoftConnectUrl();
        });
        return;
      }
      if (!mounted) return;
      widget.onSignedIn();
    } on AuthException catch (e) {
      // Every message in AuthException is already written for a person; a
      // denied consent and a busy port both land here.
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openConnect() async {
    final url = await _connectUrl;
    if (url == null || !mounted) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// Asks the platform again whether Microsoft is connected now.
  ///
  /// The cached answer is dropped first, on purpose: the status cache is thirty
  /// seconds long and the user has just spent that long in a browser, so
  /// trusting it here would report the state they went to fix.
  Future<void> _recheckConnection({bool announce = true}) async {
    final auth = ref.read(mcpStackProvider).auth;
    auth.invalidateStatusCache();
    setState(() {
      _busy = true;
      if (announce) _error = null;
    });
    try {
      final stillNeeded = await auth.needsReconsent;
      if (!mounted) return;
      if (!stillNeeded) {
        widget.onSignedIn();
        return;
      }
      if (announce) {
        setState(() => _error =
            'Microsoft is still not connected. Finish the connect step in '
            'your browser, then try again.');
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      if (announce) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mcpMode = ref.watch(
          appPrefsProvider.select((p) => p.backendMode),
        ) ==
        backendModeMcp;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Container(
            padding: const EdgeInsets.all(BondSpacing.s32),
            decoration: BoxDecoration(
              color: BondColors.surface,
              borderRadius: BondRadii.lgAll,
              border: Border.all(color: BondColors.border),
            ),
            // Scrollable because the card is not always the same height: the
            // connect step is twice the sign-in step, and a short window must
            // put it out of reach rather than cut it off.
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _connectNeeded
                    ? _connectStep()
                    : _signInStep(mcpMode: mcpMode),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _signInStep({required bool mcpMode}) {
    return [
      Text('Bond Inbox', style: BondType.title),
      const SizedBox(height: BondSpacing.s8),
      Text(
        mcpMode
            ? 'Sign in to your Bond workspace to read your mail.'
            : 'Connect your Microsoft account to read your mail.',
        style: BondType.body.copyWith(color: BondColors.inkSecondary),
      ),
      const SizedBox(height: BondSpacing.s24),
      _primaryButton(
        label: mcpMode ? 'Sign in' : 'Sign in with Microsoft',
        onPressed: _busy ? null : _signIn,
      ),
      if (_busy) ...[
        const SizedBox(height: BondSpacing.s12),
        Text(
          'Finish signing in in your browser, then come back here.',
          style: BondType.small,
        ),
      ],
      ..._errorSlot(),
    ];
  }

  /// The second step: signed in to the workspace, with no Microsoft account
  /// behind it yet.
  List<Widget> _connectStep() {
    return [
      Text('Connect your Microsoft account', style: BondType.title),
      const SizedBox(height: BondSpacing.s8),
      Text(
        'You are signed in to Bond. One more step: let Bond read your '
        'Microsoft mail, in the browser window it opens.',
        style: BondType.body.copyWith(color: BondColors.inkSecondary),
      ),
      const SizedBox(height: BondSpacing.s24),
      FutureBuilder<String?>(
        future: _connectUrl,
        builder: (context, snapshot) {
          final url = snapshot.data;
          final waiting = snapshot.connectionState != ConnectionState.done;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _primaryButton(
                label: 'Connect Microsoft',
                onPressed:
                    (_busy || waiting || url == null) ? null : _openConnect,
              ),
              if (!waiting && url == null) ...[
                const SizedBox(height: BondSpacing.s12),
                Text(
                  'This server has no connect step of its own — connect the '
                  'Microsoft account on the server, then continue.',
                  style: BondType.small,
                ),
              ],
            ],
          );
        },
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: _busy ? null : () => unawaited(_recheckConnection()),
          child: const Text("I've connected — continue"),
        ),
      ),
      ..._errorSlot(),
    ];
  }

  List<Widget> _errorSlot() {
    final error = _error;
    if (error == null) return const [];
    return [
      const SizedBox(height: BondSpacing.s16),
      Text(error, style: BondType.small.copyWith(color: BondColors.error)),
    ];
  }

  Widget _primaryButton({required String label, VoidCallback? onPressed}) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: BondColors.primary,
          foregroundColor: BondColors.surface,
          padding: const EdgeInsets.symmetric(vertical: BondSpacing.s16),
          shape: const RoundedRectangleBorder(borderRadius: BondRadii.smAll),
        ),
        child: _busy
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: BondColors.surface,
                ),
              )
            : Text(
                label,
                style: BondType.body.copyWith(color: BondColors.surface),
              ),
      ),
    );
  }
}
