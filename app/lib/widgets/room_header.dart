import 'package:flutter/material.dart';

import '../services/profile_photos.dart';
import '../theme/tokens.dart';
import 'bond_avatar.dart';
import 'chips.dart';

/// One thing a room's header can do, drawn as an icon button (tooltip =
/// [label]) when [icon] is given and as a quiet text button labelled [label]
/// otherwise.
///
/// Which of the two a call site picks is a width decision and nothing else: an
/// icon costs a fixed 20px wherever the header is squeezed beside a split, and
/// a word is worth its width only when the reader would otherwise have to
/// guess what the picture meant.
class RoomAction {
  final IconData? icon;
  final String label;
  final VoidCallback? onTap;
  final Key? key;

  const RoomAction({
    this.icon,
    required this.label,
    this.onTap,
    this.key,
  });
}

/// One entry in the ⋯ menu. [value] is the `PopupMenuItem` value, which is
/// also how a test names the item it means. A null [onTap] renders the item
/// disabled — a label like 'Syncing…' is a statement, not an offer.
class RoomMenuItem {
  final String value;
  final String label;
  final VoidCallback? onTap;

  /// Draws a divider above this item, for a group that means something
  /// different from the one before it.
  final bool dividerBefore;

  const RoomMenuItem({
    required this.value,
    required this.label,
    this.onTap,
    this.dividerBefore = false,
  });
}

/// The header every room wears: what this room IS, and what can be done to it.
///
/// A thread and a storyline each grew their own header, and the two of them
/// disagreed about where things go — one put its overflow behind a ⋯ and the
/// other spread seven quiet buttons across two lines, so a user who learned
/// one screen had learned nothing about the next. Slack's rule settles it: the
/// header is the room's identity plus what you can do to the ROOM, the ⋯ holds
/// the corrections, and anything about one message lives on that message.
///
/// [T] is the tab vocabulary. A room with fewer than two tabs draws no tab row
/// at all — one pill is a label pretending to be a choice.
class RoomHeader<T> extends StatelessWidget {
  /// Drawn before the title — `#` for a storyline, nothing for a thread.
  final Widget? leading;

  /// A `Text` for a thread; the tap-to-rename field for a storyline. Passed as
  /// a widget because the header has no business knowing which.
  final Widget title;

  final String? subtitle;

  /// The faces beside the title. Empty draws no stack rather than an empty
  /// gap.
  final List<AvatarPerson> people;

  final ProfilePhotos? photos;

  final Widget? stateChip;

  /// Null hides the Back affordance, for a room that was not navigated into.
  final VoidCallback? onBack;

  final List<RoomAction> actions;

  /// The ⋯ menu's contents. Empty hides the button — a menu with nothing in it
  /// is a control that answers nothing.
  final List<RoomMenuItem> moreItems;

  /// What tapping the faces does — open the person beside the room, the way
  /// tapping a face does in every chat app the reader already has. Null leaves
  /// the stack a picture, with no `InkWell` in the tree at all: a control that
  /// answers nothing must not look like one.
  final VoidCallback? onPeopleTap;

  final List<T> tabs;
  final T? selectedTab;
  final String Function(T)? tabLabel;
  final ValueChanged<T>? onTab;

  static const Key moreKey = ValueKey('room-header-more');

  static const Key peopleKey = ValueKey('room-header-people');

  static Key tabKey(Object value) => ValueKey('room-tab-$value');

  /// Below this much room, the header gives ground — and it gives it in this
  /// order.
  ///
  /// **The faces come off first.** Everything else on this row answers a
  /// question the reader asked — the title, the state, the actions — while the
  /// stack is a picture of people the subtitle has already named.
  ///
  /// **Then a LABELLED action folds into the ⋯ menu**, at the top of it. An
  /// action with an icon costs the same 52 pixels whatever it says, because
  /// its words are a tooltip; an action with a label costs whatever its words
  /// are, which in a side panel makes it the single widest thing on a row of
  /// controls. The ⋯ is already there and already holds this room's other
  /// whole-conversation verbs, so folding hides nothing — where the
  /// alternative, once a room grew a fourth control, is a header that clips
  /// one.
  static const double _facesFrom = 540;

