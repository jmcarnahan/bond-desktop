import 'dart:async';

/// Serializes whole queue drains against the one llama-server.
///
/// The model generates at about twelve tokens a second; two concurrent
/// requests do not go twice as fast, they make both take twice as long and
/// throw away the server's prompt cache between them. The sync path already
/// chains triage's pump before the AI worker's, but that chain is not the
/// only caller — a user's Regenerate click pumps the AI worker whenever it
/// lands — so the two drains share this gate, and whichever starts second
/// waits instead of interleaving.
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
