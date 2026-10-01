@Skip('live — needs a COPY of the app database and the decision server. '
    'Run: make decision-agreement DECISION_DB=<copy of bond.db> (after make '
    'decide)')
library;

import 'dart:io';

import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/decision/decision_client.dart';
import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:bond_inbox/services/decision/decision_input.dart';
import 'package:bond_inbox/services/decision/decision_policy.dart';
import 'package:bond_inbox/services/decision/needs_you_predicate.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/model_slots.dart' show LlmTarget;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'fixtures/golden_harness.dart';

/// The decision model against the labels the 4B already stored, on the
/// owner's own mailbox — the offline half of the plan's "no shadow mode"
/// (D5): what would move if the cutover shipped today.
///
/// Reads a COPY of the database, read-only, through raw sqlite rather than
/// `BondDatabase`: opening the store runs migrations, and a report must never
/// write to the file it reports on. Rows come back through the app's own
/// `Message.fromRow` / `AttachmentRef.fromRow` and into
/// `DecisionInput.fromRows`, so the states are the ones the triage queue will
/// render.
///
/// **Counts only.** The database is real mail: no subject, body, name,
/// address, summary or id is printed — agreement tallies and enum pairs.
///
/// The name avoids the five words the Makefile filters on (G21).

const String _dbPath = String.fromEnvironment('DECISION_DB');
const int _limit = int.fromEnvironment('DECISION_LIMIT', defaultValue: 500);