  const RoomHeader({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.people = const [],
    this.photos,
    this.stateChip,
    this.onBack,
    this.onPeopleTap,
    this.actions = const [],
    this.moreItems = const [],
    this.tabs = const [],
    this.selectedTab,
    this.tabLabel,
    this.onTab,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: BondSpacing.s16,
        vertical: BondSpacing.s12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          LayoutBuilder(
            builder: (context, constraints) =>
                _identityRow(roomy: constraints.maxWidth >= _facesFrom),
          ),
          if (tabs.length > 1) ...[
            const SizedBox(height: BondSpacing.s8),
            _tabRow(),
          ],
        ],
      ),
    );
  }

  Widget _identityRow({required bool roomy}) {
    // What stays on the row, and what goes into the menu instead. Both lists
    // are the whole set when there is room, which is the ordinary case.
    final onRow = [
      for (final action in actions)
        if (roomy || action.icon != null) action,
    ];
    final folded = [
      for (final action in actions)
        if (!roomy && action.icon == null)
          RoomMenuItem(
            // Keyed by the label, because a folded action has no `value` of
            // its own and the label is what a reader — and a test — names it
            // by either way.
            value: 'action-${action.label}',
            label: action.label,
            onTap: action.onTap,
          ),
    ];
    final menu = [
      ...folded,
      for (final (index, item) in moreItems.indexed)
        // The first of the room's own items is divided off from what folded
        // in above it: those were controls a moment ago and they are not the
        // same kind of thing as the corrections below them.
        if (index == 0 && folded.isNotEmpty)
          RoomMenuItem(
            value: item.value,
            label: item.label,
            onTap: item.onTap,
            dividerBefore: true,
          )
        else
          item,
    ];

    return Row(
      children: [
        if (onBack != null) ...[
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
            iconSize: 20,
            tooltip: 'Back',
          ),
          const SizedBox(width: BondSpacing.s4),
        ],
        if (leading != null) ...[
          leading!,
          const SizedBox(width: BondSpacing.s4),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              title,
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: BondType.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: BondSpacing.s12),
        if (roomy && people.isNotEmpty) ...[
          _faces(),
          const SizedBox(width: BondSpacing.s8),
        ],
        ?stateChip,
        for (final action in onRow) _action(action),
        if (menu.isNotEmpty) _more(menu),
      ],
    );
  }

  /// The stack, tappable when the host gave it somewhere to go.
  ///
  /// Its own transparent `Material`, because ink paints on the nearest
  /// ancestor — which here is behind the pane's opaque surface, where no
  /// splash could ever show.
  Widget _faces() {
    final stack = AvatarStack(people: people, photos: photos);
    final onTap = onPeopleTap;
    if (onTap == null) return stack;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: peopleKey,
        onTap: onTap,
        borderRadius: BondRadii.fullAll,
        child: Padding(padding: const EdgeInsets.all(2), child: stack),
      ),
    );
  }

  Widget _action(RoomAction action) {
    final icon = action.icon;
    if (icon != null) {
      return Padding(
        padding: const EdgeInsets.only(left: BondSpacing.s4),
        child: IconButton(
          key: action.key,
          onPressed: action.onTap,
          icon: Icon(icon),
          iconSize: 20,
          tooltip: action.label,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: BondSpacing.s4),
      child: TextButton(
        key: action.key,
        onPressed: action.onTap,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s8),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(action.label),
      ),
    );
  }

  /// The corrections drawer. A `PopupMenuButton` and not a pane: the no-popups
  /// rule bans dialogs, and a menu hanging off the button that opened it takes
  /// nothing over — the same reasoning the account menu already runs on.
  Widget _more(List<RoomMenuItem> items) {
    return PopupMenuButton<String>(
      key: moreKey,
      icon: const Icon(Icons.more_horiz),
      iconSize: 20,
      tooltip: 'More',
      itemBuilder: (context) => [
        for (final item in items) ...[
          if (item.dividerBefore) const PopupMenuDivider(),
          PopupMenuItem<String>(
            value: item.value,
            enabled: item.onTap != null,
            child: Text(item.label),
          ),
        ],
      ],
      onSelected: (value) {
        for (final item in items) {
          if (item.value == value) {
            item.onTap?.call();
            return;
          }
        }
      },
    );
  }

  /// Built pill by pill rather than through `BondFilterPillRow`, because each
  /// pill needs its own key: a tab is what a test taps to change what the room
  /// is showing, and a label is not a stable enough handle for that.
  Widget _tabRow() {
    final label = tabLabel;
    return Wrap(
      spacing: BondSpacing.s8,
      runSpacing: BondSpacing.s8,
      children: [
        for (final tab in tabs)
          BondFilterPill(
            key: tabKey(tab as Object),
            label: label == null ? '$tab' : label(tab),
            selected: tab == selectedTab,
            onTap: () => onTab?.call(tab),
          ),
      ],
    );
  }
}
