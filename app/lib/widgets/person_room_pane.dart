import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../models/people_sort.dart';
import '../services/conversation_state.dart' show stripReFw;
import '../services/profile_photos.dart';
import '../theme/tokens.dart';
import 'bond_avatar.dart';
import 'chips.dart';
import 'filter_field.dart';
import 'inline_alert.dart';
import 'people_rooms.dart';
import 'sort_menu.dart';
import 'source_glyph.dart';
import 'time_format.dart';

/// The room's newest mail thread, or null when the reader has only ever
/// chatted with them. What `Message` writes a new mail into when there is no
/// direct chat to put it in.
Conversation? newestMailThread(PersonRoom room) {
  for (final thread in room.threads) {
    if (thread.source != 'teams') return thread;
  }
  return null;
}

/// The person's newest 1:1 Teams chat, or null when there is none.
///
/// Direct and not merely "a chat they are on": a sentence typed at the header
/// of one person's room is addressed to that person, and dropping it into a
/// nine-way project chat because it was the newest thing they said something
/// in is the wrong room to be loud in.
Conversation? directChat(PersonRoom room) {
  // `room.threads` arrives newest first, so the first hit IS the newest.
  for (final thread in room.threads) {
    if (thread.source != 'teams') continue;
    if (!room.direct.contains(
      (source: thread.source, conversationKey: thread.id),
    )) {
      continue;
    }
    return thread;
  }
  return null;
}

/// The line under the room's name: how much there is with them, on which
/// connectors, and how much of it is finished or put off.
///
/// Both connectors named where both are present, because that IS the room's
/// claim — one row standing for one person however they reach this mailbox —
/// and a glyph would have to pick one. The done tail is here because the room
/// now HOLDS closed threads: a count that jumped when a thread was marked done
/// would have the reader hunting for mail that never left.
String roomSubtitle(PersonRoom room) {
  final count = room.threads.length;
  final threads = count == 1 ? '1 thread' : '$count threads';
  final mail = room.sources.any((s) => s != 'teams');
  final teams = room.sources.contains('teams');
  final where = switch ((mail, teams)) {
    (true, true) => 'mail and Teams',
    (true, false) => 'mail',
    (false, true) => 'Teams',
    _ => null,
  };
  final done = room.threads
      .where((t) => t.state == ConversationState.done)
      .length;
  // Deferred counted apart from done: a thread in Later is coming back, and
  // a reader who put it there wants to know it is still in the room.
  final later = room.threads
      .where((t) => t.state != ConversationState.done && t.bucket == 'later')
      .length;
  return [
    threads,
    ?where,
    if (done > 0) '$done done',
    if (later > 0) '$later later',
  ].join(' · ');
}

/// How many companions a card spells out before it counts the rest.
///
/// Three, the same as everywhere else in this app that has to name a handful
/// of people on one line. A fourth name would push the subject off a card in
/// a 420px panel, and `+2` says the same thing in two characters.
const int _maxWithNames = 3;

/// `with Ada Sun, Bo Vance` — who ELSE was on a thread, or null when nobody
/// was.
///
/// The line exists because one thread with three other parties is now in
/// three rooms under the same subject: without it a reader in Ada's room and
/// a reader in Bo's see identical cards, and neither is told the conversation
/// had a third person in it. Null and not an empty string, so a direct thread
/// draws no line rather than an empty one.
String? withLine(List<String> names) {
  final people = [
    for (final n in names)
      if (n.trim().isNotEmpty) n.trim(),
  ];
  if (people.isEmpty) return null;
  if (people.length <= _maxWithNames) return 'with ${people.join(', ')}';
  final rest = people.length - _maxWithNames;
  return 'with ${people.take(_maxWithNames).join(', ')} +$rest';
}

/// One thread, standing for itself in a person's room.
///
/// Everything a reader needs to decide whether to open it and nothing else:
/// who, what it is called, what it last said, what it is asking, how big it is
/// and whether it is still going. It is deliberately NOT a `ConversationRow` —
/// that row lives in a 260px column and is a navigation target, while this sits
/// in the reading column and has to hold its own there.
class RootMessageCard extends StatelessWidget {
  final Conversation conversation;
  final DateTime now;
  final ProfilePhotos? photos;
  final VoidCallback onOpen;

  /// Who else was on it, already phrased by [withLine]. Null on a direct
  /// thread, which draws no line at all.
  final String? withLine;

  const RootMessageCard({
    super.key,
    required this.conversation,
    required this.now,
    required this.photos,
    required this.onOpen,
    this.withLine,
  });

  static Key keyFor(String source, String conversationId) =>
      ValueKey('root-card-$source-$conversationId');

  /// What a subjectless card falls back to for its title.
  ///
  /// A mail thread has a sender and uses them. A CHAT does not — its messages
  /// come from everyone in it — and it used to spell its whole roster into the
  /// title, which is now the [withLine]'s job: the line under the title names
  /// who else was there, and repeating them in the title said it twice and
  /// pushed everything else off the row.
  String get _who {
    final c = conversation;
    if (c.source == 'teams') return 'Chat';
    return c.primaryParticipant?.display ?? noSenderRoom;
  }

