import 'package:flutter/material.dart';

import '../models/attachment_models.dart';
import '../models/message_models.dart';
import '../providers/conversations_provider.dart' show ThreadTarget;
import '../providers/draft_provider.dart' show DraftTarget;
import '../services/conversation_state.dart' show stripReFw;
import '../services/profile_photos.dart';
import '../theme/tokens.dart';
import 'bond_avatar.dart';
import 'inline_alert.dart';
import 'message_row.dart';
import 'people_rooms.dart';
import 'source_glyph.dart';
import 'time_format.dart';

/// How many of a room's chats are drawn as messages rather than as cards.
///
/// A cap and not a scroll budget: every inline chat is a transcript this pane
/// asks the store for, and a person the reader talks to constantly would
/// otherwise open with a dozen loads in flight. Five is what fits above the
/// fold on the widest window this app is used on; the rest are still here, as
/// cards, one tap from their own transcript.
const int roomChatCap = 5;

/// The chats whose MESSAGES are drawn inline: the newest [roomChatCap] of them.
///
/// Chats and not mail, because a chat has no subject and no thread to open —
/// its messages ARE the conversation, and a card standing for one would say
/// nothing a person could read. A mail thread has a subject and a shape, and
/// summarising it is what a card is for.
List<Conversation> roomChats(PersonRoom room) {
  final chats = [
    for (final thread in room.threads)
      if (thread.source == 'teams') thread,
  ];
  // `room.threads` arrives newest first, so the head IS the newest few.
  return chats.length <= roomChatCap ? chats : chats.sublist(0, roomChatCap);
}

/// The chat the room's docked composer writes into, or null when there is none
/// to write into.
///
/// One person and a chat with them means a 1:1 chat by construction: a group
/// chat's room key spells out several names, so a one-name room's Teams thread
/// can only be the two of them. Anything else — a group, a person the reader
/// has only ever mailed — gets no box, because there is no single thread a
/// typed sentence would obviously belong to.
ThreadTarget? roomComposerTarget(PersonRoom room) {
  if (room.people.length != 1) return null;
  final chats = roomChats(room);
  if (chats.isEmpty) return null;
  final newest = chats.first;
  return (source: newest.source, conversationKey: newest.id);
}

/// The room's newest mail thread, or null when the reader has only ever
/// chatted with them. What the `Message …` button writes a new mail into.
Conversation? newestMailThread(PersonRoom room) {
  for (final thread in room.threads) {
    if (thread.source != 'teams') return thread;
  }
  return null;
}

/// The line under the room's name: how much is live, and on which connectors.
///
/// Both connectors named where both are present, because that IS the room's
/// claim — one row standing for one person however they reach this mailbox —
/// and a glyph would have to pick one.
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
  return where == null ? threads : '$threads · $where';
}

/// One row of a person's timeline.
///
/// Sealed because the pane switches on it exhaustively: a fourth kind added
/// without a row to draw it would be a compile error rather than a hole in the
/// middle of somebody's history.
sealed class RoomItem {
  const RoomItem();

  /// When this row happened, as the stored ISO stamp. Null sorts oldest — a
  /// row nobody can date belongs at the top, where it is out of the way of the
  /// conversation.
  String? get at;
}

/// A mail thread, summarised. Its transcript opens beside.
class RoomCardItem extends RoomItem {
  final Conversation conversation;

  const RoomCardItem(this.conversation);

  @override
  String? get at => conversation.lastMessageAt;
}

/// The caption above a run of chat messages, saying which chat they are.
///
/// Drawn before every run rather than once per chat: two chats with the same
/// person interleave by time, and a run that started under somebody else's
/// heading would be read as part of that conversation.
class RoomChatHeaderItem extends RoomItem {
  final Conversation chat;

  @override
  final String? at;

  const RoomChatHeaderItem(this.chat, this.at);
}

/// One chat message, drawn as itself.
class RoomMessageItem extends RoomItem {
  final Conversation chat;
  final Message message;

  const RoomMessageItem(this.chat, this.message);

  @override
  String? get at => message.receivedAt;
}

