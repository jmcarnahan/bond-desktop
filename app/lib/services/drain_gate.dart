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
/// Since Round C there are THREE of these, one per lane, and the paragraph
/// above is about the FAST one: the triage drain and the fast worker share it
/// because they share the fast server. The storyline and draft lanes hold
/// their own, which is what lets a recap or a draft run beside a new message's
/// triage instead of in front of it — see `AiWorker`'s header for how the
/// lanes are cut.
///
/// A plain FIFO chain: each [run] starts after every earlier [run] has
/// settled. Errors do not break the chain — a failed drain must not wedge
/// every drain after it.
///
/// On top of the chain sits one flag, [yieldRequested], which is how a drain
/// already at the server learns that another one is waiting and worth letting
/// through. A long pass reads it at its own claim boundaries and ends the
/// pass there; the gate itself never interrupts anything.
class DrainGate {
  Future<void> _tail = Future.value();

  /// How many times a yield has been asked for. Bumped by [requestYield].
  int _asked = 0;

  /// The ask count the clearing run carried. Raised by the first [run] whose
  /// enqueue-time ticket was at or after the ask, at the instant its body
  /// starts.
  int _served = 0;

  /// Whether a drain holding the gate should end its pass and hand over.
  ///
  /// Read at claim boundaries, never acted on by the gate itself: what a
  /// yield means is the running pass's business, and the only promise made
  /// here is that the flag is transient. Neither side can be starved.
  ///
  /// The WORKER cannot be starved, because the flag cannot outlive one
  /// handoff: the requester enqueues its own [run] in the same synchronous
  /// step as the ask, so that run is the ticket holder and clears the flag
  /// when its body starts, even if it then claims nothing at all.
  ///
  /// The REQUESTER cannot be starved either, because a run queued BEFORE the
  /// ask carries a ticket below the ask count, never clears the flag, and so
  /// yields again. And a worker can only observe this flag at a claim
  /// boundary, which is strictly after [requestYield] returned, so the
  /// requester already sits ahead of any re-entry the worker queues in
  /// response.
  bool get yieldRequested => _asked > _served;

  /// Asks whoever holds the gate to end its pass. Two asks with no run
  /// between them are one ask: the flag is a fact, not a count.
  void requestYield() => _asked++;

  Future<T> run<T>(Future<T> Function() body) {
    // Read at ENQUEUE time, which is what makes the clear point meaningful:
    // it records where this run sits relative to the asks made so far.
    final ticket = _asked;
    final result = _tail.then((_) {
      // The clear point. A run queued at or after the ask is the one the ask
      // was waiting for, so the flag goes down as its body begins rather than
      // when it ends — the requester's drain is under way, which is all the
      // ask was ever about.
      if (ticket >= _asked) _served = _asked;
      return body();
    });
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}
