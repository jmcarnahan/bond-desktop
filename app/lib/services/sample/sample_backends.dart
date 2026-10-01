/// The five backend interfaces, answered from a recorded sample instead of
/// Microsoft (see `sample_env.dart` for what the sandbox is and why it exists).
///
/// Everything above the seam — sync, gates, triage, the decision model,
/// storylines, every screen — runs unchanged, which is the point: the pipeline
/// under review is the production one, fed a real-sized mailbox.
///
/// READ-ONLY. Every write refuses with the seam's own exception type and a
/// sentence that says "sandbox", so a Send pressed here fails where the owner
/// can see it rather than pretending to succeed. The two read ACKS are the
/// exception, and deliberately: `ReadAckQueue` retries whatever fails, so a
/// refusal there would retry forever — [SampleMailBackend.markRead] answers
/// "nothing to retry" and [SampleTeamsBackend.markChatRead] returns normally.
///
/// Not served, by design: attachment bytes and previews, profile photos, a
/// directory beyond the sample's own people list, and new mail after the
/// first drain (a recording does not grow).
library;

import '../../models/attachment_models.dart';
import '../../models/person.dart';
import '../backend/attachment_backend.dart';
import '../backend/auth_session.dart';
import '../backend/backend_types.dart';
import '../backend/mail_backend.dart';
import '../backend/people_backend.dart';
import '../backend/teams_backend.dart';
import '../chat_mentions.dart' show ChatMention;
import '../graph_mail.dart' show GraphMailException;
import '../graph_teams.dart' show GraphTeamsException;
import 'sample_data.dart';

/// One wording for every refusal, so a write pressed anywhere in the sandbox
/// fails with the same plain reason: this build writes nothing.
String _readOnly(String what) => 'The sample sandbox is read-only: $what.';

/// Always signed in, as the sample's owner. The sandbox has no session to
/// lose, and every scope question answers yes so no feature hides itself
/// behind a grant the recording cannot have.
class SampleAuthSession implements AuthSession {
  final Future<SampleOwner> _owner;

  SampleAuthSession(this._owner);

  Future<AccountInfo> get _account async {
    final owner = await _owner;
    return AccountInfo(
      displayName: owner.displayName,
      mail: owner.address,
      userPrincipalName: owner.address,
    );
  }

  @override
  Future<bool> get isSignedIn async => true;

  @override
  Future<bool> get needsReconsent async => false;

  @override
  Future<bool> hasScope(String bareScope) async => true;

  @override
  Future<AccountInfo?> get storedAccount => _account;

  @override
  Future<AccountInfo> signIn() => _account;

  @override
  Future<void> signOut() async {}
}

/// Mail from the sample: a delta drain over the recorded inbox and sent
/// items, and detail fetches that re-read the recorded record.
///
/// Does NOT implement [DraftRecipientsEditor]: there is no draft to edit, and
/// the composer hides its recipients row when the answer is no.
class SampleMailBackend implements MailBackend {
  final Future<SampleData> _data;

  /// Messages per delta page. A parameter so a test can walk three records
  /// in three pages; Graph's own page is about this size.
  final int pageSize;

  SampleMailBackend(this._data, {this.pageSize = 100});

  static const String _prefix = 'sample';

  /// The cursor that says "drained; nothing new will ever arrive".
  static String _doneLink(String folder) => '$_prefix|$folder|done';

  /// One page of the drain.
  ///
  /// The cursors are this backend's own strings —
  /// `sample|<folder>|<floor>|<offset>` for a next page and
  /// `sample|<folder>|done` once drained — and are parsed here, never by the caller. The floor rides in the cursor so a
  /// mid-drain page keeps the filter the drain started with, which is the
  /// promise [MailBackend.deltaPage] makes about a verbatim link.
  ///
  /// A folder the sample does not serve (junk, deleted, custom) answers an
  /// empty, drained page rather than a throw: the app only drains inbox and
  /// sent items, and "nothing here" is the true answer for anything else.
  /// A cursor this backend did not write throws [DeltaResyncRequired], which
  /// is the sync's own way to start a clean drain.
  @override
  Future<DeltaPage> deltaPage(
    String folder, {
    String? link,
    String? minReceivedIso,
  }) async {
    final data = await _data;
    final key = folder.toLowerCase();

    String floor;
    int offset;
    if (link == null) {
      floor = minReceivedIso ?? '';
      offset = 0;
    } else {
      final parts = link.split('|');
      // A cursor from another folder's drain, or one this backend never wrote,
      // is not a page of THIS drain: start clean rather than serve the wrong
      // folder's messages.
      if (parts.length < 3 || parts[0] != _prefix || parts[1] != key) {
        throw const DeltaResyncRequired();
      }
      if (parts.length == 3 && parts[0] == _prefix && parts[2] == 'done') {
        return DeltaPage(deltaLink: link, hasMore: false);
      }
      final parsedOffset = parts.length == 4 ? int.tryParse(parts[3]) : null;
      if (parsedOffset == null || parsedOffset < 0) {
        throw const DeltaResyncRequired();
      }
      floor = parts[2];
      offset = parsedOffset;
    }

    final entries = data.mailByFolder[key] ?? const <SampleMailEntry>[];
    final start = _lowerBound(entries, floor) + offset;
    final end = start + pageSize;
    final page = start >= entries.length
        ? const <SampleMailEntry>[]
        : entries.sublist(start, end > entries.length ? entries.length : end);
    final more = end < entries.length;
    final nextLink = more ? '$_prefix|$key|$floor|${offset + pageSize}' : null;
    return DeltaPage(
      messages: [for (final e in page) e.toDeltaItem()],
      nextLink: nextLink,
      deltaLink: more ? null : _doneLink(key),
      hasMore: nextLink != null,
    );
  }

