import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where each slot points once the app runs its own server.
///
/// Pure values: [AppPrefs] is immutable and every target on it is composed
/// from stored fields, so nothing here needs a database, a container or a
/// server. What is being pinned is the ROUTING RULE — managed mode answers for
/// a slot only while that slot is on the build's own values — because it is
/// the one place where turning a switch on could silently take a server away
/// from somebody who deliberately chose one.

const AppPrefs _handStarted = AppPrefs();
const AppPrefs _managed = AppPrefs(managedServer: true);

void main() {
  test('unmanaged, every slot is exactly what it always was', () {
    expect(_handStarted.fastTarget, fastSlotDefault);
    expect(_handStarted.proseTarget, proseSlotDefault);
    expect(_handStarted.targetFor(ModelSlot.embed), embedSlotDefault);
  });

  test('managed with no overrides, all three point at the router', () {
    expect(
      _managed.fastTarget,
      const LlmTarget(
        baseUrl: 'http://127.0.0.1:8080/v1/chat/completions',
        model: routerBulkId,
      ),
    );
    expect(
      _managed.proseTarget,
      const LlmTarget(
        baseUrl: 'http://127.0.0.1:8080/v1/chat/completions',
        model: routerProseId,
      ),
    );
    expect(
      _managed.embedRequestTarget,
      const LlmTarget(
        baseUrl: 'http://127.0.0.1:8080/v1/embeddings',
        model: routerEmbedId,
      ),
    );
  });

  test('a stored override keeps its slot, and only its slot', () {
    const prefs = AppPrefs(
      managedServer: true,
      fastLlmUrl: 'http://127.0.0.1:9000/v1/chat/completions',
      fastLlmModel: 'mlx-4b',
    );

    expect(
      prefs.fastTarget,
      const LlmTarget(
        baseUrl: 'http://127.0.0.1:9000/v1/chat/completions',
        model: 'mlx-4b',
      ),
    );
    expect(prefs.proseTarget.model, routerProseId);
    expect(prefs.proseTarget.baseUrl, 'http://127.0.0.1:8080/v1/chat/completions');
  });

  test('half an override is still an override', () {
    // Only the model is stored, so the URL falls back to the compiled default
    // rather than to the router: the slot is not on the build's own values,
    // and the rule is about the PAIR.
    const prefs = AppPrefs(managedServer: true, fastLlmModel: 'mlx-4b');
    expect(prefs.fastTarget.baseUrl, fastUrlDefault);
    expect(prefs.fastTarget.model, 'mlx-4b');
  });

  test('moving the port moves all three targets together', () {
    const prefs = AppPrefs(managedServer: true, routerPort: 9310);
    expect(prefs.routerBase, 'http://127.0.0.1:9310');
    expect(
      prefs.fastTarget.baseUrl,
      'http://127.0.0.1:9310/v1/chat/completions',
    );
    expect(
      prefs.proseTarget.baseUrl,
      'http://127.0.0.1:9310/v1/chat/completions',
    );
    expect(prefs.embedRequestTarget.baseUrl, 'http://127.0.0.1:9310/v1/embeddings');
  });

  /// The one that would be silently wrong if the two embed targets were
  /// merged: the DISPLAY target's model is the corpus tag every stored vector
  /// carries, and the REQUEST target's model is what the wire asks a server
  /// for. They are different strings on purpose, in both modes.
  test('the embed display target and the embed request target differ', () {
    expect(
      _handStarted.targetFor(ModelSlot.embed).model,
      EmbeddingsClient.modelTag,
    );
    expect(_handStarted.embedRequestTarget.model, EmbeddingsClient.requestModel);
    expect(_handStarted.embedRequestTarget.model, 'embed');

    expect(_managed.targetFor(ModelSlot.embed), _managed.routerEmbedTarget);
    expect(_managed.embedRequestTarget.model, routerEmbedId);
  });

  /// The editors' baseline, which is not the same question as [targetFor].
  ///
  /// A slot's editor normalises a saved value equal to its `compiledDefault`
  /// back to the empty string. Hand it the COMPILED default in managed mode
  /// and a Save on an untouched editor stores today's router URL as a real
  /// override, which detaches the slot from the router for good — the port
  /// then moves and the slot does not follow.
  test('the editor baseline is the compiled default only while unmanaged', () {
    expect(_handStarted.slotBaseline(ModelSlot.fast), fastSlotDefault);
    expect(_handStarted.slotBaseline(ModelSlot.prose), proseSlotDefault);
    expect(_handStarted.slotBaseline(ModelSlot.embed), embedSlotDefault);

    expect(_managed.slotBaseline(ModelSlot.fast), _managed.routerBulkTarget);
    expect(_managed.slotBaseline(ModelSlot.prose), _managed.routerProseTarget);
    expect(_managed.slotBaseline(ModelSlot.embed), _managed.routerEmbedTarget);
  });

  test('managed mode does not change what counts as a default slot', () {
    expect(_managed.isSlotDefault(ModelSlot.fast), isTrue);
    expect(_managed.isSlotDefault(ModelSlot.prose), isTrue);
    expect(_managed.isSlotDefault(ModelSlot.embed), isTrue);
    const overridden = AppPrefs(managedServer: true, proseLlmUrl: 'http://x/y');
    expect(overridden.isSlotDefault(ModelSlot.prose), isFalse);
  });
}
