import 'package:flutter/material.dart';

import '../models/people_sort.dart';
import '../services/profile_photos.dart';
import '../theme/tokens.dart';
import 'bond_avatar.dart';
import 'chips.dart';
import 'filter_field.dart';
import 'people_rooms.dart';
import 'sort_menu.dart';
import 'source_glyph.dart';
import 'time_format.dart';

/// Everyone the mailbox knows, one row each — the People stop's main pane when
/// no person is open.
///
/// It replaced a flat list of unclaimed threads, which was the same rows the
/// rail was already grouping into rooms, ungrouped. On a stop whose whole
/// claim is that a PERSON is the unit, a list of threads was the one thing
/// that could not be it: two rows for one colleague, and no way to see how
/// much of the mailbox they account for.
///
/// A row opens the person's room in MAIN rather than beside — the rail's
/// People row does the same, and a directory is a way in rather than a pile
/// being worked through.
class PeopleDirectoryPane extends StatelessWidget {
  /// As [peopleRooms] handed them: recency order, every person, every thread.
  final List<PersonRoom> rooms;

  final PeopleFilter filter;
  final ValueChanged<PeopleFilter> onFilter;

  final PeopleSort sort;
  final ValueChanged<PeopleSort> onSort;

  final TextEditingController searchController;
  final ValueChanged<String> onSearch;

  /// Normalised by the host, so the pane and the row it lights measure the
  /// same needle.
  final String needle;

  final DateTime now;
  final ProfilePhotos? photos;

  /// The room key of the row that was tapped.
  final ValueChanged<String> onOpen;

  /// The host's scope notice — which half of the mailbox a source pill has the
  /// pane narrowed to. Drawn under the empty line, where an empty directory
  /// would otherwise read as "nobody" when the truth is "nobody on Teams".
  final Widget? emptyNotice;

  const PeopleDirectoryPane({
    super.key,
    required this.rooms,
    required this.filter,
    required this.onFilter,
    required this.sort,
    required this.onSort,
    required this.searchController,
    required this.onSearch,
    required this.needle,
    required this.now,
    required this.photos,
    required this.onOpen,
    this.emptyNotice,
  });

  static const Key filterPillsKey = ValueKey('people-filter');
  static const Key sortKey = ValueKey('people-sort');
  static const Key emptyKey = ValueKey('people-empty');

  static Key rowKeyFor(String roomKey) => ValueKey('people-row-$roomKey');

  static Key sortItemKeyFor(PeopleSort s) => Key('people-sort-${s.name}');

  @override
  Widget build(BuildContext context) {
    final shown = sortRooms(sort, filterRooms(rooms, filter, needle));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilterField(
          controller: searchController,
          onChanged: onSearch,
          hint: 'Filter people…',
        ),
        const SizedBox(height: BondSpacing.s12),
        Row(
          // The pills wrap on a narrow pane, and the control belongs with
          // their FIRST line rather than centred against however many there
          // turned out to be.
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: BondFilterPillRow<PeopleFilter>(
                key: filterPillsKey,
                options: PeopleFilter.values,
                selected: filter,
                labelOf: (f) => f.label,
                onSelected: onFilter,
              ),
            ),
            const SizedBox(width: BondSpacing.s8),
            SortMenu<PeopleSort>(
              key: sortKey,
              value: sort,
              options: PeopleSort.values,
              labelOf: (s) => s.label,
              itemKeyFor: sortItemKeyFor,
              onChanged: onSort,
            ),
          ],
        ),
        const SizedBox(height: BondSpacing.s12),
        Expanded(
          child: shown.isEmpty
              ? _empty()
              : ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (_, i) => _PersonRow(
                    key: rowKeyFor(shown[i].key),
                    room: shown[i],
                    now: now,
                    photos: photos,
                    onTap: () => onOpen(shown[i].key),
                  ),
                ),
        ),
      ],
    );
  }

  /// Two different empties, said differently. A directory that was never going
  /// to have anybody in it and one the reader just narrowed to nothing are not
  /// the same news, and one sentence for both would send somebody looking for
  /// a sync problem that is really an × away.
  Widget _empty() {
    final narrowed = rooms.isNotEmpty;
    final notice = emptyNotice;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            narrowed ? 'Nobody matches.' : 'Nobody here yet.',
            key: emptyKey,
            style: BondType.small,
          ),
          if (notice != null) ...[
            const SizedBox(height: BondSpacing.s8),
            notice,
          ],
        ],
      ),
    );
  }
}

/// One person: their face, their name, how much of the mailbox they are, and
/// when they were last heard from.
class _PersonRow extends StatelessWidget {
  final PersonRoom room;
  final DateTime now;
  final ProfilePhotos? photos;
  final VoidCallback onTap;

  const _PersonRow({
    super.key,
    required this.room,
    required this.now,
    required this.photos,
    required this.onTap,
  });

  /// `N threads · M mail · K chats`, plus what is owed. The zero half is left
  /// out rather than written as `0 chats`, which is a number nobody asked for.
  String get _caption {
    final threads = room.threads.length;
    final mail = room.threads.where((t) => t.source != 'teams').length;
    final chats = threads - mail;
    final parts = <String>[
      threads == 1 ? '1 thread' : '$threads threads',
      if (mail > 0) mail == 1 ? '1 mail' : '$mail mail',
      if (chats > 0) chats == 1 ? '1 chat' : '$chats chats',
      if (room.needsYou > 0) '${room.needsYou} need you',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final person = room.people.isEmpty ? null : room.people.first;
    // Only when every thread came from one connector. A person on both would
    // otherwise be marked as whichever the newest thread happened to be, which
    // is a mark that changes when nothing about them did — the rail's rule.
    final title = room.sources.length == 1
        ? withSourceGlyph(room.sources.first, room.title)
        : room.title;
    final last = relativeTime(room.latestAt, now);

    return Material(
      color: BondColors.surface,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: BondSpacing.s12,
            vertical: BondSpacing.s8,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Row(
              children: [
                BondAvatar(
                  name: person?.display ?? room.title,
                  address: person?.email,
                  size: 36,
                  photoKey: photoKeyFor(address: person?.email),
                  photos: photos,
                ),
                const SizedBox(width: BondSpacing.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: BondType.body.copyWith(
                          // Bold is unread, here as everywhere else.
                          fontWeight: room.unread > 0
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _caption,
                        style: BondType.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (last != null) ...[
                  const SizedBox(width: BondSpacing.s8),
                  Text(last, style: BondType.caption),
                ],
                if (room.needsYou > 0) ...[
                  const SizedBox(width: BondSpacing.s8),
                  _badge(room.needsYou),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The needs-you count, in the attention red. `surface` for the digit
  /// because there is no on-solid-red token: `onErrorTint` is the ink for the
  /// pale tint, and it is unreadable on the solid.
  Widget _badge(int count) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: BondSpacing.s4,
          vertical: 1,
        ),
        decoration: const BoxDecoration(
          color: BondColors.error,
          borderRadius: BondRadii.smAll,
        ),
        child: Text(
          '$count',
          style: BondType.caption.copyWith(
            color: BondColors.surface,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}
