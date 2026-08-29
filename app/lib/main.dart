import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/app_providers.dart';
import 'screens/inbox_screen.dart';
import 'screens/sign_in_screen.dart';
import 'theme/bond_theme.dart';

void main() {
  runApp(const ProviderScope(child: BondInboxApp()));
}

class BondInboxApp extends StatelessWidget {
  const BondInboxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bond Inbox',
      debugShowCheckedModeBanner: false,
      theme: BondTheme.themeData,
      home: const AuthGate(),
    );
  }
}

/// Chooses the sign-in screen or the inbox from stored credentials.
///
/// The check is a stored-refresh-token lookup, not a network call: it is
/// allowed to be optimistic. A token that turns out to be dead surfaces later
/// as [NotSignedIn] from the first Graph call, which Phase 3 routes back
/// here.
class AuthGate extends ConsumerStatefulWidget {
  const AuthGate({super.key});

  @override
  ConsumerState<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends ConsumerState<AuthGate> {
  late Future<bool> _signedIn = ref.read(graphAuthProvider).isSignedIn;

  void _reload() {
    setState(() {
      _signedIn = ref.read(graphAuthProvider).isSignedIn;
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _signedIn,
      builder: (context, snapshot) {
        // A storage read that throws (no keychain access) is treated as
        // signed out — the sign-in screen is the recoverable answer.
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.data == true) {
          return InboxScreen(onSignedOut: _reload);
        }
        return SignInScreen(onSignedIn: _reload);
      },
    );
  }
}
