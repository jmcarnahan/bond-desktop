import 'dart:convert';

import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/extract_handler.dart' show cardHash;
import 'package:bond_inbox/services/gates.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/storyline_service.dart'
    show clusteringCardForConversationRow;

import 'golden_set.dart';
import 'golden_storyline.dart';

/// The mailbox behind the golden items, as the app would have had it.
///
/// The sweep replay runs the app's OWN code — `StorylineService.sweep`,
/// `keepSuggestion`, `assignConversation` — so the only way to measure it is
/// to give it a database that looks like the one it runs against. That is what
/// this file builds: one conversation per thread the set draws from, every
/// message the set carries, the triage status each of those messages would
/// have, the triage summary and extraction topics a bulk run file recorded,
/// and one live embedding per thread under the app's own clustering recipe.
///
/// Three rules decide whether the pool this produces is the pool the app
/// sweeps, and all three are load-bearing:
///
/// 1. **The gate verdict is GOLD's, not the app's.** An item gold calls a drop
///    is seeded `skipped` — its own message AND every inbound message of its
///    thread — because `MessageStore.keptMessageSql` counts anything not
///    `skipped` as kept, and one unmarked thread message would put a gated
///    thread straight back into the pool. The bench therefore measures the
///    sweep over a CORRECTLY gated mailbox and says so; the app's own gates
///    score 76–83% and are measured by `make golden-gate`.
/// 2. **The owner's own sends are born `skipped`/`outbound`**, through
///    `triageStatusOnInsert` rather than a literal, so the one rule lives in
///    one place.
/// 3. **The vector is written under `EmbeddingsClient.modelTag`**, through the
///    identical `upsertConversationAi` call `StorylineService._reembed` makes,
///    from a card built by the app's own
///    `clusteringCardForConversationRow` over the row this seeding just wrote.
///    `sweep()` reads the pool filtered on that tag, so a vector written under
///    any other string is a thread the sweep cannot see, and a card built by a
///    second recipe would measure a corpus the app never has.
/// 4. **One underlying message is one row.** A thread tail is recorded as TEXT
///    with a synthetic id per item, so two items of one conversation carry the
///    same message twice under two ids. They are de-duplicated on
///    `received_at` and body before anything is written: without that a
///    gated thread whose message also appears in another item's tail would
///    come back kept, and both thread counters would double-count.
///
/// Nothing here prints. The set is real correspondence and this repository is
/// public: what a caller gets back is counts.

/// The gate reason a gold-drop message is seeded with.
///
/// Its own slug rather than one of the app's (`newsletter`, `bulk_sender`,
/// `empty`): the seed is asserting GOLD's verdict, and borrowing a reason the
/// app's gates write would claim the app reached this answer on this message.
/// What reads it only asks whether it is null — `upsertMessage` treats
/// `skipped` with a reason as a message the gate finished at ingest.
const String goldDropGateReason = 'gold_drop';

/// One thread the seeding wrote, and the two facts the replay sorts and
/// filters it by.
class SeededThread {
  final String source;
  final String conversationKey;

  /// The newest message's `received_at`, which is the column the sweep pool
  /// and the assign pass are ordered by. Null only when the set recorded no
  /// timestamp for any message of the thread.
  final String? lastMessageAt;

  /// Whether any inbound message of this thread survived the gates. False is
  /// the gated pool the app has and the sweep refuses to look at.
  final bool keptInbound;

  /// Whether a vector was written for this thread.
  final bool embedded;

  const SeededThread({
    required this.source,
    required this.conversationKey,
    required this.lastMessageAt,
    required this.keptInbound,
    required this.embedded,
  });
}

/// What one seeding did, in counts.
class SeedReport {
  final int conversations;
  final int keptThreads;
  final int gatedThreads;
  final int embedded;
  final int embedFailures;

  /// Every thread, in the order the items named them. The replay walks this
  /// rather than asking the store again: it already knows which threads it
  /// wrote and which of them have something kept.
  final List<SeededThread> threads;

  const SeedReport({
    required this.conversations,
    required this.keptThreads,
    required this.gatedThreads,
    required this.embedded,
    required this.embedFailures,
    required this.threads,
  });

  Map<String, Object?> toJson() => {
        'conversations': conversations,
        'kept_threads': keptThreads,
        'gated_threads': gatedThreads,
        'embedded': embedded,
        'embed_failures': embedFailures,
      };

  /// Counts and nothing else — no key, no subject, no participant.
  String table() => 'seed: $conversations conversations, '
      '$keptThreads with a kept inbound message, $gatedThreads fully gated, '
      '$embedded embedded, $embedFailures embed failures';
}

