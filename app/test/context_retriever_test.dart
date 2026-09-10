import 'dart:convert';
import 'dart:typed_data';

import 'package:bond_inbox/data/context_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/context_models.dart';
import 'package:bond_inbox/services/context/context_chunker.dart';
import 'package:bond_inbox/services/context/context_pack_render.dart'
    show renderContextGuidance;
import 'package:bond_inbox/services/context/context_retriever.dart';
import 'package:bond_inbox/services/llm/context_select_task.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/search_fusion.dart' show SearchTuning;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/fake_embed_server.dart';
import 'fixtures/vec_test_db.dart';

/// What a reply is allowed to read out of the owner's own folders, and — far
/// more importantly — what it is not.
///
/// The retriever's reason for existing is a scope. A model handed the nearest
/// passage in every project the owner has registered would quote one client's
/// notes into another client's reply, in the owner's name, and it would read
/// perfectly. So most of what follows is the same test from a different side:
/// the answer comes from a directory THIS room links, or from one its
/// storyline links, or it does not come at all.
///
/// The second promise is that nothing here throws. A draft is the product; the
/// directory is what makes one better.
void main() {
  const tag = EmbeddingsClient.documentModelTag;

  late bool available;
  late BondDatabase db;
  late MessageStore messages;
  late ContextStore context;
  late FakeEmbedServer embeddings;

  setUpAll(() {
    available = ensureSqliteVecLoaded();
  });

  setUp(() {
    db = vecTestDb();
    messages = MessageStore(db);
    context = ContextStore(db);
    embeddings = FakeEmbedServer();
  });

  tearDown(() async => db.close());

  ContextRetriever retriever() =>
      ContextRetriever(messages, context, embeddings.client);

  /// An inbound message with a vector already stored, which is the ordinary
  /// case: the embed queue reaches inbound mail long before anyone asks for a
  /// draft of it.
  Future<void> seedMessage(
    String id, {
    String key = 'conv-1',
    int axis = 1,
    String subject = 'Re: Renewal quote',
    String body = 'What does the renewal come to?',
    bool vector = true,
  }) async {
    await messages.upsertMessage({
      'source': 'email',
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'from_name': 'Dana Whitfield',
      'from_address': 'dana@example.test',
      'received_at': '2026-09-09T09:00:00.000Z',
      'body_text': body,
    });
    if (!vector) return;
    await messages.upsertMessageVector(
      source: 'email',
      sourceMessageId: id,
      embedding: encodeEmbedding(axes({axis: 1.0})),
      dims: 768,
      embeddedHash: 'h-$id',
      embedModel: tag,
      receivedAt: '2026-09-09T09:00:00.000Z',
    );
  }

  Future<int> seedFile(
    String dirId,
    String relPath, {
    String kind = 'doc',
    List<String> chain = const [],
    String? description,
    String? pathsJson,
    String text = '',
    String status = 'ok',
    String mtime = '2026-08-30T09:00:00.000Z',
  }) async {
    final id = await context.upsertFile(
      dirId: dirId,
      relPath: relPath,
      size: 400,
      mtime: mtime,
      sha256: 'sha-$relPath',
      kind: kind,
      claudeChain: chain,
      description: description,
      pathsJson: pathsJson,
      textChars: text.length,
      status: status,
    );
    if (text.isNotEmpty) await context.setFileText(id, text);
    return id;
  }

  /// One passage, filed exactly as the reconcile pass files one: the stored
  /// text opens with the `<relPath> · <locator>` header, and the vector is
  /// written against that same string.
  Future<int> seedChunk(
    int fileId,
    String relPath,
    String body, {
    String locator = '',
    Map<int, double>? vector,
    int seq = 0,
  }) async {
    final header = locator.isEmpty ? relPath : '$relPath · $locator';
    final id = await context.appendChunk(
      fileId,
      locator: locator,
      text: '$header\n$body',
    );
    if (vector != null) {
      await context.setChunkEmbedding(
        id,
        embedding: encodeEmbedding(axes(vector)),
        dims: 768,
        embedModel: tag,
      );
    }
    return id;
  }

  Future<List<Map<String, Object?>>> workRows() async {
    final rows = await db
        .customSelect('SELECT task_kind, source, entity_id, status '
            'FROM work_items')
        .get();
    return [for (final row in rows) row.data];
  }

  group('the scope', () {
    test('a room with nothing linked costs no read at all', () async {
      await seedMessage('m1');
      // A file, a passage and a vector all sitting there — and none of them
      // in this room's scope, which is the whole point.
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      final file = await seedFile(dir, 'docs/pricing.md',
          text: 'Q4 rates hold at nine.');
      await seedChunk(file, 'docs/pricing.md', 'Q4 rates hold at nine.',
          vector: {1: 1.0});

      final pack = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );

      expect(pack.isEmpty, isTrue);
      expect(pack.directories, isEmpty);
      expect(pack.excerpts, isEmpty);
      // Not one POST. This runs on every draft and almost every room has no
      // directory linked to it.
      expect(embeddings.calls, 0);
    });

    test('a linked directory with no passages answers its brief and stops',
        () async {
      await seedMessage('m1');
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      await context.setDirectoryWalked(dir,
          walkedAt: MessageStore.isoStamp(DateTime.now().toUtc()),
          rootHash: 'r', filesCount: 0, textBytes: 0);
      await context.setDirectoryBrief(dir,
          briefJson: jsonEncode({
            'about': 'A renewal pricing model.',
            'reply_guidance': ['Answer in two lines.'],
            'key_facts': ['Q4 rates hold at nine.'],
            'vocabulary': ['Marrowfield'],
          }),
          briefHash: 'h');
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');

      final pack = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );

      expect(pack.directories, ['acme']);
      expect(pack.briefs.single.about, 'A renewal pricing model.');
      expect(pack.briefs.single.keyFacts, ['Q4 rates hold at nine.']);
      expect(pack.briefs.single.vocabulary, ['Marrowfield']);
      expect(pack.guidance.single.label, 'guidance');
      expect(pack.guidance.single.text, 'Answer in two lines.');
      expect(pack.excerpts, isEmpty);
      // The `LIMIT 1` guard stands in front of the vector read.
      expect(embeddings.calls, 0);
    });

    test('a directory that said nothing is not named as a source', () async {
      // A project linked a minute ago: registered, walked, and holding no
      // brief and nothing indexed. The composer's caption is built from this
      // list, and "drafted from this thread, your past mail and «acme»" when
      // not one of acme's words reached the prompt is a claim about the model
      // that is not true.
      await seedMessage('m1');
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      await context.setDirectoryWalked(dir,
          walkedAt: MessageStore.isoStamp(DateTime.now().toUtc()),
          rootHash: 'r', filesCount: 0, textBytes: 0);
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');

      final pack = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );

      expect(pack.directories, isEmpty);
      expect(pack.isEmpty, isTrue);
    });

    test('two linked directories, and only the one that spoke is named',
        () async {
      await seedMessage('m1');
      final spoke = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      final silent = await context.registerDirectory(path: '/b',
          displayName: 'ridge');
      for (final dir in [spoke, silent]) {
        await context.setDirectoryWalked(dir,
            walkedAt: MessageStore.isoStamp(DateTime.now().toUtc()),
            rootHash: 'r', filesCount: 0, textBytes: 0);
        await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');
      }
      await context.setDirectoryBrief(spoke,
          briefJson: jsonEncode({'about': 'A renewal pricing model.'}),
          briefHash: 'h');

      final pack = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );

      expect(pack.directories, ['acme']);
    });

    test('a directory nobody linked is not searched, and its skill is not '
        'matched', () async {
      if (!available) return;
      // Two projects saying near-identical things on the same axis. The only
      // difference between them is the link row, and it is the whole answer:
      // a paragraph of one client's project in another client's reply is the
      // failure this path has to be incapable of.
      await seedMessage('m1');
      final linked = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      final stranger = await context.registerDirectory(path: '/b',
          displayName: 'ridge');

      for (final (dir, name) in [(linked, 'acme'), (stranger, 'ridge')]) {
        final file = await seedFile(dir, 'docs/pricing.md',
            text: 'The $name rung schedule is settled.');
        await seedChunk(file, 'docs/pricing.md',
            'The $name rung schedule is settled.',
            vector: {1: 1.0});
        final skill = await seedFile(
          dir,
          '.claude/skills/$name-replies/SKILL.md',
          kind: 'skill',
          description: 'Quote a renewal rate.',
          text: '---\nname: $name-replies\n'
              'description: Quote a renewal rate.\n---\n'
              'Always name the rung.\n',
        );
        await context.setFileDescEmbedding(
            skill, encodeEmbedding(axes({1: 1.0})));
      }
      await context.indexPendingChunks();
      await context.link(linked, ContextScopeKind.thread, 'email', 'conv-1');

      final pack = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );

      expect(pack.excerpts, isNotEmpty);
      for (final excerpt in pack.excerpts) {
        expect(excerpt.dirId, linked);
        expect(excerpt.dirName, 'acme');
      }
      // The skill halves are searched by the same scope, through a different
      // read — so the scope is asserted on both.
      expect(pack.skills, ['acme-replies']);
      expect(pack.directories, ['acme']);
    });

    test('a thread reads what its storyline links', () async {
      if (!available) return;
      await seedMessage('m1');
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      final file = await seedFile(dir, 'docs/pricing.md',
          text: 'Q4 rates hold at nine.');
      await seedChunk(file, 'docs/pricing.md', 'Q4 rates hold at nine.',
          vector: {1: 1.0});
      await context.indexPendingChunks();
      // Linked to the STORYLINE, never to the thread.
      await context.link(dir, ContextScopeKind.storyline, '', 'story-7');

      final pack = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const ['story-7'],
      );

      expect(pack.directories, ['acme']);
      expect(pack.excerpts.single.relPath, 'docs/pricing.md');
      expect(pack.excerpts.single.dirName, 'acme');
    });
  });

  group('the ranking', () {
    /// Four passages: one the vector alone finds, one the words alone find,
    /// one both find, and one neither is about.
    Future<ContextPack> fourPassages() async {
      await seedMessage('m1', subject: 'Re: Marrowfield renewal quote');
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      final near = await seedFile(dir, 'docs/near.md');
      final words = await seedFile(dir, 'docs/words.md');
      final both = await seedFile(dir, 'docs/both.md');
      final far = await seedFile(dir, 'docs/far.md');

      await seedChunk(near, 'docs/near.md', 'The rung schedule is settled.',
          vector: {1: 1.0});
      // No vector at all: this one exists only in the word index, which is
      // exactly the file a part number or a function name lives in.
      await seedChunk(words, 'docs/words.md',
          'Marrowfield renewal quote and nothing else.');
      await seedChunk(both, 'docs/both.md',
          'The Marrowfield renewal quote sits on the settled rung.',
          vector: {1: 1.0});
      await seedChunk(far, 'docs/far.md', 'Unrelated kitchen inventory.',
          vector: {7: 1.0});
      await context.indexPendingChunks();
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');

      return retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );
    }

    test('both signals beat either alone, and neither is dropped', () async {
      if (!available) return;
      final pack = await fourPassages();
      final paths = [for (final e in pack.excerpts) e.relPath];

      expect(paths.first, 'docs/both.md');
      expect(paths, contains('docs/near.md'));
      expect(paths, contains('docs/words.md'));
      // Under the floor on both halves. "Nothing here is about that" has to
      // be a possible answer.
      expect(paths, isNot(contains('docs/far.md')));
    });

    test('no one file fills the answer, and k is the ceiling', () async {
      if (!available) return;
      await seedMessage('m1');
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      final file = await seedFile(dir, 'docs/report.md');
      for (var seq = 0; seq < 4; seq++) {
        await seedChunk(file, 'docs/report.md', 'The rung schedule, part $seq.',
            locator: 'part $seq', vector: {1: 1.0}, seq: seq);
      }
      final other = await seedFile(dir, 'docs/terms.md');
      await seedChunk(other, 'docs/terms.md', 'The rung schedule, in terms.',
          vector: {1: 1.0});
      await context.indexPendingChunks();
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');

      final capped = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
        perFile: 2,
      );
      expect(
        [for (final e in capped.excerpts) e.relPath]
            .where((p) => p == 'docs/report.md')
            .length,
        2,
      );

      final short = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
        perFile: 4,
        k: 3,
      );
      // WHICH three, not merely how many: `k` cuts the ranked list after
      // the per-file cap, so the three that survive are the head of the
      // ranking in order — and a count alone would pass just as happily on
      // a list that had lost the nearest passage and kept a far one.
      expect(
        [for (final e in short.excerpts) '${e.relPath} · ${e.locator}'],
        [
          'docs/report.md · part 0',
          'docs/report.md · part 1',
          'docs/report.md · part 2',
        ],
      );
    });

    test('a long passage is skipped rather than ending the list', () async {
      if (!available) return;
      await seedMessage('m1');
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      final long = await seedFile(dir, 'docs/long.md');
      final shortA = await seedFile(dir, 'docs/a.md');
      final shortB = await seedFile(dir, 'docs/b.md');
      // Nearest, and far too big for the budget.
      await seedChunk(long, 'docs/long.md', 'X' * 2000, vector: {1: 1.0});
      await seedChunk(shortA, 'docs/a.md', 'The rung schedule is settled.',
          vector: {1: 0.99});
      await seedChunk(shortB, 'docs/b.md', 'The rung schedule holds.',
          vector: {1: 0.98});
      await context.indexPendingChunks();
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');

      final pack = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
        budgetChars: 600,
      );

      final paths = [for (final e in pack.excerpts) e.relPath];
      expect(paths, isNot(contains('docs/long.md')));
      expect(paths, containsAll(<String>['docs/a.md', 'docs/b.md']));
    });

    test('a file the caller named floats first and is exempt from the floor',
        () async {
      if (!available) return;
      await seedMessage('m1');
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      final named = await seedFile(dir, 'docs/named.md');
      final near = await seedFile(dir, 'docs/near.md');
      await seedChunk(named, 'docs/named.md', 'Unrelated kitchen inventory.',
          vector: {7: 1.0});
      await seedChunk(near, 'docs/near.md', 'The rung schedule is settled.',
          vector: {1: 1.0});
      await context.indexPendingChunks();
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');

      final without = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );
      expect(
        [for (final e in without.excerpts) e.relPath],
        isNot(contains('docs/named.md')),
      );

      final with_ = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
        consultFirst: [named],
      );
      // First, and present at all: a floor calibrated on "is this about the
      // same thing" has no standing against a person saying "read this".
      expect(with_.excerpts.first.relPath, 'docs/named.md');
      // And it floats rather than replaces: what the question itself found is
      // still in the prompt behind it.
      expect(
        [for (final e in with_.excerpts) e.relPath],
        contains('docs/near.md'),
      );
    });

    test('a named file off the neighbour page is READ, not merely ranked',
        () async {
      if (!available) return;
      await seedMessage('m1');
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      // More nearer passages than the neighbour page holds. A file somebody
      // pointed at is usually not on that page — which is why they pointed.
      for (var i = 0; i < 14; i++) {
        final near = await seedFile(dir, 'docs/near-$i.md');
        await seedChunk(near, 'docs/near-$i.md', 'The rung schedule holds.',
            vector: {1: 1.0 - i * 0.001});
      }
      final named = await seedFile(dir, 'docs/named.md');
      await seedChunk(named, 'docs/named.md', 'Unrelated kitchen inventory.',
          vector: {7: 1.0});
      await context.indexPendingChunks();
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');

      final pack = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
        consultFirst: [named],
        k: 6,
      );

      expect(pack.excerpts.first.relPath, 'docs/named.md');
    });

    test('a named file outside every linked directory stays outside',
        () async {
      if (!available) return;
      await seedMessage('m1');
      final linked = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      final other = await context.registerDirectory(path: '/b',
          displayName: 'ridge');
      final here = await seedFile(linked, 'docs/near.md');
      await seedChunk(here, 'docs/near.md', 'The rung schedule is settled.',
          vector: {1: 1.0});
      final elsewhere = await seedFile(other, 'docs/secret.md');
      await seedChunk(elsewhere, 'docs/secret.md', 'Another client entirely.',
          vector: {7: 1.0});
      await context.indexPendingChunks();
      await context.link(linked, ContextScopeKind.thread, 'email', 'conv-1');

      final pack = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
        consultFirst: [elsewhere],
      );

      // Naming a file is not a way past the scope. One client's paragraph in
      // another client's reply is the failure this path must be incapable of.
      expect(
        [for (final e in pack.excerpts) e.relPath],
        isNot(contains('docs/secret.md')),
      );
    });

    test('a named file is read from the top when nothing can rank it',
        () async {
      await seedMessage('m1');
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      final named = await seedFile(dir, 'docs/named.md');
      await seedChunk(named, 'docs/named.md', 'The opening paragraph.',
          seq: 0);
      await seedChunk(named, 'docs/named.md', 'The second paragraph.', seq: 1);
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');

      // The embedding server is down, so there is no question to measure
      // nearness against — and "read this file first" still has an answer.
      final pack = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
        consultFirst: [named],
        queryVector: () async => null,
      );

      expect(
        [for (final e in pack.excerpts) e.text],
        ['The opening paragraph.', 'The second paragraph.'],
      );
    });
  });

  group('a passage as the prompt sees it', () {
    test('the header line comes off and the path is the FILE row\'s', () async {
      if (!available) return;
      await seedMessage('m1');
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      final file = await seedFile(dir, 'docs/pricing.md');
      await seedChunk(file, 'docs/pricing.md', 'The rung schedule is settled.',
          locator: 'Pricing > Q4 rates', vector: {1: 1.0});
      await context.indexPendingChunks();
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');
      // A rename keeps the passage and its vector and only refiles the word
      // rows, so `chunk_text`'s own header now names where the file WAS.
      await context.renameFile(file, 'docs/rates.md');

      final pack = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );

      final excerpt = pack.excerpts.single;
      expect(excerpt.text, 'The rung schedule is settled.');
      expect(excerpt.relPath, 'docs/rates.md');
      expect(excerpt.locator, 'Pricing > Q4 rates');
      expect(excerpt.modified, '2026-08-30');
    });

    test('the digest passage is kept and labelled', () async {
      if (!available) return;
      await seedMessage('m1');
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      final file = await seedFile(dir, 'analysis.html', status: 'truncated');
      await seedChunk(file, 'analysis.html',
          'What the rung schedule concluded.',
          locator: 'digest', vector: {1: 1.0});
      await context.indexPendingChunks();
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');

      final pack = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );

      expect(pack.excerpts.single.locator, 'digest');
      expect(pack.excerpts.single.truncated, isTrue);
    });
  });

  group('the guidance', () {
    test('a matching skill is offered and a far one is not', () async {
      if (!available) return;
      await seedMessage('m1');
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      final file = await seedFile(dir, 'docs/pricing.md');
      await seedChunk(file, 'docs/pricing.md', 'The rung schedule is settled.',
          vector: {1: 1.0});

      final near = await seedFile(
        dir,
        '.claude/skills/vendor-replies/SKILL.md',
        kind: 'skill',
        description: 'Quote a renewal rate.',
        text: '---\nname: vendor-replies\n'
            'description: Quote a renewal rate.\n---\n'
            'Always name the rung.\n',
      );
      final far = await seedFile(
        dir,
        '.claude/skills/kitchen/SKILL.md',
        kind: 'skill',
        description: 'Order the kitchen inventory.',
        text: '---\ndescription: Order the kitchen inventory.\n---\nNo.\n',
      );
      await context.setFileDescEmbedding(
          near, encodeEmbedding(axes({1: 1.0})));
      await context.setFileDescEmbedding(far, encodeEmbedding(axes({2: 1.0})));
      await context.indexPendingChunks();
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');

      final pack = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );

      expect(pack.skills, ['vendor-replies']);
      final skill = pack.guidance
          .firstWhere((block) => block.label == 'SKILL vendor-replies');
      // The description first: it is the author's own sentence saying when
      // this applies, and the steps under it mean nothing without it.
      expect(skill.text, startsWith('Quote a renewal rate.'));
      expect(skill.text, contains('Always name the rung.'));
      expect(
        [for (final block in pack.guidance) block.label],
        isNot(contains('SKILL kitchen')),
      );
    });

    test('a skill nobody can name does not spend one of the two slots',
        () async {
      if (!available) return;
      // Three skills on the query axis, the nearest of them filed at the root
      // with no folder above it and no frontmatter name. It cannot be
      // rendered, so it must not be counted — a slot spent on a block that
      // never appears is the second-nearest skill's place given away for
      // nothing.
      await seedMessage('m1');
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      final file = await seedFile(dir, 'docs/pricing.md');
      await seedChunk(file, 'docs/pricing.md', 'The rung schedule is settled.',
          vector: {1: 1.0});

      final nameless = await seedFile(
        dir,
        'SKILL.md',
        kind: 'skill',
        description: 'Quote a renewal rate.',
        text: '---\ndescription: Quote a renewal rate.\n---\nNo name here.\n',
      );
      final first = await seedFile(
        dir,
        '.claude/skills/vendor-replies/SKILL.md',
        kind: 'skill',
        description: 'Quote a renewal rate.',
        text: '---\nname: vendor-replies\n'
            'description: Quote a renewal rate.\n---\nName the rung.\n',
      );
      final second = await seedFile(
        dir,
        '.claude/skills/renewal-notes/SKILL.md',
        kind: 'skill',
        description: 'Quote a renewal rate.',
        text: '---\nname: renewal-notes\n'
            'description: Quote a renewal rate.\n---\nCite the table.\n',
      );
      // The nameless one is nearest, then the two that can be named.
      await context.setFileDescEmbedding(
          nameless, encodeEmbedding(axes({1: 1.0})));
      await context.setFileDescEmbedding(
          first, encodeEmbedding(axes({1: 1.0, 2: 0.1})));
      await context.setFileDescEmbedding(
          second, encodeEmbedding(axes({1: 1.0, 2: 0.2})));
      await context.indexPendingChunks();
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');

      final pack = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );

      expect(pack.skills, ['vendor-replies', 'renewal-notes']);
      expect(
        [for (final block in pack.guidance) block.label],
        containsAll(['SKILL vendor-replies', 'SKILL renewal-notes']),
      );
    });

    test('a nested CLAUDE.md rides only with a passage under it', () async {
      if (!available) return;
      await seedMessage('m1');
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      await seedFile(dir, 'docs/CLAUDE.md',
          kind: 'claude_md', text: '# docs\n\nCite the table, never the prose.\n');
      final under = await seedFile(dir, 'docs/pricing.md');
      final elsewhere = await seedFile(dir, 'src/rates.py');
      await context.setFileChain(under, const ['CLAUDE.md', 'docs/CLAUDE.md']);
      await context.setFileChain(elsewhere, const ['CLAUDE.md']);
      await seedChunk(elsewhere, 'src/rates.py', 'The rung schedule is settled.',
          vector: {1: 1.0});
      await context.indexPendingChunks();
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');

      final withoutIt = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );
      expect(
        [for (final block in withoutIt.guidance) block.label],
        isNot(contains('docs/CLAUDE.md')),
      );

      // Now a passage from UNDER the nested notes, which is what makes them
      // apply — Claude Code's own on-demand rule.
      await seedChunk(under, 'docs/pricing.md', 'The rung schedule, in docs.',
          vector: {1: 1.0});
      await context.indexPendingChunks();

      final withIt = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );
      final nested = withIt.guidance
          .firstWhere((block) => block.label == 'docs/CLAUDE.md');
      expect(nested.text, contains('Cite the table'));
    });

    test('the root notes stand in for a brief, and never beside one', () async {
      await seedMessage('m1');
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      await seedFile(dir, 'CLAUDE.md',
          kind: 'claude_md', text: '# acme\n\nReplies here stay short.\n');
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');

      final withoutBrief = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );
      expect(withoutBrief.guidance.single.label, 'CLAUDE.md');
      expect(withoutBrief.guidance.single.text, contains('stay short'));

      await context.setDirectoryBrief(dir,
          briefJson: jsonEncode({
            'about': 'A renewal pricing model.',
            'reply_guidance': ['Answer in two lines.'],
          }),
          briefHash: 'h');

      final withBrief = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );
      // The brief was compiled FROM those notes. Both would be the same
      // instructions twice, once summarised and once whole.
      expect([for (final block in withBrief.guidance) block.label],
          ['guidance']);
    });

    test('every block says which project it came from', () async {
      if (!available) return;
      await seedMessage('m1');
      // The same three files in two projects. Six identically-labelled
      // blocks of contradictory instructions is a draft following whichever
      // it read last, with nothing to say which project it was obeying.
      final labels = <String>[];
      for (final name in ['acme', 'beta']) {
        final dir = await context.registerDirectory(
            path: '/$name', displayName: name);
        await seedFile(dir, 'docs/CLAUDE.md',
            kind: 'claude_md',
            text: '# docs\n\nIn $name, cite the table.\n');
        await seedFile(dir, '.claude/rules/pricing.md',
            kind: 'rule',
            pathsJson: '["docs/**"]',
            text: '---\npaths: docs/**\n---\nIn $name, never round up.\n');
        final skill = await seedFile(
          dir,
          '.claude/skills/vendor-replies/SKILL.md',
          kind: 'skill',
          description: 'Quote a renewal rate.',
          text: '---\nname: vendor-replies\n'
              'description: Quote a renewal rate.\n---\n'
              'In $name, name the rung.\n',
        );
        await context.setFileDescEmbedding(
            skill, encodeEmbedding(axes({1: 1.0})));
        final under = await seedFile(dir, 'docs/pricing.md');
        await context.setFileChain(under, const ['docs/CLAUDE.md']);
        await seedChunk(under, 'docs/pricing.md',
            'The rung schedule is settled in $name.',
            vector: {1: 1.0});
        await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');
        labels.addAll([
          'docs/CLAUDE.md «$name»',
          'SKILL vendor-replies «$name»',
          'rule pricing.md «$name»',
        ]);
      }
      await context.indexPendingChunks();

      final pack = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );

      expect(
        [for (final block in pack.guidance) block.label]..sort(),
        labels..sort(),
      );
      expect(
        pack.guidance
            .firstWhere((b) => b.label == 'rule pricing.md «beta»')
            .text,
        contains('In beta, never round up.'),
      );
    });

    test('the fence is fitted to its budget, and the rules still arrive',
        () async {
      if (!available) return;
      await seedMessage('m1');
      // Two real projects' worth of standing advice. Before the fence was
      // fitted this overran it by thousands of characters and the renderer
      // answered by dropping whole blocks off the END — so the rules never
      // reached the model while the pack went on naming them.
      final line = 'Quote the rung and never the prose, and say which sheet '
          'the figure came from before anything else. ' * 2;
      for (final name in ['acme', 'beta']) {
        final dir = await context.registerDirectory(
            path: '/$name', displayName: name);
        await context.setDirectoryBrief(
          dir,
          briefJson: jsonEncode({
            'about': 'A renewal pricing model.',
            'reply_guidance': [for (var i = 0; i < 6; i++) '$i. $line'],
          }),
          briefHash: 'h-$name',
        );
        await seedFile(dir, '.claude/rules/pricing.md',
            kind: 'rule',
            pathsJson: '["docs/**"]',
            text: '---\npaths: docs/**\n---\n${'R' * 400}\n');
        final file = await seedFile(dir, 'docs/pricing.md');
        await seedChunk(file, 'docs/pricing.md',
            'The rung schedule is settled in $name.',
            vector: {1: 1.0});
        await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');
      }
      // One skill, matched by the cosine, at its full body cap.
      final acme = (await context.directories()).first;
      final skill = await seedFile(
        acme.id,
        '.claude/skills/vendor-replies/SKILL.md',
        kind: 'skill',
        description: 'Quote a renewal rate.',
        text: '---\nname: vendor-replies\n'
            'description: Quote a renewal rate.\n---\n${'S' * 600}\n',
      );
      await context.setFileDescEmbedding(
          skill, encodeEmbedding(axes({1: 1.0})));
      await context.indexPendingChunks();

      final pack = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );

      final rendered =
          renderContextGuidance(pack, ContextTuning.guidanceBudget);
      expect(rendered.length, lessThanOrEqualTo(ContextTuning.guidanceBudget));
      // Nothing was lost to the renderer's clamp: every block the pack
      // carries is in the text the model reads.
      for (final block in pack.guidance) {
        expect(rendered, contains('[${block.label}]'), reason: block.label);
      }
      final labels = [for (final block in pack.guidance) block.label];
      expect(labels, containsAll(<String>[
        'rule pricing.md «acme»',
        'rule pricing.md «beta»',
        'SKILL vendor-replies «acme»',
      ]));
      expect(pack.skills, ['vendor-replies']);
      // The broad blocks paid for it. Standing advice shortened still says
      // something; a rule that never arrived says nothing at all.
      for (final block in pack.guidance.where((b) => b.broad)) {
        expect(block.text.length, lessThan(6 * line.length));
        expect(block.text.length,
            greaterThanOrEqualTo(ContextTuning.guidanceFloor));
      }
    });

    test('a skill the fence could not hold is not named either', () async {
      if (!available) return;
      await seedMessage('m1');
      // Five projects' standing advice, all of it already at the floor, and
      // two skills behind it. Nothing can be shortened any further, so the
      // last block goes — and `pack.skills` has to say so, because it is
      // what the provenance row shows a person as the instructions the
      // draft was written under.
      final dirs = <String>[];
      for (var i = 0; i < 5; i++) {
        final dir = await context.registerDirectory(
            path: '/p$i', displayName: 'p$i');
        await context.setDirectoryBrief(
          dir,
          briefJson: jsonEncode({
            'about': 'A project.',
            'reply_guidance': ['${'G' * 400}$i'],
          }),
          briefHash: 'h$i',
        );
        await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');
        dirs.add(dir);
      }
      final file = await seedFile(dirs.first, 'docs/pricing.md');
      await seedChunk(file, 'docs/pricing.md', 'The rung schedule is settled.',
          vector: {1: 1.0});
      final nearer = await seedFile(
        dirs.first,
        '.claude/skills/vendor-replies/SKILL.md',
        kind: 'skill',
        description: 'Quote a renewal rate.',
        text: '---\nname: vendor-replies\n'
            'description: Quote a renewal rate.\n---\n${'S' * 600}\n',
      );
      final farther = await seedFile(
        dirs[1],
        '.claude/skills/renewal-notes/SKILL.md',
        kind: 'skill',
        description: 'Quote a renewal rate.',
        text: '---\nname: renewal-notes\n'
            'description: Quote a renewal rate.\n---\n${'T' * 600}\n',
      );
      await context.setFileDescEmbedding(
          nearer, encodeEmbedding(axes({1: 1.0})));
      await context.setFileDescEmbedding(
          farther, encodeEmbedding(axes({1: 1.0, 2: 0.2})));
      await context.indexPendingChunks();

      final pack = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );

      final labels = [for (final block in pack.guidance) block.label];
      expect(labels, contains('SKILL vendor-replies «p0»'));
      expect(labels, isNot(contains('SKILL renewal-notes «p1»')));
      // The list the provenance reads names what the model actually read.
      expect(pack.skills, ['vendor-replies']);
      expect(
        renderContextGuidance(pack, ContextTuning.guidanceBudget).length,
        lessThanOrEqualTo(ContextTuning.guidanceBudget),
      );
    });

    test('a rule rides only when its own paths match a kept passage',
        () async {
      if (!available) return;
      await seedMessage('m1');
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      await seedFile(dir, '.claude/rules/pricing.md',
          kind: 'rule',
          pathsJson: '["docs/**"]',
          text: '---\npaths: docs/**\n---\nNever round a rate up.\n');
      await seedFile(dir, '.claude/rules/source.md',
          kind: 'rule',
          pathsJson: '["src/**"]',
          text: '---\npaths: src/**\n---\nNever paste a key.\n');
      final file = await seedFile(dir, 'docs/pricing.md');
      await seedChunk(file, 'docs/pricing.md', 'The rung schedule is settled.',
          vector: {1: 1.0});
      await context.indexPendingChunks();
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');

      final pack = await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );

      final labels = [for (final block in pack.guidance) block.label];
      expect(labels, contains('rule pricing.md'));
      expect(labels, isNot(contains('rule source.md')));
      expect(
        pack.guidance
            .firstWhere((block) => block.label == 'rule pricing.md')
            .text,
        contains('Never round a rate up.'),
      );
    });
  });

  group('freshness and failure', () {
    test('a stale directory is queued for a re-read and never waited on',
        () async {
      await seedMessage('m1');
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      await context.setDirectoryWalked(
        dir,
        walkedAt: MessageStore.isoStamp(
          DateTime.now().toUtc().subtract(const Duration(minutes: 11)),
        ),
        rootHash: 'r',
        filesCount: 0,
        textBytes: 0,
      );
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');

      await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );

      final rows = await workRows();
      expect(rows, hasLength(1));
      expect(rows.single['task_kind'], 'context_reconcile');
      expect(rows.single['source'], 'local');
      expect(rows.single['entity_id'], dir);
      expect(rows.single['status'], 'pending');
    });

    test('a fresh directory queues nothing', () async {
      await seedMessage('m1');
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      await context.setDirectoryWalked(dir,
          walkedAt: MessageStore.isoStamp(DateTime.now().toUtc()),
          rootHash: 'r', filesCount: 0, textBytes: 0);
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');

      await retriever().packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );

      expect(await workRows(), isEmpty);
    });

    test('a store that throws costs the passages and not the brief', () async {
      await seedMessage('m1');
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      await context.setDirectoryWalked(dir,
          walkedAt: MessageStore.isoStamp(DateTime.now().toUtc()),
          rootHash: 'r', filesCount: 1, textBytes: 40);
      await context.setDirectoryBrief(dir,
          briefJson: jsonEncode({'about': 'A renewal pricing model.'}),
          briefHash: 'h');
      final file = await seedFile(dir, 'docs/pricing.md');
      await seedChunk(file, 'docs/pricing.md', 'The rung schedule is settled.',
          vector: {1: 1.0});
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');

      final pack = await ContextRetriever(
        messages,
        _ThrowingContextStore(db),
        embeddings.client,
      ).packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );

      expect(pack.briefs.single.about, 'A renewal pricing model.');
      expect(pack.excerpts, isEmpty);
    });

    test('a message with no vector and no embedder still answers its brief',
        () async {
      // The embedding server is down. Degraded, never thrown: the reply below
      // this is written without citations.
      await seedMessage('m1', vector: false);
      final dead = FakeEmbedServer(status: null);
      final dir = await context.registerDirectory(path: '/a',
          displayName: 'acme');
      await context.setDirectoryWalked(dir,
          walkedAt: MessageStore.isoStamp(DateTime.now().toUtc()),
          rootHash: 'r', filesCount: 1, textBytes: 40);
      await context.setDirectoryBrief(dir,
          briefJson: jsonEncode({'about': 'A renewal pricing model.'}),
          briefHash: 'h');
      final file = await seedFile(dir, 'docs/pricing.md');
      await seedChunk(file, 'docs/pricing.md', 'The rung schedule is settled.',
          vector: {1: 1.0});
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');

      final pack = await ContextRetriever(messages, context, dead.client)
          .packFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const [],
      );

      expect(pack.briefs.single.about, 'A renewal pricing model.');
      expect(pack.excerpts, isEmpty);
      expect(pack.skills, isEmpty);
    });
  });

  group('look closer', () {
    /// A price sheet with a nested section, a sibling that is unrelated, and
    /// a preamble before either — cut up by the REAL chunker, so every
    /// locator in the fixture is one the app would actually have written.
    const priceSheet = '''
Rates are reviewed each quarter by the Marrowfield desk.

## Pricing

The desk publishes one sheet and nothing else binds a renewal quote.

### Q4 rates

Standard freight is 41 credits per pallet.

## Kitchen

The kitchen inventory is counted on the first of the month.
''';

    /// The chunker's own passages, filed as the reconcile pass files them and
    /// each embedded on [axis]. Real locators, because the whole feature is
    /// the model handing one of them back.
    Future<void> seedChunked(
      int fileId,
      String relPath,
      String text, {
      int axis = 1,
      bool vectors = true,
    }) async {
      final ids = await context.replaceChunks(fileId, [
        for (final chunk in chunkContextText(relPath, text))
          (seq: chunk.seq, locator: chunk.locator, text: chunk.text),
      ]);
      if (!vectors) return;
      for (final id in ids) {
        await context.setChunkEmbedding(
          id,
          embedding: encodeEmbedding(axes({axis: 1.0})),
          dims: 768,
          embedModel: tag,
        );
      }
    }

    /// A linked directory holding the price sheet, with a brief whose one
    /// pointer names it. The pointer is what makes the call happen: a pack
    /// with pointers qualifies however short its ranking is.
    Future<String> seedDirectory({
      String sheet = priceSheet,
      int axis = 1,
      bool vectors = true,
      bool messageVector = true,
      List<String> chain = const [],
    }) async {
      await seedMessage('m1', vector: messageVector);
      final dir =
          await context.registerDirectory(path: '/a', displayName: 'acme');
      await context.setDirectoryWalked(dir,
          walkedAt: MessageStore.isoStamp(DateTime.now().toUtc()),
          rootHash: 'r', filesCount: 1, textBytes: sheet.length);
      await context.setDirectoryBrief(
        dir,
        briefJson: jsonEncode({
          'about': 'A renewal pricing model.',
          'pointers': [
            {'topic': 'renewal rates', 'path': 'docs/pricing.md'},
          ],
        }),
        briefHash: 'h',
      );
      final file =
          await seedFile(dir, 'docs/pricing.md', text: sheet, chain: chain);
      await seedChunked(file, 'docs/pricing.md', sheet,
          axis: axis, vectors: vectors);
      await context.indexPendingChunks();
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');
      return dir;
    }

    Future<ContextPack> packWith(
      FakeLlm? fake, {
      bool on = true,
      EmbeddingsClient? embedder,
      int perFile = 3,
      int budgetChars = 2500,
      int k = 6,
    }) =>
        ContextRetriever(
          messages,
          context,
          embedder ?? embeddings.client,
          fastClient: fake,
          selectExpand: () => on,
        ).packFor(
          source: 'email',
          conversationKey: 'conv-1',
          replyToId: 'm1',
          storylineIds: const [],
          perFile: perFile,
          budgetChars: budgetChars,
          k: k,
        );

    /// The same sheet with nothing in it the message's own words can reach.
    /// The subject is `Renewal quote`, and the keyword half of the ranking
    /// would otherwise carry the file in on those two words alone — which is
    /// not the pack these cases are about.
    const unreachableSheet = '''
## Pricing

The desk publishes one sheet and nothing else binds a rate.

### Q4 rates

Standard freight is 41 credits per pallet.
''';

    Map<String, dynamic> answer({
      List<Map<String, String>> read = const [],
      List<String> skills = const [],
      String reason = 'The section holds the figure.',
    }) =>
        {'read': read, 'skills': skills, 'reason': reason};

    test('a section is read whole, and what it contains comes out', () async {
      if (!available) return;
      final dir = await seedDirectory();
      // A second file, so there is a ranked passage the expansion has no
      // business touching: the per-file cap would otherwise have trimmed the
      // sheet's own sibling section off the page before the model saw it.
      const notes = '## Kitchen\n\nThe inventory is counted on the first.\n';
      final other = await seedFile(dir, 'docs/notes.md', text: notes);
      await seedChunked(other, 'docs/notes.md', notes);
      await context.indexPendingChunks();
      final fake = FakeLlm([
        answer(read: [
          {'path': 'docs/pricing.md', 'locator': 'Pricing'},
        ]),
      ]);

      final pack = await packWith(fake);

      final first = pack.excerpts.first;
      expect(first.expanded, isTrue);
      expect(first.locator, 'Pricing');
      // The whole of `## Pricing` is `## Pricing` AND its `### Q4 rates`.
      expect(first.text, contains('The desk publishes one sheet'));
      expect(first.text, contains('41 credits per pallet'));
      expect(pack.expanded, ['docs/pricing.md § Pricing']);

      // The passages the section already holds are gone — quoting a
      // paragraph beside the section it was cut from reads as two sources
      // saying the same thing, and spends the fence twice.
      final rest = pack.excerpts.skip(1).toList();
      expect([for (final e in rest) e.locator],
          isNot(contains('Pricing')));
      expect([for (final e in rest) e.locator],
          isNot(contains('Pricing > Q4 rates')));
      // And the other file's passage is still there, behind it.
      expect([for (final e in rest) e.relPath], contains('docs/notes.md'));
      expect(pack.selectError, isNull);
    });

    test('a clamped section keeps the passages it did not reach', () async {
      if (!available) return;
      // A section far longer than the ceiling: the expansion arrives cut to
      // three thousand characters, and the parts past the cut are the only
      // place the rest of it still exists.
      final body = [
        for (var i = 0; i < 60; i++)
          'Paragraph $i of the desk\'s pricing note, which sets out how one '
              'renewal is quoted and what the freight rung costs.',
      ].join('\n\n');
      final dir = await seedDirectory(sheet: '## Pricing\n\n$body\n',
          vectors: false);
      final file = (await context.fileByPath(dir, 'docs/pricing.md'))!;
      final parts = await context.chunksForFile(file.id, limit: 50);
      expect(parts.length, greaterThanOrEqualTo(5),
          reason: 'the real chunker cuts this into parts');
      expect(parts.first.locator, 'Pricing · part 1');
      // The first part and the last, both ranked. One is inside the three
      // thousand characters that arrive and one is past them.
      for (final part in [parts.first, parts.last]) {
        await context.setChunkEmbedding(
          part.chunkId,
          embedding: encodeEmbedding(axes({1: 1.0})),
          dims: 768,
          embedModel: tag,
        );
      }
      await context.indexPendingChunks();
      final fake = FakeLlm([
        answer(read: [
          {'path': 'docs/pricing.md', 'locator': 'Pricing'},
        ]),
      ]);

      final pack = await packWith(fake);

      final expanded = pack.excerpts.first;
      expect(expanded.expanded, isTrue);
      expect(expanded.text.length, ContextTuning.expandedSectionCap);
      final rest = [for (final e in pack.excerpts.skip(1)) e.locator];
      // The part the clamp cut off is still in the pack. Dropping it because
      // the WHOLE section would have held it takes those paragraphs out of
      // the prompt and puts nothing in their place.
      expect(rest, contains(parts.last.locator));
      // And the part the section really does carry comes out, as before.
      expect(rest, isNot(contains('Pricing · part 1')));
    });

    test('a section that fits still drops every part of it', () async {
      if (!available) return;
      // The behaviour the clamp rule must not disturb: a section the ceiling
      // never touched holds all of its parts, so quoting one beside it is
      // two sources saying the same thing.
      final body = [
        for (var i = 0; i < 25; i++)
          'Paragraph $i of the desk\'s pricing note about the freight rung.',
      ].join('\n\n');
      final dir = await seedDirectory(sheet: '## Pricing\n\n$body\n',
          vectors: false);
      final file = (await context.fileByPath(dir, 'docs/pricing.md'))!;
      final parts = await context.chunksForFile(file.id, limit: 50);
      expect(parts.length, greaterThanOrEqualTo(2));
      for (final part in parts) {
        await context.setChunkEmbedding(
          part.chunkId,
          embedding: encodeEmbedding(axes({1: 1.0})),
          dims: 768,
          embedModel: tag,
        );
      }
      await context.indexPendingChunks();
      final fake = FakeLlm([
        answer(read: [
          {'path': 'docs/pricing.md', 'locator': 'Pricing'},
        ]),
      ]);

      final pack = await packWith(fake);

      expect(pack.excerpts.single.expanded, isTrue);
      expect(pack.excerpts.single.text.length,
          lessThan(ContextTuning.expandedSectionCap));
    });

    test('a part of a prose file expands to the file, and says so', () async {
      if (!available) return;
      // The case a `.txt` makes: there is no `part 2` to cut out of a prose
      // file, so the reader hands back the whole text. Expanding it under
      // the locator `part 2` would leave parts 1 and 3 quoted beside the
      // very words that already hold them.
      final dir = await seedDirectory();
      final notes = [
        for (var i = 0; i < 17; i++)
          'Paragraph $i of the analysis, at about the length one of them '
              'runs to when somebody has written it out in full for a '
              'reader who was not there.',
      ].join('\n\n');
      final file = await seedFile(dir, 'notes.txt', text: notes);
      final chunks = await context.replaceChunks(file, [
        for (final chunk in chunkContextText('notes.txt', notes))
          (seq: chunk.seq, locator: chunk.locator, text: chunk.text),
      ]);
      expect(chunks.length, 3);
      for (final id in chunks) {
        await context.setChunkEmbedding(
          id,
          embedding: encodeEmbedding(axes({1: 1.0})),
          dims: 768,
          embedModel: tag,
        );
      }
      await context.indexPendingChunks();
      final fake = FakeLlm([
        answer(read: [
          {'path': 'notes.txt', 'locator': 'part 2'},
        ]),
      ]);

      final pack = await packWith(fake);

      final mine = [
        for (final e in pack.excerpts)
          if (e.relPath == 'notes.txt') e,
      ];
      expect(mine, hasLength(1));
      expect(mine.single.expanded, isTrue);
      // The render says `whole file, read in full`, and the handback names
      // the bare path — both of which are true, and `part 2` was not.
      expect(mine.single.locator, '');
      expect(pack.expanded, ['notes.txt']);
    });

    test('the selector saw the message, the pointers and the passages',
        () async {
      if (!available) return;
      await seedDirectory();
      final fake = FakeLlm([answer()]);

      await packWith(fake);

      final sent = fake.userMessages.single;
      expect(sent, contains('renewal rates · docs/pricing.md'));
      // Fenced, so the chunker's ` > ` breadcrumb arrives escaped — every
      // one of these lines is inside an `<untrusted_data>` block.
      expect(sent, contains('docs/pricing.md · Pricing &gt; Q4 rates · '));
      expect(sent, contains('Renewal quote'));
      expect(sent, contains('<untrusted_data source="candidates">'));
      // Deterministic: two drafts of one message must read the same
      // sections.
      expect(fake.temperatures.single, 0);
    });

    test('a very long section is clamped to its own ceiling', () async {
      if (!available) return;
      final long = '## Pricing\n\n${'word ' * 4000}\n';
      await seedDirectory(sheet: long);
      final fake = FakeLlm([
        answer(read: [
          {'path': 'docs/pricing.md', 'locator': 'Pricing'},
        ]),
      ]);

      final pack = await packWith(fake);

      expect(pack.excerpts.first.expanded, isTrue);
      expect(pack.excerpts.first.text.length,
          ContextTuning.expandedSectionCap);
    });

    test('an empty answer changes nothing at all', () async {
      if (!available) return;
      await seedDirectory();
      final fake = FakeLlm([answer()]);

      final chosen = await packWith(fake);
      final untouched = await packWith(null);

      expect([for (final e in chosen.excerpts) e.locator],
          [for (final e in untouched.excerpts) e.locator]);
      expect(chosen.expanded, isEmpty);
      expect(chosen.selectError, isNull);
      expect(fake.userMessages, hasLength(1));
    });

    test('a selector that throws changes nothing and is noted', () async {
      if (!available) return;
      await seedDirectory();
      final fake = FakeLlm([Exception('boom')]);

      final failed = await packWith(fake);
      final untouched = await packWith(null);

      expect([for (final e in failed.excerpts) e.locator],
          [for (final e in untouched.excerpts) e.locator]);
      expect(failed.expanded, isEmpty);
      expect(failed.selectError, contains('boom'));
      // The brief, the guidance and the skills the pack already had are the
      // pack it would have been anyway.
      expect(failed.briefs.single.about, 'A renewal pricing model.');
      expect(failed.skills, untouched.skills);
    });

    test('the preference off makes no call', () async {
      if (!available) return;
      await seedDirectory();
      final fake = FakeLlm([answer()]);

      final pack = await packWith(fake, on: false);

      expect(fake.userMessages, isEmpty);
      expect(pack.excerpts, isNotEmpty);
      expect(pack.expanded, isEmpty);
    });

    test('no pointers and a short ranking makes no call', () async {
      if (!available) return;
      // Three passages and no brief. The ranking has already shown the model
      // nearly everything the directory had to say, and choosing two of
      // three it can see in full is a model call spent reordering.
      await seedMessage('m1');
      final dir =
          await context.registerDirectory(path: '/a', displayName: 'acme');
      final file = await seedFile(dir, 'docs/pricing.md', text: 'x');
      for (var seq = 0; seq < 3; seq++) {
        await seedChunk(file, 'docs/pricing.md', 'The rung schedule $seq.',
            locator: 'part $seq', vector: {1: 1.0}, seq: seq);
      }
      await context.indexPendingChunks();
      await context.link(dir, ContextScopeKind.thread, 'email', 'conv-1');
      final fake = FakeLlm([answer()]);

      final pack = await packWith(fake);

      expect(fake.userMessages, isEmpty);
      expect(pack.excerpts, isNotEmpty);
      expect(ContextTuning.selectMinCandidates, 8);
    });

    test('a path outside the scope is not read', () async {
      if (!available) return;
      await seedDirectory();
      // A second project, registered and never linked to this room. Its file
      // exists and its path is spellable; the scope is the whole point.
      final other =
          await context.registerDirectory(path: '/b', displayName: 'ridge');
      await seedFile(other, 'secret/rates.md',
          text: '## Rates\n\nAnother client pays nineteen.\n');
      final fake = FakeLlm([
        answer(read: [
          {'path': 'secret/rates.md', 'locator': 'Rates'},
        ]),
      ]);

      final pack = await packWith(fake);

      expect(pack.expanded, isEmpty);
      // Not an error either: the model named a file this room may not read,
      // and the pack it would have had is the pack it gets.
      expect(pack.selectError, isNull);
      expect([for (final e in pack.excerpts) e.text],
          isNot(contains(contains('nineteen'))));
    });

    test('a chosen skill displaces the second cosine match', () async {
      if (!available) return;
      final dir = await seedDirectory();
      final near = await seedFile(
        dir,
        '.claude/skills/vendor-replies/SKILL.md',
        kind: 'skill',
        description: 'Quote a renewal rate.',
        text: '---\ndescription: Quote a renewal rate.\n---\nName the rung.\n',
      );
      final second = await seedFile(
        dir,
        '.claude/skills/scheduling/SKILL.md',
        kind: 'skill',
        description: 'Offer times.',
        text: '---\ndescription: Offer times.\n---\nOffer two slots.\n',
      );
      // The third has no description vector at all, so the cosine cannot
      // reach it — which is exactly the skill the selector is for.
      await seedFile(
        dir,
        '.claude/skills/renewals/SKILL.md',
        kind: 'skill',
        description: 'Answer a renewal question.',
        text: '---\ndescription: Answer a renewal question.\n---\nCite it.\n',
      );
      await context.setFileDescEmbedding(
          near, encodeEmbedding(axes({1: 1.0})));
      await context.setFileDescEmbedding(
          second, encodeEmbedding(axes({1: 1.0, 2: 1.0})));
      final fake = FakeLlm([answer(skills: const ['renewals'])]);

      final pack = await packWith(fake);

      // Displaced, never stacked: three sets of instructions is a draft
      // obeying whichever it read last.
      expect(pack.skills, ['renewals', 'vendor-replies']);
      final labels = [
        for (final block in pack.guidance)
          if (block.label.startsWith('SKILL ')) block.label,
      ];
      expect(labels, ['SKILL renewals', 'SKILL vendor-replies']);
    });

    test('an empty locator reads the whole file and clears its passages',
        () async {
      if (!available) return;
      await seedDirectory();
      final fake = FakeLlm([
        answer(read: [
          {'path': 'docs/pricing.md', 'locator': ''},
        ]),
      ]);

      final pack = await packWith(fake);

      final whole = pack.excerpts.single;
      expect(whole.relPath, 'docs/pricing.md');
      expect(whole.expanded, isTrue);
      expect(whole.locator, '');
      expect(whole.text, contains('Rates are reviewed each quarter'));
      expect(whole.text, contains('kitchen inventory'));
      // Every ranked passage of that file is now in front of the model
      // twice over if it stays, so none of them does.
      expect(pack.expanded, ['docs/pricing.md']);
    });

    test('a leading ./ on the answer still finds the file', () async {
      if (!available) return;
      await seedDirectory();
      final fake = FakeLlm([
        answer(read: [
          {'path': './docs/pricing.md', 'locator': 'Pricing'},
        ]),
      ]);

      final pack = await packWith(fake);

      expect(pack.expanded, ['docs/pricing.md § Pricing']);
    });

    test('a pointer is read closer with no vector and no embedder', () async {
      if (!available) return;
      // The embedding server is down and nothing in the directory carries a
      // vector, so there is no ranking at all — and the brief still POINTS at
      // the file that answers this. The selector reads pointers, not vectors,
      // so this is exactly the pack it exists for.
      await seedDirectory(vectors: false, messageVector: false);
      final dead = FakeEmbedServer(status: null);
      final fake = FakeLlm([
        answer(read: [
          {'path': 'docs/pricing.md', 'locator': ''},
        ]),
      ]);

      final pack = await packWith(fake, embedder: dead.client);

      expect(fake.userMessages, hasLength(1));
      final whole = pack.excerpts.single;
      expect(whole.expanded, isTrue);
      expect(whole.text, contains('41 credits per pallet'));
      expect(pack.expanded, ['docs/pricing.md']);
      // Skills are matched against a vector and there is none, so the cosine
      // offered none and the answer named none.
      expect(pack.skills, isEmpty);
      expect(pack.selectError, isNull);
    });

    test('an expanded file brings the notes beside it', () async {
      if (!available) return;
      // Every passage of the sheet is on a far axis, so the ranking keeps
      // none of them and the pointer is the only way in. The nested note
      // governing `docs/` has to ride with the section all the same.
      final dir = await seedDirectory(
        sheet: unreachableSheet,
        axis: 9,
        chain: const ['CLAUDE.md', 'docs/CLAUDE.md'],
      );
      await seedFile(dir, 'docs/CLAUDE.md',
          text: 'Every rate in this folder is quoted per pallet.\n');
      final fake = FakeLlm([
        answer(read: [
          {'path': 'docs/pricing.md', 'locator': 'Pricing'},
        ]),
      ]);

      final pack = await packWith(fake);

      expect(pack.expanded, ['docs/pricing.md § Pricing']);
      final labels = [for (final block in pack.guidance) block.label];
      expect(labels, contains('docs/CLAUDE.md'));
      expect(
        pack.guidance
            .firstWhere((block) => block.label == 'docs/CLAUDE.md')
            .text,
        contains('quoted per pallet'),
      );
    });

    test('an expanded file brings the rule that governs it', () async {
      if (!available) return;
      final dir = await seedDirectory(sheet: unreachableSheet, axis: 9);
      await seedFile(dir, '.claude/rules/pricing.md',
          kind: 'rule',
          pathsJson: '["docs/**"]',
          text: '---\npaths: docs/**\n---\nNever round a rate up.\n');
      final fake = FakeLlm([
        answer(read: [
          {'path': 'docs/pricing.md', 'locator': 'Pricing'},
        ]),
      ]);

      final pack = await packWith(fake);

      expect(pack.expanded, ['docs/pricing.md § Pricing']);
      final labels = [for (final block in pack.guidance) block.label];
      expect(labels, contains('rule pricing.md'));
    });

    test('an expanded window swallows the windows it covers', () async {
      if (!available) return;
      final dir = await seedDirectory();
      // Two hundred lines cut into sixty-line windows every fifty lines:
      // `lines 1–60`, `lines 51–110`, `lines 101–160`, `lines 151–200`.
      final code = [for (var i = 1; i <= 200; i++) 'line $i'].join('\n');
      final file = await seedFile(dir, 'lib/rate.dart', text: code);
      await seedChunked(file, 'lib/rate.dart', code);
      await context.indexPendingChunks();
      final fake = FakeLlm([
        answer(read: [
          {'path': 'lib/rate.dart', 'locator': 'lines 61–120'},
        ]),
      ]);

      // Room for every window of the file, so what the drop rule takes out is
      // the only reason one is missing.
      final pack =
          await packWith(fake, perFile: 8, budgetChars: 12000, k: 20);

      final first = pack.excerpts.first;
      expect(first.expanded, isTrue);
      // Two windows on, because a function rarely ends where its window did.
      expect(first.text.split('\n').first, 'line 61');
      expect(first.text.split('\n').last, 'line 180');
      final rest = [
        for (final excerpt in pack.excerpts.skip(1))
          if (excerpt.relPath == 'lib/rate.dart') excerpt.locator,
      ];
      // Entirely inside 61–180, so quoting it again is the same sixty lines
      // twice.
      expect(rest, isNot(contains('lines 101–160')));
      // These two are not: one opens before line 61 and the other runs past
      // line 180, and each carries lines the section does not.
      expect(rest, contains('lines 51–110'));
      expect(rest, contains('lines 151–200'));
    });

    test('a section and the section inside it are read once', () async {
      if (!available) return;
      for (final order in [
        [
          {'path': 'docs/pricing.md', 'locator': 'Pricing > Q4 rates'},
          {'path': 'docs/pricing.md', 'locator': 'Pricing'},
        ],
        [
          {'path': 'docs/pricing.md', 'locator': 'Pricing'},
          {'path': 'docs/pricing.md', 'locator': 'Pricing > Q4 rates'},
        ],
      ]) {
        await seedDirectory();
        final fake = FakeLlm([answer(read: order)]);

        final pack = await packWith(fake);

        // The larger wins either way round. Expanding both would put the
        // child's text in the fence twice, which is what the drop rule is
        // for in the first place.
        expect(pack.expanded, ['docs/pricing.md § Pricing'],
            reason: order.first['locator']);
        expect(
          [for (final e in pack.excerpts) if (e.expanded) e.locator],
          ['Pricing'],
          reason: order.first['locator'],
        );
        await db.close();
        db = vecTestDb();
        messages = MessageStore(db);
        context = ContextStore(db);
      }
    });

    test('a skill is named by its folder, whatever its header says', () async {
      if (!available) return;
      final dir = await seedDirectory();
      await seedFile(
        dir,
        '.claude/skills/renewals/SKILL.md',
        kind: 'skill',
        description: 'Answer a renewal question.',
        text: '---\nname: quote-desk\ndescription: Answer a renewal '
            'question.\n---\nCite the rung.\n',
      );
      final fake = FakeLlm([answer(skills: const ['renewals'])]);

      final pack = await packWith(fake);

      // What the model is SHOWN and what the block is LABELLED are one name,
      // or the dedup between the cosine's picks and the model's is comparing
      // two spellings of the same file.
      expect(fake.userMessages.single, contains('renewals · Answer a renewal'));
      expect(pack.skills, ['renewals']);
      expect([for (final block in pack.guidance) block.label],
          contains('SKILL renewals'));
    });

    test('the two ceilings are the same number, said once each', () {
      // The fence in `draft_task.dart` was widened to hold exactly this
      // many sections; a task that could ask for three would overrun it.
      expect(ContextTuning.maxExpanded, ContextSelectTask.maxRead);
    });
  });

  test('the floor is the search\'s own, restated nowhere', () {
    // A second spelling of the number is how the mailbox search and the
    // directory search would start disagreeing about what "relevant" means.
    expect(SearchTuning.minScore, 0.25);
    expect(ContextTuning.maxSkills, 2);
  });
}

/// An [LlmClient] that answers from a script and never opens a socket.
///
/// The house shape — every test file declares its own, with the positional
/// script `draft_handler_test.dart` uses — because there is no shared fake
/// and two of them would drift.
class FakeLlm extends LlmClient {
  final List<Object> script;
  final List<String> userMessages = [];
  final List<double> temperatures = [];

  FakeLlm(this.script) : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

  @override
  Future<Map<String, dynamic>> completeJson({
    required String system,
    required String user,
    required Map<String, dynamic> schema,
    String schemaName = 'result',
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
  }) async {
    userMessages.add(user);
    temperatures.add(temperature);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final step = script.length > 1 ? script.removeAt(0) : script.first;
    if (step is Exception) throw step;
    return Map<String, dynamic>.from(step as Map);
  }
}

/// A store whose vector half is broken. Everything above it must still answer.
class _ThrowingContextStore extends ContextStore {
  _ThrowingContextStore(super.db);

  @override
  Future<List<ContextChunkHit>?> chunkKnn(
    Uint8List query, {
    required String embedModel,
    required List<String> dirIds,
    List<int>? fileIds,
    int k = 12,
    bool excludeDigests = false,
  }) =>
      throw StateError('the index is on fire');
}
