import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/db.dart';
import 'data/message_store.dart';
import 'providers/app_providers.dart';
import 'screens/inbox_screen.dart';
import 'screens/sign_in_screen.dart';
import 'theme/bond_theme.dart';

Future<void> main() async {
  // Required before path_provider's platform channel can be called, which
  // openAppDb does.
  WidgetsFlutterBinding.ensureInitialized();

  // Opened once, here, rather than lazily behind a provider: the open is
  // async, every screen needs it, and a database that cannot be opened is a
  // launch failure, not something to discover three screens in.
  final db = await openAppDb();

  // Anything the last run was working on when it quit is still claimed —
  // triage on the message row, everything else on the work queue. Clearing
  // both here, before a screen exists to start a new drain, is what keeps a
  // crash from stranding that work permanently.
  MessageStore(db)
    ..resetInterruptedTriage()
    ..resetInterruptedWork();

  runApp(
    ProviderScope(
      overrides: [dbProvider.overrideWithValue(db)],
      child: const BondInboxApp(),
    ),
  );
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
