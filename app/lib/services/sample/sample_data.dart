/// The sample sandbox's reader: a recorded mailbox on disk, parsed once and
/// held in the shapes the backends serve.
///
/// The recording is the normalised sample format (one owner, gzipped JSONL
/// shards under `messages/`, plus `attachments.jsonl.gz`, `people.jsonl.gz`
/// and `manifest.json`). It is read straight from those files, with no
/// pre-processing step, because a step would be one more thing to rerun
/// whenever the sample is rebuilt.
///
/// What is held, and why it is not everything:
///
/// - **Mail** keeps a SLIM index entry per message — exactly the fields a
///   delta page carries — plus where its full record sits (shard and line).
///   Bodies are most of a shard's bytes and only a detail fetch needs one, so
///   [mailDetail] re-reads the shard instead of holding tens of thousands of
///   HTML bodies for the whole run.
/// - **Teams** keeps every chat message whole, already in the Graph-ish shape
///   `TeamsSync` reads: they are small, and a chat is read all at once.
///   Channel messages are dropped at load — the app never reads channels (the
///   `TeamsBackend` doc says why).
/// - **Attachments** are keyed `'<sample id>|<attachment id>'`, and the
///   extracted text is kept only for a record whose extraction finished.
///
/// Nothing from the recording is ever written anywhere by this file.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;

import '../gates.dart' show meetingInviteType, meetingResponseTypes;

/// The one person the sample is the mailbox of.
class SampleOwner {
  final String displayName;
  final String address;

  /// Null when the recording has no Teams identity for the owner; the Teams
  /// backend then refuses rather than calling every chat message inbound.
  final String? teamsUserId;

  const SampleOwner({
    required this.displayName,
    required this.address,
    this.teamsUserId,
  });

  static final Map<String, Future<SampleOwner>> _loads = {};

  /// The owner out of `manifest.json` alone, memoised per directory.
  ///
  /// Separate from [SampleData.load] so the sign-in check answers at once:
  /// the auth gate asks "signed in?" before the first frame, and the full
  /// parse takes tens of seconds.
  static Future<SampleOwner> load(String dir) {
    final key = p.normalize(dir.trim());
    return _loads.putIfAbsent(key, () async {
      try {
        final raw = await File(p.join(key, 'manifest.json')).readAsString();
        return _ownerFrom(jsonDecode(raw));
      } catch (_) {
        // Not memoised as a failure: a directory fixed while the app runs is
        // picked up by the next call rather than by a rebuild.
        _loads.remove(key);
        rethrow;
      }
    });
  }
}

/// One mail message as the delta page needs it, and where its full record is.
class SampleMailEntry {
  final String graphId;
  final String sampleId;
  final String? internetMessageId;
  final String? conversationId;
  final String receivedAt;

  /// [receivedAt] as microseconds since the epoch, so the floor and the order
  /// compare instants rather than strings of differing precision.
  final int receivedMicros;
  final String folderFamily;
  final String? subject;
  final String? bodyPreview;
  final String? fromName;
  final String? fromAddress;

  /// `(name, address)` for each To: recipient.
  final List<(String?, String?)> to;
  final bool isRead;
  final bool hasAttachments;
  final String shardPath;

  /// The index among the shard's NON-BLANK lines — the same count
  /// [SampleData.mailDetail] walks when it re-reads the shard.
  final int lineIndex;

  const SampleMailEntry({
    required this.graphId,
    required this.sampleId,
    required this.internetMessageId,
    required this.conversationId,
    required this.receivedAt,
    required this.receivedMicros,
    required this.folderFamily,
    required this.subject,
    required this.bodyPreview,
    required this.fromName,
    required this.fromAddress,
    required this.to,
    required this.isRead,
    required this.hasAttachments,
    required this.shardPath,
    required this.lineIndex,
  });

