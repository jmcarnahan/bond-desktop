import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/services/gates.dart';

import 'golden_run.dart';
import 'golden_set.dart';

/// The golden set through the app's own gates, offline.
///
/// The gates are pure — no I/O, no clock, no model — so the whole of this
/// replay is a function call per item and there is no server anywhere in it.
/// What it replays is exactly what the set carries: the item's `direction`
/// through [triageStatusOnInsert], and its sender address and body through
/// [gateFor].
///
/// **Three things it cannot see, and the run says so rather than scoring them
/// as passes.** Tier 2 is the mail header gates (`newsletter`,
/// `auto_generated`): the set records a message's sender and body and no
/// headers at all, so [gateFor] reaches the header block with an empty map
/// and returns null every time — a header-only gold drop is KEPT here, and
/// that is the replay being honest about its input rather than the gate
/// regressing. The two Teams ingest gates (a bot sender, the user's own
/// message) are decided in `TeamsSync` from Graph fields — `from.application`
/// and the message's own direction — which the set does not carry either. The
/// Teams `empty` gate IS measured, because it reads the body and the set has
/// one.
///
/// That is also why this number and `make golden-baseline`'s gate number are
/// not the same measurement and must never be read as one beating the other:
/// the baseline is what the shipping app did with headers in front of it, and
/// this is what the set alone can ask.
///
/// The model's `notification` verdict rides along as [GoldenGateOut.modelCategory]
/// when a bulk run file is passed, and it is REPORTED and never applied: it
/// fired on 0 of 24 gold drops when it was measured on 2026-09-16, so it is
/// not a gate, and a replay that quietly used it would be scoring a pipeline
/// that does not exist. See `docs/pipeline/03-triage.md`.

/// The gate's verdict on [item], exactly as the app would reach it from what
/// the set carries.
GoldenGateOut gateReplay(
  GoldenItem item, {
  required String? ownerAddress,
  String? modelCategory,
}) {
  // Direction first, for the app's own reason: a message the user sent never
  // reaches `gateFor` at all — it is already `skipped/outbound` by the time
  // the triage columns are written.
  final (status, reason) =
      triageStatusOnInsert(outbound: item.direction == 'outbound');
  if (status == 'skipped') {
    return GoldenGateOut(
      verdict: 'drop',
      reason: reason,
      modelCategory: modelCategory,
    );
  }
  final gate = gateFor(item.message, userAddress: ownerAddress);
  return gate == null
      ? GoldenGateOut(verdict: 'keep', modelCategory: modelCategory)
      : GoldenGateOut(
          verdict: 'drop',
          reason: gate,
          modelCategory: modelCategory,
        );
}

/// `item id → triage.category` from a bulk run file, for the proxy column.
///
/// Throws for `loadGoldenCards`' reason, and names what to pass: a run file is
/// written by `make golden` into the git-ignored `tmp/bench/`, so "no file" is
/// the normal failure of somebody who has not run the bulk half yet.
///
/// A row without a triage section is skipped rather than defaulted: the proxy
/// line reports how many items carried no category, and a fabricated one there
/// would be counted as a model answer nobody's model gave.
Future<Map<String, String>> loadGoldenTriageCategories(String path) async {
  final file = File(path);
  if (!await file.exists()) {
    throw StateError(
      'no run file at $path — GOLDEN_RUN wants a bulk run file from '
      '`make golden`, whose triage.category is the proxy column',
    );
  }
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! List) {
    throw StateError(
      'the file at $path is not a run file — a run file is a JSON array of '
      'per-item objects',
    );
  }
  final byId = <String, String>{};
  for (final element in decoded) {
    if (element is! Map) continue;
    final id = element['id'];
    final triage = element['triage'];
    if (id is! String || triage is! Map) continue;
    final category = triage['category'];
    if (category is! String) continue;
    byId[id] = category;
  }
  return byId;
}
