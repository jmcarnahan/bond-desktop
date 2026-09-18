import 'dart:convert';

import 'package:bond_inbox/models/draft_request.dart';
import 'package:flutter_test/flutter_test.dart';

// The payload on a `draft` work row is the one free-form field in the queue,
// so most of these are hostile-input tests rather than round-trip
// formalities: a value nobody can read must cost the pinning, the
// consultation and the `asked` flag, and never the draft.

/// What every unreadable payload has to come back as.
final Matcher isNothingAsked = predicate<DraftRequest>(
  (r) => r.pinnedAttachmentIds.isEmpty && r.contextFileIds.isEmpty && !r.asked,
  'a request that names nothing and nobody asked for',
);

void main() {
  group('a payload nobody can read', () {
    test('null, empty and non-string read as nothing asked for', () {
      expect(DraftRequest.fromPayload(null), isNothingAsked);
      expect(DraftRequest.fromPayload(''), isNothingAsked);
      expect(DraftRequest.fromPayload(42), isNothingAsked);
      expect(DraftRequest.fromPayload(const ['a']), isNothingAsked);
    });

    test('garbage that is not JSON reads as nothing asked for', () {
      expect(DraftRequest.fromPayload('{not json at all'), isNothingAsked);
      expect(DraftRequest.fromPayload('}'), isNothingAsked);
    });

    test('JSON that is not an object reads as nothing asked for', () {
      expect(DraftRequest.fromPayload('[1,2,3]'), isNothingAsked);
      expect(DraftRequest.fromPayload('"a string"'), isNothingAsked);
      expect(DraftRequest.fromPayload('7'), isNothingAsked);
      expect(DraftRequest.fromPayload('null'), isNothingAsked);
    });

    test('an object with none of the keys reads as nothing asked for', () {
      expect(DraftRequest.fromPayload('{"something_else":1}'), isNothingAsked);
    });
  });

  group('the ids are filtered to what they could legitimately be', () {
    test('a pinned id is a non-empty string, and nothing else survives', () {
      final request = DraftRequest.fromPayload(
        '{"pinned_attachment_ids":["att-1","",7,null,{"a":1},"att-2"]}',
      );

      expect(request.pinnedAttachmentIds, ['att-1', 'att-2']);
    });

    test('a context file id is a positive integer, and nothing else is', () {
      final request = DraftRequest.fromPayload(
        '{"context_file_ids":[7,0,-1,"9",null,2.5,11]}',
      );

      expect(request.contextFileIds, [7, 11]);
    });

    test('an id list that is not a list costs only that list', () {
      final request = DraftRequest.fromPayload(
        '{"pinned_attachment_ids":"att-1","context_file_ids":[7],'
        '"asked":true}',
      );

      expect(request.pinnedAttachmentIds, isEmpty);
      expect(request.contextFileIds, [7]);
      expect(request.asked, isTrue);
    });
  });

  group('asked', () {
    test('only the literal true reads as a person having asked', () {
      expect(DraftRequest.fromPayload('{"asked":true}').asked, isTrue);
      expect(DraftRequest.fromPayload('{"asked":"true"}').asked, isFalse);
      expect(DraftRequest.fromPayload('{"asked":1}').asked, isFalse);
      expect(DraftRequest.fromPayload('{"asked":false}').asked, isFalse);
      expect(DraftRequest.fromPayload('{"asked":null}').asked, isFalse);
      expect(DraftRequest.fromPayload('{}').asked, isFalse);
    });
  });

  group('encode', () {
    test('an empty request encodes to null, not to an empty object', () {
      // An eager prefetch keeps the null payload it has always had.
      expect(const DraftRequest().encode(), isNull);
      expect(DraftRequest.none.encode(), isNull);
    });

    test('only the keys that carry something are written', () {
      expect(
        const DraftRequest(pinnedAttachmentIds: ['att-1']).encode(),
        '{"pinned_attachment_ids":["att-1"]}',
      );
      expect(
        const DraftRequest(contextFileIds: [7]).encode(),
        '{"context_file_ids":[7]}',
      );
      expect(const DraftRequest(asked: true).encode(), '{"asked":true}');
    });

    test('the wire keys are the ones the stored rows already use', () {
      final decoded = jsonDecode(
        const DraftRequest(
          pinnedAttachmentIds: ['att-1'],
          contextFileIds: [7],
          asked: true,
        ).encode()!,
      ) as Map<String, Object?>;

      expect(
        decoded.keys,
        ['pinned_attachment_ids', 'context_file_ids', 'asked'],
      );
    });
  });

  group('round trip', () {
    void roundTrips(String what, DraftRequest request) {
      test(what, () {
        final back = DraftRequest.fromPayload(request.encode());

        expect(back.pinnedAttachmentIds, request.pinnedAttachmentIds);
        expect(back.contextFileIds, request.contextFileIds);
        expect(back.asked, request.asked);
      });
    }

    roundTrips('nothing at all', const DraftRequest());
    roundTrips('pinned alone',
        const DraftRequest(pinnedAttachmentIds: ['att-1', 'att-2']));
    roundTrips('consulted alone', const DraftRequest(contextFileIds: [7, 11]));
    roundTrips('asked alone', const DraftRequest(asked: true));
    roundTrips(
      'all three together',
      const DraftRequest(
        pinnedAttachmentIds: ['att-1'],
        contextFileIds: [7],
        asked: true,
      ),
    );
  });
}