  /// The delta item `SyncService`'s ingest loop reads, in Graph's own nested
  /// shape. Built per page rather than held, so the index stays slim.
  ///
  /// `isDraft` is stated false because the sample carries no Drafts folder and
  /// the reader skips a draft on `== true`; no `@removed` key is ever sent,
  /// because nothing is ever deleted from a recording.
  Map<String, dynamic> toDeltaItem() => {
        'id': graphId,
        'isDraft': false,
        'receivedDateTime': receivedAt,
        'subject': subject,
        'bodyPreview': bodyPreview,
        'conversationId': conversationId,
        if (fromAddress != null || fromName != null)
          'from': {
            'emailAddress': {'name': fromName, 'address': fromAddress},
          },
        'toRecipients': [
          for (final (name, address) in to)
            {
              'emailAddress': {'name': name, 'address': address},
            },
        ],
        'internetMessageId': internetMessageId,
        'isRead': isRead,
        'hasAttachments': hasAttachments,
      };
}

/// One chat member, as `chatMembers` answers it.
class SampleMember {
  final String userId;
  final String? displayName;

  const SampleMember({required this.userId, this.displayName});
}

/// One 1:1, group or meeting chat.
class SampleChat {
  final String id;
  final String? topic;
  final String type;
  final List<SampleMember> members;

  /// Newest first, in the shape `TeamsSync._messageRow` reads.
  final List<Map<String, dynamic>> messages;

  /// Each message's `createdDateTime` in microseconds, index for index with
  /// [messages]. Chat stamps arrive at three fractional precisions, and a
  /// string compare would sort `…:05.5Z` before `…:05Z`.
  final List<int> createdMicros;

  /// The newest message's `createdDateTime`, verbatim.
  final String newestAt;

  const SampleChat({
    required this.id,
    required this.topic,
    required this.type,
    required this.members,
    required this.messages,
    required this.createdMicros,
    required this.newestAt,
  });
}

/// One directory entry.
class SamplePerson {
  final String? name;
  final String? address;
  final String? teamsUserId;
  final bool internal;

  const SamplePerson({
    this.name,
    this.address,
    this.teamsUserId,
    this.internal = false,
  });
}

/// The parsed sample.
class SampleData {
  final String dir;
  final SampleOwner owner;

  /// The index, per served folder (`inbox`, `sentitems`), oldest first.
  final Map<String, List<SampleMailEntry>> mailByFolder;

  /// Chats by id.
  final Map<String, SampleChat> chats;
  final List<SamplePerson> people;

  /// `'<sample id>|<attachment id>'` → the attachment record, minus `text`
  /// where the extraction did not finish.
  final Map<String, Map<String, dynamic>> attachments;

  /// `'<source>|<graph id>'` → sample id, `source` being `email` or `teams` —
  /// the app keys attachments by the Graph message id, the sample by its own.
  final Map<String, String> sampleIdByGraphId;

  final Map<String, SampleMailEntry> _mailByGraphId;

  SampleData._({
    required this.dir,
    required this.owner,
    required this.mailByFolder,
    required this.chats,
    required this.people,
    required this.attachments,
    required this.sampleIdByGraphId,
  }) : _mailByGraphId = {
          for (final list in mailByFolder.values)
            for (final entry in list) entry.graphId: entry,
        };

  static final Map<String, Future<SampleData>> _loads = {};

  /// The sample in [dir], parsed once per directory for the whole run: the
  /// five backends share this one future, so the parse happens once however
  /// many of them ask first.
  ///
  /// The parse runs in [Isolate.run] — it decompresses and decodes every shard,
  /// which is tens of seconds of work the UI must not stall on — and the
  /// classes are built there too, so the finished instance crosses back in
  /// one hand-off (it is sendable: the shard cache is empty at construction
  /// and the memo maps are static).
  ///
  /// A malformed line or an unreadable shard is skipped and counted rather
  /// than failing the whole sandbox; only the manifest is fatal, because
  /// without an owner there is no mailbox to be.
  static Future<SampleData> load(String dir) {
    final key = p.normalize(dir.trim());
    return _loads.putIfAbsent(key, () async {
      try {
        final (data, skipped) = await _parseInIsolate(key);
        if (skipped > 0) {
          debugPrint('sample: skipped $skipped unreadable line(s) or shard(s)');
        }
        return data;
      } catch (_) {
        _loads.remove(key);
        rethrow;
      }
    });
  }

