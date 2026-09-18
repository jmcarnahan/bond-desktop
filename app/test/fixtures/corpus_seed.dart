import 'package:bond_inbox/data/message_store.dart';

import 'corpus.dart';

/// The suffix copy [copy] of the corpus carries on its ids.
///
/// Copy 1 carries NONE, which is the compatibility rule this whole file turns
/// on: `make drain` asserts on `emailCorpus`'s own ids, so a seeding that
/// renamed the first copy would silently stop measuring the same mail.
String copySuffix(int copy) => copy <= 1 ? '' : '-c$copy';

/// One message's id in copy [copy].
String corpusMessageId(String id, int copy) => '$id${copySuffix(copy)}';

/// [emailCorpus] in the store, [copies] times over.
///
/// Body, headers and all, the way a delta page plus a detail fetch would have
/// left it — the queues that read this are given no `ensureBody`, so what is
/// stored here is all they will ever have to read. Deliberately NO conversation
/// rows: what these benches measure is the drain, and a thread would drag the
/// fold-up and the embedding in with it.
///
/// Copies exist because the corpus is twenty-two messages and the backlog the
/// roadmap's targets are written about is sixty. Each copy suffixes both the
/// message id and the conversation key, so copy 2's threads are threads of
/// their own rather than twenty-two messages landing in copy 1's — which would
/// measure a thread getting longer instead of a mailbox getting fuller.
Future<void> seedCorpus(MessageStore store, {int copies = 1}) async {
  for (var copy = 1; copy <= copies; copy++) {
    final suffix = copySuffix(copy);
    for (final entry in emailCorpus) {
      final message = entry.message;
      await store.upsertMessage({
        'source': message.source,
        'source_message_id': '${entry.id}$suffix',
        'conversation_key': '${entry.conversationKey}$suffix',
        'direction': message.outbound ? 'outbound' : 'inbound',
        'subject': message.subject,
        'from_name': message.fromName,
        'from_address': message.fromAddress,
        'received_at': message.receivedAt,
        'body_preview': message.bodyPreview,
        'body_text': message.bodyText,
        'source_meta_json': message.sourceMetaJson,
        'triage_status': 'pending',
      });
    }
  }
}

/// Every seeded message the gates will let through to a model, across
/// [copies] — what a throughput number is legitimately divided by.
///
/// All `email`: [emailCorpus] is the one-source slice of [corpus], which is
/// what both benches seed.
List<String> ungatedCorpusIds({int copies = 1}) => [
      for (var copy = 1; copy <= copies; copy++)
        for (final entry in emailCorpus)
          if (entry.expectedGate == null) corpusMessageId(entry.id, copy),
    ];
