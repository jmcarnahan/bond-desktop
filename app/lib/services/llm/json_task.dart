import 'llm_client.dart';

/// One structured job for the local model: the prompt it runs on, the schema
/// its answer is constrained to, and the validation that turns that answer
/// into a typed result.
///
/// The split exists so the prompt and its validator live in the same file and
/// are tested without a model: everything below [runTask] is pure.
abstract class JsonTask<T> {
  /// MUST be identical on every call. llama-server caches the KV prefix, and
  /// a system prompt that varies — even by a date — pays roughly two seconds
  /// per message to rebuild it. Per-message text goes in the user message.
  String get systemPrompt;

  /// The JSON schema the answer is constrained to. This server enforces it,
  /// so a schema it cannot convert fails the request with a 400 rather than
  /// being quietly ignored.
  Map<String, dynamic> get schema;

  String get schemaName;

  String buildUserMessage(covariant Object input);

  /// Turns one decoded answer into [T]. MUST NOT throw: a grammar guarantees
  /// the shape of what comes back and nothing about its sense, so every field
  /// is clamped to something renderable rather than trusted.
  T validate(Map<String, dynamic> json);
}

/// Runs [task] over [input]. The only place the two halves meet.
///
/// [temperature] is per call rather than per task: the same task can want a
/// deterministic answer in a batch job and a slightly varied one behind a
/// button, and the schema does not change either way.
///
/// [maxTokens] is per call for a blunter reason: a label fits in a fraction of
/// the default and a drafted reply does not, and a budget that runs out mid-
/// string comes back as a grammar-valid answer that was simply cut off.
///
/// [think] exists for the bakeoff and defaults to the app's own answer: off.
/// Every caller in `lib/` leaves it alone, so nothing about the shipping path
/// changes. A benched CANDIDATE can need it — an always-reasoning model like
/// R1-Distill has no `enable_thinking` toggle to honour, so sending the kwarg
/// asks for something the runtime cannot give and the tripwire then counts a
/// fact about the model as a defect. Under `BENCH_THINK` the benches pass true,
/// which drops `chat_template_kwargs` from the body entirely: the request stops
/// claiming otherwise, and the leak count stops being a gate.
Future<T> runTask<T>(
  LlmClient client,
  JsonTask<T> task,
  Object input, {
  double temperature = 0.2,
  int maxTokens = 512,
  bool think = false,
}) async {
  final json = await client.completeJson(
    system: task.systemPrompt,
    user: task.buildUserMessage(input),
    schema: task.schema,
    schemaName: task.schemaName,
    temperature: temperature,
    maxTokens: maxTokens,
    think: think,
  );
  return task.validate(json);
}