  /// The mail entry for [graphId], or null.
  SampleMailEntry? mailEntry(String graphId) => _mailByGraphId[graphId];

  /// The recently read shards, most recent last. A thread's messages tend to
  /// share a shard, and triage walks newest first, so a small cache turns most
  /// detail fetches into one decode of one line.
  final List<(String, Future<List<String>>)> _shards = [];
  static const int _shardCacheSize = 3;

  /// The detail fetch's answer for [graphId], in the shape
  /// `SyncService._fetchDetailInto` reads, or null for an id the sample does
  /// not hold.
  ///
  /// The body is the ORIGINAL HTML with `contentType: 'html'`, so the app's
  /// own converter runs over it exactly as it does on the SDK path.
  Future<Map<String, dynamic>?> mailDetail(String graphId) async {
    final entry = _mailByGraphId[graphId];
    if (entry == null) return null;
    final lines = await _shardLines(entry.shardPath);
    if (entry.lineIndex >= lines.length) return null;
    final record = jsonDecode(lines[entry.lineIndex]);
    if (record is! Map) return null;
    return detailFromRecord(record, attachments);
  }

  Future<List<String>> _shardLines(String path) {
    for (var i = 0; i < _shards.length; i++) {
      if (_shards[i].$1 == path) {
        final hit = _shards.removeAt(i);
        _shards.add(hit);
        return hit.$2;
      }
    }
    final future = _readShardInIsolate(path);
    _shards.add((path, future));
    if (_shards.length > _shardCacheSize) _shards.removeAt(0);
    // A failed read must not be served from the cache forever. The future
    // catchError derives is discarded on purpose: the caller still receives
    // the error through the original [future] returned below.
    future.catchError((Object _) {
      _shards.removeWhere((s) => identical(s.$2, future));
      return const <String>[];
    });
    return future;
  }

  /// Graph's `meetingMessageType` vocabulary, lowercased. The sample's
  /// `meeting.type` is recorded from the EVENT (`singleInstance`,
  /// `seriesMaster`), which is a different field; passed through as the
  /// message type it would read as "Graph said the kind", and `gates.dart`
  /// would then skip the subject fallbacks that catch an "Accepted:" reply.
  static final Set<String> _meetingMessageTypes = {
    'none',
    meetingInviteType,
    ...meetingResponseTypes,
  };

  /// A full mail record as the detail shape. Public and static so the test can
  /// pin the mapping without a shard on disk.
  static Map<String, dynamic> detailFromRecord(
    Map record,
    Map<String, Map<String, dynamic>> attachments,
  ) {
    final sampleId = record['sample_id'] as String? ?? '';
    final body = (record['unique_body_html'] as String?) ??
        (record['body_html'] as String?) ??
        '';
    final meeting = record['meeting'];
    final meetingType =
        meeting is Map ? (meeting['type'] as String?)?.trim() : null;
    final served = meetingType != null &&
        _meetingMessageTypes.contains(meetingType.toLowerCase());
    return {
      'uniqueBody': {'content': body, 'contentType': 'html'},
      'internetMessageHeaders': _headerList(record),
      if (served) 'meetingMessageType': meetingType,
      'hasAttachments': record['has_attachments'] == true,
      'attachments': [
        for (final raw in record['attachments'] is List
            ? record['attachments'] as List
            : const [])
          if (raw is Map && (raw['attachment_id'] as String? ?? '').isNotEmpty)
            _mailAttachmentEntry(
              raw,
              attachments['$sampleId|${raw['attachment_id']}'],
            ),
      ],
    };
  }

  /// `{name, value}` pairs, null values dropped. The lowercased `headers` map
  /// is the recording's own first-value-wins view, which is exactly the rule
  /// the sync applies when it folds the list back into a map; the raw pairs
  /// are the fallback for a record without it.
  static List<Map<String, String>> _headerList(Map record) {
    final headers = record['headers'];
    if (headers is Map) {
      return [
        for (final e in headers.entries)
          if (e.key is String && e.value != null)
            {'name': e.key as String, 'value': e.value.toString()},
      ];
    }
    final raw = record['headers_raw'];
    if (raw is List) {
      return [
        for (final pair in raw)
          if (pair is List &&
              pair.length == 2 &&
              pair[0] is String &&
              pair[1] != null)
            {'name': pair[0] as String, 'value': pair[1].toString()},
      ];
    }
    return const [];
  }

