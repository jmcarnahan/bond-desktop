@Skip('live — needs the embedding server (make embed) and the fast server '
    '(make fast) up at the addresses EmbeddingsClient and LlmClient.fastBaseUrl '
    'default to, and CONTEXT_DIR. Run: cd app && CONTEXT_DIR=/path/to/a/project '
    'flutter test test/context_pack_live_test.dart --run-skipped')
library;

import 'dart:io';

import 'package:bond_inbox/data/context_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/context_models.dart';
import 'package:bond_inbox/services/context/context_brief_handler.dart';
import 'package:bond_inbox/services/context/context_pack_render.dart';
import 'package:bond_inbox/services/context/context_reconcile_handler.dart';
import 'package:bond_inbox/services/context/context_retriever.dart';
import 'package:bond_inbox/services/context/directory_access.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/vec_test_db.dart';

/// What a real project actually hands a reply, PRINTED for a person to read.
///
/// Point `CONTEXT_DIR` at a directory the owner would register — a Claude Code
/// project, a folder of analyses — and this walks it, indexes it, briefs it,
/// and then builds the pack for three canned questions the way a draft would:
/// the same retriever, the same fences, the same section pick. Every block is
/// printed verbatim.
///
/// **Nothing here is scored, and that is the design rather than an omission.**
/// The brief is right when the person who owns the project recognizes their
/// own work in it, and the two sections chosen are right when they are the
/// ones somebody would have opened — neither is a string comparison, and
/// inventing one would score the model against whatever phrasing happened to
/// be typed into a fixture. `CLAUDE.md`'s rule for every live harness in this
/// suite: a threshold here would fail on the next model swap for no defect.
/// So what is asserted is SHAPE — the pick did not fall over, it asked for at
/// most the two sections it is allowed, every passage carries words, and a
/// directory that indexed anything at all is named as a source.
///
/// Digests are turned off for the run: a walk plus its embeddings is the part
/// that has to be real, and forty per-file summary calls would make this a
/// twenty-minute test of a stage `context_digest_handler_test.dart` already
/// pins.
void main() {
  setUpAll(ensureSqliteVecLoaded);

  test(
    'a real directory, three questions, and the pack each one gets',
    () async {
      final path = Platform.environment['CONTEXT_DIR'] ?? '';
      if (path.isEmpty) {
        markTestSkipped('set CONTEXT_DIR to a project to read');
        return;
      }

      final BondDatabase db = vecTestDb();
      addTearDown(db.close);
      final messages = MessageStore(db);
      final context = ContextStore(db);
      final embeddings = EmbeddingsClient();
      final fast = LlmClient(
        baseUrl: LlmClient.fastBaseUrl,
        model: LlmClient.fastModel,
      );

      final dirId = await context.registerDirectory(
        path: path,
        displayName: p.basename(path),
      );
      await context.setDirectoryOptions(dirId, digests: false);

      final walkStarted = DateTime.now();
      await ContextReconcileHandler(
        context,
        embeddings,
        const PlainDirectoryAccess(),
      ).run({
        'task_kind': 'context_reconcile',
        'source': 'local',
        'entity_id': dirId,
        'payload_json': '{"force":true}',
      });
      await ContextBriefHandler(context, fast).run({
        'task_kind': 'context_brief',
        'source': 'local',
        'entity_id': dirId,
      });

      final dir = await context.directory(dirId);
      final counts = await context.chunkCounts(dirId);
      // ignore: avoid_print
      print('\n══ ${p.basename(path)} ══\n'
          'files ${dir?.filesCount ?? 0} · passages ${counts.chunks} · '
          'embedded ${counts.embedded} · '
          'walked and briefed in '
          '${DateTime.now().difference(walkStarted).inMilliseconds} ms');

      await context.link(dirId, ContextScopeKind.thread, 'email', 'conv-live');

      /// The three shapes of question this feature exists for: what a project
      /// FOUND, which file explains a thing and what it says, and how replies
      /// here are supposed to read.
      const questions = <({String id, String subject, String body})>[
        (
          id: 'live-1',
          subject: 'What did the analysis find?',
          body: 'Could you tell me what the analysis concluded?',
        ),
        (
          id: 'live-2',
          subject: 'Which file explains how the sync works, and what does it '
              'say?',
          body: 'I am trying to follow the sync and cannot find where it is '
              'written down.',
        ),
        (
          id: 'live-3',
          subject: 'Remind me what the conventions are for replies here',
          body: 'Before I answer this one, what are the house rules?',
        ),
      ];

      final retriever = ContextRetriever(
        messages,
        context,
        embeddings,
        fastClient: fast,
        selectExpand: () => true,
      );

      for (final question in questions) {
        // No stored vector: the retriever embeds the card itself, which is
        // the path a draft takes when the embed queue has not reached the
        // message yet. The sender is fictional; this repo is public.
        await messages.upsertMessage({
          'source': 'email',
          'source_message_id': question.id,
          'conversation_key': 'conv-live',
          'direction': 'inbound',
          'subject': question.subject,
          'from_name': 'Dana Whitfield',
          'from_address': 'dana@example.test',
          'received_at': '2026-09-09T09:00:00.000Z',
          'body_text': question.body,
        });

        final startedAt = DateTime.now();
        final pack = await retriever.packFor(
          source: 'email',
          conversationKey: 'conv-live',
          replyToId: question.id,
          storylineIds: const [],
        );
        final tookMs = DateTime.now().difference(startedAt).inMilliseconds;

        // ignore: avoid_print
        print('\n── ${question.subject} ── $tookMs ms\n'
            'directories: ${pack.directories}\n'
            'skills: ${pack.skills}\n'
            'read in full: ${pack.expanded}\n'
            'select error: ${pack.selectError}\n'
            '\n[brief]\n${renderContextBrief(pack, 700)}'
            '\n\n[guidance]\n${renderContextGuidance(pack, 1500)}'
            '\n\n[passages]\n${renderContextExcerpts(pack, 8700)}\n');

        // The pick either happened or it did not; it may never fail.
        expect(pack.selectError, isNull, reason: question.id);
        expect(pack.expanded.length, lessThanOrEqualTo(2), reason: question.id);
        for (final excerpt in pack.excerpts) {
          expect(excerpt.text.trim(), isNotEmpty,
              reason: '${question.id} ${excerpt.relPath}');
        }
        // A directory that indexed nothing at all is a folder of binaries and
        // says nothing about anything; one that indexed words has to be named
        // as a source, or the caption would credit a project the model never
        // read.
        if (counts.chunks > 0) {
          expect(pack.directories, isNotEmpty, reason: question.id);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