/// One message row, before it is written: the message the set recorded and the
/// two triage columns this seeding decides for it.
class _SeedMessage {
  final Message message;
  final String triageStatus;
  final String? gateReason;

  const _SeedMessage({
    required this.message,
    required this.triageStatus,
    required this.gateReason,
  });

  String get id => message.id;
  bool get outbound => message.outbound;
  String? get receivedAt => message.receivedAt;
  bool get kept => triageStatus != 'skipped';

  /// The same row under another row's gate verdict — what a de-duplication
  /// collision produces when the loser was gated.
  _SeedMessage gatedAs(_SeedMessage other) => _SeedMessage(
        message: message,
        triageStatus: other.triageStatus,
        gateReason: other.gateReason,
      );

  /// What two rows are the same message BY: when the set recorded it, and what
  /// it says. The ids cannot be used — a tail entry's is synthetic and carries
  /// the id of the item that quoted it, so the same message has as many ids as
  /// items quote it.
  String get signature => '$receivedAt\u0000${message.bodyText}';
}

/// Seeds the conversations, messages, triage, extractions and vectors behind
/// [set], and returns what it wrote.
///
/// [cards] is a bulk run file's topics and summary, exactly as
/// `make golden-storyline` uses one: the replay never triaged these messages,
/// so the only honest card is the one the app would carry if the model that
/// wrote that run file were the one shipping.
///
/// [withParticipants] is `SWEEP_CARD`, passed straight to the app's own
/// `clusteringCardForConversationRow`. It is the variable this bench prices,
/// so it is a parameter rather than a read of the app's own
/// `StorylineTuning.participantsInClusteringCard` — a seeding that consulted
/// the const could only ever measure the const.
///
/// [ownerName] and [ownerAddress] are the inbox owner, who is the sender of
/// every `You` message in a thread tail. Empty strings are tolerated and leave
/// the row's sender as the set recorded it.
///
/// An embedding that fails is COUNTED and never fatal: the embedding server
/// answering nonsense for one thread costs that thread its place in the pool,
/// and the run should report that rather than die ninety minutes in.
Future<SeedReport> seedGoldenMailbox(
  MessageStore store,
  GoldenSet set,
  GoldenCards cards, {
  required bool withParticipants,
  required EmbeddingsClient embeddings,
  required String ownerName,
  required String ownerAddress,
}) async {
  // Insertion-ordered, so two runs of the same set write the same threads in
  // the same order. Two golden items drawn from one conversation are ONE
  // thread — the golden set's own rule, and the app files threads.
  final grouped = <String, List<GoldenItem>>{};
  for (final item in set.items) {
    grouped
        .putIfAbsent('${item.source}\n${item.conversationKey}', () => [])
        .add(item);
  }

  final threads = <SeededThread>[];
  var embedded = 0;
  var embedFailures = 0;

  for (final group in grouped.values) {
    final first = group.first;
    final source = first.source;
    final key = first.conversationKey;
    if (key.isEmpty) continue;

    // First-seen order, case-insensitively de-duplicated: the same union
    // `StorylineService._participantsOfStoryline` builds, so the card this
    // seeding embeds is the card the app would embed.
    final seen = <String>{};
    final displays = <String>[];
    for (final item in group) {
      for (final person in item.conversationParticipants) {
        if (person.isEmpty) continue;
        if (seen.add(person.toLowerCase())) displays.add(person);
      }
    }

    // One row per underlying MESSAGE, not per quotation of one. The same
    // message reaches this loop once as an item's own and once inside another
    // item's tail, under two ids, and a gated thread whose message another
    // item quotes would otherwise come back kept.
    final rows = <_SeedMessage>[];
    final indexBySignature = <String, int>{};
    // What each seeded id resolved to, so a card written for an item that lost
    // a collision still lands on the row that survived it.
    final survivingId = <String, String>{};

    void addRow(_SeedMessage row) {
      final index = indexBySignature[row.signature];
      if (index == null) {
        indexBySignature[row.signature] = rows.length;
        rows.add(row);
        survivingId[row.id] = row.id;
        return;
      }
      final kept = rows[index];
      survivingId[row.id] = kept.id;
      // The GATED verdict wins, and the first id stays. Gold calling a thread
      // a drop has to cover every row of it, so a collision that kept one copy
      // and skipped the other would leave the thread in the pool on the
      // strength of a message the same gold threw out.
      if (!row.kept && kept.kept) rows[index] = kept.gatedAs(row);
    }

    for (final item in group) {
      // The gold verdict covers the item's own message and every inbound
      // message of its thread — see rule 1 in the header.
      final dropped = item.gold.gateVerdict == 'drop';
      addRow(_seedRowFor(item.message, dropped: dropped));
      for (final tail in item.tail) {
        addRow(_seedRowFor(tail, dropped: dropped));
      }
    }

    final inbound = [for (final row in rows) if (!row.outbound) row];
    final lastMessageAt = _newest([for (final row in rows) row.receivedAt]);
    final lastInboundAt = _newest([for (final row in inbound) row.receivedAt]);
    final lastOutboundAt =
        _newest([for (final row in rows) if (row.outbound) row.receivedAt]);

    await store.upsertConversation({
      'source': source,
      'conversation_key': key,
      'subject': first.conversationSubject,
      'participants_json':
          jsonEncode([for (final display in displays) {'name': display}]),
      'state': first.conversationState,
      // Over the de-duplicated rows, so a thread two items quote is not a
      // thread that looks twice as long as it is.
      'message_count': rows.length,
      'inbound_count': inbound.length,
      'last_inbound_at': lastInboundAt,
      'last_outbound_at': lastOutboundAt,
      // The sweep pool is ordered `last_message_at DESC` and the assign pass
      // walks it in arrival order, so this column decides what the replay
      // measures. Derived from the newest message rather than written by hand
      // for gotcha 4's reason: two runs must see one order.
      'last_message_at': lastMessageAt,
    });

    // Hand-built rather than through a `toRow` — `Message` has none — exactly
    // as `corpus_seed.dart` builds one.
    for (final row in rows) {
      final message = row.message;
      await store.upsertMessage({
        'source': source,
        'source_message_id': row.id,
        'conversation_key': key,
        'direction': message.outbound ? 'outbound' : 'inbound',
        'subject': message.subject ?? first.conversationSubject,
        'from_name': message.outbound && ownerName.isNotEmpty
            ? ownerName
            : message.fromName,
        'from_address': message.outbound && ownerAddress.isNotEmpty
            ? ownerAddress
            : message.fromAddress,
        'received_at': message.receivedAt,
        'body_text': message.bodyText,
        'is_read': message.isRead ? 1 : 0,
        'addressed_me': message.addressedMe ? 1 : 0,
        'triage_status': row.triageStatus,
        'gate_reason': row.gateReason,
      });
    }

    // What the pipeline would have written for the messages it kept. Only the
    // items have a card: the set records a thread tail as text, and no stage
    // ever ran on one.
    final byId = {for (final row in rows) row.id: row};
    for (final item in group) {
      final card = cards.byId[item.id];
      if (card == null) continue;
      final id = survivingId[item.message.id];
      final row = id == null ? null : byId[id];
      if (row == null || row.outbound || !row.kept) continue;
      if (card.summary != null) {
        await store.writeTriage(
          source,
          row.id,
          status: 'triaged',
          // The card's summary and task defaults for the rest. The run file's
          // other triage fields are not carried by `GoldenCards` and nothing
          // on the clustering path reads them: the card is built from
          // `messages.summary` and the extraction topics, and those are what
          // this write exists to put where `newestInboundCardData` looks.
          result: TriageResult(
            urgency: 'normal',
            category: 'other',
            summary: card.summary!,
            needsAction: false,
            actionItems: const [],
          ),
        );
      }
      if (card.topics.isNotEmpty) {
        await store.writeExtraction(
          source,
          row.id,
          jsonEncode({'topics': card.topics}),
        );
      }
    }

    final keptInbound = inbound.any((row) => row.kept);
    var wroteVector = false;
    if (keptInbound) {
      // The app's OWN recipe over the row this seeding just wrote, and the
      // app's own rule for which message's summary and topics ride in it:
      // kept inbound first, then newest. A second recipe here would embed a
      // corpus the app never has, which is the one thing this bench must not
      // measure.
      final stored = await store.getConversationRow(source, key);
      final card = clusteringCardForConversationRow(
        stored!,
        await store.newestInboundCardData(source, key),
        withParticipants: withParticipants,
      );
      final result = await embeddings.embedResult(card);
      final vector = result.vector;
      if (vector == null) {
        embedFailures++;
      } else {
        // The identical write `StorylineService._reembed` makes, tag included.
        await store.upsertConversationAi(
          source,
          key,
          embedding: encodeEmbedding(vector),
          embeddedHash: cardHash(card),
          embedModel: EmbeddingsClient.modelTag,
        );
        embedded++;
        wroteVector = true;
      }
    }

    threads.add(SeededThread(
      source: source,
      conversationKey: key,
      lastMessageAt: lastMessageAt,
      keptInbound: keptInbound,
      embedded: wroteVector,
    ));
  }

  return SeedReport(
    conversations: threads.length,
    keptThreads: threads.where((t) => t.keptInbound).length,
    gatedThreads: threads.where((t) => !t.keptInbound).length,
    embedded: embedded,
    embedFailures: embedFailures,
    threads: threads,
  );
}