  /// The MCP flat entry `_storeAttachments` reads: `id`, not `attachment_id`.
  static Map<String, Object?> _mailAttachmentEntry(
    Map raw,
    Map<String, dynamic>? full,
  ) =>
      {
        'id': raw['attachment_id'] as String,
        'kind': raw['kind'] as String? ?? 'unknown',
        'name': raw['name'] as String?,
        'content_type': raw['content_type'] as String?,
        'size': (raw['size'] as num?)?.toInt() ?? 0,
        'is_inline': raw['is_inline'] == true,
        'content_id': raw['content_id'] as String?,
        'source_url': (raw['source_url'] as String?) ??
            (full?['source_url'] as String?) ??
            (full?['content_url'] as String?),
      };

  static SampleData _build(String dir, Map<String, Object?> raw) {
    final mailByFolder = <String, List<SampleMailEntry>>{};
    for (final m in raw['mail'] as List) {
      final e = m as Map;
      final entry = SampleMailEntry(
        graphId: e['g'] as String,
        sampleId: e['s'] as String,
        internetMessageId: e['imid'] as String?,
        conversationId: e['cid'] as String?,
        receivedAt: e['at'] as String,
        receivedMicros: e['us'] as int,
        folderFamily: e['fam'] as String,
        subject: e['subj'] as String?,
        bodyPreview: e['prev'] as String?,
        fromName: e['fn'] as String?,
        fromAddress: e['fa'] as String?,
        to: [
          for (final t in e['to'] as List)
            ((t as List)[0] as String?, t[1] as String?),
        ],
        isRead: e['read'] == true,
        hasAttachments: e['att'] == true,
        shardPath: e['shard'] as String,
        lineIndex: e['line'] as int,
      );
      mailByFolder.putIfAbsent(entry.folderFamily, () => []).add(entry);
    }
    for (final list in mailByFolder.values) {
      list.sort((a, b) {
        final byTime = a.receivedMicros.compareTo(b.receivedMicros);
        return byTime != 0 ? byTime : a.graphId.compareTo(b.graphId);
      });
    }

    final chats = <String, SampleChat>{};
    for (final c in raw['chats'] as List) {
      final e = c as Map;
      final chat = SampleChat(
        id: e['id'] as String,
        topic: e['topic'] as String?,
        type: e['type'] as String,
        members: [
          for (final m in e['members'] as List)
            SampleMember(
              userId: (m as Map)['userId'] as String,
              displayName: m['displayName'] as String?,
            ),
        ],
        messages: [
          for (final m in e['messages'] as List)
            Map<String, dynamic>.from(m as Map),
        ],
        createdMicros: [for (final u in e['micros'] as List) u as int],
        newestAt: e['newestAt'] as String,
      );
      chats[chat.id] = chat;
    }

    return SampleData._(
      dir: dir,
      owner: _ownerFrom(raw['manifest']),
      mailByFolder: mailByFolder,
      chats: chats,
      people: [
        for (final x in raw['people'] as List)
          SamplePerson(
            name: (x as Map)['name'] as String?,
            address: x['address'] as String?,
            teamsUserId: x['teamsUserId'] as String?,
            internal: x['internal'] == true,
          ),
      ],
      attachments: {
        for (final e in (raw['attachments'] as Map).entries)
          e.key as String: Map<String, dynamic>.from(e.value as Map),
      },
      sampleIdByGraphId: {
        for (final e in (raw['sampleIds'] as Map).entries)
          e.key as String: e.value as String,
      },
    );
  }
}