  /// `Done · ` or `Later · ` in front of the count line.
  ///
  /// The room holds closed and deferred threads now, so every card has to say
  /// which it is: an unmarked done thread in a list of live ones is a thread
  /// the reader answers twice.
  String get _statePrefix {
    if (conversation.state == ConversationState.done) return 'Done · ';
    if (conversation.bucket == 'later') return 'Later · ';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final c = conversation;
    final who = _who;
    final subject = stripReFw(c.subject);
    final title = withSourceGlyph(
      c.source,
      subject.isEmpty ? who : subject,
    );
    final preview = c.lastMessagePreview?.trim() ?? '';
    final cta = c.ctaText?.trim() ?? '';
    final last = relativeTime(c.lastMessageAt, now);
    final count =
        c.messageCount == 1 ? '1 message' : '${c.messageCount} messages';
    final tail = last == null ? count : '$count · last $last';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: BondSpacing.s4),
      decoration: BoxDecoration(
        borderRadius: BondRadii.smAll,
        border: Border.all(color: BondColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: BondColors.surface,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(BondSpacing.s12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                BondAvatar(
                  name: c.primaryParticipant?.name ?? who,
                  address: c.primaryEmail,
                  photoKey: photoKeyFor(address: c.primaryEmail),
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
                          fontWeight: c.hasUnread
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (withLine != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          withLine!,
                          style: BondType.caption.copyWith(
                            color: BondColors.inkSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (preview.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          // A chat's preview stands alone: its messages come
                          // from everyone in it, so `who · line` would name
                          // the wrong person as the one who said it.
                          c.source == 'teams' ? preview : '$who · $preview',
                          style: BondType.caption,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (cta.isNotEmpty) ...[
                        const SizedBox(height: BondSpacing.s8),
                        InlineAlert(
                          severity: InlineAlertSeverity.attention,
                          text: cta,
                          maxLines: 2,
                        ),
                      ],
                      const SizedBox(height: BondSpacing.s8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '$_statePrefix$tail',
                              style: BondType.caption,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: BondSpacing.s8),
                          Text('open ›', style: BondType.caption),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One person, every thread — 1:1 or in a group, mail or Teams — in one
/// filterable list.
///
/// Goal one of this whole round, literally: a colleague who mails and chats
/// has ONE place here rather than two piles the reader merges in their head,
/// and a thread they were on with four other people is under their name too.
///
/// Every thread is a CARD, and a card opens the conversation BESIDE the room
/// (D3) with its own composer, its own files and its own menu. The pane
/// deliberately renders no transcript of its own: a room that drew some
/// conversations inline and summarised the rest was a list whose rows meant
/// two different things, and the merged timeline it needed had the newest row
/// pinned to the bottom of a `reverse: true` list — which left a person with
/// three threads reading as a gap with three cards under it.
///
/// Top-anchored and newest first, with the reader's own order and their own
/// needle over it.
class PersonRoomPane extends StatelessWidget {
  final PersonRoom room;

  final RoomFilter filter;
  final ValueChanged<RoomFilter> onFilter;

  final RoomSort sort;
  final ValueChanged<RoomSort> onSort;

  final TextEditingController searchController;
  final ValueChanged<String> onSearch;

  /// Normalised by the host, so this pane and the directory measure the same
  /// needle the same way.
  final String needle;

  final DateTime now;
  final ProfilePhotos? photos;

  /// Opens one of the room's threads beside the room, D3's rule: the room the
  /// reader came from stays on screen.
  final void Function(String source, String conversationKey) onOpenThread;

  /// The host's scope notice — see [PeopleDirectoryPane].
  final Widget? emptyNotice;

  const PersonRoomPane({
    super.key,
    required this.room,
    required this.filter,
    required this.onFilter,
    required this.sort,
    required this.onSort,
    required this.searchController,
    required this.onSearch,
    required this.needle,
    required this.now,
    required this.photos,
    required this.onOpenThread,
    this.emptyNotice,
  });

  static const Key listKey = ValueKey('person-room-list');
  static const Key emptyKey = ValueKey('person-room-empty');
  static const Key filterPillsKey = ValueKey('room-filter');
  static const Key sortKey = ValueKey('room-sort');

  static Key sortItemKeyFor(RoomSort s) => Key('room-sort-${s.name}');

  @override
  Widget build(BuildContext context) {
    final shown = sortRoomThreads(
      sort,
      filterRoomThreads(room, filter, needle),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilterField(
          controller: searchController,
          onChanged: onSearch,
          hint: 'Filter threads…',
        ),
        const SizedBox(height: BondSpacing.s12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: BondFilterPillRow<RoomFilter>(
                key: filterPillsKey,
                options: RoomFilter.values,
                selected: filter,
                labelOf: (f) => f.label,
                onSelected: onFilter,
              ),
            ),
            const SizedBox(width: BondSpacing.s8),
            SortMenu<RoomSort>(
              key: sortKey,
              value: sort,
              options: RoomSort.values,
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
              : ListView(
                  key: listKey,
                  padding: const EdgeInsets.only(bottom: BondSpacing.s8),
                  children: [
                    for (final thread in shown)
                      RootMessageCard(
                        key: RootMessageCard.keyFor(thread.source, thread.id),
                        conversation: thread,
                        now: now,
                        photos: photos,
                        withLine: withLine(
                          room.companions[(
                                source: thread.source,
                                conversationKey: thread.id,
                              )] ??
                              const [],
                        ),
                        onOpen: () =>
                            onOpenThread(thread.source, thread.id),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  /// A room with nobody in it and a room the reader just narrowed to nothing
  /// are not the same news — [PeopleDirectoryPane]'s rule, said about threads.
  Widget _empty() {
    final narrowed = room.threads.isNotEmpty;
    final notice = emptyNotice;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            narrowed ? 'Nothing matches.' : 'No threads with them.',
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
