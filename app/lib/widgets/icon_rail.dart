import 'package:flutter/material.dart';

import '../services/backend/people_backend.dart' show PeopleBackend;
import '../services/profile_photos.dart';
import '../theme/tokens.dart';
import 'app_rail.dart' show RailSection, RailSectionLabel;
import 'bond_avatar.dart';

/// The 56px strip of stops at the very left, and the account's face at the
/// foot of it.
///
/// Two columns rather than one, because the old single rail was doing two
/// jobs: WHERE you are (six destinations, always visible, never scrolling) and
/// WHAT is there (a list that scrolls and changes with the destination). This
/// is the first job. It never scrolls and it never changes.
///
/// The identity lives on the avatar (D8) rather than in a footer row of five
/// icons. The account name, Settings, the activity log and Sign out are all
/// about the app rather than about the mail, they are all reached rarely, and
/// a face is where every desktop app of this shape has taught people to look
/// for them. It also empties the foot of the list column, which is what the
/// footer was crowding.
class IconRail extends StatelessWidget {
  /// Fixed, like [AppRail.width]: the icon rail is a landmark, not a pane.
  static const double width = 56;

  /// The account button. One key rather than a tooltip finder because the menu
  /// it opens is the only way to Settings and Sign out now, and a test that
  /// had to guess at the avatar's label would be pinning the wrong thing.
  static const Key accountMenuKey = ValueKey('account-menu');
  static const Key settingsItemKey = ValueKey('account-menu-settings');
  static const Key activityItemKey = ValueKey('account-menu-activity');
  static const Key signOutItemKey = ValueKey('account-menu-signout');

  /// The stop the list column is scoped to, or null while something that is
  /// not a section — a thread, a storyline, a room, a pane — has the screen.
  final RailSection? selected;

  /// What Needs You is holding, for the badge. Zero hides it.
  final int needsYouCount;

  final void Function(RailSection section) onSelect;

  /// The signed-in account, for the avatar's initials and the menu's header.
  /// Empty until the stored account resolves, which is a face with a '?' on it
  /// for a frame or two.
  final String accountName;
  final String? accountAddress;

  final VoidCallback onSettings;

  /// Null leaves the item out entirely — the log is behind a preference, and
  /// an item that did nothing would be worse than no item.
  final VoidCallback? onActivityLog;

  final VoidCallback onSignOut;

  final ProfilePhotos? photos;

  const IconRail({
    super.key,
    required this.selected,
    required this.needsYouCount,
    required this.onSelect,
    required this.accountName,
    this.accountAddress,
    required this.onSettings,
    this.onActivityLog,
    required this.onSignOut,
    this.photos,
  });

  /// Top to bottom. Home leads because it is where the app lands; AI is last
  /// because it is the only one that is about the app rather than the mail.
  static const List<(RailSection, IconData)> stops = [
    (RailSection.home, Icons.bolt),
    (RailSection.needsYou, Icons.notifications_outlined),
    (RailSection.storylines, Icons.tag),
    (RailSection.people, Icons.people_outline),
    (RailSection.archive, Icons.schedule),
    (RailSection.ai, Icons.auto_awesome),
  ];

  static const double _stopSize = 44;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Material(
        color: BondColors.railDeep,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: BondSpacing.s8),
                children: [
                  for (final (section, icon) in stops) _stop(section, icon),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: BondSpacing.s12),
              child: _account(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stop(RailSection section, IconData icon) {
    final isSelected = selected == section;
    final ink = isSelected ? BondColors.onDarkPrimary : BondColors.onDarkMuted;
    final badge = section == RailSection.needsYou && needsYouCount > 0
        ? _badge(needsYouCount)
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: BondSpacing.s4),
      child: Center(
        child: Tooltip(
          message: section.label,
          child: SizedBox(
            width: _stopSize,
            height: _stopSize,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: Material(
                    color: isSelected
                        ? BondColors.onDarkTint
                        : BondColors.railDeep,
                    borderRadius: BondRadii.smAll,
                    child: InkWell(
                      onTap: () => onSelect(section),
                      borderRadius: BondRadii.smAll,
                      hoverColor: BondColors.onDarkFaint,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(icon, size: 20, color: ink),
                          const SizedBox(height: 2),
                          // The label is what stops six similar glyphs being a
                          // guessing game. It clips before the rail widens:
                          // the tooltip carries the whole word.
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: Text(
                              section.label,
                              style: BondType.caption.copyWith(
                                fontSize: 10,
                                height: 1,
                                color: ink,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (badge != null)
                  Positioned(top: -2, right: -4, child: badge),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The count over Needs You. It stops at `99+` because three digits do not
  /// fit on a 44px square and because past a hundred the exact number stops
  /// being a number anybody acts on.
  Widget _badge(int count) {
    return Container(
      constraints: const BoxConstraints(minWidth: 16),
      padding: const EdgeInsets.symmetric(horizontal: 3),
      decoration: const BoxDecoration(
        color: BondColors.railBadge,
        borderRadius: BondRadii.fullAll,
      ),
      alignment: Alignment.center,
      child: Text(
        count > 99 ? '99+' : '$count',
        style: BondType.caption.copyWith(
          fontSize: 10,
          height: 1.4,
          color: BondColors.onDarkPrimary,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  /// The account, and everything that is about the app rather than the mail.
  ///
  /// A [PopupMenuButton] and not a pane: these are four rare destinations, and
  /// the no-popups rule is about DIALOGS — a menu that hangs off the control
  /// that opened it takes nothing over and blocks nothing.
  Widget _account() {
    final activity = onActivityLog;
    final address = accountAddress?.trim() ?? '';
    return PopupMenuButton<String>(
      key: accountMenuKey,
      tooltip: 'Account',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.over,
      onSelected: (value) {
        switch (value) {
          case 'settings':
            onSettings();
          case 'activity':
            activity?.call();
          case 'signout':
            onSignOut();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                accountName,
                style: BondType.small,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (address.isNotEmpty)
                Text(
                  address,
                  style: BondType.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          key: settingsItemKey,
          value: 'settings',
          child: Text('Settings'),
        ),
        if (activity != null)
          const PopupMenuItem<String>(
            key: activityItemKey,
            value: 'activity',
            child: Text('Activity log'),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          key: signOutItemKey,
          value: 'signout',
          child: Text('Sign out'),
        ),
      ],
      child: BondAvatar(
        name: accountName,
        address: accountAddress,
        size: 28,
        photoKey: PeopleBackend.self,
        photos: photos,
      ),
    );
  }
}
