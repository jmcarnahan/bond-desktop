import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/db.dart';
import 'data/message_store.dart';
import 'providers/app_providers.dart';
import 'providers/prefs_provider.dart';
import 'screens/inbox_screen.dart';
import 'screens/sign_in_screen.dart';
import 'services/triage_queue.dart';
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
  // The activity log is trimmed in the same breath. Once per launch is the
  // whole policy: the table only grows while the app is running, and a prune
  // on every write would be a delete per sync on a database the UI isolate
  // reads synchronously.
  final store = MessageStore(db);
  // Every source the queue drains, so a chat claimed at the moment of a crash
  // is freed exactly as an email is.
  for (final source in TriageQueue.sources) {
    await store.resetInterruptedTriage(source: source);
  }
  await store.resetInterruptedWork();
  await store.pruneActivity();

  // Read before the first frame rather than a microtask into it: every backend
  // provider watches the stored mode, and a frame on the defaults would build
  // — and immediately dispose — a session pointed at the wrong server.
  final prefs = await AppPrefsNotifier.read(store);

  runApp(
    ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        initialAppPrefsProvider.overrideWithValue(prefs),
        // Stamped here, once: the processing indicator only speaks for mail
        // that arrived after the app was already open, and this is the only
        // place that knows when that was.
        sessionStartProvider.overrideWithValue(DateTime.now()),
      ],
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
///
/// It answers ONCE at launch, and again only when a screen explicitly reports
/// a sign-in or a sign-out. Changing the backend or the server in Settings
/// never swaps the screen mid-session: the settings dialog is where sessions
/// are managed, and it shows the selected target's state and signs in and out
/// in place. A gate that swapped the whole screen under an open dialog was
/// three live bugs, all of them in the gap between the switch and the answer.
class AuthGate extends ConsumerStatefulWidget {
  const AuthGate({super.key});

  @override
  ConsumerState<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends ConsumerState<AuthGate> {
  late Future<bool> _signedIn = ref.read(authSessionProvider).isSignedIn;

  void _reload() {
    setState(() {
      _signedIn = ref.read(authSessionProvider).isSignedIn;
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
