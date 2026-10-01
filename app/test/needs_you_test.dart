import 'package:bond_inbox/services/needs_you.dart';
import 'package:flutter_test/flutter_test.dart';

/// The deterministic floor, as a pure function over one stored row. No
/// database and no model: the whole point of this half of the judgement is
/// that it is arithmetic on columns the connector already wrote.

Map<String, Object?> row({
  String source = 'teams',
  String direction = 'inbound',
  int addressedMe = 1,
}) =>
    {
      'source': source,
      'source_message_id': 'm1',
      'direction': direction,
      'addressed_me': addressedMe,
    };

void main() {
  group('needsYouFloor', () {
    test('a chat that named the owner, or was only to them, is a yes', () {
      // Teams ingest writes one bit for both of those, so this is the only
      // shape the floor ever sees on a direct chat.
      expect(needsYouFloor(row()), isTrue);
    });

    test('a chat that named nobody is not', () {
      // A busy group channel. Not a no — the floor only ever raises — but
      // nothing this function can settle.
      expect(needsYouFloor(row(addressedMe: 0)), isFalse);
    });

    test('sole-recipient mail is not, however addressed it looks', () {
      // `addressed_me` on mail means "the only To: address", which every
      // receipt and vendor blast also satisfies. The model reads these.
      expect(needsYouFloor(row(source: 'email')), isFalse);
    });

    test('the owner writing in their own 1:1 chat is never', () {
      expect(needsYouFloor(row(direction: 'outbound')), isFalse);
    });

    test('the flag is read as the INTEGER sqlite stores, not for truthiness',
        () {
      // A STRICT column holds 0 or 1, and anything else on the row is a bug
      // upstream — it must not be rounded up into a verdict here.
      expect(needsYouFloor({...row(), 'addressed_me': true}), isFalse);
      expect(needsYouFloor({...row(), 'addressed_me': null}), isFalse);
    });
  });
}
