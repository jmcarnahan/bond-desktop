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
/// - an issue-tracker or code-host gate on the bare local parts those systems
///   send from (`jira@`, `github@`, …). On the golden set that exact shape is
///   two gold drops AND two gold keeps — the same address sends the digest
///   nobody reads and the mention that is addressed to the reader — so no
///   name rule can split them. What separates those two populations is which
///   tenant is talking, which is data (the sender rule below) or a header,
///   never a pattern compiled into this file.
///
/// A MEETING RESPONSE is gated and a meeting INVITE is not, and what draws the
/// line is the one field on the row that can tell them apart.
/// `meetingMessageType` — Graph's own word: `meetingAccepted`,
/// `meetingDeclined`, `meetingCancelled`, the tentative one, `meetingRequest`
/// — rides the per-message detail `$select` for exactly this purpose, which is
/// why the older note here ("nothing on a stored row distinguishes an invite
/// from a message") is no longer true. A response answers a question the
/// reader themselves asked: nobody replies to "Accepted:", and one of these
/// threads sat in Needs You marked `Needs reply` while the model's own summary
/// of it read "no further action required". An invite is the opposite kind of
/// message — it asks for the reader's time and can be the most important mail
/// of the day — so `meetingRequest` is never gated, and a test pins that it
/// never will be. A cancellation IS gated even though it is mildly
/// informative: it tells the reader to do nothing, and the calendar has
/// already done it.
///
/// Two fallbacks sit under that field, for the rows whose detail fetch never
/// carried it — every row a build before it wrote, and every row whose fetch
/// failed. Both are shaped so an invite cannot reach them: each REQUIRES a
/// response-shaped subject (`Accepted:`, `Declined:`, `Tentative:`,
/// `Canceled:`) before it looks at anything else. `Content-Class:
/// urn:content-classes:calendarmessage` is on the invite as much as on the
/// response, so alone it gates nothing; an empty body is what a calendar
/// response IS, but alone it is also just a message somebody sent with no
/// words in it. Where Graph DID say the kind, the fallbacks are not consulted
/// at all — the server's answer is the whole answer, and a subject line does
/// not get to re-litigate `meetingRequest`. The localized prefixes Outlook
/// sends in other languages are deliberately not here: a table of translations
/// compiled into this file is the pattern the tracker bullet above refuses.
///
/// One gate here is not a judgement about the message at all. `sender_rule`
/// comes from `sender_prefs.disposition = 'drop'`, which the owner writes
/// through "Drop this sender" — a standing instruction about one address,
/// and the only per-tenant gate this app has. It sits immediately after
/// `self`, because a person's own word beats every name rule below it while
/// the owner's own mail is still their own mail. The gate stays pure: the
/// disposition arrives as an argument, and the call site in
/// `triage_queue.dart` is what reads the table.
///
/// The gates are called TWICE per message, and the split is the point. A
/// delta page carries the sender but no headers, so the first call can only
/// answer the address questions — which is exactly what makes it worth
/// asking, since a message gated there never costs a Graph round trip. The
/// triage worker then fetches that message's detail and asks again, and only
/// on the second call do the header gates have anything to read. Opening a
/// thread fetches the same detail, so a message can also arrive here with its
/// headers already stored. The meeting-response rung is mostly a second-call
/// gate for that reason — `meetingMessageType` and `Content-Class` both arrive
/// with the detail — with one exception worth knowing: a delta row whose
/// preview came down empty can be caught by the subject-and-empty-body
/// fallback on the FIRST call, which is a calendar response gated before it
/// ever cost a round trip.
///
/// A message whose detail fetch failed still reaches the model, with empty
/// headers and only its preview. Letting a newsletter through costs one model
/// call; refusing to classify anything until Graph cooperates would cost the
/// whole feature.

