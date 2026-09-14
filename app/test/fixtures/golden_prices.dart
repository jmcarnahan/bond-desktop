/// What a golden run would cost per message if the model were rented rather
/// than run on this desk.
///
/// The bakeoff's local candidates cost nothing per token and a great deal in
/// RAM; the cloud candidates cost the reverse. A speed table alone cannot put
/// those two next to each other, so a run prices its own token sums here and
/// quotes a dollars-per-thousand-messages column beside the throughput one.
///
/// Nothing in `lib/` reads any of this. It is a bakeoff's arithmetic, kept in
/// `test/fixtures/` with the rest of the bench apparatus for that reason.
library;

/// The day the prices below were copied down.
///
/// Dated on purpose and printed with every cost figure: prices move, and a
/// cost column that does not say when it was priced is a rumour. A row in the
/// ledger quoted against a stale table is a number nobody can re-derive.
const String pricesDated = '2026-09-12';

/// List price for one model, in USD per million tokens.
class TokenPrice {
  final double inputPerMTok;
  final double outputPerMTok;

  const TokenPrice(this.inputPerMTok, this.outputPerMTok);
}

/// Bedrock list prices, keyed by the `model` field a request actually carries.
///
/// Keyed by wire id rather than by a friendly name because that is the only
/// string a run knows about itself: `BENCH_MODEL` goes into the request body
/// and into the result JSON, and a lookup by anything else would need a second
/// mapping to drift out of step with this one.
const Map<String, TokenPrice> bedrockPrices = {
  'nvidia.nemotron-nano-3-30b': TokenPrice(0.06, 0.24),
  // The wire id here is not yet confirmed against a live call; a later phase
  // pins it. An id that turns out wrong reads as an unpriced model — blank
  // rather than zero — which is the failure this table is built to prefer.
  'nvidia.nemotron-nano-9b-v2': TokenPrice(0.06, 0.23),
  'openai.gpt-oss-safeguard-20b': TokenPrice(0.07, 0.20),
  'zai.glm-4.7-flash': TokenPrice(0.07, 0.40),
  'google.gemma-3-12b-it': TokenPrice(0.09, 0.29),
  'openai.gpt-oss-120b-1:0': TokenPrice(0.15, 0.60),
  'nvidia.nemotron-super-3-120b': TokenPrice(0.15, 0.65),
  'minimax.minimax-m2.5': TokenPrice(0.30, 1.20),
  'deepseek.v3.2': TokenPrice(0.62, 1.85),
  'us.anthropic.claude-opus-5': TokenPrice(5, 25),
  'us.anthropic.claude-sonnet-5': TokenPrice(2, 10),
  'us.anthropic.claude-haiku-4-5-20251001-v1:0': TokenPrice(1, 5),
};

/// Whether [url] names a server on this machine.
///
/// A malformed URL is deliberately NOT local: "I could not read where this
/// went" must not resolve to "it was free", which is the one direction of
/// error this whole file is arranged to avoid.
bool isLocalUrl(String url) {
  final host = Uri.tryParse(url)?.host;
  return host == 'localhost' || host == '127.0.0.1' || host == '::1';
}

/// USD for one stage's worth of tokens, or null when nobody can say.
///
/// Zero for a local server whatever the model is called — the weights are on
/// this disk and no invoice follows — and null, never zero, for a remote model
/// the table above does not price. An unpriced cloud call is unknown, not
/// free, and a run that summed unknowns as zeroes would quote a candidate as
/// the cheapest in the bakeoff for the sole reason that nobody had priced it.
double? costFor({
  required String url,
  required String model,
  required int promptTokens,
  required int completionTokens,
}) {
  if (isLocalUrl(url)) return 0;
  final price = bedrockPrices[model];
  if (price == null) return null;
  return promptTokens * price.inputPerMTok / 1000000 +
      completionTokens * price.outputPerMTok / 1000000;
}
