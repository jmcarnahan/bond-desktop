import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/draft_provider.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/memory_token_store.dart';
import 'fixtures/test_db.dart';

/// A worker that records every pump's `first:` and drains nothing.
class _RecordingWorker extends AiWorker {
  _RecordingWorker(super.store) : super(handlers: const []);

  final List<List<({String source, String id})>> pumped = [];

  @override
  Future<void> pump({List<({String source, String id})> first = const []}) {
    pumped.add([...first]);
    return Future.value();
  }
}

/// The draft lane also drains `meeting_brief`, so an asked draft must be
/// NAMED to the pump, not just pumped: named, it is served at the next claim
/// boundary instead of behind up to six briefs.
void main() {
  late BondDatabase db;
  late MessageStore store;

  final never = MockClient((_) async => http.Response('never dialled', 500));

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  test("an asked draft is passed to the pump as `first`, by its message's "
      'ref', () async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'inbound-1',
      'conversation_key': 'conv-1',
      'direction': 'inbound',
      'received_at': '2026-08-29T10:00:00Z',
    });
    final worker = _RecordingWorker(store);
    addTearDown(worker.dispose);
    final auth = GraphAuth(httpClient: never, store: MemoryTokenStore());
    final notifier = DraftNotifier(
      store,
      auth,
      GraphMail(auth, httpClient: never),
      (source: 'email', conversationKey: 'conv-1'),
      worker: worker,
    );
    addTearDown(notifier.dispose);
    await notifier.load();

    await notifier.generate();

    expect(worker.pumped, [
      [(source: 'email', id: 'inbound-1')],
    ]);
  });
}