  /// The first index at or after [floorIso], by instant. No floor, or one
  /// that will not parse, starts from the beginning.
  static int _lowerBound(List<SampleMailEntry> entries, String floorIso) {
    if (floorIso.isEmpty) return 0;
    final floor = DateTime.tryParse(floorIso)?.microsecondsSinceEpoch;
    if (floor == null) return 0;
    var lo = 0;
    var hi = entries.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (entries[mid].receivedMicros < floor) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// An id the sample does not hold is a 404, which the sync reads as "this
  /// one message is gone" and skips without parking anything.
  @override
  Future<Map<String, dynamic>> getMessageDetail(String id) async {
    final detail = await (await _data).mailDetail(id);
    if (detail == null) {
      throw const GraphMailException('This message is not in the sample.', 404);
    }
    return detail;
  }

  @override
  Future<Map<String, dynamic>> createReplyDraft(String messageId) async =>
      throw GraphMailException(_readOnly('no reply draft can be created'));

  @override
  Future<Map<String, dynamic>> createDraft({
    required List<String> to,
    List<String> cc = const [],
    required String subject,
    required String body,
  }) async =>
      throw GraphMailException(_readOnly('no draft can be created'));

  @override
  Future<void> updateDraftBody(String draftId, String text) async =>
      throw GraphMailException(_readOnly('no draft can be edited'));

  @override
  Future<SentDraft> sendDraft(String draftId) async =>
      throw GraphMailException(_readOnly('nothing can be sent'));

  @override
  Future<void> deleteDraft(String draftId) async =>
      throw GraphMailException(_readOnly('there is no draft to delete'));

  /// Nothing to retry: the local store already flipped its rows, and there is
  /// no server to tell. A throw would make the ack queue retry forever.
  @override
  Future<List<String>> markRead(
    List<String> messageIds, {
    bool isRead = true,
  }) async =>
      const [];
}

/// The sample's 1:1, group and meeting chats. Channels are never served.
class SampleTeamsBackend implements TeamsBackend {
  final Future<SampleData> _data;

  /// Messages in the one page a chat with no cursor gets — Graph's own page.
  final int pageSize;

  SampleTeamsBackend(this._data, {this.pageSize = 50});

  @override
  Future<String> myUserId() async {
    final id = (await _data).owner.teamsUserId;
    if (id == null) {
      throw const GraphTeamsException(
        'The sample names no Teams id for its owner.',
      );
    }
    return id;
  }

  /// Every chat, newest activity first. [maxPages] is ignored: there is no
  /// paging to bound. `viewpoint` is null — the recording has no read state
  /// for chats — so the sync stores every chat message as read
  /// (`TeamsSync._isRead`'s uncertain case), and no chat bolds.
  @override
  Future<List<Map<String, dynamic>>> listChats({int maxPages = 4}) async {
    final chats = (await _data).chats.values.toList()
      ..sort((a, b) => b.createdMicros.first.compareTo(a.createdMicros.first));
    return [
      for (final chat in chats)
        {
          'id': chat.id,
          'topic': chat.topic,
          'lastMessagePreview': {'createdDateTime': chat.newestAt},
          'viewpoint': null,
        },
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> chatMembers(String chatId) async {
    final chat = (await _data).chats[chatId];
    if (chat == null) return const [];
    return [
      for (final m in chat.members)
        {'displayName': m.displayName, 'userId': m.userId},
    ];
  }

  /// Newest first. No cursor takes the newest [pageSize]; a cursor takes every
  /// message created after it, compared as instants because the recording's
  /// stamps carry differing fractional precision.
  @override
  Future<List<Map<String, dynamic>>> chatMessagesSince(
    String chatId,
    String? sinceIso, {
    int maxPages = 40,
  }) async {
    final chat = (await _data).chats[chatId];
    if (chat == null) return const [];
    if (sinceIso == null || sinceIso.isEmpty) {
      return [
        for (final m in chat.messages.take(pageSize))
          Map<String, dynamic>.from(m),
      ];
    }
    final since = DateTime.tryParse(sinceIso)?.microsecondsSinceEpoch;
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < chat.messages.length; i++) {
      final newer = since == null
          ? (chat.messages[i]['createdDateTime'] as String)
                  .compareTo(sinceIso) >
              0
          : chat.createdMicros[i] > since;
      if (!newer) break;
      out.add(Map<String, dynamic>.from(chat.messages[i]));
    }
    return out;
  }

  /// Returns normally, for the reason [SampleMailBackend.markRead] answers
  /// `[]`: the ack queue retries a failure, and there is nothing to tell.
  @override
  Future<void> markChatRead(String chatId) async {}

  @override
  Future<Map<String, dynamic>> sendChatMessage(
    String chatId,
    String text, {
    List<ChatMention> mentions = const [],
  }) async =>
      throw GraphTeamsException(_readOnly('no chat message can be sent'));

  @override
  Future<EnsuredChat> ensureChat(List<String> userIds, {String? topic}) async =>
      throw GraphTeamsException(_readOnly('no chat can be opened'));
}

/// The sample's people list as the directory. No photos.
class SamplePeopleBackend implements PeopleBackend {
  final Future<SampleData> _data;