SampleOwner _ownerFrom(Object? manifest) {
  final owners = manifest is Map ? manifest['owners'] : null;
  if (owners is! Map || owners.isEmpty) {
    throw const FormatException('The sample manifest names no owner.');
  }
  final o = owners.values.first;
  if (o is! Map) {
    throw const FormatException('The sample manifest owner is malformed.');
  }
  final address = (o['primary_address'] as String?)?.trim() ?? '';
  final name = (o['display_name'] as String?)?.trim() ?? '';
  final teams = (o['teams_user_id'] as String?)?.trim() ?? '';
  return SampleOwner(
    displayName: name.isEmpty ? address : name,
    address: address,
    teamsUserId: teams.isEmpty ? null : teams,
  );
}

// ---------------------------------------------------------------------------
// Isolate side. Everything below returns plain lists, maps, strings, numbers
// and bools, so what crosses back is data and nothing else.
// ---------------------------------------------------------------------------

/// The folders the delta drain serves. Junk, deleted and custom folders are
/// never drained by the app, so they are not held.
const Set<String> _servedFolders = {'inbox', 'sentitems'};

/// The chat kinds the app reads. A channel is absent on purpose.
const Set<String> _chatTypes = {'oneOnOne', 'group', 'meeting'};

/// The Teams attachment kinds the sync knows by name; everything else is
/// `other`, which is what `GraphTeams.attachmentEntries` answers for a kind it
/// has no word for.
const Set<String> _teamsKinds = {'file', 'card', 'message_reference', 'image'};

// The two isolate entry points are top-level on purpose. A closure written
// inside an instance method can close over `this`, and a [SampleData] can hold
// futures, which cannot cross an isolate boundary; here the closure sees one
// string and nothing else.
Future<(SampleData, int)> _parseInIsolate(String dir) => Isolate.run(() {
      final raw = _parseSample(dir);
      return (SampleData._build(dir, raw), raw['skipped'] as int);
    });

Future<List<String>> _readShardInIsolate(String path) =>
    Isolate.run(() => _readShardLines(path));

List<String> _readShardLines(String path) {
  final text = utf8.decode(gzip.decode(File(path).readAsBytesSync()));
  return [
    for (final line in const LineSplitter().convert(text))
      if (line.trim().isNotEmpty) line,
  ];
}

/// Microseconds for an ISO stamp, or 0 when it will not parse (which sorts it
/// oldest and keeps it out of any floor).
int _micros(String? iso) =>
    iso == null ? 0 : (DateTime.tryParse(iso)?.microsecondsSinceEpoch ?? 0);

String? _str(Object? v) => v is String ? v : null;

/// Lines and shards the parse could not read, counted so the load can say so
/// once instead of failing.
class _Skips {
  int n = 0;
}

/// [path]'s non-blank lines, or empty (counted) when the file will not read.
List<String> _linesOrSkip(String path, _Skips skips) {
  try {
    return _readShardLines(path);
  } catch (_) {
    skips.n++;
    return const [];
  }
}

/// One line decoded, or null (counted) when it is not JSON.
Object? _decodeOrSkip(String line, _Skips skips) {
  try {
    return jsonDecode(line);
  } on FormatException {
    skips.n++;
    return null;
  }
}

