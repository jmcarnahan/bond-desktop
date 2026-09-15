import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:http/http.dart' as http;

import 'bench_stats.dart';

/// Where a live bench points, and what the report should call it.
///
/// A target is an ordinary VALUE, not configuration the app reads: the live
/// tests construct their own clients, and the dart-defines below are only the
/// defaults the Makefile fills in. Nothing in `lib/` looks at any of this —
/// the app's own servers stay on `LLAMA_URL`/`FAST_LLAMA_URL`, so pointing a
/// bakeoff at an experimental runtime cannot move the app onto it by accident.
///
/// [label] is the whole reason a run is readable a week later. It names the
/// runtime AND the weights (`omlx/qwen3-4b-4bit`), because two candidates that
/// differ only in quantization produce two tables that are otherwise identical.
class BenchTarget {
  /// `bulk` or `prose` — which of the app's two jobs this target stands in
  /// for. Kept so a bench can say what it was benching; the report identifies
  /// targets by [label].
  final String slot;

  final String label;
  final String url;
  final String model;

  /// Which request shape this target is spoken to in — `openai` or
  /// `converse`, parsed by [parseWire]. A string rather than an [LlmWire]
  /// because it comes straight off a `--dart-define`, and a const constructor
  /// cannot parse.
  final String wireName;

  const BenchTarget({
    required this.slot,
    required this.label,
    required this.url,
    required this.model,
    this.wireName = 'openai',
  });

  /// The bulk-work slot: triage, extraction, membership. Defaults to the fast
  /// server the app already uses, so a bench with no defines benches today.
  static const BenchTarget bulk = BenchTarget(
    slot: 'bulk',
    label: String.fromEnvironment('BENCH_LABEL', defaultValue: 'fast (default)'),
    url: String.fromEnvironment('BENCH_URL', defaultValue: LlmClient.fastBaseUrl),
    model: String.fromEnvironment('BENCH_MODEL',
        defaultValue: LlmClient.defaultModel),
    wireName: String.fromEnvironment('BENCH_WIRE', defaultValue: 'openai'),
  );

  /// The prose slot: drafts and storyline names — the work that goes to the
  /// big server today, and the side of the A/B a candidate is compared against.
  static const BenchTarget prose = BenchTarget(
    slot: 'prose',
    label: String.fromEnvironment('PROSE_LABEL', defaultValue: '27B (default)'),
    url: String.fromEnvironment('PROSE_URL',
        defaultValue: LlmClient.defaultBaseUrl),
    model: String.fromEnvironment('PROSE_MODEL',
        defaultValue: LlmClient.defaultModel),
    wireName: String.fromEnvironment('PROSE_WIRE', defaultValue: 'openai'),
  );

  /// Where a run drops its JSON, or empty for none. Absolute: `flutter test`
  /// runs with `app/` as its working directory, so a relative path would
  /// scatter results wherever the runner happened to be invoked from.
  static const String outDir = String.fromEnvironment('BENCH_OUT');

  /// Discarded calls before the clock starts. llama.cpp measured 6.8 tok/s on
  /// its first call against 130 warm on this machine — a cold call in the
  /// sample does not slow the median down, it replaces it with a number about
  /// weight loading. See MODEL_FLAGS in the Makefile.
  static const int warmup = int.fromEnvironment('BENCH_WARMUP', defaultValue: 1);

  /// The escape hatch for candidates that always reason: R1-Distill has no
  /// `enable_thinking` toggle to honour, so the leak tripwire would fail every
  /// run against it for no defect. With this set the benches PRINT the leak
  /// count instead of asserting it is zero — the number still has to be read,
  /// it just stops being a gate.
  static const bool allowReasoning = bool.fromEnvironment('BENCH_THINK');