/// `noreply` anywhere in the local part: the compact spellings as plain
/// substrings, the punctuated ones as delimited TOKENS.
///
/// Wider than the prefix rule it was split out of, and deliberately so: real
/// mailboxes spell the word in the middle (`orders-noreply`, `noreply+billing`,
/// `noreply2`, and one twenty-letter run with `noreply` buried in it) and
/// every one of them was passing the anchored rule live. The split in the
/// pattern is about ambiguity, not width. `noreply` and `donotreply` are not
/// substrings of any word a person's mailbox is named after — on the golden
/// set a bare substring match adds one gold drop and no gold keep — so they
/// need no boundary. The punctuated forms (`no-reply`, `do.not.reply`) do:
/// `no` and `reply` are ordinary syllables, and a boundary either side is what
/// keeps `nota` and `renotify` on their way to the model.
final RegExp _noReplyToken = RegExp(
  r'noreply|donotreply'
  r'|(^|[-._+])(no[-._]?reply|do[-._]?not[-._]?reply)([-._+]|$|\d)',
  caseSensitive: false,
);

/// Sender local-parts that are machine mailboxes by construction.
///
/// PREFIX-anchored, which is the entire subtlety here: the anchor is what
/// keeps `salerts@` and `renotify@` — plausible human or product
/// addresses — out of the gate, since a substring match would have
/// swallowed both. The
/// `noreply` family moved to [_noReplyToken], which needs a delimiter rather
/// than the start of the string; these words do not, because nothing spells a
/// person's mailbox with `postmaster` in the middle of it.
final RegExp _machineSender = RegExp(
  r'^(notifications?|alerts?|mailer-daemon|postmaster|bounces?)',
  caseSensitive: false,
);

/// The monitoring mailbox: whatever watches the servers, talking to a person
/// who is not on call.
///
/// The slug it returns is `monitoring` — the golden set's own taxonomy, not a
/// name invented here — so a replay of the gates scores the REASON column and
/// not just the verdict. Delimited like every other shape in this file:
/// `monitoring@`, `monitoring-eu@` and `prod-monitoring@` are gated, and
/// `remonitoring@` is a word that happens to contain one.
final RegExp _monitoringSender = RegExp(
  r'^monitoring$|^monitoring[-._]|[-._]monitoring$',
  caseSensitive: false,
);

/// The build and service mailboxes — a pipeline reporting on itself.
///
/// `machine_sender` for the same reason [_monitoringSender] returns
/// `monitoring`: it is the gold slug, so the reason a replay reads is the
/// reason the set wrote down. The delimiter is required on the prefixes and
/// the suffix, which is why `abbott@` is a person and `cicd-team@` is a team;
/// the three bare words are exact, so nothing longer than them matches.
final RegExp _serviceSender = RegExp(
  r'^svc[-._]|^bot[-._]|[-._]bot$|^(pipelines|builds|ci)$',
  caseSensitive: false,
);

/// The one thing in this file that is NOT a gate, and it is here because it is
/// the same question asked for a different purpose.
///
/// [suspectMachineSender] never decides whether a message reaches the model.
/// It decides whether a detail fetch that FAILED is worth one more attempt
/// before the message is classified from its preview with no headers at all —
/// which is exactly the case where the header gates would have had something
/// to say. So it is wide where the gates are narrow: a false positive
/// costs one deferred triage, where a false positive in [gateFor] costs the
/// message.
///
/// Anywhere in the local part rather than delimited, for the same reason.
/// `prod-alerts` and `ops-digest` are machine mailboxes whose shape every gate
/// above deliberately refuses — `alerts` is prefix-anchored and `digest` is no
/// gate at all — and each is a mailbox whose headers are worth waiting for.
final RegExp _suspectMachineSender = RegExp(
  r'no[-._]?reply|do[-._]?not[-._]?reply|notif|alert|monitor|digest'
  r'|newsletter|mailer|bounce|robot|automat|system|postmaster|daemon'
  r'|\bsvc\b|(^|[-._])bot([-._]|$)|^(pipelines|builds|ci)$',
  caseSensitive: false,
);

/// Whether a sender's local part LOOKS like a machine, loosely — wide on
/// purpose, and NOT a gate. See [_suspectMachineSender] for what it is for.
bool suspectMachineSender(String localPart) =>
    localPart.isNotEmpty && _suspectMachineSender.hasMatch(localPart);

