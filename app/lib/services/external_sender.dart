/// Whether the person who sent a message is from outside the owner's own
/// organisation.
///
/// Pure, for `gates.dart`'s reason: one authority on a question two passes ask,
/// no I/O and no clock, so the whole set is table-testable. Nothing here is a
/// verdict about a message — being external is a fact about an address, and what
/// to do about it belongs to whoever was told what to do about it. Today that is
/// `needs_you_handler.dart`, which spends it as a RANKING: a stranger's first
/// approach loses the needs-you floor and has to earn the rail through what the
/// message actually says.
///
/// NO DOMAIN NAME APPEARS IN THIS FILE, and that is the hard rule about it. The
/// owner's domains arrive as an argument, derived from the one address the app
/// knows them by, exactly as `label_rules.dart`'s domain scope compares against
/// a value the owner wrote. A vendor list compiled in here would be the pattern
/// `gates.dart`'s decision record refuses.
library;

/// The owner's own domains, from the address their account signs in under.
///
/// [ownerAddress] is normalized the way `IdentityGuard._identityOf` normalizes
/// it — `account.mail ?? account.userPrincipalName`, trimmed and lowercased —
/// because these two answers have to agree about who the owner is, and the
/// guard's is the one that decides whose database this is.
///
/// One domain, not a set of them, until somebody asks for more: a tenant with
/// several verified domains needs an owner-managed list, and inventing one from
/// the mail the inbox happens to hold would call a colleague at a sister brand a
/// stranger. An empty set means "the app does not know who the owner is", which
/// [isExternalAddress] reads as "nobody is external" rather than as "everybody
/// is".
Set<String> ownerDomainsOf(String? ownerAddress) {
  final raw = ownerAddress?.trim().toLowerCase() ?? '';
  final at = raw.lastIndexOf('@');
  if (at < 0 || at == raw.length - 1) return const {};
  return {raw.substring(at + 1)};
}

/// Whether [address] belongs to somebody outside [ownerDomains].
///
/// FALSE is the answer to every question this cannot settle, and that is a
/// constraint rather than a convenience — the caller spends a true by taking a
/// message OFF the rail, so nothing may read as external by accident:
///
/// - a null or empty address. A row whose sender the connector never wrote.
/// - an address with no `@` in it. Every Teams sender is `teams:<id>`, which has
///   no domain part at all and must never read as external: a colleague's chat
///   is the most internal message this app carries, and a federated guest in a
///   chat is a question about the tenant's federation rather than about a string
///   with no domain in it. `label_rules.dart`'s domain scope leans on the same
///   fact for the same reason.
/// - an empty [ownerDomains]. Signed out, or a tenant that left `mail` and the
///   UPN both unset: the app cannot say who the owner is, so it does not get to
///   call anybody a stranger.
///
/// A SUBDOMAIN of an owner domain is internal — `eu.example.com` under
/// `example.com` — the same suffix test `label_rules.dart` applies to a
/// domain-scoped rule, with the leading dot that keeps `notexample.com` out.
bool isExternalAddress(String? address, Set<String> ownerDomains) {
  if (ownerDomains.isEmpty) return false;
  final raw = address?.trim().toLowerCase() ?? '';
  final at = raw.lastIndexOf('@');
  if (at < 0 || at == raw.length - 1) return false;
  final domain = raw.substring(at + 1);
  for (final owned in ownerDomains) {
    if (owned.isEmpty) continue;
    if (domain == owned || domain.endsWith('.$owned')) return false;
  }
  return true;
}
