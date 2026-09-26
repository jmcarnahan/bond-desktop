// `show BondDatabase`: drift generates row classes named Label and LabelRule
// from the tables, and this file means the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/label_models.dart';
import 'package:bond_inbox/models/message_models.dart' show ConversationState;
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// Standing rules: the CRUD behind the Settings list, the retroactive apply that
/// creating one runs, and the undo that takes it back.
///
/// Three rules run through all of it. A rule acts through machinery that already
/// exists — the needs-you VERDICT and the conversation BUCKET, never a new state
/// on a thread. `hidden_count` counts the rule's OWN links, so a thread the owner
/// had already filed by hand is not counted twice and undo takes back exactly
/// what was counted. And nothing a rule does touches a row the owner overrode:
/// `gate_override = 'user'` is their own hand on the gates and outranks every
/// derivation, this one included.

void main() {
  late BondDatabase db;
  late MessageStore store;

  /// A stamp [hours] back. Derived from now rather than written out, because a
  /// literal date in a fixture rots the day a window walks past it.
  String ago(int hours) => MessageStore.isoStamp(
      DateTime.now().toUtc().subtract(Duration(hours: hours)));

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedConversation(
    String key, {
    String source = 'email',
    String subject = 'Quarterly planning',
  }) async {
    await store.upsertConversation({
      'source': source,
      'conversation_key': key,
      'subject': subject,
      'state': 'needs_reply',
      'last_message_at': ago(2),
    });
  }

  /// One inbound message, with only the fields a rule reads spelled out.
  Future<void> seedMessage(
    String id, {
    String source = 'email',
    String conversationKey = 'c1',
    String from = 'alerts@tracker.example.com',
    String fromName = 'Tracker',
    String subject = 'Quarterly planning',
    int hoursAgo = 2,
    int addressedMe = 0,
    String? bodyText = 'Please take a look when you get a chance.',
    String? bodyPreview = 'Please take a look',
    String? meta,
    String direction = 'inbound',
  }) async {
    await seedConversation(conversationKey, source: source, subject: subject);
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': conversationKey,
      'direction': direction,
      'subject': subject,
      'from_name': fromName,
      'from_address': from,
      'received_at': ago(hoursAgo),
      'is_read': 0,
      'body_text': bodyText,
      'body_preview': bodyPreview,
      'addressed_me': addressedMe,
      'source_meta_json': meta,
    });
  }

  Future<List<Map<String, Object?>>> linksOf(String conversationKey) async =>
      [
        for (final row in await db.customSelect(
          'SELECT * FROM conversation_labels WHERE conversation_key = ? '
          'ORDER BY label_id',
          variables: [Variable(conversationKey)],
        ).get())
          row.data,
      ];

  Future<Map<String, Object?>?> aiRow(String conversationKey) async {
    final rows = await db.customSelect(
      'SELECT * FROM conversation_ai WHERE conversation_key = ?',
      variables: [Variable(conversationKey)],
    ).get();
    return rows.isEmpty ? null : rows.first.data;
  }

  Future<List<String>> pendingNeedsYou() async => [
        for (final row in await db.customSelect(
          "SELECT entity_id FROM work_items WHERE task_kind = 'needs_you' "
          'ORDER BY entity_id',
        ).get())
          row.data['entity_id'] as String,
      ];

  group('createLabelRule', () {
    test('mints an id, folds the scope and starts at nothing hidden', () async {
      final label = await store.createLabel('Meeting response');

      final rule = await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: '  Alerts@Tracker.Example.com ',
        disposition: LabelRule.hideNeedsYou,
      );

      expect(rule.id, startsWith('rule-sender-'));
      expect(rule.scopeValue, 'alerts@tracker.example.com');
      expect(rule.unlessMentionsMe, isTrue);
      expect(rule.hiddenCount, 0);
      expect(rule.labelName, 'Meeting response');
      // The id carries the scope KIND and never the value: an address in an id
      // would put a real mailbox into every log line naming the rule.
      expect(rule.id, isNot(contains('example.com')));
    });

    test('refuses a rule with nothing to match on', () async {
      final label = await store.createLabel('Meeting response');

      await expectLater(
        store.createLabelRule(
          labelId: label.id,
          scopeKind: LabelRule.scopeSubject,
          scopeValue: '   ',
          disposition: LabelRule.sendToLater,
        ),
        throwsStateError,
      );
      expect(await store.listLabelRules(), isEmpty);
    });

    test('a second rule over the same scope corrects the first', () async {
      final quiet = await store.createLabel('Not for me');
      final later = await store.createLabel('Later');

      final first = await store.createLabelRule(
        labelId: quiet.id,
        scopeKind: LabelRule.scopeDomain,
        scopeValue: 'example.com',
        disposition: LabelRule.hideNeedsYou,
      );
      await store.bumpRuleHiddenCount(first.id, by: 4);

      final again = await store.createLabelRule(
        labelId: later.id,
        scopeKind: LabelRule.scopeDomain,
        scopeValue: 'EXAMPLE.COM',
        disposition: LabelRule.sendToLater,
        unlessMentionsMe: false,
      );

      // One rule per scope, and the owner choosing again is a correction rather
      // than an error: the word, the disposition and the exception move.
      expect(again.id, first.id);
      expect(again.labelId, later.id);
      expect(again.disposition, LabelRule.sendToLater);
      expect(again.unlessMentionsMe, isFalse);
      // The count and the creation stamp survive, because the links the rule has
      // already filed still point at it and undo still owes them.
      expect(again.hiddenCount, 4);
      expect(again.createdAt, first.createdAt);
      expect(await store.listLabelRules(), hasLength(1));
    });

    test('one rule per scope is enforced by the database, not the method',
        () async {
      final label = await store.createLabel('Not for me');
      final rule = await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'alerts@tracker.example.com',
        disposition: LabelRule.hideNeedsYou,
      );

      await expectLater(
        db.customUpdate(
          'INSERT INTO label_rules (id, label_id, scope_kind, scope_value, '
          'disposition, unless_mentions_me, hidden_count, created_at, '
          'updated_at) VALUES (?, ?, ?, ?, ?, 1, 0, ?, ?)',
          variables: [
            Variable('rule-sender-ffff'),
            Variable(label.id),
            Variable(LabelRule.scopeSender),
            Variable('alerts@tracker.example.com'),
            Variable(LabelRule.sendToLater),
            Variable(ago(0)),
            Variable(ago(0)),
          ],
        ),
        throwsA(anything),
      );
      expect((await store.listLabelRules()).single.id, rule.id);
    });

    test('the same address under two scope kinds is two rules', () async {
      final label = await store.createLabel('Not for me');

      await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'example.com',
        disposition: LabelRule.hideNeedsYou,
      );
      await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeDomain,
        scopeValue: 'example.com',
        disposition: LabelRule.hideNeedsYou,
      );

      expect(await store.listLabelRules(), hasLength(2));
    });
  });

  group('reading and removing', () {
    test('lists newest first, each carrying its word', () async {
      final quiet = await store.createLabel('Not for me');
      final later = await store.createLabel('Later');
      final first = await store.createLabelRule(
        labelId: quiet.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'alerts@tracker.example.com',
        disposition: LabelRule.hideNeedsYou,
      );
      await db.customUpdate(
        'UPDATE label_rules SET created_at = ? WHERE id = ?',
        variables: [Variable(ago(48)), Variable(first.id)],
      );
      final second = await store.createLabelRule(
        labelId: later.id,
        scopeKind: LabelRule.scopeDomain,
        scopeValue: 'vendor.example.com',
        disposition: LabelRule.sendToLater,
      );

      final rules = await store.listLabelRules();

      expect(rules.map((r) => r.id).toList(), [second.id, first.id]);
      expect(
        {for (final r in rules) r.id: r.labelName},
        {second.id: 'Later', first.id: 'Not for me'},
      );
    });

    test('a renamed label moves the reason the rule writes', () async {
      final label = await store.createLabel('Not for me');
      final rule = await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'alerts@tracker.example.com',
        disposition: LabelRule.hideNeedsYou,
      );
      expect(rule.verdictReason, 'label_rule:Not for me');

      await store.renameLabel(label.id, 'Tracker noise');

      expect(
        (await store.getLabelRule(rule.id))!.verdictReason,
        'label_rule:Tracker noise',
      );
    });

    test('a missing rule reads as null rather than throwing', () async {
      expect(await store.getLabelRule('rule-sender-0000'), isNull);
    });

    test('the hidden count adds and never goes below nothing', () async {
      final label = await store.createLabel('Not for me');
      final rule = await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'alerts@tracker.example.com',
        disposition: LabelRule.hideNeedsYou,
      );

      await store.bumpRuleHiddenCount(rule.id, by: 3);
      await store.bumpRuleHiddenCount(rule.id);
      expect((await store.getLabelRule(rule.id))!.hiddenCount, 4);

      await store.bumpRuleHiddenCount(rule.id, by: -99);
      expect((await store.getLabelRule(rule.id))!.hiddenCount, 0);
    });

    test('deleting the word takes its rules with it', () async {
      final label = await store.createLabel('Not for me');
      await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'alerts@tracker.example.com',
        disposition: LabelRule.hideNeedsYou,
      );

      await store.deleteLabel(label.id);

      // A rule outliving its word would go on hiding mail under a label the
      // owner can no longer see.
      expect(await store.listLabelRules(), isEmpty);
    });

    test('deleting a rule leaves the threads it filed where they are',
        () async {
      await seedMessage('m1');
      final label = await store.createLabel('Not for me');
      final rule = await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'alerts@tracker.example.com',
        disposition: LabelRule.hideNeedsYou,
      );
      await store.applyLabelRule(rule.id);

      await store.deleteLabelRule(rule.id);

      expect(await store.listLabelRules(), isEmpty);
      expect(await linksOf('c1'), hasLength(1));
    });
  });

  group('applyLabelRule', () {
    test('hides the mail already here and says how much it moved', () async {
      await seedMessage('m1', conversationKey: 'c1');
      await seedMessage('m2', conversationKey: 'c2');
      await seedMessage(
        'm3',
        conversationKey: 'c3',
        from: 'alex@example.com',
        fromName: 'Alex Rivera',
      );
      final label = await store.createLabel('Not for me');
      final rule = await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'alerts@tracker.example.com',
        disposition: LabelRule.hideNeedsYou,
      );

      final moved = await store.applyLabelRule(rule.id);

      expect(moved, 2);
      final hidden = await store.getMessageRow('email', 'm1');
      expect(hidden!['needs_you_verdict'], 0);
      expect(hidden['needs_you_reason'], 'label_rule:Not for me');
      // The thread nobody's rule spoke about is untouched, verdict included.
      expect(
        (await store.getMessageRow('email', 'm3'))!['needs_you_verdict'],
        isNull,
      );
      expect(await linksOf('c3'), isEmpty);

      final link = (await linksOf('c1')).single;
      expect(link['applied_by'], 'rule');
      expect(link['rule_id'], rule.id);
      expect((await store.getLabelRule(rule.id))!.hiddenCount, 2);
      // A rule filing a hundred threads must not reorder the owner's picker.
      expect((await store.listLabels()).single.useCount, 0);
    });

    test('running the same rule twice moves the same threads and counts once',
        () async {
      await seedMessage('m1');
      final label = await store.createLabel('Not for me');
      final rule = await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'alerts@tracker.example.com',
        disposition: LabelRule.hideNeedsYou,
      );

      expect(await store.applyLabelRule(rule.id), 1);
      expect(await store.applyLabelRule(rule.id), 1);

      expect(await linksOf('c1'), hasLength(1));
      expect((await store.getLabelRule(rule.id))!.hiddenCount, 1);
    });

    test('a word the owner already applied by hand keeps its own link',
        () async {
      await seedMessage('m1');
      final label = await store.createLabel('Not for me');
      await store.applyLabels('email', 'c1', [label.id]);
      final rule = await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'alerts@tracker.example.com',
        disposition: LabelRule.hideNeedsYou,
      );

      expect(await store.applyLabelRule(rule.id), 1);

      // One link, the owner's, and no double count — which is what makes undo
      // able to take back exactly what the rule did.
      final link = (await linksOf('c1')).single;
      expect(link['applied_by'], 'user');
      expect(link['rule_id'], isNull);
      expect((await store.getLabelRule(rule.id))!.hiddenCount, 0);
    });

    test('a later rule buckets the thread and drops any stale date', () async {
      await seedMessage('m1');
      await store.setSnoozedUntil('email', 'c1', ago(-24));
      final label = await store.createLabel('Later');
      final rule = await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeDomain,
        scopeValue: 'tracker.example.com',
        disposition: LabelRule.sendToLater,
      );

      expect(await store.applyLabelRule(rule.id), 1);

      final ai = (await aiRow('c1'))!;
      expect(ai['bucket'], 'later');
      // `'user'`, the one reason the attention sweep and the extractor both
      // refuse to overrule: a rule IS the owner's instruction.
      expect(ai['bucket_reason'], 'user');
      // A rule has no "when" in it, so a date inherited from an earlier
      // hand-deferral would draw a `Back <when>` the rule would never honour.
      expect(ai['snoozed_until'], isNull);
      // A later rule is not a needs-you verdict.
      expect(
        (await store.getMessageRow('email', 'm1'))!['needs_you_verdict'],
        isNull,
      );
    });

    test('a chat that named the owner escapes a rule with the exception on',
        () async {
      await seedMessage(
        'm1',
        source: 'teams',
        conversationKey: 'chat1',
        from: 'teams:19:alex',
        addressedMe: 1,
      );
      final label = await store.createLabel('Not for me');
      final rule = await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'teams:19:alex',
        disposition: LabelRule.hideNeedsYou,
      );

      expect(await store.applyLabelRule(rule.id), 0);

      expect(
        (await store.getMessageRow('teams', 'm1'))!['needs_you_verdict'],
        isNull,
      );
      expect(await linksOf('chat1'), isEmpty);
    });

    test('with the exception off the same chat is hidden anyway', () async {
      await seedMessage(
        'm1',
        source: 'teams',
        conversationKey: 'chat1',
        from: 'teams:19:alex',
        addressedMe: 1,
      );
      final label = await store.createLabel('Not for me');
      final rule = await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'teams:19:alex',
        disposition: LabelRule.hideNeedsYou,
        unlessMentionsMe: false,
      );

      expect(await store.applyLabelRule(rule.id), 1);

      expect(
        (await store.getMessageRow('teams', 'm1'))!['needs_you_verdict'],
        0,
      );
    });

    test('never touches a message the owner restored by hand', () async {
      await seedMessage('m1');
      await db.customUpdate(
        "UPDATE messages SET gate_override = 'user' WHERE source_message_id = ?",
        variables: [Variable('m1')],
      );
      final label = await store.createLabel('Not for me');
      final rule = await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'alerts@tracker.example.com',
        disposition: LabelRule.hideNeedsYou,
      );

      expect(await store.applyLabelRule(rule.id), 0);
      expect(
        (await store.getMessageRow('email', 'm1'))!['needs_you_verdict'],
        isNull,
      );
    });

    test('an outbound message is nobody rule business', () async {
      await seedMessage('m1', direction: 'outbound');
      final label = await store.createLabel('Not for me');
      final rule = await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'alerts@tracker.example.com',
        disposition: LabelRule.hideNeedsYou,
      );

      expect(await store.applyLabelRule(rule.id), 0);
    });

    test('the lookback bounds the walk', () async {
      await seedMessage('m1', conversationKey: 'c1', hoursAgo: 2);
      await seedMessage('m2', conversationKey: 'c2', hoursAgo: 96);
      final label = await store.createLabel('Not for me');
      final rule = await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'alerts@tracker.example.com',
        disposition: LabelRule.hideNeedsYou,
      );

      expect(await store.applyLabelRule(rule.id, sinceIso: ago(24)), 1);
      expect(await linksOf('c2'), isEmpty);
    });

    test('a classification rule sleeps until a caller can name the kind',
        () async {
      await seedMessage('m1', subject: 'Accepted: Quarterly planning');
      final label = await store.createLabel('Meeting response');
      final rule = await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeClassification,
        scopeValue: 'meeting_response',
        disposition: LabelRule.hideNeedsYou,
      );

      expect(await store.applyLabelRule(rule.id), 0);

      expect(
        await store.applyLabelRule(
          rule.id,
          classify: (row) =>
              (row['subject'] as String? ?? '').startsWith('Accepted:')
                  ? 'meeting_response'
                  : null,
        ),
        1,
      );
    });

    test('a rule nobody wrote moves nothing', () async {
      expect(await store.applyLabelRule('rule-sender-0000'), 0);
    });
  });

  group('undoLabelRule', () {
    test('takes back the rule, its links and its verdicts', () async {
      await seedMessage('m1', conversationKey: 'c1');
      await seedMessage('m2', conversationKey: 'c2');
      final label = await store.createLabel('Not for me');
      final rule = await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'alerts@tracker.example.com',
        disposition: LabelRule.hideNeedsYou,
      );
      await store.applyLabelRule(rule.id);

      expect(await store.undoLabelRule(rule.id), 2);

      expect(await store.listLabelRules(), isEmpty);
      expect(await linksOf('c1'), isEmpty);
      expect(await linksOf('c2'), isEmpty);
      // A RECOMPUTE, not a restore: the verdict goes back to "never judged" and
      // the needs-you pass is queued to judge it properly.
      final row = (await store.getMessageRow('email', 'm1'))!;
      expect(row['needs_you_verdict'], isNull);
      expect(row['needs_you_reason'], isNull);
      expect(await pendingNeedsYou(), ['m1', 'm2']);
    });

    test('leaves the word the owner applied by hand', () async {
      await seedMessage('m1');
      final quiet = await store.createLabel('Not for me');
      final mine = await store.createLabel('Waiting on legal');
      await store.applyLabels('email', 'c1', [mine.id]);
      final rule = await store.createLabelRule(
        labelId: quiet.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'alerts@tracker.example.com',
        disposition: LabelRule.hideNeedsYou,
      );
      await store.applyLabelRule(rule.id);
      expect(await linksOf('c1'), hasLength(2));

      await store.undoLabelRule(rule.id);

      final link = (await linksOf('c1')).single;
      expect(link['label_id'], mine.id);
      expect(link['rule_id'], isNull);
    });

    test('leaves a verdict the model wrote alone', () async {
      await seedMessage('m1', conversationKey: 'c1');
      await seedMessage('m2', conversationKey: 'c1');
      final label = await store.createLabel('Not for me');
      final rule = await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'alerts@tracker.example.com',
        disposition: LabelRule.hideNeedsYou,
      );
      await store.applyLabelRule(rule.id);
      // A judgement of this message that came from somewhere else. Undoing the
      // rule must not spend a model call re-asking a question already answered.
      await store.writeNeedsYouVerdict(
        'email',
        'm2',
        verdict: true,
        reason: 'asks the owner for a decision',
      );

      await store.undoLabelRule(rule.id);

      expect(
        (await store.getMessageRow('email', 'm2'))!['needs_you_verdict'],
        1,
      );
      expect(await pendingNeedsYou(), ['m1']);
    });

    test('a later rule undo puts the thread back in the inbox', () async {
      await seedMessage('m1');
      final label = await store.createLabel('Later');
      final rule = await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeDomain,
        scopeValue: 'tracker.example.com',
        disposition: LabelRule.sendToLater,
      );
      await store.applyLabelRule(rule.id);

      expect(await store.undoLabelRule(rule.id), 1);

      final ai = (await aiRow('c1'))!;
      expect(ai['bucket'], isNull);
      // `(null, 'user')` — the state a person putting a thread back by hand
      // writes, and the one the sweep leaves alone in both directions.
      expect(ai['bucket_reason'], 'user');
    });

    test('a hide rule undo leaves a bucket the owner set by hand', () async {
      await seedMessage('m1');
      final label = await store.createLabel('Not for me');
      final rule = await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'alerts@tracker.example.com',
        disposition: LabelRule.hideNeedsYou,
      );
      await store.applyLabelRule(rule.id);
      // The owner's own Later, set AFTER the rule filed the thread. A
      // hide_needs_you rule never wrote a bucket, so its undo owes the
      // buckets nothing — clearing this one would pull the thread back into
      // the inbox against the owner's explicit word.
      await store.setConversationBucket(
        'email',
        'c1',
        bucket: 'later',
        reason: 'user',
      );

      await store.undoLabelRule(rule.id);

      final ai = (await aiRow('c1'))!;
      expect(ai['bucket'], 'later');
      expect(ai['bucket_reason'], 'user');
    });

    test('a rule that filed nothing undoes to nothing', () async {
      final label = await store.createLabel('Not for me');
      final rule = await store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'alerts@tracker.example.com',
        disposition: LabelRule.hideNeedsYou,
      );

      expect(await store.undoLabelRule(rule.id), 0);
      expect(await store.listLabelRules(), isEmpty);
    });
  });

  group('regateMeetingResponses', () {
    test('gates the four response words Graph sends', () async {
      const words = [
        'meetingAccepted',
        'meetingDeclined',
        'meetingCancelled',
        'meetingTenativelyAccepted',
      ];
      for (var i = 0; i < words.length; i++) {
        await seedMessage(
          'm$i',
          conversationKey: 'c$i',
          subject: 'Accepted: Quarterly planning',
          meta: '{"meeting":"${words[i]}"}',
        );
      }

      expect(await store.regateMeetingResponses(), 4);

      for (var i = 0; i < words.length; i++) {
        final row = (await store.getMessageRow('email', 'm$i'))!;
        expect(row['triage_status'], 'skipped', reason: words[i]);
        expect(row['gate_reason'], 'meeting_response', reason: words[i]);
      }
    });

    test('an invitation is never touched', () async {
      await seedMessage(
        'm1',
        subject: 'Quarterly planning',
        meta: '{"meeting":"meetingRequest"}',
      );

      expect(await store.regateMeetingResponses(), 0);
      expect(
        (await store.getMessageRow('email', 'm1'))!['triage_status'],
        'pending',
      );
    });

    test('an empty-bodied Accepted: with no meeting field is a response',
        () async {
      await seedMessage(
        'm1',
        subject: 'Tentative: Quarterly planning',
        bodyText: '   ',
        bodyPreview: null,
      );

      expect(await store.regateMeetingResponses(), 1);
      expect(
        (await store.getMessageRow('email', 'm1'))!['gate_reason'],
        'meeting_response',
      );
    });

    test('an Exchange-empty body, a bare CRLF, is still nothing in it',
        () async {
      // What the mailbox actually stores for an empty Accepted: — sqlite's
      // one-argument TRIM strips spaces only and kept all of these.
      await seedMessage(
        'm1',
        conversationKey: 'c1',
        subject: 'Accepted: Quarterly planning',
        bodyText: '\r\n',
        bodyPreview: '',
      );
      await seedMessage(
        'm2',
        conversationKey: 'c2',
        subject: 'Canceled: Weekly review',
        bodyText: ' \t\r\n ',
        bodyPreview: '\n',
      );

      expect(await store.regateMeetingResponses(), 2);
      for (final id in ['m1', 'm2']) {
        expect(
          (await store.getMessageRow('email', id))!['gate_reason'],
          'meeting_response',
          reason: id,
        );
      }
    });

    test('a CRLF around real words is still somebody talking', () async {
      await seedMessage(
        'm1',
        subject: 'Canceled: 1:1',
        bodyText: 'PTO\r\n',
        bodyPreview: 'PTO',
      );

      expect(await store.regateMeetingResponses(), 0);
    });

    test('the same subject with something written in it is somebody talking',
        () async {
      await seedMessage(
        'm1',
        subject: 'Declined: Quarterly planning',
        bodyText: "Sorry, I'm out that week — can we move it?",
      );

      expect(await store.regateMeetingResponses(), 0);
    });

    test('a reply quoting the prefix is not a response', () async {
      await seedMessage(
        'm1',
        subject: 'Re: Accepted: Quarterly planning',
        bodyText: null,
        bodyPreview: null,
      );

      expect(await store.regateMeetingResponses(), 0);
    });

    test('leaves a row the owner restored by hand', () async {
      await seedMessage(
        'm1',
        subject: 'Accepted: Quarterly planning',
        meta: '{"meeting":"meetingAccepted"}',
      );
      await db.customUpdate(
        "UPDATE messages SET gate_override = 'user' WHERE source_message_id = ?",
        variables: [Variable('m1')],
      );

      expect(await store.regateMeetingResponses(), 0);
    });

    test('a row already gated keeps the reason it has', () async {
      await seedConversation('c1');
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'm1',
        'conversation_key': 'c1',
        'direction': 'inbound',
        'subject': 'Accepted: Quarterly planning',
        'from_address': 'alex@example.com',
        'received_at': ago(2),
        'is_read': 0,
        'triage_status': 'skipped',
        'gate_reason': 'outbound',
        'source_meta_json': '{"meeting":"meetingAccepted"}',
      });

      expect(await store.regateMeetingResponses(), 0);
      expect(
        (await store.getMessageRow('email', 'm1'))!['gate_reason'],
        'outbound',
      );
    });

    test('a malformed meta blob costs one row, not the statement', () async {
      await seedMessage(
        'm1',
        conversationKey: 'c1',
        subject: 'Accepted: Quarterly planning',
        meta: 'not json at all',
        bodyText: null,
        bodyPreview: null,
      );
      await seedMessage(
        'm2',
        conversationKey: 'c2',
        subject: 'Accepted: Quarterly planning',
        meta: '{"meeting":"meetingAccepted"}',
      );

      // The unreadable row falls through to the fallback shape, which it also
      // satisfies; what matters is that the good row is still gated.
      expect(await store.regateMeetingResponses(), 2);
      expect(
        (await store.getMessageRow('email', 'm2'))!['gate_reason'],
        'meeting_response',
      );
    });

    test('a chat is not mail', () async {
      await seedMessage(
        'm1',
        source: 'teams',
        conversationKey: 'chat1',
        from: 'teams:19:alex',
        subject: 'Accepted: Quarterly planning',
        bodyText: null,
        bodyPreview: null,
      );

      expect(await store.regateMeetingResponses(), 0);
    });
  });

  /// Requirement 12i's Recently dismissed view: the owner's dismissals and the
  /// rules' filings, one row per thread, newest first, each attributed.
  group('recently_dismissed', () {
    String daysAgo(int days) => ago(days * 24);

    Future<void> stampDone(String key, String at) async {
      await store.setConversationState('email', key, ConversationState.done);
      await db.customUpdate(
        'UPDATE conversations SET state_changed_at = ? '
        'WHERE conversation_key = ?',
        variables: [Variable(at), Variable(key)],
      );
    }

    Future<void> stampFiled(String key, String at) => db.customUpdate(
          'UPDATE conversation_labels SET applied_at = ? '
          'WHERE conversation_key = ? AND rule_id IS NOT NULL',
          variables: [Variable(at), Variable(key)],
        );

    Future<LabelRule> hideRule({
      String value = 'alerts@tracker.example.com',
      String name = 'Tracker noise',
      String disposition = LabelRule.hideNeedsYou,
    }) async {
      final label = await store.createLabel(name);
      return store.createLabelRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: value,
        disposition: disposition,
      );
    }

    Future<List<String>> keys() async => [
          for (final row
              in await store.recentlyDismissed(sinceIso: daysAgo(7)))
            row.conversation.id,
        ];

    test('a dismissal inside the window is there, one outside is not',
        () async {
      await seedConversation('inside');
      await seedConversation('outside');
      final closedAt = ago(3);
      await stampDone('inside', closedAt);
      await stampDone('outside', daysAgo(9));

      final rows = await store.recentlyDismissed(sinceIso: daysAgo(7));

      expect(rows.map((r) => r.conversation.id), ['inside']);
      final row = rows.single;
      expect(row.byRule, isFalse);
      expect(row.reopenable, isTrue);
      expect(row.dismissedAt, closedAt);
      expect(row.conversation.stateChangedAt, closedAt);
      expect(row.caption, 'Marked done');
    });

    test('a dismissal names the labels the owner filed it under', () async {
      await seedConversation('c1');
      final word = await store.createLabel('Waiting on legal');
      await store.applyLabels('email', 'c1', [word.id]);
      await stampDone('c1', ago(1));

      final row = (await store.recentlyDismissed(sinceIso: daysAgo(7))).single;

      expect(row.caption, 'Marked done · Waiting on legal');
    });

    test('a reopened thread is not dismissed any more', () async {
      await seedConversation('c1');
      await stampDone('c1', ago(1));
      await store.setConversationState(
          'email', 'c1', ConversationState.needsReply);

      expect(await keys(), isEmpty);
    });

    test('a rule-filed thread carries the rule and its label', () async {
      await seedMessage('m1', conversationKey: 'c1');
      final rule = await hideRule();
      await store.applyLabelRule(rule.id);

      final row = (await store.recentlyDismissed(sinceIso: daysAgo(7))).single;

      // A rule hides without dismissing: the thread is still needs_reply, and
      // it is here anyway — the whole reason the read is a union.
      expect(row.conversation.state, ConversationState.needsReply);
      expect(row.byRule, isTrue);
      expect(row.reopenable, isFalse);
      expect(row.ruleId, rule.id);
      expect(row.ruleScopeKind, LabelRule.scopeSender);
      expect(row.ruleScopeValue, 'alerts@tracker.example.com');
      expect(row.ruleLabelName, 'Tracker noise');
      expect(row.caption,
          'Filed by rule "alerts@tracker.example.com" · Tracker noise');
    });

    test('a link the owner applied by hand is not a rule filing', () async {
      await seedConversation('c1');
      final word = await store.createLabel('Waiting on legal');
      await store.applyLabels('email', 'c1', [word.id]);

      expect(await keys(), isEmpty);
    });

    test('a rule filing outside the window is not there', () async {
      await seedMessage('m1', conversationKey: 'c1', hoursAgo: 9 * 24);
      final rule = await hideRule();
      await store.applyLabelRule(rule.id);
      await stampFiled('c1', daysAgo(8));

      expect(await keys(), isEmpty);
    });

    test('newest first across both populations', () async {
      await seedConversation('closed-old');
      await seedConversation('closed-new');
      await seedMessage('m1', conversationKey: 'filed-mid');
      final rule = await hideRule();
      await store.applyLabelRule(rule.id);
      await stampDone('closed-old', daysAgo(5));
      await stampFiled('filed-mid', daysAgo(2));
      await stampDone('closed-new', ago(1));

      expect(await keys(), ['closed-new', 'filed-mid', 'closed-old']);
    });

    test('a thread both dismissed and filed appears once, as the newer',
        () async {
      await seedMessage('m1', conversationKey: 'dismissed-last',
          hoursAgo: 4 * 24);
      await seedMessage('m2', conversationKey: 'filed-last', hoursAgo: 4 * 24);
      final rule = await hideRule();
      await store.applyLabelRule(rule.id);
      await stampFiled('dismissed-last', daysAgo(3));
      final closedAt = ago(2);
      final filedAt = ago(5);
      await stampDone('dismissed-last', closedAt);
      await stampDone('filed-last', daysAgo(3));
      await stampFiled('filed-last', filedAt);

      final rows = await store.recentlyDismissed(sinceIso: daysAgo(7));

      expect(rows.map((r) => r.conversation.id),
          ['dismissed-last', 'filed-last']);
      final dismissed = rows.first;
      expect(dismissed.dismissedAt, closedAt);
      expect(dismissed.byRule, isFalse);
      expect(dismissed.caption, startsWith('Marked done'));
      final filed = rows.last;
      expect(filed.dismissedAt, filedAt);
      expect(filed.ruleId, rule.id);
      // Closed by hand as well, so Reopen still applies to it.
      expect(filed.reopenable, isTrue);
    });

    // `applied_at` is the FIRST filing and is never refreshed (the insert's
    // count is what the tally and undo stand on), so a rule that has kept a
    // thread hidden for weeks is dated by the newest mail it hid.
    test('a hide rule filed long ago that hid mail today is there', () async {
      await seedMessage('m1', conversationKey: 'c1', hoursAgo: 10 * 24);
      final rule = await hideRule();
      await store.applyLabelRule(rule.id);
      await stampFiled('c1', daysAgo(10));
      await seedMessage('m2', conversationKey: 'c1', hoursAgo: 1);
      await store.writeNeedsYouVerdict('email', 'm2',
          verdict: false, reason: rule.verdictReason);

      final row = (await store.recentlyDismissed(sinceIso: daysAgo(7))).single;

      expect(row.conversation.id, 'c1');
      expect(row.ruleId, rule.id);
      expect(row.dismissedAt,
          (await store.getMessageRow('email', 'm2'))!['received_at']);
    });

    test('but mail the floor raised past the rule does not date it',
        () async {
      await seedMessage('m1', conversationKey: 'c1', hoursAgo: 10 * 24);
      final rule = await hideRule();
      await store.applyLabelRule(rule.id);
      await stampFiled('c1', daysAgo(10));
      // "Shown despite": the rule's reason under a YES, which the rule did
      // not hide.
      await seedMessage('m2', conversationKey: 'c1', hoursAgo: 1);
      await store.writeNeedsYouVerdict('email', 'm2',
          verdict: true, reason: rule.verdictReason);

      expect(await keys(), isEmpty);
    });

    test('a later rule filed long ago is dated by the newest inbound',
        () async {
      await seedMessage('m1', conversationKey: 'c1', hoursAgo: 10 * 24);
      final rule = await hideRule(disposition: LabelRule.sendToLater);
      await store.applyLabelRule(rule.id);
      await stampFiled('c1', daysAgo(10));
      expect(await keys(), isEmpty);

      await seedMessage('m2', conversationKey: 'c1', hoursAgo: 1);

      expect(await keys(), ['c1']);
    });

    test('a rule deleted since still says a rule filed it', () async {
      await seedMessage('m1', conversationKey: 'c1');
      final rule = await hideRule();
      await store.applyLabelRule(rule.id);
      await store.deleteLabelRule(rule.id);

      final row = (await store.recentlyDismissed(sinceIso: daysAgo(7))).single;

      expect(row.caption, 'Filed by a rule · Tracker noise');
    });

    group('showRuleFiledThread', () {
      test('shows one thread and leaves the rule standing', () async {
        await seedMessage('m1', conversationKey: 'c1');
        await seedMessage('m2', conversationKey: 'c2');
        final rule = await hideRule();
        await store.applyLabelRule(rule.id);
        expect((await store.getLabelRule(rule.id))!.hiddenCount, 2);

        expect(
          await store.showRuleFiledThread('email', 'c1', ruleId: rule.id),
          isTrue,
        );

        // The rule is still there and still holds the OTHER thread.
        final standing = await store.getLabelRule(rule.id);
        expect(standing, isNotNull);
        expect(standing!.hiddenCount, 1);
        expect(await linksOf('c1'), isEmpty);
        expect(await linksOf('c2'), hasLength(1));
        expect((await store.getMessageRow('email', 'm2'))!['needs_you_reason'],
            'label_rule:Tracker noise');

        // The thread's verdict goes back to never-judged, it is queued, and
        // the stamp keeps the standing rule from re-hiding it on that pass.
        final row = (await store.getMessageRow('email', 'm1'))!;
        expect(row['needs_you_verdict'], isNull);
        expect(row['needs_you_reason'], isNull);
        expect(row['gate_override'], 'user');
        expect(await pendingNeedsYou(), ['m1']);
        expect(await keys(), ['c2']);
      });

      test('clears the bucket a later rule wrote, under the owner\'s word',
          () async {
        await seedMessage('m1', conversationKey: 'c1');
        final rule = await hideRule(disposition: LabelRule.sendToLater);
        await store.applyLabelRule(rule.id);
        expect((await aiRow('c1'))!['bucket'], 'later');

        await store.showRuleFiledThread('email', 'c1', ruleId: rule.id);

        final ai = (await aiRow('c1'))!;
        expect(ai['bucket'], isNull);
        // `'user'` is what the attention sweep refuses to overrule, so the
        // sweep does not file it straight back under the same rule.
        expect(ai['bucket_reason'], 'user');
        expect(await store.getLabelRule(rule.id), isNotNull);
      });

      test('a hide rule leaves a bucket the owner set by hand', () async {
        await seedMessage('m1', conversationKey: 'c1');
        await store.setConversationBucket('email', 'c1',
            bucket: 'later', reason: 'user');
        final rule = await hideRule();
        await store.applyLabelRule(rule.id);

        await store.showRuleFiledThread('email', 'c1', ruleId: rule.id);

        expect((await aiRow('c1'))!['bucket'], 'later');
      });

      test('writes nothing when the rule never filed the thread', () async {
        await seedMessage('m1', conversationKey: 'c1');
        final rule = await hideRule(value: 'someone@else.example.com');

        expect(
          await store.showRuleFiledThread('email', 'c1', ruleId: rule.id),
          isFalse,
        );
        expect(
            (await store.getMessageRow('email', 'm1'))!['gate_override'],
            isNull);
        expect(await pendingNeedsYou(), isEmpty);
      });
    });
  });
}