/// `Precedence` values that mean "sent to a list, not to you". `first-class`
/// and `normal` are ordinary mail and are deliberately absent.
const Set<String> _bulkPrecedence = {'bulk', 'list', 'junk', 'auto_reply'};

/// Graph's `meetingMessageType` values that ANSWER rather than ask, lowercased
/// because a caller folds case before asking: the field is stored verbatim as
/// the server spelled it, and one spelling is a typo Microsoft shipped.
///
/// `meetingTenativelyAccepted` [sic] is that typo — the Outlook REST enum
/// carried it for years and Graph spells the same value
/// `meetingTentativelyAccepted` — so both are here and neither is the one to
/// remove. `meetingCanceled` is the same defence across a regional spelling.
/// Matching a value the server never sends costs nothing; missing the one it
/// does send puts a calendar response back in front of the reader as
/// `Needs reply`.
///
/// Shared with `classification.dart`, which answers the same question for a
/// different purpose and must not keep a second copy of Graph's vocabulary.
const Set<String> meetingResponseTypes = {
  'meetingaccepted',
  'meetingdeclined',
  'meetingcancelled',
  'meetingcanceled',
  'meetingtentativelyaccepted',
  'meetingtenativelyaccepted',
};

/// The one `meetingMessageType` value this file will never gate on, named so
/// that the rule reads as a rule rather than as a string literal buried in a
/// condition. Lowercased like [meetingResponseTypes].
const String meetingInviteType = 'meetingrequest';

/// The subject a calendar response arrives under, and the required half of
/// BOTH header-less fallbacks.
///
/// Anchored at the start and ending at the colon, which is what keeps a person
/// writing "the proposal was declined: here is why" out of it. No invite is
/// titled this way — Outlook puts the meeting's own subject on a request,
/// unprefixed — so requiring this before either fallback runs is what makes an
/// invite unreachable by them.
final RegExp _meetingResponseSubject = RegExp(
  r'^\s*(accepted|declined|tentative|tentatively accepted|canceled|cancelled)'
  r'\s*:',
  caseSensitive: false,
);

/// Exchange's marker for a message the calendar wrote. On the invite as much as
/// on the response, which is why it never answers alone.
const String _calendarContentClass = 'urn:content-classes:calendarmessage';

/// Whether this message is somebody answering an invitation.
///
/// Read the decision record at the top of the file for why the invite is
/// excluded by construction rather than by a list of exceptions: the moment
/// Graph has said the kind, nothing below gets a vote.
bool _isMeetingResponse(Message message) {
  final meeting = message.meetingMessageType?.trim().toLowerCase();
  if (meeting != null && meeting.isNotEmpty) {
    return meetingResponseTypes.contains(meeting);
  }

  // Nobody said, so the fallbacks — and neither of them starts without a
  // subject only a response carries.
  if (!_meetingResponseSubject.hasMatch(message.subject ?? '')) return false;

  final contentClass = message.headers['content-class']?.trim().toLowerCase();
  if (contentClass == _calendarContentClass) return true;

  // Last resort: a response-shaped subject over a message with nothing in it.
  // The preview stands in for the body, so this can answer on a delta row that
  // no detail fetch has touched yet. Nothing in it includes no file: a
  // calendar response never carries an attachment, and "Accepted: signed
  // offer letter" with a PDF and no text is somebody sending a document.
  if (message.hasAttachments) return false;
  final body = message.bodyText ?? message.bodyPreview ?? '';
  return body.trim().isEmpty;
}

/// Returns a gate reason, or null to proceed to the model.
///
/// The switch is the seam a second connector lands on: a Teams message has
/// its own notion of a bot sender and gets its own gate rather than being
/// squeezed through the email one.
///
/// [senderDisposition] is this sender's standing rule as the store holds it,
/// or null when there is none and when the caller has a reason not to ask.
/// Passed in rather than read here, so the gates stay pure.
String? gateFor(
  Message message, {
  required String? userAddress,
  String? senderDisposition,
}) =>
    switch (message.source) {
      'email' => _emailGate(message, userAddress, senderDisposition),
      'teams' => _teamsGate(message, senderDisposition),
      _ => null,
    };