/// The triage columns one seeded message gets.
_SeedMessage _seedRowFor(Message message, {required bool dropped}) {
  if (message.outbound) {
    final (status, reason) = triageStatusOnInsert(outbound: true);
    return _SeedMessage(
      message: message,
      triageStatus: status,
      gateReason: reason,
    );
  }
  return _SeedMessage(
    message: message,
    // `triaged` and not `pending`: these messages have been through the
    // pipeline by the time a sweep looks at the mailbox, and a pending row
    // would have the lifecycle gate call the mailbox unsettled.
    triageStatus: dropped ? 'skipped' : 'triaged',
    gateReason: dropped ? goldDropGateReason : null,
  );
}

/// The latest of some ISO-8601 stamps, or null when there are none. A string
/// comparison IS the chronological one for the stamps the connectors store.
String? _newest(List<String?> stamps) {
  String? newest;
  for (final stamp in stamps) {
    if (stamp == null || stamp.isEmpty) continue;
    if (newest == null || newest.compareTo(stamp) < 0) newest = stamp;
  }
  return newest;
}

/// [key] with every digit spelled out, so the default subject gives each
/// thread its own SERIES key.
///
/// The sweep's series pre-pass folds every digit run in a subject to one
/// placeholder, which would make `Subject for c1`, `Subject for c2` and
/// `Subject for c3` one recurring series — three threads with no outbound
/// message and one sender, so the pre-pass would drop them from the pool and
/// every test that seeds three default threads would see nothing. Spelling
/// the digits keeps the fixture's keys apart under the fold. A test that
/// passes its own subject is unaffected.
String _spellDigits(String key) {
  const words = {
    '0': 'zero',
    '1': 'one',
    '2': 'two',
    '3': 'three',
    '4': 'four',
    '5': 'five',
    '6': 'six',
    '7': 'seven',
    '8': 'eight',
    '9': 'nine',
  };
  final out = StringBuffer();
  for (final rune in key.split('')) {
    final word = words[rune];
    if (word == null) {
      out.write(rune);
    } else {
      out.write(out.isEmpty ? word : ' $word');
    }
  }
  return out.toString();
}

