/// Who the owner is, asked lazily. A record rather than two arguments so
/// "the app does not know yet" is one null rather than two — a keychain that
/// has not answered has no name AND no address.
typedef OwnerIdentity = ({String? name, String? address});

/// The lookup itself. Shared by the needs-you handler and the storyline
/// service, which is why it lives here and not in either of them.
typedef OwnerLookup = Future<OwnerIdentity?> Function();

/// [lookup], asked ONCE for the life of the returned closure.
///
/// The answer is a keychain read that only changes on sign-out, and sign-out
/// disposes the provider that built the caller — so one read per caller is a
/// read per session, not a stale cache.
///
/// Degraded rather than trusted: only a lookup that ANSWERED is kept. A throw
/// is forgotten, so the next call asks again rather than rethrowing one
/// hiccup forever, and the caller reads null until an answer arrives. A
/// lookup that answers null IS an answer and is kept.
OwnerLookup memoizedOwner(OwnerLookup lookup) {
  Future<OwnerIdentity?>? pending;
  return () async {
    try {
      return await (pending ??= lookup());
    } catch (_) {
      pending = null;
      return null;
    }
  };
}
