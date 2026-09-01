import 'package:bond_inbox/services/gates.dart';
import 'package:bond_inbox/services/llm/extract_task.dart';
import 'package:bond_inbox/services/llm/triage_task.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/corpus.dart';

/// The whole corpus through the pure layers — no model, no socket, no store.
///
/// `gates_test.dart` proves each gate against a message built to trip it. This
/// file asks the opposite question: given the mail this app will actually be
/// timed on, does every message end up on the side of the gate it belongs on,
/// and does the prompt built for the survivors hold together? A corpus entry
/// that quietly starts gating is a perf number measured on nineteen emails
/// instead of twenty, and nothing else would say so.

/// Pinned, because the anchor line is asserted. Any date works; this one is a
/// Monday, which is what makes the weekday in the anchor worth printing.
final DateTime pinnedNow = DateTime(2026, 8, 31, 9, 30);

/// `wrapUntrusted`'s escaping, restated rather than imported — a test that
/// built its expectation with the function under test would pass on any
/// escaping at all, including none.
String escaped(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// What both tasks feed the model: the body, or the preview standing in for
/// one, clipped at the cap.
String promptBody(CorpusEmail entry) {
  final message = entry.message;
  final body = message.bodyText?.isNotEmpty == true
      ? message.bodyText!
      : (message.bodyPreview ?? '');
  return body.length > bodyCap ? body.substring(0, bodyCap) : body;
}

void main() {
  test('the corpus is the twenty-two messages the phases measure', () {
    expect(corpus.length, 22);
    expect(gatedCorpus.length + nonGatedCorpus.length, corpus.length);
    // Slugs are ids, conversation keys and test names all at once, so a
    // duplicate would silently collapse two fixtures into one.
    expect(corpus.map((entry) => entry.id).toSet().length, corpus.length);
  });

  group('gates', () {
    for (final entry in gatedCorpus) {
      test('${entry.id} is caught as ${entry.expectedGate}', () {
        expect(
          gateFor(entry.message, userAddress: userAddress),
          entry.expectedGate,
        );
      });
    }

    for (final entry in nonGatedCorpus) {
      test('${entry.id} reaches the model', () {
        expect(gateFor(entry.message, userAddress: userAddress), isNull);
      });
    }
  });

  group('the triage prompt', () {
    const task = TriageTask();

    for (final entry in nonGatedCorpus) {
      test('${entry.id} is anchored and fenced', () {
        final user = task.buildUserMessage(TriageInput(entry.message, pinnedNow));

        // The anchor is ours and sits OUTSIDE the fence; everything the
        // sender wrote sits inside it.
        expect(user, startsWith('Today is 2026-08-31 ('));
        expect(user, contains('<untrusted_data source="inbound_email">'));
        expect(user, contains('</untrusted_data>'));
        expect(user, contains(escaped(promptBody(entry))));
      });
    }

    test('the quoted-thread monster is clipped at the body cap', () {
      final entry =
          corpus.firstWhere((entry) => entry.id == 'quoted-thread-monster');
      final body = entry.message.bodyText!;

      // The fixture only means something if the marker really is past the cap.
      expect(body.length, greaterThan(bodyCap));
      expect(body.indexOf(quotedTailMarker), greaterThan(bodyCap));

      final user = task.buildUserMessage(TriageInput(entry.message, pinnedNow));

      // Four rounds of quoted history and a confidentiality footer, not sent.
      expect(user, isNot(contains(quotedTailMarker)));
      expect(user, contains('sending the revised homepage copy'));
    });
  });

  group('the extraction prompt', () {
    const task = ExtractTask();

    for (final entry in nonGatedCorpus) {
      test('${entry.id} builds the same way triage does', () {
        final user =
            task.buildUserMessage(ExtractionInput(entry.message, pinnedNow));

        expect(user, startsWith('Today is 2026-08-31 ('));
        expect(user, contains(escaped(promptBody(entry))));
      });
    }
  });
}
