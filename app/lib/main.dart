import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/inbox_screen.dart';
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
      home: const InboxScreen(),
    );
  }
}