Map<String, Object?> _parseSample(String dir) {
  final manifest = jsonDecode(
    File(p.join(dir, 'manifest.json')).readAsStringSync(),
  );

  final messagesDir = Directory(p.join(dir, 'messages'));
  final shards = messagesDir.existsSync()
      ? (messagesDir
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((path) => path.endsWith('.jsonl.gz'))
          .toList()
        ..sort())
      : <String>[];

  final mail = <Map<String, Object?>>[];
  final sampleIds = <String, String>{};
  final chatMeta = <String, Map<String, Object?>>{};
  final chatMessages = <String, List<(int, Map<String, Object?>)>>{};
  final skips = _Skips();

  for (final shard in shards) {
    final base = p.basename(shard);
    final isMail = base.startsWith('mail-');
    final isTeams = base.startsWith('teams-');
    if (!isMail && !isTeams) continue;
    // The index `i` counts every non-blank line, decodable or not, which is
    // the same count `mailDetail` walks when it re-reads the shard.
    final lines = _linesOrSkip(shard, skips);
    for (var i = 0; i < lines.length; i++) {
      final r = _decodeOrSkip(lines[i], skips);
      if (r is! Map) continue;
      if (isMail) {
        final entry = _mailEntry(r, shard, i);
        if (entry == null) continue;
        mail.add(entry);
        sampleIds['email|${entry['g']}'] = entry['s'] as String;
      } else {
        _teamsRecord(r, chatMeta, chatMessages, sampleIds);
      }
    }
  }

  final chats = <Map<String, Object?>>[];
  for (final entry in chatMessages.entries) {
    final list = entry.value
      ..sort((a, b) {
        final byTime = b.$1.compareTo(a.$1);
        return byTime != 0
            ? byTime
            : (b.$2['id'] as String).compareTo(a.$2['id'] as String);
      });
    final meta = chatMeta[entry.key]!;
    chats.add({
      ...meta,
      'messages': [for (final m in list) m.$2],
      'micros': [for (final m in list) m.$1],
      'newestAt': list.first.$2['createdDateTime'],
    });
  }

  // Attachment records are kept only for messages the backends serve: the
  // recording also holds channel, junk and deleted mail, whose extracted text
  // nothing would ever ask for.
  final served = sampleIds.values.toSet();
  final people = _people(p.join(dir, 'people.jsonl.gz'), skips);
  final attachments =
      _attachments(p.join(dir, 'attachments.jsonl.gz'), served, skips);
  return {
    'manifest': manifest,
    'mail': mail,
    'chats': chats,
    'people': people,
    'attachments': attachments,
    'sampleIds': sampleIds,
    'skipped': skips.n,
  };
}

Map<String, Object?>? _mailEntry(Map r, String shard, int line) {
  final family = _str(r['folder_family']);
  if (!_servedFolders.contains(family)) return null;
  final graph = r['graph'];
  final graphId = graph is Map ? _str(graph['id']) : null;
  final sampleId = _str(r['sample_id']);
  final at = _str(r['received_at']);
  if (graphId == null || graphId.isEmpty || sampleId == null || at == null) {
    return null;
  }
  final from = r['from'];
  return {
    'g': graphId,
    's': sampleId,
    'imid': graph is Map ? _str(graph['internet_message_id']) : null,
    'cid': graph is Map ? _str(graph['conversation_id']) : null,
    'at': at,
    'us': _micros(at),
    'fam': family,
    'subj': _str(r['subject']),
    'prev': _str(r['body_preview']),
    'fn': from is Map ? _str(from['name']) : null,
    'fa': from is Map ? _str(from['address']) : null,
    'to': [
      for (final t in r['to'] is List ? r['to'] as List : const [])
        if (t is Map) [_str(t['name']), _str(t['address'])],
    ],
    'read': r['is_read'] == true,
    'att': r['has_attachments'] == true,
    'shard': shard,
    'line': line,
  };
}

void _teamsRecord(
  Map r,
  Map<String, Map<String, Object?>> chatMeta,
  Map<String, List<(int, Map<String, Object?>)>> chatMessages,
  Map<String, String> sampleIds,
) {
  final chat = r['chat'];
  if (chat is! Map || !_chatTypes.contains(chat['type'])) return;
  if (r['channel'] != null) return;
  final graph = r['graph'];
  if (graph is! Map) return;
  final chatId = _str(graph['chat_id']);
  final id = _str(graph['id']);
  final created = _str(r['received_at']);
  if (chatId == null || id == null || id.isEmpty || created == null) return;

  final meta = chatMeta.putIfAbsent(
    chatId,
    () => {
      'id': chatId,
      'topic': null,
      'type': chat['type'],
      'members': <Map<String, Object?>>[],
    },
  );
  // The first record that says anything wins: members and topic are the
  // chat's, not the message's, and every record repeats them.
  meta['topic'] ??= _str(chat['topic']);
  final members = meta['members'] as List<Map<String, Object?>>;
  if (members.isEmpty && chat['members'] is List) {
    for (final m in chat['members'] as List) {
      if (m is! Map) continue;
      final userId = _str(m['user_id']);
      if (userId == null || userId.isEmpty) continue;
      members.add({'userId': userId, 'displayName': _str(m['name'])});
    }
  }

  final sampleId = _str(r['sample_id']);
  if (sampleId != null) sampleIds['teams|$id'] = sampleId;

  chatMessages
      .putIfAbsent(chatId, () => [])
      .add((_micros(created), _teamsMessage(r, id, created)));
}