  SamplePeopleBackend(this._data);

  /// Case-insensitive substring over name and address. A blank query does no
  /// work at all, as the interface promises.
  @override
  Future<List<Person>> searchPeople(String query, {int top = 10}) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty || top <= 0) return const [];
    final out = <Person>[];
    for (final person in (await _data).people) {
      final name = person.name;
      final address = person.address;
      final id = person.teamsUserId ??
          (address == null ? null : 'mail:${address.toLowerCase()}');
      if (id == null) continue;
      final hit = (name?.toLowerCase().contains(q) ?? false) ||
          (address?.toLowerCase().contains(q) ?? false);
      if (!hit) continue;
      out.add(Person(
        id: id,
        displayName: name ?? address ?? id,
        mail: address,
        source: PersonSource.directory,
      ));
      if (out.length >= top) break;
    }
    return out;
  }

  /// Null is the everyday "no face here" answer, and the only one a recording
  /// can give.
  @override
  Future<ProfilePhoto?> profilePhoto(
    String user, {
    String size = '96x96',
  }) async =>
      null;
}

/// Attachment words from the sample's recorded extractions; never bytes.
class SampleAttachmentBackend implements AttachmentBackend {
  final Future<SampleData> _data;

  SampleAttachmentBackend(this._data);

  /// Zero: no bytes are served, so the caller refuses every preview before
  /// asking.
  @override
  int get maxPreviewBytes => 0;

  @override
  Future<AttachmentText> extractText(AttachmentRef ref) async {
    final data = await _data;
    final sampleId = data.sampleIdByGraphId['${ref.source}|${ref.messageId}'];
    final record =
        sampleId == null ? null : data.attachments['$sampleId|${ref.attachmentId}'];
    if (record == null) return const AttachmentText.skipped('unavailable');
    return attachmentTextFor(record);
  }

  /// The recorded extraction as the seam's answer. Static so the reason
  /// mapping can be pinned directly.
  ///
  /// The reason is mapped INTO the closed vocabulary [AttachmentText.reason]
  /// documents, and the recorded `text_reason` string is never passed
  /// through: it can hold a whole Graph error body, and it would land on the
  /// chip.
  static AttachmentText attachmentTextFor(Map<String, dynamic> record) {
    final status = record['text_status'] as String?;
    final itemSubject = record['item_subject'] as String?;
    final itemFrom = record['item_from'] as String?;
    final itemReceived = record['item_received'] as String?;
    final text = record['text'] as String?;
    if (status == 'done' && text != null) {
      return AttachmentText.ok(
        text,
        truncated: record['truncated'] == true,
        itemSubject: itemSubject,
        itemFrom: itemFrom,
        itemReceived: itemReceived,
      );
    }
    return AttachmentText.skipped(
      skipReasonFor(status, record['text_reason'] as String?),
      itemSubject: itemSubject,
      itemFrom: itemFrom,
      itemReceived: itemReceived,
    );
  }

  /// The recorded status and reason, as one word of the closed vocabulary.
  static String skipReasonFor(String? status, String? reason) {
    // A failed fetch's reason is an error body, never a word, and a fetch the
    // recording never made has none; the status is the whole of what can be
    // said for both.
    if (status == 'failed' || status == 'not_fetched') return 'unavailable';
    final r = reason ?? '';
    if (r == 'too_large') return 'too_large';
    if (r == 'no_extractor') return 'no_extractor';
    if (r == 'inline' || r == 'per_message_cap' || r.startsWith('kind_')) {
      return 'unsupported';
    }
    if (r == 'empty' || r == 'no_text') return 'empty';
    if (r == 'failed' || r == 'not_fetched') return 'unavailable';
    if (r == 'reference') return 'reference';
    if (status == 'empty') return 'empty';
    // A `done` record with no words amounts to an empty document.
    if (status == 'done') return 'empty';
    return 'unsupported';
  }

  @override
  Future<AttachmentBytesResult> fetchBytes(
    AttachmentRef ref, {
    String thumbnail = '',
  }) async =>
      throw const AttachmentUnavailable(
        'unavailable',
        'The sample sandbox serves no attachment bytes.',
      );
}
