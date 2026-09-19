/// The conversation state machine, with no I/O in it.
///
/// Folding a message into a thread is the one piece of sync logic that is
/// pure arithmetic on timestamps, so it lives away from sqlite and from
/// Graph: everything here is exercised by unit tests that construct
/// snapshots directly.
///
/// Ported from a sibling app. Its asymmetry is deliberate and is the whole point
/// of the file — see [foldMessage].
library;

/// The subset of a `conversations` row the fold reads and writes.
///
/// Deliberately not the [Conversation] model: that one is immutable and
/// carries render-only fields (cta text, category, counts) the fold has no
/// opinion about. Counts in particular are RECOMPUTED from the messages
/// table after a drain, never incremented here.
class ConvSnapshot {
  /// Wire form — `needs_reply` / `waiting` / `done`, matching the column.
  String state;

  String? lastInboundAt;
  String? lastOutboundAt;
  String? lastMessageAt;
  String? lastMessagePreview;

  /// Already stripped of Re:/Fwd: by whoever set it.
  String? subject;

  ConvSnapshot({
    this.state = stateWaiting,
    this.lastInboundAt,
    this.lastOutboundAt,
    this.lastMessageAt,
    this.lastMessagePreview,
    this.subject,
  });

  ConvSnapshot copy() => ConvSnapshot(
        state: state,
        lastInboundAt: lastInboundAt,
        lastOutboundAt: lastOutboundAt,
        lastMessageAt: lastMessageAt,
        lastMessagePreview: lastMessagePreview,
        subject: subject,
      );
}

const String stateNeedsReply = 'needs_reply';
const String stateWaiting = 'waiting';
const String stateDone = 'done';

/// Folds one message into [existing] and returns the result. [existing] is
/// never mutated; a null one starts a fresh thread at [stateWaiting] — an
/// unclassifiable thread should sit quiet, not demand a reply and not hide
/// itself under Done.
///
/// The two transitions are NOT mirror images, and the difference is load
/// bearing:
///
/// - an inbound message may set `needs_reply` only if the thread has no
///   outbound at all, or its newest outbound is STRICTLY older than this
///   message. An inbound that arrived before the user's reply was already
///   answered by that reply.
/// - an outbound message may set `waiting` only if the thread has no inbound
///   at all, or its newest inbound is older than OR EQUAL TO this message.
///   The `<=` is the asymmetry: when a reply and the mail it answers carry
///   the same timestamp, the reply wins and the thread goes quiet. Ties
///   resolving the other way leave threads stuck asking for a reply that was
///   already sent.
///
/// Both guards read [existing]'s timestamps BEFORE this message's timestamp
/// is folded in — comparing against a value this same call just wrote would
/// make every message trivially satisfy its own guard.
///
/// `done` is a human's decision and no outbound can undo it. A qualifying
/// inbound can: new mail on a closed thread reopens it, which is why the
/// inbound rule has no precondition on the current state.
///
/// [historical] says this message is older than everything the caller has
/// shown the user before — a backfill from a widened sync window, not a
/// delivery — and it suppresses BOTH transitions above while leaving every
/// other field to work normally. Both, because either one alone would be a
/// lie told in a different direction: an old inbound would reopen a thread the
/// user closed months after that mail arrived, and an old outbound would fold
/// a live `needs_reply` to `waiting` as though a question asked last week had
/// been answered the week before. The high-water marks, the preview and the
/// subject still update, because those describe what the thread CONTAINS,
/// which the backfill genuinely changes; the state describes where the thread
/// stands with the user, which it does not.
ConvSnapshot foldMessage(
  ConvSnapshot? existing, {
  required bool outbound,
  required String? receivedAt,
  String? subject,
  String? preview,
  bool historical = false,
}) {
  final next = existing?.copy() ?? ConvSnapshot();

  // A message with no timestamp cannot be ordered against anything, so it
  // never satisfies a guard and never advances a high-water mark. It still
  // counts as a message and may supply a subject or a first preview.
  final ordered = receivedAt != null && receivedAt.isNotEmpty;

  if (ordered && !historical) {
    if (outbound) {
      final lastInbound = next.lastInboundAt;
      if (lastInbound == null || lastInbound.compareTo(receivedAt) <= 0) {
        // Never off `done` — only the inbound rule reopens a thread.
        if (next.state != stateDone) next.state = stateWaiting;
      }
    } else {
      final lastOutbound = next.lastOutboundAt;
      if (lastOutbound == null || lastOutbound.compareTo(receivedAt) < 0) {
        next.state = stateNeedsReply;
      }
    }
  }

  if (ordered) {
    if (outbound) {
      next.lastOutboundAt = _newer(next.lastOutboundAt, receivedAt);
    } else {
      next.lastInboundAt = _newer(next.lastInboundAt, receivedAt);
    }
  }

  // The preview belongs to whatever is newest in the thread. An undated
  // message takes the slot only when nothing else has claimed it.
  final previousMessageAt = next.lastMessageAt;
  final isNewest = ordered
      ? (previousMessageAt == null ||
          previousMessageAt.compareTo(receivedAt) <= 0)
      : (previousMessageAt == null &&
          (next.lastMessagePreview == null ||
              next.lastMessagePreview!.isEmpty));
  if (isNewest && preview != null && preview.isNotEmpty) {
    next.lastMessagePreview = preview;
  }
  if (ordered) next.lastMessageAt = _newer(previousMessageAt, receivedAt);

  // First non-empty subject wins: the thread is named by how it opened, not
  // by whoever last edited the subject line mid-thread.
  if (next.subject == null || next.subject!.isEmpty) {
    final stripped = stripReFw(subject);
    if (stripped.isNotEmpty) next.subject = stripped;
  }

  return next;
}