/// The triage columns a message gets the first time it is stored, for BOTH
/// connectors. Ignored on a re-sync of a message already present.
///
/// One function rather than one per ingest because the rule is about the
/// message, not the channel: the user's own sent message never asks the user
/// for anything, and a message older than the caller's window is history the
/// model should not spend seventeen seconds on.
///
/// [backlogCutoff] is the pass's effective sync floor — BOTH ingests pass it,
/// so the depth the models read is exactly the lookback the user chose. Null
/// means "no cap", and the only callers that pass null are the send paths
/// (the mail echo, the composer's chat post), where `outbound` has already
/// decided the answer before the cutoff is consulted.
(String, String?) triageStatusOnInsert({
  required bool outbound,
  String? receivedAt,
  String? backlogCutoff,
}) {
  // Triage answers "does this need me?" — the user's own sent message never
  // does.
  if (outbound) return ('skipped', 'outbound');
  if (backlogCutoff != null &&
      receivedAt != null &&
      receivedAt.isNotEmpty &&
      receivedAt.compareTo(backlogCutoff) < 0) {
    return ('skipped', 'backlog');
  }
  return ('pending', null);
}

/// Two checks, and that is the honest size of it.
///
/// Everything the email gates work out from an address or a header is already
/// decided by the time a chat message is stored: `TeamsSync` knows who the
/// user is (so `self` is the message's own `direction`) and knows a bot from a
/// person (`from.application`), and it writes both as the row's `gate_reason`
/// at ingest. What is left is the owner's own standing rule about this sender,
/// and the case nothing upstream can see — a message whose body stripped down
/// to nothing, which is what a lone emoji reaction or an image-only post
/// leaves behind.
///
/// Those two are therefore the WHOLE chat gate, and they run on every chat
/// message the triage queue claims: bot and self exclusion happened at ingest,
/// so anything reaching here is a person talking to the user, and the only
/// reasons to refuse it the model are the owner having said so and the message
/// having nothing to read.
String? _teamsGate(Message message, String? senderDisposition) {
  if (senderDisposition == 'drop') return 'sender_rule';
  final body = message.bodyText ?? message.bodyPreview ?? '';
  return body.trim().isEmpty ? 'empty' : null;
}

/// First match wins, and the order is the order of confidence: who sent it
/// beats what it claims about itself.
String? _emailGate(
  Message message,
  String? userAddress,
  String? senderDisposition,
) {
  final from = message.fromAddress?.toLowerCase() ?? '';

  // The user's own mail, arriving in the inbox because they were
  // cc'd or the message came back off a list. Triage answers "does this need
  // me?" and the answer is never yes.
  if (userAddress != null && userAddress.isNotEmpty) {
    if (from.isNotEmpty && from == userAddress.toLowerCase()) return 'self';
  }

  // The owner's own word about this address, which outranks every pattern
  // below: they have already answered the question the name rules guess at.
  if (senderDisposition == 'drop') return 'sender_rule';

  // Somebody answering an invitation. Above the name rules because it is a
  // fact about the message rather than a guess from its sender: the colleague
  // who accepted is an ordinary human address every rule below waves through,
  // which is how these landed in Needs You saying `Needs reply`.
  if (_isMeetingResponse(message)) return 'meeting_response';

  if (from.isNotEmpty) {
    final at = from.indexOf('@');
    final localPart = at >= 0 ? from.substring(0, at) : from;
    if (localPart.isNotEmpty) {
      if (_noReplyToken.hasMatch(localPart)) return 'no_reply';
      if (_machineSender.hasMatch(localPart)) return 'no_reply';
      if (_monitoringSender.hasMatch(localPart)) return 'monitoring';
      if (_serviceSender.hasMatch(localPart)) return 'machine_sender';
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
