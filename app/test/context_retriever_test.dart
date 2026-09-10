import 'dart:convert';
import 'dart:typed_data';

import 'package:bond_inbox/data/context_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/context_models.dart';
import 'package:bond_inbox/services/context/context_retriever.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
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
      expect(short.excerpts, hasLength(3));
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

  test('the floor is the search\'s own, restated nowhere', () {
    // A second spelling of the number is how the mailbox search and the
    // directory search would start disagreeing about what "relevant" means.
    expect(SearchTuning.minScore, 0.25);
    expect(ContextTuning.maxSkills, 2);
  });
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