/// Whether an outbound message at [receivedAt] answers everything [existing]
/// has heard — the same timestamp guard [foldMessage] uses to fold the thread
/// to [stateWaiting], exposed so ingest can resolve side state (the CTA) on
/// exactly the transition the fold takes, without the fold growing an opinion
/// about fields it deliberately does not carry.
///
/// A reply is an answer to the ask the thread was holding, wherever it was
/// written — this app's composer, Outlook, a phone. The composer's own send
/// path clears the CTA directly; this is how a reply made anywhere else gets
/// the same treatment when sync pulls it in.
bool outboundResolves(ConvSnapshot? existing, String? receivedAt) {
  if (receivedAt == null || receivedAt.isEmpty) return false;
  final lastInbound = existing?.lastInboundAt;
  return lastInbound == null || lastInbound.compareTo(receivedAt) <= 0;
}

/// The thread key for a message. Graph groups a thread with `conversationId`;
/// a message without one is its own thread, namespaced so a bare message id
/// can never collide with a real conversation id.
String conversationKeyFor(String? graphConversationId, String messageId) {
  if (graphConversationId != null && graphConversationId.isNotEmpty) {
    return graphConversationId;
  }
  return 'msg:$messageId';
}

/// Leading reply/forward markers, repeated: mail clients stack them
/// (`Re: Fwd: Re:`) and some localize or number them (`RE[2]:`).
final RegExp _reFwPrefix = RegExp(
  r'^\s*(re|fw|fwd)\s*(\[\d+\])?\s*:\s*',
  caseSensitive: false,
);

/// [subject] with every leading Re:/Fw:/Fwd: stripped, trimmed. Null and
/// empty both come back as `''` — the caller decides what an unnamed thread
/// is called.
String stripReFw(String? subject) {
  var text = (subject ?? '').trim();
  while (true) {
    final match = _reFwPrefix.firstMatch(text);
    if (match == null) break;
    final rest = text.substring(match.end).trim();
    // A subject that is nothing BUT markers ("Re:") keeps nothing; stopping
    // here instead would leave the marker as the thread's name.
    text = rest;
    if (text.isEmpty) break;
  }
  return text;
}

/// An ISO date, the first thing that varies between two issues of a series.
final RegExp _seriesIsoDate = RegExp(r'\d{4}-\d{2}-\d{2}');

