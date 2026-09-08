import 'package:flutter/material.dart';

import '../models/attachment_models.dart';
import '../models/files_models.dart';
import '../models/message_models.dart';
import '../models/storyline_models.dart';
import '../services/conversation_state.dart' show stripReFw;
import '../services/profile_photos.dart';
import '../theme/tokens.dart';
import 'attachment_card.dart';
import 'people_rooms.dart';
import 'source_glyph.dart';
import 'time_format.dart';

/// One person, read beside whatever they turned up in.
///
/// It answers the question a name raises and a thread cannot: who is this,
/// how much is live with them, what are we in the middle of, and what have
/// they sent me. Every line of it is derived — from the room, from the
/// storyline members, from the attachments table — because there is no
/// contacts table behind this app and a person is not a stored thing here.
///
/// The lists are the panel's whole content, so they say which state they are
/// in: `Loading…` while the read is out, and a sentence when the answer is
/// genuinely nothing. An empty list drawn as empty space reads as a bug.
class PersonPanelBody extends StatelessWidget {
  /// The room this person is, or null when they have nothing live at all.
  ///
  /// Rooms are derived from the live inbox by construction, so a person whose
  /// only thread is deferred or done has no room — and the honest answer is
  /// that there is nothing going on, not an empty panel.
  final PersonRoom? room;

  /// The storylines their threads belong to, already resolved to titles by the
  /// host. Ids the host could not resolve are simply absent: a `#` with an
  /// opaque id after it names nothing to a reader.
  final List<Storyline> storylines;

  final List<FileRow> files;

  /// Whether the facts read has come back. What separates "still reading" from
  /// "they have sent nothing".
  final bool loaded;

  final DateTime now;
  final ProfilePhotos? photos;
  final ImageProvider? Function(AttachmentRef attachment)? thumbnailFor;

  final void Function(String source, String conversationKey) onOpenThread;
  final void Function(String storylineId) onOpenStoryline;
  final void Function(FileRow row) onOpenFile;

  const PersonPanelBody({
    super.key,
    required this.room,
    required this.storylines,
    required this.files,
    required this.loaded,
    required this.now,
    required this.photos,
    required this.thumbnailFor,
    required this.onOpenThread,
    required this.onOpenStoryline,
    required this.onOpenFile,
  });

  static Key threadKeyFor(String source, String conversationId) =>
      ValueKey('person-thread-$source-$conversationId');

  static Key storylineKeyFor(String storylineId) =>
      ValueKey('person-storyline-$storylineId');

  /// Keyed by the FILE, so the card here and the card in the transcript are
  /// the same file to a test.
  static Key fileKeyFor(FileRow row) => AttachmentCard.keyFor(row.ref);

  /// How many of their files the panel lists.
  ///
  /// A panel and not a shelf: the Files stop is where a whole correspondence
  /// is browsed, and thirty is already more than anybody scrolls in a 420px
  /// column beside a thread.
  static const int _fileCap = 30;

  @override
  Widget build(BuildContext context) {
    final r = room;
    if (r == null) {
      return Padding(
        padding: const EdgeInsets.all(BondSpacing.s16),
        child: Text(
          'Nothing live with this person right now.',
          style: BondType.small,
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        BondSpacing.s16,
        BondSpacing.s12,
        BondSpacing.s16,
        BondSpacing.s24,
      ),
      children: [
        ..._identity(r),
        const SizedBox(height: BondSpacing.s16),
        _label('STORYLINES'),
        ..._storylines(),
        const SizedBox(height: BondSpacing.s16),
        _label('THREADS'),
        ..._threads(r),
        const SizedBox(height: BondSpacing.s16),
        _label('FILES'),
        ..._files(),
      ],
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: BondSpacing.s4),
        child: Text(text, style: BondType.label),
      );

  /// Who they are, how much is live, and when they were last heard from.
  ///
  /// A `teams:` address is hidden rather than shown: it is a Graph id, it
  /// means nothing to a reader, and it cannot be written to.
  List<Widget> _identity(PersonRoom room) {
    final threads = room.threads.length;
    final mail = room.threads.where((t) => t.source != 'teams').length;
    final chats = threads - mail;
    final counts = <String>[
      threads == 1 ? '1 thread' : '$threads threads',
      if (mail > 0) mail == 1 ? '1 mail' : '$mail mail',
      if (chats > 0) chats == 1 ? '1 chat' : '$chats chats',
      if (room.needsYou > 0) '${room.needsYou} need you',
    ];
    final lastSeen = relativeTime(room.latestAt, now);

    return [
      for (final person in room.people) ...[
        Text(
          person.display,
          style: BondType.body.copyWith(fontWeight: FontWeight.w600),
        ),
        if (_writableAddress(person.email) != null)
          Text(_writableAddress(person.email)!, style: BondType.caption),
        const SizedBox(height: BondSpacing.s4),
      ],
      Text(counts.join(' · '), style: BondType.small),
      if (lastSeen != null) Text('Last seen $lastSeen', style: BondType.caption),
    ];
  }

  String? _writableAddress(String? email) {
    final address = email?.trim() ?? '';
    if (address.isEmpty || address.startsWith('teams:')) return null;
    return address;
  }

  List<Widget> _storylines() {
    if (!loaded) return [Text('Loading…', style: BondType.small)];
    if (storylines.isEmpty) {
      return [Text('In no storyline.', style: BondType.small)];
    }
    return [
      for (final storyline in storylines)
        _quietButton(
          key: storylineKeyFor(storyline.id),
          label: '# ${storyline.title}',
          onTap: () => onOpenStoryline(storyline.id),
        ),
    ];
  }

  /// Every live thread with them, newest first — the same list the room draws,
  /// as one line each. It is here so the panel is useful beside a THREAD as
  /// well as beside the room: from a conversation, this is the way to the rest
  /// of what is going on with the person on it.
  List<Widget> _threads(PersonRoom room) {
    if (room.threads.isEmpty) {
      return [Text('Nothing live with them.', style: BondType.small)];
    }
    return [
      for (final thread in room.threads)
        _quietButton(
          key: threadKeyFor(thread.source, thread.id),
          label: withSourceGlyph(thread.source, _threadLabel(thread)),
          onTap: () => onOpenThread(thread.source, thread.id),
        ),
    ];
  }

  String _threadLabel(Conversation thread) {
    final subject = stripReFw(thread.subject);
    if (subject.isNotEmpty) return subject;
    final who = [
      for (final p in thread.participants)
        if (p.display.isNotEmpty) p.display,
    ].join(', ');
    return who.isEmpty ? '(no subject)' : who;
  }

  List<Widget> _files() {
    if (!loaded) return [Text('Loading…', style: BondType.small)];
    if (files.isEmpty) {
      return [Text('No files from them.', style: BondType.small)];
    }
    final shown = files.length <= _fileCap ? files : files.sublist(0, _fileCap);
    return [
      Wrap(
        spacing: BondSpacing.s8,
        runSpacing: BondSpacing.s8,
        children: [
          for (final row in shown)
            AttachmentCard(
              key: fileKeyFor(row),
              attachment: row.ref,
              compact: true,
              image: thumbnailFor?.call(row.ref),
              onTap: () => onOpenFile(row),
            ),
        ],
      ),
    ];
  }

  Widget _quietButton({
    required Key key,
    required String label,
    required VoidCallback onTap,
  }) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        key: key,
        onPressed: onTap,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s4),
          minimumSize: const Size(0, 28),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          alignment: Alignment.centerLeft,
        ),
        child: Text(
          label,
          style: BondType.small,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
