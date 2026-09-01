import '../data/message_store.dart';
import 'backend/backend_types.dart';

/// Keeps one local database to one Microsoft identity.
///
/// The invariant is old — two mailboxes must never interleave in one inbox —
/// but until now it was enforced by ritual: sign-out wiped, so as long as every
/// user signed out before the next one signed in, the rows stayed one person's.
/// Nothing enforced the ritual. A crash, a slot switched in Settings, an
/// expired session that dropped the user back at the sign-in screen: any of
/// them lets a second identity sign in on top of the first one's mail.
///
/// So the database now records WHOSE it is, and every completed sign-in passes
/// through here. A different identity finds the mail gone rather than mixed.
/// The check is on the identity, not on the session or the server: the same
/// person reaching the same mailbox through the deployed platform and through a
/// local server is one owner, and must not lose their mail for switching.
class IdentityGuard {
  IdentityGuard(this._store);

  final MessageStore _store;

  /// Claims the database for [account], wiping it first if it belonged to
  /// somebody else. True only when a wipe happened, so the caller knows the
  /// providers it holds are now describing rows that no longer exist.
  Future<bool> adopt(AccountInfo account) async {
    final identity = _identityOf(account);

    // No identity to compare is not a mismatch. The MCP local-mode placeholder
    // ("Local session") and a workspace sign-in with no Microsoft account
    // connected yet both arrive here nameless — they have read no mail, so
    // there is nothing of theirs to protect, and claiming ownership in their
    // name would hand the database to a label rather than to a person.
    if (identity == null) return false;

    final owner = await _store.getPref(dbOwnerKey);
    if (owner == identity) return false;
    if (owner == null) {
      // First claim on an unowned database — the state every fresh install and
      // every post-sign-out database is in. Silent: there is nothing to lose.
      await _store.setPref(dbOwnerKey, identity);
      return false;
    }

    // The one case this class exists for. The wipe clears db_owner along with
    // the mail, so the claim below is the write that re-establishes ownership.
    await _store.wipeAll();
    await _store.setPref(dbOwnerKey, identity);
    return true;
  }

  /// The comparable form of an account's identity.
  ///
  /// Mail first, UPN as the fallback — a tenant can leave `mail` unset, and the
  /// UPN is then the only stable name it offers. Lowercased because Microsoft
  /// hands the same address back in whatever case it was typed, and a user must
  /// not lose their mailbox to a capital letter.
  static String? _identityOf(AccountInfo account) {
    final raw = (account.mail ?? account.userPrincipalName)?.trim();
    return raw == null || raw.isEmpty ? null : raw.toLowerCase();
  }
}
