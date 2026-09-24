/// What KIND of message this is, in the four words the app has for it.
///
/// This asks a different question from `gates.dart`. A gate decides whether
/// the local model reads a message at all, and a false positive there costs
/// the message. A classification decides nothing: it names the class of mail
/// and hands the decision to somebody who was told what to do about it. Two
/// readers ask:
/// - the owner's own label rules. A `label_rules` row with
///   `scope_kind = 'classification'` holds one of these strings and matches it
///   against the message in front of it, which is how "never show me another
///   meeting response" becomes a rule rather than a regex somebody compiled
///   in here.
/// - the reply paths, which have no business drafting an answer to a calendar
///   response or a ticket digest.
///
/// The four returned strings are a STORED-DATA CONTRACT, not an internal
/// enum: a `label_rules` row the owner wrote months ago carries one of them
/// verbatim, so renaming one does not fail a test, it silently stops a rule
/// the owner taught from ever matching again. They are
/// `meeting_response`, `meeting_invite`, `tracker_notification` and
/// `automated_notification`, and null means "nothing here says".
///
/// Pure, like the gates and for the same reason: no I/O, no clock, nothing
/// but the stored row, so the whole set is table-testable.
///
/// NO TRACKER OR VENDOR DOMAIN appears in this file, and that is the one hard
/// rule about it. `gates.dart`'s decision record explains why: on the golden
/// set the same tracker address sends the digest nobody reads AND the mention
/// addressed to the reader, so the thing that splits those two populations is
/// data the owner taught, never a host name compiled in here. A header name
/// and a display-name suffix are protocol shapes rather than tenants — the
/// tracker stamped them itself, on its own mail, whoever is running it — so
/// those are exactly what this file is allowed to read.
library;

import '../models/message_models.dart';
import 'gates.dart';

/// `X-JIRA-FingerPrint`, lowercased: the tracker's own stamp on its own
/// notification mail, present whether the body is a digest or an @mention.
const String _trackerFingerprintHeader = 'x-jira-fingerprint';

/// Every `X-Atlassian-*` header at once, by prefix rather than by name: the
/// set of them changes with the tracker's own versions (mail-counter, token,
/// request-id and more), and any one of them means the same thing.
const String _trackerHeaderPrefix = 'x-atlassian-';

/// The display name a tracker sends under when it is speaking FOR a person:
/// `Dana Whitlock (Jira)`, which is one person's edit relayed by a shared
/// notification mailbox. Anchored at the END, so a person whose own name has
/// a parenthesis in the middle of it is left alone, and open inside the
/// bracket so the product's longer names (`(Jira Service Management)`) match
/// the same shape.
final RegExp _trackerDisplaySuffix = RegExp(
  r'\(jira[^)]*\)\s*$',
  caseSensitive: false,
);

/// A bracketed tag at the very start of a subject — `[JIRA] (KEY) …`, which
/// is the shape a tracker's mail handler prepends and nothing a person types.
///
/// Never enough on its own: a colleague writes `[URGENT]` and `[FYI]` in the
/// same position, and reading that as a tracker notification would classify a
/// human asking for something. It is why [classificationOf] pairs this with
/// an automated SENDER before it believes it. Length-capped for the same
/// reason — a bracketed sentence is prose, not a tag.
final RegExp _bracketedSubjectTag = RegExp(r'^\s*\[[A-Za-z][\w .-]{0,15}\]');

/// `Auto-Submitted` values that mean a machine sent this. RFC 3834 makes `no`
/// the explicit "a human did", so every other value is the interesting one —
/// the same reading `gates.dart` gives the header.
const String _humanAutoSubmitted = 'no';

/// RFC 2369 and RFC 2919: a message sent to a list rather than to a person.
/// Any one of them is the whole signal.
const Set<String> _listHeaders = {
  'list-id',
  'list-unsubscribe',
  'list-post',
};

/// This message's class, or null when nothing on the row says.
///
/// The signals are asked in order of how much they know, and the first one to
/// answer wins:
///
/// 1. `meetingMessageType`, because Graph itself said what the message is and
///    no shape below can out-argue that. A response value answers
///    `meeting_response`, `meetingRequest` answers `meeting_invite`, and any
///    other value — `none` on ordinary mail, anything Graph adds later —
///    falls THROUGH to the rules below rather than ending the walk: a tracker
///    notification carrying `none` is still a tracker notification.
/// 2. The tracker's own stamps: its fingerprint header, any of its
///    `X-Atlassian-*` headers, the `(Jira)` display-name suffix, and last the
///    bracketed subject tag PAIRED with a sender that looks automated. Above
///    the automated rung because it is the more specific answer for the same
///    mail: a ticket digest carries `List-Id` as well, and the owner who
///    wrote a rule about tracker mail meant that mail.
/// 3. The generic automated shapes, `Auto-Submitted` and the `List-*` family.
///
/// Every signal here is a mail shape. A chat or MCP message carries none of
/// them and comes back null, which is the honest answer rather than a special
/// case.
String? classificationOf(Message message) {
  final meeting = message.meetingMessageType?.trim().toLowerCase();
  if (meeting != null && meeting.isNotEmpty) {
    if (meetingResponseTypes.contains(meeting)) return 'meeting_response';
    if (meeting == meetingInviteType) return 'meeting_invite';
  }

  final headers = message.headers;
  if (headers.containsKey(_trackerFingerprintHeader) ||
      headers.keys.any((k) => k.startsWith(_trackerHeaderPrefix))) {
    return 'tracker_notification';
  }
  final fromName = message.fromName ?? '';
  if (fromName.isNotEmpty && _trackerDisplaySuffix.hasMatch(fromName)) {
    return 'tracker_notification';
  }
  final autoSubmitted = headers['auto-submitted']?.trim().toLowerCase();
  final automatedHeaders =
      (autoSubmitted != null && autoSubmitted != _humanAutoSubmitted) ||
          headers.keys.any(_listHeaders.contains);
  if (_bracketedSubjectTag.hasMatch(message.subject ?? '') &&
      (automatedHeaders || _automatedSenderShape(message))) {
    return 'tracker_notification';
  }

  if (automatedHeaders) return 'automated_notification';
  return null;
}

/// Whether the sender's local part reads as a machine mailbox, loosely.
///
/// [suspectMachineSender] is the existing loose read of that question and this
/// is its second caller — deliberately the loose one rather than a gate's
/// narrow pattern, because the mailbox a tracker relays through is exactly the
/// `notifications@`, `jira-noreply@`, `svc-…@` shape it was written for, and
/// because a false positive here costs a label on a message whose subject
/// already carried a bracketed tag.
///
/// It leaves the bare `jira@` local part alone, and that is the line holding:
/// that address is the one the decision record in `gates.dart` says no name
/// rule may judge, and the owner's own label rule is what answers for it.
bool _automatedSenderShape(Message message) {
  final from = message.fromAddress?.toLowerCase() ?? '';
  if (from.isEmpty) return false;
  final at = from.indexOf('@');
  final localPart = at >= 0 ? from.substring(0, at) : from;
  return suspectMachineSender(localPart);
}
