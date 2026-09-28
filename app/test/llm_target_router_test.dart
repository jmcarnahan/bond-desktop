import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where each role points while this Mac runs the models, with the app's own
/// server and without it.
///
/// Pure values: [AppPrefs] is immutable and every spec on it is composed from
/// stored fields, so nothing here needs a database, a container or a server.
/// What is pinned is the THIS MAC half of the rule: the managed router answers
/// every role on one origin and routes on the `model` field, and a
/// `BOND_DEV_HAND_SERVERS` build dials the hand-started servers instead.

/// The build that hands the servers over — `BOND_DEV_HAND_SERVERS` — said
/// here as the field it sets, because the define is compiled and a test cannot
/// pass one. [_managed] is what every shipped build reads.
const AppPrefs _handStarted = AppPrefs(managedServer: false);
const AppPrefs _managed = AppPrefs();

void main() {
  test('hand-started, each role dials its make-target server', () {
    expect(_handStarted.generativeSpec.url, proseUrlDefault);
    expect(_handStarted.generativeSpec.model, proseModelDefault);
    expect(_handStarted.generativeSpec.id, localGenerativeId);
    expect(_handStarted.decisionSpec.url, decideUrlDefault);
    expect(_handStarted.decisionSpec.model, decideModelDefault);
    expect(_handStarted.decisionSpec.id, localDecisionId);
    expect(
      _handStarted.embedRequestTarget,
      const LlmTarget(
        baseUrl: EmbeddingsClient.defaultBaseUrl,
        model: EmbeddingsClient.requestModel,
      ),
    );
  });

  test('managed, every role is the router, told apart by model', () {
    expect(_managed.generativeSpec.url,
        'http://127.0.0.1:8080/v1/chat/completions');
    // The full tier (the default until the hardware answers) serves the 27B.
    expect(_managed.generativeSpec.model, routerProseId);
    expect(_managed.decisionSpec.url, 'http://127.0.0.1:8080/v1/embeddings');
    expect(_managed.decisionSpec.model, routerDecideId);
    expect(
      _managed.embedRequestTarget,
      const LlmTarget(
        baseUrl: 'http://127.0.0.1:8080/v1/embeddings',
        model: routerEmbedId,
      ),
    );
  });

  test('the managed generative model follows the tier and the choice', () {
    expect(const AppPrefs(machineTier: MachineTier.inbox).generativeSpec.model,
        routerBulkId);
    expect(
      const AppPrefs(generativeManagedModel: routerBulkId)
          .generativeSpec
          .model,
      routerBulkId,
    );
    // The 27B is refused on the inbox tier, whatever was stored.
    expect(
      const AppPrefs(
        machineTier: MachineTier.inbox,
        generativeManagedModel: routerProseId,
      ).generativeSpec.model,
      routerBulkId,
    );
  });

  test('the generative width is the drafts-in-flight setting here', () {
    expect(const AppPrefs(proseParallel: 4).generativeSpec.parallel, 4);
    expect(
      const AppPrefs(proseParallel: 2, managedServer: false)
          .generativeSpec
          .parallel,
      2,
    );
  });

  test('moving the port moves all three roles together', () {
    const prefs = AppPrefs(routerPort: 9310);
    expect(prefs.routerBase, 'http://127.0.0.1:9310');
    expect(prefs.generativeSpec.url,
        'http://127.0.0.1:9310/v1/chat/completions');
    expect(prefs.decisionSpec.url, 'http://127.0.0.1:9310/v1/embeddings');
    expect(prefs.embedRequestTarget.baseUrl,
        'http://127.0.0.1:9310/v1/embeddings');
  });

  /// The one that would be silently wrong if the corpus tag were sent: the
  /// tag every stored vector carries is not a model any server serves.
  test('the embed request never carries the corpus tag', () {
    expect(_handStarted.embedRequestTarget.model, 'embed');
    expect(_managed.embedRequestTarget.model, routerEmbedId);
    for (final prefs in [_handStarted, _managed]) {
      expect(prefs.embedRequestTarget.model,
          isNot(EmbeddingsClient.modelTag));
    }
  });
}