/// One chat message in the shape `McpTeamsBackend._messageShape` produces.
Map<String, Object?> _teamsMessage(Map r, String id, String created) {
  final from = r['from'];
  final userId = from is Map ? _str(from['user_id']) : null;
  final appId = from is Map ? _str(from['application_id']) : null;
  final html = _str(r['body_html']);
  return {
    'id': id,
    'messageType': 'message',
    'createdDateTime': created,
    'lastModifiedDateTime': _str(r['modified_at']) ?? created,
    // HTML when the recording kept it, because that is what Graph sent and
    // `stripChatHtml` is the converter under test; plain text otherwise.
    'body': html != null
        ? {'contentType': 'html', 'content': html}
        : {'contentType': 'text', 'content': _str(r['body_text']) ?? ''},
    'from': (userId != null && userId.isNotEmpty)
        ? {
            'user': {'id': userId, 'displayName': _str((from as Map)['name'])},
          }
        : (appId != null && appId.isNotEmpty)
            ? {
                'application': {
                  'id': appId,
                  'displayName': _str((from as Map)['name']),
                },
              }
            : null,
    'mentions': [
      for (final m in r['mentions'] is List ? r['mentions'] as List : const [])
        if (m is Map && (_str(m['user_id']) ?? '').isNotEmpty)
          {
            'mentioned': {
              'user': {'id': m['user_id']},
            },
          },
    ],
    'attachments': [
      for (final a
          in r['attachments'] is List ? r['attachments'] as List : const [])
        if (a is Map && (_str(a['attachment_id']) ?? '').isNotEmpty)
          {
            'id': a['attachment_id'],
            'kind': _teamsKinds.contains(a['kind']) ? a['kind'] : 'other',
            'name': _str(a['name']),
            'content_type': _str(a['content_type']),
            'content_url': _str(a['content_url']),
            'thumbnail_url': _str(a['thumbnail_url']),
            'card_text': _str(a['card_text']),
            // The recording keeps no quoted-message fields; a quote renders
            // as a block with no sender and no snippet.
            'message_id': null,
            'message_sender': null,
            'message_preview': null,
          },
    ],
  };
}

List<Map<String, Object?>> _people(String path, _Skips skips) {
  final file = File(path);
  if (!file.existsSync()) return const [];
  final out = <Map<String, Object?>>[];
  for (final line in _linesOrSkip(path, skips)) {
    final r = _decodeOrSkip(line, skips);
    if (r is! Map) continue;
    out.add({
      'name': _str(r['name']),
      'address': _str(r['address']),
      'teamsUserId': _str(r['teams_user_id']),
      'internal': r['internal'] == true,
    });
  }
  return out;
}

Map<String, Map<String, Object?>> _attachments(
  String path,
  Set<String> served,
  _Skips skips,
) {
  final file = File(path);
  if (!file.existsSync()) return const {};
  final out = <String, Map<String, Object?>>{};
  for (final line in _linesOrSkip(path, skips)) {
    final r = _decodeOrSkip(line, skips);
    if (r is! Map) continue;
    final sampleId = _str(r['sample_id']);
    final attachmentId = _str(r['attachment_id']);
    if (sampleId == null || attachmentId == null) continue;
    if (!served.contains(sampleId)) continue;
    final done = r['text_status'] == 'done';
    out['$sampleId|$attachmentId'] = {
      'text_status': _str(r['text_status']),
      'text_reason': _str(r['text_reason']),
      // Only a finished extraction's words are held: nothing else serves them.
      if (done) 'text': _str(r['text']),
      'truncated': r['truncated'] == true,
      'item_subject': _str(r['item_subject']),
      'item_from': _str(r['item_from']),
      'item_received': _str(r['item_received']),
      'source_url': _str(r['source_url']),
      'content_url': _str(r['content_url']),
    };
  }
  return out;
}