/// `Month D`, `Month D, YYYY`, `Sept 3rd` — month names full or abbreviated,
/// an optional ordinal suffix, an optional year.
///
/// The month alternatives are spelled out rather than a three-letter prefix
/// followed by `[a-z]*`, which matched any word starting with one: `decide 5
/// options` and `marketing 5 ideas` folded their whole phrase away and two
/// unrelated subjects became one series key.
final RegExp _seriesWordyDate = RegExp(
  r'\b(jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|may|jun(e)?|jul(y)?'
  r'|aug(ust)?|sep(t(ember)?)?|oct(ober)?|nov(ember)?|dec(ember)?)\.?\s+'
  r'\d{1,2}(st|nd|rd|th)?(,?\s+\d{4})?\b',
  caseSensitive: false,
);

/// A ticket id (`OPS-1234`, `ops-1234`) or a bare issue number (`#4412`).
final RegExp _seriesTicketId = RegExp(
  r'\b[A-Za-z][A-Za-z0-9]+-\d+\b|#\d+',
);

/// Whatever digits are left after the dates and the ticket ids: an issue
/// number, a week number, a count.
final RegExp _seriesDigits = RegExp(r'\d+');

/// A run of whitespace, folded to one space so spacing never splits a series.
final RegExp _seriesSpaces = RegExp(r'\s+');

/// The subject with everything that varies between issues of one recurring
/// series folded away, so "Weekly digest 2026-09-14" and "Weekly digest
/// 2026-09-21" read as one key. Empty when the subject is empty.
///
/// What is folded, in order, each replaced by `#`:
///
/// | step | what it matches | example |
/// | --- | --- | --- |
/// | `stripReFw` | leading `Re:`/`Fw:`/`Fwd:` | `Re: Weekly digest` |
/// | lower-case | letter case | `Weekly` and `weekly` |
/// | `_seriesIsoDate` | `\d{4}-\d{2}-\d{2}` | `2026-09-14` |
/// | `_seriesWordyDate` | a month NAME, full or abbreviated, then `D(, YYYY)` | `Sept 3`, `September 10, 2026` |
/// | `_seriesTicketId` | `[A-Za-z][A-Za-z0-9]+-\d+`, `#\d+` | `OPS-118`, `#4412` |
/// | `_seriesDigits` | any remaining digit run | `2` in `Budget review 2` |
/// | `_seriesSpaces` | whitespace runs | two spaces become one |
///
/// The bare-digit rule is last on purpose: the dates and the ticket ids are
/// recognised as wholes first, so `OPS-118` folds to one `#` rather than to a
/// word and a number.
String seriesKeyFor(String? subject) {
  var text = stripReFw(subject).toLowerCase();
  if (text.isEmpty) return '';
  text = text.replaceAll(_seriesIsoDate, '#');
  text = text.replaceAll(_seriesWordyDate, '#');
  text = text.replaceAll(_seriesTicketId, '#');
  text = text.replaceAll(_seriesDigits, '#');
  text = text.replaceAll(_seriesSpaces, ' ').trim();
  return text;
}

/// The subject as a FRAGMENT identity: the same text, reply markers and case
/// and spacing aside. Empty when the subject is empty.
///
/// Deliberately not [seriesKeyFor], and the difference is the whole point of
/// there being two. A re-send and a reply-all fork carry the SAME subject, down
/// to the date in it; the issues of a dated series carry different ones, which
/// is exactly what makes them a series. Folding the digits here would read
/// three issues of a weekly digest among the same people as one thread that had
/// arrived three times, and the pre-pass that exists to recognise a recurring
/// series would never see it. So this folds only what a mail client adds on the
/// way past: the leading `Re:`/`Fw:`/`Fwd:` markers through [stripReFw], letter
/// case, and runs of whitespace.
String fragmentKeyFor(String? subject) {
  final text = stripReFw(subject).toLowerCase();
  if (text.isEmpty) return '';
  return text.replaceAll(_seriesSpaces, ' ').trim();
}

/// The later of two ISO-8601 UTC timestamps. Both are Graph's own strings,
/// stored verbatim, so a string comparison IS the chronological one.
String _newer(String? a, String b) =>
    (a == null || a.compareTo(b) < 0) ? b : a;
