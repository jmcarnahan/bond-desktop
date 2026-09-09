import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/home_result.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Inbox feed's narrator: which LABEL a row gets, which reason rides in the
/// cell beside it, and what the Ask · Summary column says.
///
/// Pure, so the awkward cases are cheap — a row that is stalled AND errored
/// AND dropped, a drop with no reason on it, a verdict nobody has written yet.
/// The priority order is the load-bearing part: the first rule that matches
/// wins, and a row that is stuck says so before it says anything else it might
/// also be.

final DateTime _now = DateTime.utc(2026, 9, 3, 12);

String _minutesAgo(int minutes) =>
    _now.subtract(Duration(minutes: minutes)).toIso8601String();

HomeFeedRow _row({
  String source = 'email',
  String id = 'm1',
  String conversationKey = 'c1',
  String? summary,
  String? ctaText,
  String triage = 'done',
  String extract = 'done',
  String storyline = 'done',
  String draft = 'skipped',
  String settle = 'done',
  String outcome = 'done',
  bool dropped = false,
  String? dropReason,
  String? storylineId,
  String? storylineTitle,
  bool needsYou = false,
  String? urgency,
  String? updatedAt,
  bool? needsYouVerdict,
  String? needsYouReason,
  String? gateReason,
  String? bucket,
  String? bucketReason,
  String? storylineEvidence,
  String? storylineAddedBy,
  bool workOpen = false,
}) =>
    HomeFeedRow(
      source: source,
      sourceMessageId: id,
      conversationKey: conversationKey,
      receivedAt: '2026-09-03T09:00:00Z',
      summary: summary,
      ctaText: ctaText,
      triageState: triage,
      extractState: extract,
      storylineState: storyline,
      draftState: draft,
      settleState: settle,
      outcome: outcome,
      dropped: dropped,
      dropReason: dropReason,
      storylineId: storylineId,
      storylineTitle: storylineTitle,
      needsYou: needsYou,
      urgency: urgency,
      updatedAt: updatedAt ?? _minutesAgo(1),
      needsYouVerdict: needsYouVerdict,
      needsYouReason: needsYouReason,
      gateReason: gateReason,
      bucket: bucket,
      bucketReason: bucketReason,
      storylineEvidence: storylineEvidence,
      storylineAddedBy: storylineAddedBy,
      workOpen: workOpen,
    );

HomeResult _line(HomeFeedRow row) => resultLine(row, now: _now);

