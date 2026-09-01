import '../models/message_models.dart';

/// The cheap checks that run before the model does.
///
/// Every message the gates catch is a message the local model does not spend
/// seventeen seconds on, and a triage result nobody wanted anyway: a shipping
/// notification has no urgency and asks the reader for nothing. The
/// gates are pure — no I/O, no clock — so the whole set is table-testable.
///
/// Two gates deliberately do NOT exist:
/// - an internal-domain gate. Mail from a colleague is exactly the mail that
///   blocks the reader's own work, and skipping it would hide the requests
///   this app exists to surface.
/// - a meeting-invite gate. The delta `$select` this app uses carries no
///   `@odata.type`, so there is nothing on a stored row that distinguishes an
///   invite from a message. Adding one would mean a second Graph field on
///   every page of every sync, for a class of mail the newsletter and
///   auto-generated gates already catch most of.
///
/// The gates are called TWICE per message, and the split is the point. A
/// delta page carries the sender but no headers, so the first call can only
/// answer the address questions — which is exactly what makes it worth
/// asking, since a message gated there never costs a Graph round trip. The
/// triage worker then fetches that message's detail and asks again, and only
/// on the second call do the header gates have anything to read. Opening a
/// thread fetches the same detail, so a message can also arrive here with its
/// headers already stored.
///
/// A message whose detail fetch failed still reaches the model, with empty
/// headers and only its preview. Letting a newsletter through costs one model
/// call; refusing to classify anything until Graph cooperates would cost the
/// whole feature.

/// Sender local-parts that are machine mailboxes by construction.
///
/// PREFIX-anchored, which is the entire subtlety here: `notifications?` must
/// match `notifications@` without matching `not-a-noreply@`, and it does
/// because after `not` the pattern demands `ifications`. Anchoring also keeps
/// `salerts@` and `renotify@` — plausible human or product addresses — out of
/// the gate.
final RegExp _machineSender = RegExp(
  r'^(no[-._]?reply|do[-._]?not[-._]?reply|notifications?|alerts?'
  r'|mailer-daemon|postmaster|bounces?)',
  caseSensitive: false,
);

/// `Precedence` values that mean "sent to a list, not to you". `first-class`
/// and `normal` are ordinary mail and are deliberately absent.
const Set<String> _bulkPrecedence = {'bulk', 'list', 'junk', 'auto_reply'};

/// Returns a gate reason, or null to proceed to the model.
///
/// The switch is the seam a second connector lands on: a Teams message has
/// its own notion of a bot sender and gets its own gate rather than being
/// squeezed through the email one.
String? gateFor(Message message, {required String? userAddress}) =>
    switch (message.source) {
      'email' => _emailGate(message, userAddress),
      'teams' => _teamsGate(message),
      _ => null,
    };

/// One check, and that is the honest size of it.
///
/// Everything the email gates work out from an address or a header is already
/// decided by the time a chat message is stored: `TeamsSync` knows who the
/// user is (so `self` is the message's own `direction`) and knows a bot from a
/// person (`from.application`), and it writes both as the row's `gate_reason`
/// at ingest. What is left is the case nothing upstream can see — a message
/// whose body stripped down to nothing, which is what a lone emoji reaction or
/// an image-only post leaves behind.
///
/// It is currently reached by nobody: chat messages never enter triage, and
/// extraction is queued straight from SQL that already filters on
/// `gate_reason`. It exists so the dispatch above has a real arm rather than
/// falling through to "no gate", which is the answer for a source this app has
/// never heard of and should not be the answer for one it has.
String? _teamsGate(Message message) {
  final body = message.bodyText ?? message.bodyPreview ?? '';
  return body.trim().isEmpty ? 'empty' : null;
}

/// First match wins, and the order is the order of confidence: who sent it
/// beats what it claims about itself.
String? _emailGate(Message message, String? userAddress) {
  final from = message.fromAddress?.toLowerCase() ?? '';

  // The user's own mail, arriving in the inbox because they were
  // cc'd or the message came back off a list. Triage answers "does this need
  // me?" and the answer is never yes.
  if (userAddress != null && userAddress.isNotEmpty) {
    if (from.isNotEmpty && from == userAddress.toLowerCase()) return 'self';
  }

  if (from.isNotEmpty) {
    final at = from.indexOf('@');
    final localPart = at >= 0 ? from.substring(0, at) : from;
    if (localPart.isNotEmpty && _machineSender.hasMatch(localPart)) {
      return 'no_reply';
    }
  }

  final headers = message.headers;
  if (headers.isEmpty) return null;

  // Either header means a mailing list, and RFC 2369 says an unsubscribe link
  // is present on exactly the mail nobody replies to.
  if (headers.containsKey('list-unsubscribe') ||
      headers.containsKey('list-id')) {
    return 'newsletter';
  }
  final precedence = headers['precedence']?.trim().toLowerCase();
  if (precedence != null && _bulkPrecedence.contains(precedence)) {
    return 'newsletter';
  }

  // RFC 3834: `Auto-Submitted: no` is the explicit "a human sent this", and
  // every other value — auto-generated, auto-replied — is a machine.
  final autoSubmitted = headers['auto-submitted']?.trim().toLowerCase();
  if (autoSubmitted != null && autoSubmitted != 'no') return 'auto_generated';
  // Exchange's own marker, present on out-of-office and system mail.
  if (headers.containsKey('x-auto-response-suppress')) return 'auto_generated';

  return null;
}