/// One thread with a vector, for a unit test that needs a pool rather than a
/// mailbox.
///
/// The shape `storyline_service_test.dart`'s own `seed` has, shared so a new
/// test does not write a fifth copy of it — the old tests keep theirs. The one
/// rule worth restating: **a seeded vector brings the kept inbound message it
/// implies.** A conversation carrying an embedding and no messages is a shape
/// the app cannot produce — extraction writes the embedding and does not run
/// until triage has spoken — and both the sweep pool and `assignConversation`
/// ask for a kept inbound message before they look at a vector, so such a
/// thread would be silently invisible. Pass `keptInbound: false` to build that
/// state on purpose.
///
/// [messageCount], [inboundCount] and [fromAddress] are the series pre-pass's
/// three facts: a group where every thread is unanswered and one address sent
/// the newest kept message in all of them is a notification feed, not a
/// recurring effort. Only a test that means to build that shape passes them.
Future<void> seedThread(
  MessageStore store,
  String key, {
  List<double>? vector,
  List<String> participants = const [],
  String state = 'waiting',
  String lastMessageAt = '2026-08-28T10:00:00Z',
  String? subject,
  String embedModel = EmbeddingsClient.modelTag,
  String source = 'email',
  bool keptInbound = true,
  int? messageCount,
  int? inboundCount,
  String fromAddress = 'sarah@example.com',
}) async {
  await store.upsertConversation({
    'source': source,
    'conversation_key': key,
    'subject': subject ?? 'Subject for ${_spellDigits(key)}',
    'state': state,
    'last_message_at': lastMessageAt,
    'participants_json':
        jsonEncode([for (final person in participants) {'name': person}]),
    // Left off the map entirely when the test does not care: the series
    // pre-pass reads them, and a column the fixture never writes keeps the
    // schema's own default.
    'message_count': ?messageCount,
    'inbound_count': ?inboundCount,
  });
  if (vector == null) return;
  if (keptInbound) {
    await store.upsertMessage({
      'source': source,
      'source_message_id': 'kept-$key',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject ?? 'Subject for ${_spellDigits(key)}',
      'from_name': 'Sarah',
      'from_address': fromAddress,
      'received_at': lastMessageAt,
      'body_text': 'body of kept-$key',
      'triage_status': 'triaged',
    });
  }
  await store.upsertConversationAi(
    source,
    key,
    embedding: encodeEmbedding(vector),
    embeddedHash: 'h-$key',
    embedModel: embedModel,
  );
}