void main() {
  test(
    'db agreement: the decision model against the stored labels',
    () async {
      if (_dbPath.isEmpty) {
        fail('DECISION_DB is not defined — run make decision-agreement '
            'DECISION_DB=<path to a COPY of the app database>');
      }
      if (!File(_dbPath).existsSync()) {
        fail('no database at $_dbPath');
      }
      if (_limit < 1) {
        fail('DECISION_LIMIT must be a positive integer, got $_limit');
      }
      final headsPath = decideHeadsPath();
      if (!File(headsPath).existsSync()) {
        fail('no decision heads at $headsPath — run make decide-install, or '
            'pass --dart-define=DECIDE_HEADS=<path>');
      }
      final heads = await DecisionHeads.load(File(headsPath));
      final owner = decisionOwnerString(
        (name: GoldenDefines.ownerName, address: GoldenDefines.ownerAddress),
      );
      if (owner == null) {
        // ignore: avoid_print
        print('WARNING: GOLDEN_OWNER_NAME / GOLDEN_OWNER_ADDRESS not set — '
            'the states carry no owner line, and needs_you depends on it');
      }

      final db = sqlite3.open(_dbPath, mode: OpenMode.readOnly);
      final inputs = <DecisionInput>[];
      final stored = <Message>[];
      try {
        final rows = db.select(
          "SELECT * FROM messages WHERE direction = 'inbound' "
          "AND triage_status = 'triaged' "
          'AND urgency IS NOT NULL AND category IS NOT NULL '
          'ORDER BY received_at DESC LIMIT ?',
          [_limit],
        );
        for (final row in rows) {
          final data = Map<String, Object?>.from(row);
          final message = Message.fromRow(data);
          final key = data['conversation_key'] as String?;
          final thread = key == null || key.isEmpty
              ? const <Message>[]
              : [
                  for (final t in db.select(
                    'SELECT * FROM messages WHERE conversation_key = ? '
                    'AND source = ? '
                    'ORDER BY received_at ASC, source_message_id ASC',
                    [key, message.source],
                  ))
                    Message.fromRow(Map<String, Object?>.from(t)),
                ];
          final attachments = [
            for (final a in db.select(
              'SELECT * FROM attachments WHERE source = ? '
              'AND source_message_id = ? ORDER BY ordinal',
              [message.source, message.id],
            ))
              AttachmentRef.fromRow(
                Map<String, Object?>.from(a),
                conversationKey: key,
              ),
          ];
          inputs.add(
            DecisionInput.fromRows(
              message: message,
              thread: thread,
              attachments: attachments,
              owner: owner,
            ),
          );
          stored.add(message);
        }
      } finally {
        db.close();
      }
      if (inputs.isEmpty) {
        fail('no triaged inbound message with stored labels in the copy');
      }

      final client = DecisionClient(
        resolveTarget: () => const LlmTarget(
          baseUrl: DecisionClient.defaultBaseUrl,
          model: DecisionClient.defaultModel,
        ),
        heads: () => heads,
      );
      final results = <DecisionAnswers>[];
      final sw = Stopwatch()..start();
      try {
        for (var i = 0; i < inputs.length; i += DecisionClient.batchChunk) {
          final end = i + DecisionClient.batchChunk > inputs.length
              ? inputs.length
              : i + DecisionClient.batchChunk;
          for (final r in await client.decideBatch(inputs.sublist(i, end))) {
            results.add(r.answers);
          }
        }
      } on LlmUnavailableException {
        fail('the decision server at ${DecisionClient.defaultBaseUrl} is not '
            'answering — run make decide');
      }
      sw.stop();

      final tally = _Tally();
      var wouldDrop = 0;
      var nyYes = 0;
      var nyNo = 0;
      for (var i = 0; i < results.length; i++) {
        final a = results[i];
        final m = stored[i];
        tally.add('urgency', a['urgency'].choice, m.urgency);
        tally.add('category', a['category'].choice, m.category);
        if (m.needsAction != null) {
          tally.add(
            'needs_action',
            '${a.p('needs_action', 'yes') >= DecisionPolicy.booleanYes}',
            '${m.needsAction}',
          );
        }
        if (m.replyExpected != null) {
          tally.add(
            'reply_expected',
            '${a.p('reply_expected', 'yes') >= DecisionPolicy.replyYes}',
            '${m.replyExpected}',
          );
        }
        if (learnedGateReason(a) != null) wouldDrop++;

        final p = a.p('needs_you', 'yes');
        // The app's one rule: the probability against the slider, here at
        // the shipped default. No band, no floor, no cold bar.
        if (needsYouAt(p, NeedsYouTuning.defaultThreshold)) {
          nyYes++;
        } else {
          nyNo++;
        }
        // Against the probability stored on the row, through the same cut.
        if (m.needsYouP != null) {
          tally.add(
            'needs_you',
            '${needsYouAt(p, NeedsYouTuning.defaultThreshold)}',
            '${needsYouAt(m.needsYouP, NeedsYouTuning.defaultThreshold)}',
          );
        }
      }

      final n = results.length;
      // Counts and enum pairs only: the database is real mail.
      // ignore: avoid_print
      print(
        '\ndecision vs stored labels: $n messages (limit $_limit), owner '
        '${owner == null ? 'NOT set' : 'set'}, model ${heads.model}, '
        '${sw.elapsedMilliseconds} ms\n'
        '${tally.report()}\n'
        'gate: $n kept by the rules; the learned gate '
        '(p(drop) >= ${DecisionPolicy.gateDrop}, not cold outreach) would '
        'drop $wouldDrop\n'
        'needs_you at p(yes) >= ${NeedsYouTuning.defaultThreshold}: '
        'yes $nyYes, no $nyNo\n'
        'needs_you agreement above reads the stored probability at the '
        'same cut\n'
        '\n${tally.confusion('urgency')}\n'
        '\n${tally.confusion('category')}\n',
      );

      expect(results, hasLength(inputs.length));
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

/// Agreement counts per field, and the (model, stored) pairs behind them.
class _Tally {
  final Map<String, Map<(String, String), int>> _pairs = {};

  void add(String field, String model, String? stored) {
    final pairs = _pairs.putIfAbsent(field, () => {});
    final key = (model, stored ?? '(null)');
    pairs[key] = (pairs[key] ?? 0) + 1;
  }

  String report() => [
        for (final MapEntry(key: field, value: pairs) in _pairs.entries)
          () {
            final total = pairs.values.fold(0, (a, b) => a + b);
            final agree = pairs.entries
                .where((e) => e.key.$1 == e.key.$2)
                .fold(0, (a, e) => a + e.value);
            final pct = total == 0 ? 0 : (100 * agree / total).round();
            return '${field.padRight(18)} $agree/$total agree ($pct%)';
          }(),
      ].join('\n');

  /// Rows are the model's answer, columns the stored one.
  String confusion(String field) {
    final pairs = _pairs[field] ?? const {};
    final models = {for (final k in pairs.keys) k.$1}.toList()..sort();
    final storedVals = {for (final k in pairs.keys) k.$2}.toList()..sort();
    return [
      '$field: model \\ stored  ${storedVals.join(' | ')}',
      for (final m in models)
        '  ${m.padRight(14)} '
            '${[for (final s in storedVals) '${pairs[(m, s)] ?? 0}'].join(' | ')}',
    ].join('\n');
  }
}
