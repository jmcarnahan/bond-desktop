import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../models/files_models.dart';
import '../widgets/people_rooms.dart';
import 'app_providers.dart';

/// What is known about one person beyond their threads: which storylines they
/// turn up in, and what they have sent.
///
/// A `StateNotifier` and not a family, because a [PersonRoom] is derived in
/// `build` from the live list and is therefore a NEW object on every frame —
/// it cannot be a family key, and a family keyed on the room's string key
/// would still have to be handed the room to read anything. The panel shows
/// one person at a time, so one notifier is enough; [PersonFactsState.roomKey]
/// is what a reader checks before believing the lists belong to the person on
/// screen.
///
/// The rule every list in this app shares: **stamp before the first await**. A
/// read started for one person can land after the reader has moved to another,
/// and an answer to a question nobody is asking any more must write nothing.
@immutable
class PersonFactsState {
  /// Whose facts these are. Null before anything has been asked. A panel
  /// comparing this against the room it is drawing is what stops one person's
  /// files appearing under another's name for a frame.
  final String? roomKey;

  /// The live storylines any of their threads belongs to, in first-seen order.
  final List<String> storylineIds;

  /// Files they SENT, newest first.
  final List<FileRow> files;

  /// Whether a read has come back at all — success or failure. What separates
  /// "nothing has been read yet" from "they have sent nothing", which are the
  /// same empty list and very different sentences.
  final bool loaded;

  /// Non-null when the read failed. The lists stay as they are: a panel that
  /// blanked on a failed re-read would throw away answers that are still true.
  final String? error;

  const PersonFactsState({
    this.roomKey,
    this.storylineIds = const [],
    this.files = const [],
    this.loaded = false,
    this.error,
  });
}

/// How many files are scanned before they are narrowed to one person.
///
/// The narrowing is by SENDER, which the shelf query cannot do — it has no
/// index on the from-address and the room's identity is a display name as
/// often as an address. So the read is a bounded page and the filter is here.
/// Two hundred is months of documents at any volume a desktop mailbox sees.
const int _fileScanRows = 200;

class PersonFactsNotifier extends StateNotifier<PersonFactsState> {
  final MessageStore _store;

  int _seq = 0;

  PersonFactsNotifier(this._store) : super(const PersonFactsState());

  /// Reads everything the panel shows about one person.
  ///
  /// [sources] is passed per call rather than held, for the reason the files
  /// shelf passes it: the header's source chips scope every pane, and the
  /// screen is what owns them.
  Future<void> load(PersonRoom room, {required List<String> sources}) async {
    final seq = ++_seq;
    // Named immediately, before the first await: the panel draws its heading
    // from the room and its lists from here, and a stale key is how the two
    // come to describe different people.
    state = PersonFactsState(roomKey: room.key);

    final storylineIds = <String>[];
    final files = <FileRow>[];
    String? error;

    try {
      final seen = <String>{};
      for (final thread in room.threads) {
        for (final id in await _store.storylineIdsFor(thread.source, thread.id)) {
          if (id.isNotEmpty && seen.add(id)) storylineIds.add(id);
        }
      }

      final addresses = <String>{};
      final names = <String>{};
      for (final person in room.people) {
        final email = person.email?.trim().toLowerCase() ?? '';
        if (email.isNotEmpty) addresses.add(email);
        final name = person.name?.trim().toLowerCase() ?? '';
        if (name.isNotEmpty) names.add(name);
      }

      final page = await _store.recentAttachments(
        sources: sources,
        kind: FilesKind.all,
        limit: _fileScanRows,
      );
      for (final row in page) {
        // Files they SENT. The reader's own attachments are theirs, and a
        // person's shelf listing the reader's own outbound documents would
        // answer a question nobody asked.
        if (row.outbound) continue;
        final from = row.fromAddress?.trim().toLowerCase() ?? '';
        final name = row.fromName?.trim().toLowerCase() ?? '';
        // Either half, because the two connectors identify the same person
        // differently: mail carries an address, a Teams roster carries a name
        // and a `teams:` id no mailbox address will ever equal.
        if (addresses.contains(from) || names.contains(name)) files.add(row);
      }
    } catch (e) {
      debugPrint('person facts read failed: $e');
      error = 'Could not read everything about them.';
    }

    if (seq != _seq || !mounted) return;
    state = PersonFactsState(
      roomKey: room.key,
      storylineIds: storylineIds,
      files: files,
      loaded: true,
      error: error,
    );
  }
}

/// Deliberately NOT autoDispose: the panel is opened and closed as the reader
/// moves between a room and a thread, and a re-read on every reopen would be a
/// spinner over an answer that has not changed.
final personFactsProvider =
    StateNotifierProvider<PersonFactsNotifier, PersonFactsState>(
  (ref) => PersonFactsNotifier(ref.watch(messageStoreProvider)),
);
