import 'dart:async';

/// Serializes whole queue DRAINS against the model servers.
///
/// Not a claim that concurrency never pays — it does, and each drain now runs
/// up to K items in flight internally (K=3, matched by the fast server's
/// `FAST_SLOTS` slots): a batched decode reads the weights once for the whole
/// batch, so K requests cost far less than K times one. What rises with the
/// batch is any ONE request's latency, which is why K is small and why the
/// number of clients is kept equal to the number of slots.
///
/// This gate is about the other axis. Two DRAINS at the same server would put
/// an unbounded, unowned number of requests in front of it — triage's K plus
/// the worker's K, against slots sized for one drain — and they would trade
/// the byte-identical system prompt each maintains for the other's, which is
/// how the KV prefix cache gets thrown away. The sync path already chains
/// triage's pump before the AI worker's, but that chain is not the only caller
/// — a user's Regenerate click pumps the AI worker whenever it lands — so the
/// two drains share this gate, and whichever starts second waits.
///
/// A plain FIFO chain: each [run] starts after every earlier [run] has
/// settled. Errors do not break the chain — a failed drain must not wedge
/// every drain after it.
class DrainGate {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() body) {
    final result = _tail.then((_) => body());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}