/// Everything live with one person, oldest first.
///
/// The merge is the point of the whole pane: a mail thread that landed between
/// two chat messages is DRAWN between them, because that is the order the
/// reader lived through and any other order makes them reconstruct it.
///
/// A chat whose transcript has not arrived is a card until it does, so the
/// room never has a hole where a conversation should be — and a chat past the
/// cap is a card for good.
///
/// Sorting is stable by construction: Dart's sort is not, so the atoms carry
/// their discovery index and use it as the tie-break rather than trusting the
/// implementation.
List<RoomItem> roomTimeline(
  PersonRoom room,
  Map<ThreadTarget, List<Message>> chats,
) {
  final inline = {for (final chat in roomChats(room)) chat.id};

  final atoms = <(int, RoomItem)>[];
  var index = 0;
  for (final thread in room.threads) {
    final target = (source: thread.source, conversationKey: thread.id);
    final messages = inline.contains(thread.id) && thread.source == 'teams'
        ? chats[target]
        : null;
    if (messages == null || messages.isEmpty) {
      atoms.add((index++, RoomCardItem(thread)));
      continue;
    }
    for (final message in messages) {
      atoms.add((index++, RoomMessageItem(thread, message)));
    }
  }

  atoms.sort((a, b) {
    final byTime = _oldestFirst(a.$2.at, b.$2.at);
    if (byTime != 0) return byTime;
    return a.$1.compareTo(b.$1);
  });

  // The heading goes in on the walk rather than with the atoms, because
  // whether a run needs one depends on what ended up in front of it.
  final items = <RoomItem>[];
  RoomItem? previous;
  for (final (_, item) in atoms) {
    if (item is RoomMessageItem) {
      final continues = previous is RoomMessageItem &&
          previous.chat.id == item.chat.id &&
          previous.chat.source == item.chat.source;
      if (!continues) items.add(RoomChatHeaderItem(item.chat, item.at));
    }
    items.add(item);
    previous = item;
  }
  return items;
}

/// Oldest first, with unstamped rows treated as the oldest of all.
int _oldestFirst(String? a, String? b) {
  if (a == b) return 0;
  if (a == null) return -1;
  if (b == null) return 1;
  return a.compareTo(b);
}

/// One mail thread, standing for itself in a person's timeline.
///
/// Everything a reader needs to decide whether to open it and nothing else:
/// who, what it is called, what it last said, what it is asking, and how big
/// it is. It is deliberately NOT a `ConversationRow` — that row lives in a
/// 260px column and is a navigation target, while this sits in the reading
/// column beside real messages and has to hold its own against them.
class RootMessageCard extends StatelessWidget {
  final Conversation conversation;
  final DateTime now;
  final ProfilePhotos? photos;
  final VoidCallback onOpen;

  const RootMessageCard({
    super.key,
    required this.conversation,
    required this.now,
    required this.photos,
    required this.onOpen,
  });

  static Key keyFor(String source, String conversationId) =>
      ValueKey('root-card-$source-$conversationId');

