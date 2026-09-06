import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// One row of the settings screen: what it is, what it currently says, and a
/// way to open it.
///
/// Collapsed is the default for every section, so the screen opens as a list
/// of answers rather than a wall of controls — a person arriving to change one
/// thing can see the other seven states without reading a single control.
///
/// Stateless over props: the screen owns which sections are open (several may
/// be), and that state is deliberately NOT persisted — where the user left the
/// disclosure triangles is not a preference, it is a scroll position.
class SettingsSection extends StatelessWidget {
  final String title;

  /// One line of current state, shown whether or not the section is open.
  /// Recomputed by the screen from its own state — never a future, never
  /// per-frame work.
  final String summary;

  final bool expanded;
  final VoidCallback onToggle;
  final Widget body;

  const SettingsSection({
    super.key,
    required this.title,
    required this.summary,
    required this.expanded,
    required this.onToggle,
    required this.body,
  });

  /// The key on the toggle, so a test can open one named section without
  /// walking the tree for the right 'Expand'.
  static Key toggleKey(String title) => ValueKey('settings-toggle-$title');

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: BondSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // No maxLines on the title: at a large text scale it wraps
                    // rather than losing its own name, and the summary below is
                    // the line that ellipsises.
                    Text(
                      title,
                      style: BondType.body.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: BondSpacing.s4),
                    // Two lines, not one: the connection summary is three
                    // segments and an account address, and it must degrade by
                    // wrapping rather than by hiding the account.
                    Text(
                      summary,
                      style: BondType.small.copyWith(
                        color: BondColors.inkSecondary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: BondSpacing.s12),
              TextButton(
                key: toggleKey(title),
                onPressed: onToggle,
                child: Text(expanded ? 'Collapse' : 'Expand'),
              ),
            ],
          ),
          // The summary stays visible when the body is open. It is the answer,
          // and hiding it behind the controls would make Collapse the only way
          // to check what the controls did.
          if (expanded) ...[
            const SizedBox(height: BondSpacing.s12),
            body,
          ],
          const SizedBox(height: BondSpacing.s8),
          const Divider(height: 1, color: BondColors.border),
        ],
      ),
    );
  }
}
