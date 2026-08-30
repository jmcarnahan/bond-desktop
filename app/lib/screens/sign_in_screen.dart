import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import '../services/graph_auth.dart';
import '../theme/tokens.dart';

/// The gate in front of the inbox: one button that hands off to the system
/// browser and waits for the loopback redirect to come back.
class SignInScreen extends ConsumerStatefulWidget {
  /// Fired once tokens are stored, so the gate above can swap in the inbox.
  final VoidCallback onSignedIn;

  const SignInScreen({super.key, required this.onSignedIn});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(graphAuthProvider).signIn();
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

  @override
  Widget build(BuildContext context) {
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Bond Inbox', style: BondType.title),
                const SizedBox(height: BondSpacing.s8),
                Text(
                  'Connect your Microsoft account to read your mail.',
                  style: BondType.body.copyWith(color: BondColors.inkSecondary),
                ),
                const SizedBox(height: BondSpacing.s24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy ? null : _signIn,
                    style: FilledButton.styleFrom(
                      backgroundColor: BondColors.primary,
                      foregroundColor: BondColors.surface,
                      padding: const EdgeInsets.symmetric(
                        vertical: BondSpacing.s16,
                      ),
                      shape: const RoundedRectangleBorder(
                        borderRadius: BondRadii.smAll,
                      ),
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
                            'Sign in with Microsoft',
                            style: BondType.body
                                .copyWith(color: BondColors.surface),
                          ),
                  ),
                ),
                if (_busy) ...[
                  const SizedBox(height: BondSpacing.s12),
                  Text(
                    'Finish signing in in your browser, then come back here.',
                    style: BondType.small,
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: BondSpacing.s16),
                  Text(
                    _error!,
                    style: BondType.small.copyWith(color: BondColors.error),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