  @override
  Widget build(BuildContext context) {
    final c = conversation;
    final who = c.primaryParticipant?.display ?? '(no sender)';
    final subject = stripReFw(c.subject);
    final title = withSourceGlyph(
      c.source,
      subject.isEmpty ? who : subject,
    );
    final preview = c.lastMessagePreview?.trim() ?? '';
    final cta = c.ctaText?.trim() ?? '';
    final last = relativeTime(c.lastMessageAt, now);
    final count = c.messageCount == 1 ? '1 message' : '${c.messageCount} messages';

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
                      if (preview.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          '$who · $preview',
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
                              last == null ? count : '$count · last $last',
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

/// One person, and everything live with them, in one column.
///
/// Goal one of this whole round, literally: a colleague who mails and chats
/// has ONE history here rather than two piles the reader merges in their head.
/// Chat messages read as messages, mail threads read as cards, and the two are
/// interleaved by time.
///
/// Newest at the BOTTOM and the list reversed, which is the chat convention
/// and the reason for it: the newest thing is what the room is about, and it
/// should be on screen the moment the room opens without anybody scrolling.
class PersonRoomPane extends StatelessWidget {
  final PersonRoom room;

  /// The transcripts that have arrived, by thread. A chat missing from here is
  /// drawn as a card — never as a gap.
  final Map<ThreadTarget, List<Message>> chats;

  final DateTime now;
  final ProfilePhotos? photos;
  final ImageProvider? Function(AttachmentRef attachment)? thumbnailFor;

  /// Opens one of the room's threads beside the room, D3's rule: the room the
  /// reader came from stays on screen.
  final void Function(String source, String conversationKey) onOpenThread;

  /// A file from an inline chat message. The thread it came from rides along,
  /// because that is what 'Use in reply' writes into and what a pin resolves
  /// its storyline through.
  final void Function(AttachmentRef attachment, DraftTarget from)
      onOpenAttachment;

  final void Function(String url)? onOpenLink;

  /// Draws the `Message …` button under the list. Non-null only where there is
  /// no docked composer — a room with a chat gets a box, and a mail-only room
  /// gets the button, and never both.
  final VoidCallback? onMessage;

  const PersonRoomPane({
    super.key,
    required this.room,
    required this.chats,
    required this.now,
    required this.photos,
    required this.thumbnailFor,
    required this.onOpenThread,
    required this.onOpenAttachment,
    this.onOpenLink,
    this.onMessage,
  });

  static const Key listKey = ValueKey('person-room-list');
  static const Key messageButtonKey = ValueKey('person-room-message');
  static const Key emptyKey = ValueKey('person-room-empty');

  static Key openChatKeyFor(String conversationKey) =>
      ValueKey('person-room-open-chat-$conversationKey');

  @override
  Widget build(BuildContext context) {
    final items = roomTimeline(room, chats);
    final button = onMessage;

    if (items.isEmpty) {
      return Center(
        child: Text(
          'No live threads with them.',
          key: emptyKey,
          style: BondType.small,
        ),
      );
    }

    // Built oldest-first with its dividers in place, then handed to a reversed
    // list: `reverse: true` starts the viewport at the END of the child list,
    // so the newest row is the one on screen.
    final rows = <Widget>[];
    String? previousDay;
    for (final item in items) {
      final day = dayKeyOfIso(item.at);
      final label = formatDayLabel(item.at);
      if (label != null && day != previousDay) {
        rows.add(DayDivider(label: label));
        previousDay = day;
      }
      rows.add(_row(item));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            key: listKey,
            reverse: true,
            padding: const EdgeInsets.only(bottom: BondSpacing.s8),
            children: rows.reversed.toList(),
          ),
        ),
        if (button != null) ...[
          const SizedBox(height: BondSpacing.s12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: messageButtonKey,
              onPressed: button,
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: Text('Message ${room.title}'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _row(RoomItem item) => switch (item) {
        RoomCardItem(:final conversation) => RootMessageCard(
            key: RootMessageCard.keyFor(conversation.source, conversation.id),
            conversation: conversation,
            now: now,
            photos: photos,
            onOpen: () => onOpenThread(conversation.source, conversation.id),
          ),
        RoomChatHeaderItem(:final chat) => _chatHeader(chat),
        RoomMessageItem(:final chat, :final message) => MessageRow(
            key: ValueKey('${chat.id}-${message.id}'),
            message: message,
            photos: photos,
            thumbnailFor: thumbnailFor,
            onOpenAttachment: (attachment) => onOpenAttachment(
              attachment,
              (source: chat.source, conversationKey: chat.id),
            ),
            onOpenLink: onOpenLink,
          ),
      };

  /// Which chat the run below belongs to, and the way into it.
  ///
  /// The way in matters even though the messages are already here: the chat's
  /// own pane is where the composer, the files tab and the thread menu live,
  /// and this pane deliberately offers none of them per chat.
  Widget _chatHeader(Conversation chat) {
    final who = chat.participants
        .map((p) => p.display)
        .where((d) => d.isNotEmpty)
        .join(', ');
    final subject = stripReFw(chat.subject);
    final name = subject.isNotEmpty ? subject : (who.isEmpty ? 'Chat' : who);
    return Padding(
      padding: const EdgeInsets.only(top: BondSpacing.s12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$teamsGlyph $name',
              style: BondType.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            key: openChatKeyFor(chat.id),
            onPressed: () => onOpenThread(chat.source, chat.id),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s8),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: BondType.caption,
            ),
            child: const Text('Open chat ›'),
          ),
        ],
      ),
    );
  }
}