  /// Which concurrencies the drain races, comma-separated and in the order it
  /// races them — `1,3` by default, the shipping pair.
  ///
  /// The server has to be started with AT LEAST max(K) slots
  /// (`make fast FAST_SLOTS=…`) or the high rounds measure the wrong thing
  /// entirely: requests past the slot count queue on the server rather than
  /// batch, so K=6 against a 4-slot server reports queue-wait dressed up as
  /// throughput and the speedup flattens for a reason that has nothing to do
  /// with the runtime under test.
  static const String drainK =
      String.fromEnvironment('BENCH_K', defaultValue: '1,3');

  /// The cloud key, for both slots at once — an A/B against a hosted model
  /// uses one account, not two.
  ///
  /// Resolved by the SHELL inside the Makefile recipe (`$(grep … $(BEDROCK_ENV)
  /// | cut -d= -f2-)`), so the value never sits in a make variable and
  /// `make -n` prints the grep rather than the key. Empty means none, which is
  /// every local run.
  static const String bearer = String.fromEnvironment('BENCH_BEARER');

  /// Which wire this target's client speaks.
  LlmWire get wire => parseWire(wireName);

  /// The key this target is entitled to, or null — see [bearerFor].
  String? get bearerToken => bearerFor(url, bearer);

  LlmClient client({LlmCallObserver? onCall, http.Client? httpClient}) =>
      LlmClient(
        baseUrl: url,
        model: model,
        onCall: onCall,
        httpClient: httpClient,
        bearerToken: bearerToken,
        wire: wire,
      );

  CallCollector collector() =>
      CallCollector(label: label, url: url, model: model);
}

/// [BenchTarget.drainK] as the numbers it names, in the order it names them.
///
/// Loud rather than lenient: a define is typed by hand on a command line, and
/// a `BENCH_K=1,3,` that silently became `[1, 3]` — or a `BENCH_K=1;3` that
/// became `[1]` — would produce a table with a round missing and nothing
/// anywhere saying so.
List<int> parseDrainK([String raw = BenchTarget.drainK]) {
  final rounds = <int>[];
  for (final part in raw.split(',')) {
    final value = int.tryParse(part.trim());
    if (value == null || value < 1) {
      throw ArgumentError.value(
        raw,
        'BENCH_K',
        'expected comma-separated positive integers (e.g. 1,3,6)',
      );
    }
    rounds.add(value);
  }
  if (rounds.isEmpty) {
    throw ArgumentError.value(raw, 'BENCH_K', 'names no concurrency to run');
  }
  return rounds;
}

/// The key a target at [url] may be handed, or null.
///
/// The key is Bedrock's, so it goes to Bedrock and nowhere else: only a host
/// under `amazonaws.com` receives it. A llama-server on this desk, on the LAN
/// or on a `.local` name has no use for it and is not shown it, so a `.env`
/// that carries a key does not change a single byte of what any other run
/// sends. A URL that cannot be parsed gets nothing, for the same reason
/// `isLocalUrl` in `golden_prices.dart` treats one as remote: "could not read
/// where this went" must never resolve to "so send the credential".
String? bearerFor(String url, String key) {
  if (key.isEmpty) return null;
  final host = Uri.tryParse(url)?.host ?? '';
  final isBedrock =
      host == 'amazonaws.com' || host.endsWith('.amazonaws.com');
  return isBedrock ? key : null;
}

/// [BenchTarget.wireName] as the wire it names.
///
/// Loud rather than lenient, for [parseDrainK]'s reason: a `BENCH_WIRE=bedrock`
/// that quietly meant `openai` would send an OpenAI body to an endpoint that
/// answers 404 for it, and the run would report the candidate as broken rather
/// than the define as mistyped.
LlmWire parseWire(String raw) => switch (raw) {
      'openai' => LlmWire.openAi,
      'converse' => LlmWire.bedrockConverse,
      _ => throw ArgumentError.value(
          raw,
          'BENCH_WIRE',
          "expected 'openai' or 'converse'",
        ),
    };