void main() {
  group('the drop labels', () {
    test('are the words a person would use', () {
      expect(homeDropLabel('fyi'), 'FYI');
      expect(homeDropLabel('no_reply'), 'No reply needed');
      expect(homeDropLabel('gated'), 'Filtered');
      expect(homeDropLabel('user'), 'Ignored');
      expect(homeDropLabel('brand_new_reason'), 'brand new reason');
      expect(homeDropLabel(null), 'Dropped');
      expect(homeDropLabel(''), 'Dropped');
    });
  });

  group('stalled', () {
    test('is what a pending row nobody is working on reads as', () {
      final result = _line(_row(
        outcome: 'pending',
        updatedAt: _minutesAgo(40),
        storyline: 'pending',
      ));

      expect(result.kind, HomeResultKind.stalled);
      expect(result.text, 'Stalled');
      expect(
        result.detail,
        'No progress for 15 minutes and nothing is queued — waiting on '
            'storyline.',
        reason: 'every stalled row says the same word; WHICH stage it is stuck '
            'behind is the reason rather than the verdict',
      );
      expect(result.tooltip, '${result.text} — ${result.detail}');
      expect(result.tone, BondTone.error);
      expect(result.retryable, isTrue);
    });

    test('yields to a failure — the failure is WHY it stalled', () {
      final result = _line(_row(
        outcome: 'pending',
        updatedAt: _minutesAgo(40),
        extract: 'error',
        storyline: 'pending',
      ));

      expect(result.kind, HomeResultKind.error);
      expect(result.text, 'Failed at extract');
      expect(result.retryable, isTrue);
    });

    test('names the earliest stage the row has not finished', () {
      expect(
        _line(_row(
          outcome: 'pending',
          updatedAt: _minutesAgo(20),
          triage: 'done',
          extract: 'pending',
          storyline: 'pending',
        )).detail,
        endsWith('waiting on extract.'),
      );
      // Skipped is finished, not owed: a message nobody is drafting for is
      // waiting on the settle behind it.
      expect(
        _line(_row(
          outcome: 'pending',
          updatedAt: _minutesAgo(20),
          draft: 'skipped',
          settle: 'pending',
        )).detail,
        endsWith('waiting on settle.'),
      );
    });

    test('the tooltip says what Retry will do', () {
      expect(
        _line(_row(outcome: 'pending', updatedAt: _minutesAgo(20))).tooltip,
        contains('${homeStalledAfter.inMinutes} minutes'),
      );
    });

    test('fourteen minutes is slow; sixteen is stuck', () {
      expect(
        _line(_row(
          outcome: 'pending',
          settle: 'pending',
          updatedAt: _minutesAgo(14),
        )).kind,
        HomeResultKind.inFlight,
      );
      expect(
        _line(_row(
          outcome: 'pending',
          settle: 'pending',
          updatedAt: _minutesAgo(16),
        )).kind,
        HomeResultKind.stalled,
      );
    });

    test('a row with work open is never stalled, however long it sat', () {
      expect(
        _line(_row(
          outcome: 'pending',
          settle: 'pending',
          updatedAt: _minutesAgo(600),
          workOpen: true,
        )).kind,
        HomeResultKind.inFlight,
      );
    });
  });

  group('errored', () {
    test('names the FIRST stage that failed', () {
      final result = _line(_row(triage: 'error', settle: 'error'));

      expect(result.kind, HomeResultKind.error);
      expect(result.text, 'Failed at triage');
      expect(result.detail, 'The triage stage ended in an error.');
      expect(
        result.tooltip,
        'Failed at triage — The triage stage ended in an error.',
      );
      expect(result.tone, BondTone.error);
      expect(result.retryable, isTrue);
    });

    test('yields to a drop — Retry refuses a dropped row, Restore is its lever',
        () {
      final result =
          _line(_row(extract: 'error', dropped: true, dropReason: 'fyi'));
      expect(result.kind, HomeResultKind.dropped);
      expect(result.text, 'FYI');
      expect(result.retryable, isFalse);
    });
  });

  group('dropped', () {
    test('reads as the label, with the drop in the tooltip', () {
      final result = _line(_row(dropped: true, dropReason: 'newsletter'));

      expect(result.kind, HomeResultKind.dropped);
      expect(result.text, 'Newsletter');
      expect(result.detail, isNull);
      expect(result.tooltip, 'Dropped: Newsletter');
      expect(result.tone, BondTone.neutral);
      expect(result.retryable, isFalse);
    });

    test('not_worthy carries the reason the judge gave, or says there was '
        'none', () {
      expect(
        _line(_row(
          dropped: true,
          dropReason: 'not_worthy',
          needsYouVerdict: false,
          needsYouReason: 'a receipt, nobody is asked for anything',
        )).detail,
        'a receipt, nobody is asked for anything',
      );
      expect(
        _line(_row(dropped: true, dropReason: 'not_worthy')).text,
        'Nothing to do',
      );
      expect(
        _line(_row(dropped: true, dropReason: 'not_worthy')).detail,
        'no ask found',
      );
      expect(
        _line(_row(
          dropped: true,
          dropReason: 'not_worthy',
          needsYouVerdict: false,
          needsYouReason: '   ',
        )).detail,
        'no ask found',
      );
    });

    test('not_worthy under a YES verdict names the clause that said no, '
        'never the reason that said yes', () {
      // The judge said this wants the owner; the sweep set it aside anyway.
      // Quoting "asks for the DPA" under "Nothing to do" would be the app
      // contradicting itself in one line.
      expect(
        _line(_row(
          dropped: true,
          dropReason: 'not_worthy',
          needsYouVerdict: true,
          needsYouReason: 'asks for the DPA by Friday',
          bucket: 'later',
          bucketReason: 'user',
        )).detail,
        'the thread is in Later',
      );
      expect(
        _line(_row(
          dropped: true,
          dropReason: 'not_worthy',
          needsYouVerdict: true,
          needsYouReason: 'asks for the DPA by Friday',
        )).detail,
        'below the attention threshold',
      );
    });

    test('a gated drop names the gate that caught it', () {
      expect(
        _line(_row(
          dropped: true,
          dropReason: 'gated',
          gateReason: 'sender_muted',
        )).detail,
        'sender muted',
      );
      expect(
        _line(_row(
          dropped: true,
          dropReason: 'gated',
          gateReason: 'sender_muted',
        )).tooltip,
        'Dropped: Filtered — sender muted',
      );
      // No gate reason recorded is still a filter, just a quieter one.
      expect(
        _line(_row(dropped: true, dropReason: 'gated')).text,
        'Filtered',
      );
      expect(
        _line(_row(dropped: true, dropReason: 'gated')).detail,
        isNull,
      );
    });
  });

  group('in flight', () {
    test('a running stage speaks in the words the bar uses, capitalised',
        () {
      final result = _line(_row(
        outcome: 'pending',
        triage: 'done',
        extract: 'running',
        storyline: 'pending',
        settle: 'pending',
      ));

      expect(result.kind, HomeResultKind.inFlight);
      expect(result.text, 'Extracting…');
      expect(
        result.detail,
        isNull,
        reason: '"not queued yet" beside "Extracting…" would be the row '
            'contradicting itself',
      );
      expect(result.tone, BondTone.primary);
      expect(result.retryable, isFalse);
    });

    test('nothing running with work open is waiting its turn', () {
      final result = _line(_row(
        outcome: 'pending',
        storyline: 'pending',
        settle: 'pending',
        workOpen: true,
      ));

      expect(result.text, 'Waiting on storyline');
      expect(result.detail, isNull);
    });

    test('nothing running and nothing queued says so', () {
      final result = _line(_row(
        outcome: 'pending',
        storyline: 'pending',
        settle: 'pending',
      ));

      expect(result.text, 'Waiting on storyline');
      expect(result.detail, 'Not queued yet');
      expect(result.tooltip, 'Waiting on storyline — Not queued yet');
    });
  });

  group('needs you', () {
    test('a direct Teams message is named as one', () {
      final result = _line(_row(
        source: 'teams',
        needsYou: true,
        needsYouReason: 'teams_direct',
      ));

      expect(result.kind, HomeResultKind.needsYou);
      expect(result.text, 'Needs you');
      expect(result.detail, 'a direct Teams message');
      expect(result.tooltip, 'Needs you — a direct Teams message');
      expect(result.tone, BondTone.attention);
    });

    test('a sentence the model wrote is passed through as written', () {
      expect(
        _line(_row(
          needsYou: true,
          needsYouReason: 'asks you to confirm Thursday',
        )).detail,
        'asks you to confirm Thursday',
      );
    });

    test('no reason at all still says who decided', () {
      expect(
        _line(_row(needsYou: true)).detail,
        'the app thinks this wants you',
      );
      expect(
        _line(_row(needsYou: true, needsYouReason: '  ')).detail,
        'the app thinks this wants you',
      );
    });

    test('urgent turns the sentence red', () {
      expect(
        _line(_row(needsYou: true, urgency: 'urgent')).tone,
        BondTone.error,
      );
      expect(
        _line(_row(needsYou: true, urgency: 'high')).tone,
        BondTone.attention,
      );
    });

    test('outranks the filing it also has', () {
      expect(
        _line(_row(
          needsYou: true,
          storylineId: 's1',
          storylineTitle: 'Website redesign',
        )).kind,
        HomeResultKind.needsYou,
      );
    });
  });

  group('filed', () {
    test('names the storyline and why the row joined it', () {
      final result = _line(_row(
        storylineId: 's1',
        storylineTitle: 'Website redesign',
        storylineEvidence: 'same launch thread',
      ));

      expect(result.kind, HomeResultKind.filed);
      expect(result.text, 'Filed in Website redesign');
      expect(result.detail, 'same launch thread');
      expect(
        result.tooltip,
        'Filed in Website redesign — same launch thread',
      );
      expect(result.tone, BondTone.success);
    });

    test('a filing by hand says so, over whatever evidence was written', () {
      expect(
        _line(_row(
          storylineId: 's1',
          storylineTitle: 'Website redesign',
          storylineEvidence: 'same launch thread',
          storylineAddedBy: 'user',
        )).detail,
        'filed by you',
      );
      expect(
        homeFiledEvidence(_row(storylineAddedBy: 'user')),
        'filed by you',
      );
    });

    test('no evidence is a shorter sentence, not an empty clause', () {
      expect(
        _line(_row(storylineId: 's1', storylineTitle: 'Website redesign'))
            .detail,
        isNull,
      );
      expect(
        _line(_row(
          storylineId: 's1',
          storylineTitle: 'Website redesign',
          storylineEvidence: '   ',
        )).tooltip,
        'Filed in Website redesign',
      );
    });

    test('a title with no id behind it is not a filing', () {
      expect(
        _line(_row(storylineTitle: 'Website redesign')).kind,
        HomeResultKind.nothing,
      );
    });
  });

  group('later', () {
    test('every reason the sweep writes has words', () {
      expect(
        _line(_row(bucket: 'later', bucketReason: 'low_value')).detail,
        'low value',
      );
      expect(
        _line(_row(bucket: 'later', bucketReason: 'user')).detail,
        'you deferred it',
      );
      expect(
        _line(_row(bucket: 'later', bucketReason: 'sender_pref')).detail,
        'sender rule',
      );
      expect(
        _line(_row(bucket: 'later', bucketReason: 'low_value')).text,
        'Later',
      );
    });

    test('a reason this build has never heard of reads as itself', () {
      expect(
        _line(_row(bucket: 'later', bucketReason: 'quiet_hours')).detail,
        'quiet_hours',
      );
      expect(_line(_row(bucket: 'later')).detail, 'deferred');
    });

    test('another bucket is not this sentence', () {
      expect(
        _line(_row(bucket: 'done', bucketReason: 'low_value')).kind,
        HomeResultKind.nothing,
      );
    });
  });

  test('a finished draft is the last thing worth saying', () {
    final result = _line(_row(draft: 'done'));

    expect(result.kind, HomeResultKind.draftReady);
    expect(result.text, 'Draft ready');
    expect(result.detail, isNull);
    expect(result.tooltip, 'Draft ready');
    expect(result.tone, BondTone.success);
  });

  group('nothing to do', () {
    test('is what is left, and says nothing it cannot back up', () {
      final result = _line(_row());

      expect(result.kind, HomeResultKind.nothing);
      expect(result.text, 'Nothing to do');
      expect(result.detail, isNull);
      expect(result.tooltip, 'Nothing to do');
      expect(result.tone, BondTone.neutral);
    });

    test('a recorded NO carries its reason into the tooltip', () {
      expect(
        _line(_row(
          needsYouVerdict: false,
          needsYouReason: 'a calendar invite you already accepted',
        )).tooltip,
        'Nothing to do — a calendar invite you already accepted',
      );
    });

    test('an unasked verdict has nothing to add', () {
      // The reason column can hold a stale sentence from a verdict that was
      // never re-run; without a recorded no beside it, it is not an answer.
      expect(
        _line(_row(needsYouReason: 'looked like an ask once')).tooltip,
        'Nothing to do',
      );
    });
  });

  group('the ask line', () {
    HomeAsk ask(HomeFeedRow row) => askLine(row, _line(row));

    test('a needs-you row prefers the thread\'s ask over everything', () {
      final result = ask(_row(
        needsYou: true,
        needsYouReason: 'asks you to confirm Thursday',
        ctaText: 'Confirm Thursday with Sarah',
        summary: 'Sarah proposes moving the launch',
      ));

      expect(result.text, 'Confirm Thursday with Sarah');
      expect(result.ask, isTrue);
    });

    test('then the judge\'s reason, then the reason clause', () {
      expect(
        ask(_row(
          needsYou: true,
          needsYouReason: 'asks you to confirm Thursday',
          summary: 'Sarah proposes moving the launch',
        )).text,
        'asks you to confirm Thursday',
        reason: 'an ask is per thread; the summary is about one message on it',
      );
      // No ask and no reason: the clause the Result cell put down is what is
      // left, and it is better than a blank.
      expect(
        ask(_row(needsYou: true)).text,
        'the app thinks this wants you',
      );
      // Whitespace is not an ask.
      expect(
        ask(_row(needsYou: true, ctaText: '   ', needsYouReason: '  ')).text,
        'the app thinks this wants you',
      );
    });

    test('a settled row shows the summary, and is not an ask', () {
      final result = ask(_row(summary: 'A receipt for the annual licence'));

      expect(result.text, 'A receipt for the annual licence');
      expect(result.ask, isFalse);
    });

    test('a dropped row is never an ask, whatever the thread wanted', () {
      // The app judged this one did not need the owner. Drawing its CTA as
      // work would be the app arguing with itself.
      final result = ask(_row(
        dropped: true,
        dropReason: 'newsletter',
        needsYou: true,
        ctaText: 'Reply to the newsletter',
        summary: 'This week in widgets',
      ));

      expect(result.text, 'This week in widgets');
      expect(result.ask, isFalse);
    });

    test('a row with no summary falls back to the reason clause', () {
      // A gate-dropped message never reached triage, so there is no summary
      // for it to fall back to.
      expect(
        ask(_row(
          dropped: true,
          dropReason: 'gated',
          gateReason: 'sender_muted',
        )).text,
        'sender muted',
      );
      // And a row with neither is empty rather than inventing a sentence.
      expect(ask(_row()).text, '');
    });
  });

  test('only a stalled or failed row can be retried', () {
    expect(
      _line(_row(outcome: 'pending', updatedAt: _minutesAgo(30))).retryable,
      isTrue,
    );
    expect(_line(_row(settle: 'error')).retryable, isTrue);
    for (final row in [
      _row(dropped: true, dropReason: 'newsletter'),
      _row(outcome: 'pending', settle: 'pending'),
      _row(needsYou: true),
      _row(storylineId: 's1', storylineTitle: 'Website redesign'),
      _row(bucket: 'later'),
      _row(draft: 'done'),
      _row(),
    ]) {
      expect(_line(row).retryable, isFalse, reason: _line(row).text);
    }
  });
}
