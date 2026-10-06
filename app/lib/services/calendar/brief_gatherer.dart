import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:intl/intl.dart' show DateFormat;

import '../../data/calendar_store.dart';
import '../../data/message_store.dart';
import '../../models/attachment_models.dart';
import '../../models/calendar_models.dart';
import '../../models/home_models.dart' show RelatedConversation;
import '../../models/message_models.dart';
import '../decision/decision_policy.dart';
import '../decision/needs_you_predicate.dart' show needsYouAt;
import '../decision/stored_decision.dart';
import '../attachments/attachment_markers.dart';
import '../attachments/attachment_policy.dart' show attachmentEntityId;
import '../html_text.dart' show stripLinkTargets;
import '../llm/embeddings_client.dart';
import '../llm/prompt_guard.dart';
import 'ask_words.dart' show askOwnWords, capAtWord;
import 'brief_path.dart';
import 'calendar_zone.dart';
import 'day_items.dart' show formatEventRange;
import 'event_view.dart' show EventStanding, lastMetLabel, standingOf;

/// Why a meeting gets no brief (D6). [wire] is the word a stored row and an
/// activity row carry — an enum word, never anything about the meeting.
enum BriefIneligibility {
  past('past'),
  tooFar('too_far'),
  noOthers('no_others'),
  cancelled('cancelled'),
  declined('declined'),
  noMail('no_mail'),

  /// The event is no longer in the mirror. Only the handler says this: the
  /// gatherer is always handed an event.
  gone('gone'),

  /// A file sent ahead is still being read, and the meeting is far enough
  /// off to wait for it. Only the handler says this, and only for a while:
  /// the row is gathered again every planner pass, and the hash moves when
  /// the text lands.
  materialsPending('materials_pending');

  const BriefIneligibility(this.wire);
  final String wire;
}

/// One thread the brief is written from, numbered by its place in
/// [BriefInput.threads].
///
/// [subject] is raw (the panel links by it, and the task fences it as it lays
/// the list out); every snippet is already fenced with [wrapUntrusted].
@immutable
class BriefThread {
  final String source;
  final String conversationKey;
  final String subject;

  /// The conversation's state word: `needs_reply`, `waiting` or `done`.
  final String state;

  /// `last_message_at`, as stored.
  final String lastAt;
  final int messageCount;

  /// The last two messages, oldest first, each fenced and capped.
  final List<String> snippets;

  /// Whether the decision model read the latest inbound message as urgent or
  /// important — what put the thread at the front of the list.
  final bool ranked;

  /// Whether this is one of the meeting's own invite threads, which lead
  /// the list on either path. The task says so on the thread's line, so the
  /// model can tell the meeting's own mail from mail found by its people or
  /// its text.
  final bool invite;

  /// Whether this is a PART of a Teams chat rather than a whole thread: the
  /// message the related search matched and the few around it. A chat is
  /// one conversation however many subjects pass through it, so its newest
  /// messages say nothing about why it was found. For such a thread [lastAt]
  /// is the newest message SHOWN and [messageCount] how many are shown, so
  /// the room's later chatter moves neither.
  final bool excerpt;

  const BriefThread({
    required this.source,
    required this.conversationKey,
    required this.subject,
    required this.state,
    required this.lastAt,
    this.messageCount = 0,
    this.snippets = const [],
    this.ranked = false,
    this.invite = false,
    this.excerpt = false,
  });
}

/// Something an attendee asked the owner that is still open (§1.1 point 1).
@immutable
class BriefAsk {
  /// Who asked: the name the invite gives them, else the sender's, else the
  /// address. Raw; the task fences it.
  final String person;

  /// The message's text, fenced and capped.
  final String ask;

  /// The decision model's `intent`: `question`, `request` or `approval`.
  final String intent;

  /// 0-based, into [BriefInput.threads].
  final int threadIndex;

  /// For the inputs hash only.
  final String messageId;

  const BriefAsk({
    required this.person,
    required this.ask,
    required this.intent,
    required this.threadIndex,
    this.messageId = '',
  });
}

/// A storyline one of the threads belongs to: its title raw, and where it
/// stands (the recap, else the summary) fenced and capped.
@immutable
class BriefStoryline {
  final String id;
  final String title;
  final String summary;

  const BriefStoryline({
    required this.id,
    required this.title,
    required this.summary,
  });
}

/// A file on one of THIS meeting's invite threads — sent by one of its
/// people or by the owner — as the brief task is shown it. A file on other
/// mail with the same people is never one ([BriefInput.otherFiles]).
///
/// The identity ([source], [messageId], [attachmentId]) is what the handler
/// stores so the agenda can open the file; the rest is what the model reads.
/// [name] and [sender] are raw (the task fences them as it lays the list
/// out); every passage is already inside [wrapUntrusted].
///
/// A file whose text has not been read ([textStatus] not `done`) is still a
/// material: it carries no [digest], no [text] and no [passages], and the
/// brief names it as arrived rather than summarising words nobody has read.
///
/// [text] is raw, like [digest]: the task fences it as it spends its budget,
/// because how much of it fits is the task's to decide.
@immutable
class BriefMaterial {
  final String source;
  final String messageId;
  final String attachmentId;
  final String name;
  final String contentType;

  /// The invite's name for whoever sent it, else the sender's, else the
  /// address; the word `you` when the owner sent it.
  final String sender;

  /// `yyyy-MM-dd` of the mail that carried it, in the display zone; '' when
  /// the mail has no readable stamp.
  final String date;

  /// The carrying mail's `received_at` stamp, one end of how long a file
  /// still being read is waited for ([BriefGatherer.pendingMaxAge]); '' when
  /// the mail has none. Not hashed.
  final String receivedAt;

  /// `attachments.text_status`: `pending`, `done` or `skipped`.
  final String textStatus;

  /// `attachments.digest_status`, for the inputs hash only.
  final String digestStatus;

  /// What the digest stage made of it, or null before it has (or when it
  /// never will).
  final AttachmentDigest? digest;

  /// The passages nearest the meeting, at most two, each already fenced.
  /// They come from anywhere in the document; [text] is its head.
  final List<String> passages;

  /// The file's extracted words, cut at a word to
  /// [BriefGatherer.materialTextCap]; '' when they were not read — the file
  /// is not `done`, or the gather was the planner's, which reads no text.
  final String text;

  /// Whether [text] is a head: the extracted words ran past
  /// [BriefGatherer.materialTextCap] and were cut. The task shows the
  /// passages only for a file it did not show whole.
  final bool textCut;

  const BriefMaterial({
    required this.source,
    required this.messageId,
    required this.attachmentId,
    required this.name,
    this.contentType = '',
    this.sender = '',
    this.date = '',
    this.receivedAt = '',
    this.textStatus = 'pending',
    this.digestStatus = '',
    this.digest,
    this.passages = const [],
    this.text = '',
    this.textCut = false,
  });

  BriefMaterial withPassages(List<String> passages) =>
      _copy(passages: passages);

  BriefMaterial withText(String text, {bool cut = false}) =>
      _copy(text: text, textCut: cut);

  BriefMaterial _copy({List<String>? passages, String? text, bool? textCut}) =>
      BriefMaterial(
          source: source,
          messageId: messageId,
          attachmentId: attachmentId,
          name: name,
          contentType: contentType,
          sender: sender,
          date: date,
          receivedAt: receivedAt,
          textStatus: textStatus,
          digestStatus: digestStatus,
          digest: digest,
          passages: passages ?? this.passages,
          text: text ?? this.text,
          textCut: textCut ?? this.textCut,
        );
}

/// One other person in a meeting, as the brief task is shown them: who they
/// are as far as the mail and the calendar say, and what is open with them.
///
/// The labels ([name], [org], [lastSubject]) are raw — the task caps and
/// fences each as it lays the block out (the org inside the name's fence:
/// a domain's owner chose it); the two bodies ([lastWords], [openAsk]) arrive
/// already inside [wrapUntrusted], the [BriefInput] rule. Never hashed:
/// every field follows from inputs that are (the threads, the asks, the
/// event), except [lastMet], and a past meeting ageing by a day is no reason
/// to write the brief again.
@immutable
class BriefPerson {
  /// The invite's name, else the address.
  final String name;
  final String address;

  /// [briefOrgOf] the address: `fabrikam` for `dana@mail.fabrikam.com`, ''
  /// for a consumer mailbox.
  final String org;

  /// Whether they organised the meeting.
  final bool isOrganizer;

  /// What is known of their answer, in words: `accepted`, `tentative`,
  /// `declined` or `no answer yet` on the owner's own organiser copy, which
  /// is the only copy that tracks answers; `response not known` on any
  /// other.
  final String response;

  /// "Last met 3 days ago", or null when the mirror holds no earlier
  /// meeting with them.
  final String? lastMet;

  /// How many of [BriefInput.threads] they are in.
  final int threadCount;

  /// How long ago their newest inbound message in those threads arrived
  /// ([briefAgo]); '' when they wrote none of it.
  final String lastInboundAgo;

  /// The subject of the thread that message is in; '' with no message.
  final String lastSubject;

  /// That message's own words — the quoted history cut off — at most
  /// [BriefGatherer.lastWordsCap] cut at a word, fenced; '' with no message.
  final String lastWords;

  /// Their open ask in [BriefInput.openAsks], fenced as it is there; ''
  /// when they have none.
  final String openAsk;

  const BriefPerson({
    required this.name,
    required this.address,
    this.org = '',
    this.isOrganizer = false,
    this.response = 'response not known',
    this.lastMet,
    this.threadCount = 0,
    this.lastInboundAgo = '',
    this.lastSubject = '',
    this.lastWords = '',
    this.openAsk = '',
  });
}

/// Everything the brief task is shown about one meeting, gathered without a
/// model call.
///
/// The fencing rule: every free-text BODY (a message snippet, an ask, a
/// storyline recap, the invite's own text) arrives here already inside
/// [wrapUntrusted]; the short labels (subjects, names, titles, file names)
/// stay raw because the panel links and the hash read them, and the task
/// fences each of those as it lays them out. Nothing reaches the model
/// unfenced either way.
@immutable
class BriefInput {
  /// The occurrence being briefed — never a series master.
  final CalendarEvent event;

  /// [briefWhenLine] in the display zone: "Wed 7 Oct 2026 · 10:00–11:00 AM
  /// PDT". Absolute, never "Tomorrow": the brief is stored and read for up to
  /// a day and a half, and a relative word the model copied into it would be
  /// false by the next morning.
  final String whenLocal;

  /// [briefNowLine]: when the brief was gathered, in the same absolute shape,
  /// so the model can reason about "before the meeting" without being handed
  /// a relative word to repeat.
  final String nowLocal;

  /// The instant [nowLocal] names, for the threads' relative ages
  /// ([briefAgo]). Null in a hand-built input, which then shows the raw
  /// stamps. Never hashed: the hash must not move with the clock.
  final DateTime? now;

  /// Names (else addresses) of everyone in the meeting but the owner.
  final List<String> attendees;
  final List<BriefThread> threads;
  final List<BriefAsk> openAsks;

  /// Threads from [threads] waiting on the attendees: state `waiting` and the
  /// owner's message last.
  final List<BriefThread> waitingOn;
  final List<BriefStoryline> storylines;

  /// The files sent on THIS meeting's own invite threads (the
  /// occurrence's, then its series master's) — whoever sent them, the owner
  /// included — newest first. Never a file from a thread that merely
  /// involves the same people: that is in [otherFiles].
  final List<BriefMaterial> materials;

  /// The names of the files on the other threads in [threads] — the
  /// address-matched or related mail, not this meeting's own — newest first,
  /// one per name, at most [BriefGatherer.maxOtherFiles]. Raw, like every
  /// label; the task lists them as NOT sent for this meeting, so a resume
  /// sent for another interview cannot become this meeting's purpose.
  final List<String> otherFiles;

  /// Whether any of [materials] is still being read: its `text_status` is
  /// `pending` AND its `attachment_text` work row is `pending` or
  /// `processing` AND it has been being read for less than
  /// [BriefGatherer.pendingMaxAge]: measured from the later of its mail's
  /// `received_at` and its text work row's `created_at`, so a file a fetch
  /// lists on mail sent days ago is still waited for. A file whose text work gave up
  /// (the work row `error`, the attachment row left `pending`) or was never
  /// queued ([BriefEligible.unqueued]) is not being read, and an old one is
  /// not worth holding a brief for. The handler waits on it while the
  /// meeting is far enough off. Not hashed: the materials' states already
  /// are.
  final bool materialsPending;

  /// The people in the meeting, the organiser first and then the attendees'
  /// order, at most
  /// [BriefGatherer.maxPeople]; empty from the planner's gather, which
  /// needs only the hash.
  final List<BriefPerson> people;

  /// How many people there are beyond [people].
  final int peopleMore;

  /// "Last met 3 days ago", or null when the mirror holds no earlier meeting
  /// with any of them — on the related path, with any of the people the
  /// block lists ([BriefGatherer.maxPeople], the organiser first).
  final String? lastMet;

  /// The invite's `body_preview`, fenced and capped; null when it has none.
  final String? invitePreview;

  /// Which way [threads] were found ([briefPathOf]). Hashed only when it is
  /// [BriefPath.related], so every people-path hash is the one it was
  /// before there were two paths.
  final BriefPath path;

  /// The cosine of the nearest related thread kept, on the
  /// [BriefPath.related] path; null on the people path or when none was
  /// kept. For the activity row; never hashed, since the threads are.
  final double? relatedBest;

  final String inputsHash;

  const BriefInput({
    required this.event,
    required this.whenLocal,
    this.nowLocal = '',
    this.now,
    this.attendees = const [],
    this.threads = const [],
    this.openAsks = const [],
    this.waitingOn = const [],
    this.storylines = const [],
    this.materials = const [],
    this.otherFiles = const [],
    this.materialsPending = false,
    this.people = const [],
    this.peopleMore = 0,
    this.lastMet,
    this.invitePreview,
    this.path = BriefPath.people,
    this.relatedBest,
    required this.inputsHash,
  });
}

/// What [BriefGatherer.gather] found.
sealed class BriefGather {
  const BriefGather();
}

final class BriefEligible extends BriefGather {
  final BriefInput input;

  /// The chosen threads' mail messages that say they carry files nobody has
  /// listed yet (`has_attachments` set, no `attachments` row) — a sent
  /// invite's own PDF, whose detail is fetched only when its thread is
  /// opened. Newest first, at most [BriefGatherer.maxUnlisted]. The handler
  /// fetches them once and gathers again.
  final List<({String source, String messageId})> unlisted;

  /// The materials whose attachment row is `pending` with NO
  /// `attachment_text` work row at all — listed by a fetch that queued no
  /// text (`ensureBodiesFor`), so nothing will ever read them unless
  /// somebody queues it. [young] is always true: the handler queues them
  /// once, this run, so their reading starts now and the next gather times
  /// it from the work row's `created_at` ([BriefInput.materialsPending]).
  final List<({BriefMaterial material, bool young})> unqueued;

  const BriefEligible(
    this.input, {
    this.unlisted = const [],
    this.unqueued = const [],
  });
}

final class BriefIneligible extends BriefGather {
  final BriefIneligibility why;
  const BriefIneligible(this.why);
}

/// [BriefGatherer.gather] with the owner's address not known yet. Thrown
/// rather than answered, so the worker's retry picks the meeting up again.
class BriefOwnerUnknown implements Exception {
  const BriefOwnerUnknown();

  @override
  String toString() => "BriefOwnerUnknown: the owner's address is not known "
      'yet';
}

/// The gatherer's display zone asked for before it has resolved. Thrown by
/// the zone closure rather than answering UTC, whose "today and tomorrow"
/// is not the owner's; the worker retries the meeting as it does
/// [BriefOwnerUnknown].
class BriefZoneUnknown implements Exception {
  const BriefZoneUnknown();

  @override
  String toString() => 'BriefZoneUnknown: the display zone has not resolved '
      'yet';
}

/// [s] cut to at most [max] UTF-16 code units, never ending on the first half
/// of a surrogate pair: a cut through an emoji would leave a lone surrogate,
/// which is not text and which a JSON encoder or a model server may refuse.
String capRunes(String s, int max) {
  if (s.length <= max) return s;
  var end = max;
  if (end > 0) {
    final last = s.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end -= 1;
  }
  return s.substring(0, end);
}

/// One other person in a meeting, as [briefOthers] finds them.
typedef BriefOther = ({String name, String address});

/// The mailbox providers whose domain says nothing about who someone works
/// for.
const Set<String> briefConsumerDomains = {
  'gmail',
  'googlemail',
  'outlook',
  'hotmail',
  'live',
  'msn',
  'yahoo',
  'icloud',
  'me',
  'mac',
  'proton',
  'protonmail',
  'aol',
};

/// The second-level labels that sit inside a country's two-part suffix
/// (`co.uk`, `com.au`, `ac.jp`): the organisation is the label before them.
const Set<String> _secondLevelSuffixes = {
  'co',
  'com',
  'org',
  'net',
  'ac',
  'gov',
  'edu',
  'ne',
  'or',
};

/// The organisation an address's domain names: the label before its public
/// suffix, so `fabrikam` for `dana@mail.fabrikam.com` and `contoso` for
/// `sam@contoso.co.uk`. '' for a consumer mailbox ([briefConsumerDomains]),
/// a Google calendar resource (`*.calendar.google.com`), an address written
/// as an IP, or anything that is not an address; the tenant for Microsoft's
/// `contoso.onmicrosoft.com` (and its `contoso.mail.onmicrosoft.com`
/// routing domain). Only letters, digits and hyphens ever come back — but
/// whoever owns a domain chose its words, so the task fences it with the
/// name.
String briefOrgOf(String address) {
  final at = address.lastIndexOf('@');
  if (at < 0) return '';
  final domain = address.substring(at + 1).trim().toLowerCase();
  if (domain.endsWith('.calendar.google.com')) return '';
  final labels = [
    for (final l in domain.split('.'))
      if (l.isNotEmpty) l,
  ];
  if (labels.length < 2) return '';
  // An address written as an IP names no organisation.
  if (labels.every(_numericLabel.hasMatch)) return '';
  final twoPart = labels.length >= 3 &&
      labels.last.length == 2 &&
      _secondLevelSuffixes.contains(labels[labels.length - 2]);
  // Microsoft's tenant domain (`contoso.onmicrosoft.com`, a default M365
  // address or a B2B guest) names the tenant in the label before it, or
  // before the `mail` of its routing domain (`contoso.mail.onmicrosoft.com`).
  var tenant = labels.indexOf('onmicrosoft');
  if (tenant > 1 && labels[tenant - 1] == 'mail') tenant -= 1;
  if (tenant == 0) return '';
  final org = tenant > 0
      ? labels[tenant - 1]
      : labels[labels.length - (twoPart ? 3 : 2)];
  // A label the DNS letters could not spell (an unencoded IDN, a stray
  // character) is not shown.
  if (!_dnsLabel.hasMatch(org)) return '';
  return briefConsumerDomains.contains(org) ? '' : org;
}

final RegExp _numericLabel = RegExp(r'^[0-9]+$');
final RegExp _dnsLabel = RegExp(r'^[a-z0-9-]+$');

/// The instant briefs stop: the local midnight in [zone] that ends tomorrow.
/// Briefs cover today and tomorrow in the display zone — a standing meeting
/// months out is never gathered — and the planner, the gatherer and the
/// panel all read this one function.
DateTime briefHorizonEnd(DateTime nowUtc, CalendarZone zone) =>
    zone.localDateTime(zone.dateOf(nowUtc.toUtc()).addDays(2), 0, 0).toUtc();

/// How far back the mail with its people is read (D6), and how far back the
/// related search looks ([BriefPath.related]).
const Duration briefMailWindow = Duration(days: 30);

/// How far back the related search looks ([BriefPath.related]). Shorter than
/// the people path's window on purpose: a brief is a catch-up on what is
/// being said about the subject now, and three weeks of it is plenty.
const Duration briefRelatedWindow = Duration(days: 21);

/// "Wed 7 Oct 2026 · 10:00–11:00 AM PDT" for a timed event in [zone] (the
/// zone's abbreviation, else its IANA name); "All day · Wed 7 Oct 2026" for a
/// one-day all-day event, "All day · Wed 7 Oct 2026 – Fri 9 Oct 2026" for a
/// longer one; "" when the times are missing. Absolute on purpose — see
/// [BriefInput.whenLocal].
String briefWhenLine(CalendarEvent e, CalendarZone zone) {
  final dayFormat = DateFormat('EEE d MMM y');
  String day(CalendarDate d) =>
      dayFormat.format(DateTime(d.year, d.month, d.day));
  if (e.isAllDay) {
    final start = e.startDate;
    if (start == null) return '';
    final end = e.endDate;
    if (end != null && end.isAfter(start.addDays(1))) {
      return 'All day · ${day(start)} – ${day(end.addDays(-1))}';
    }
    return 'All day · ${day(start)}';
  }
  final s = e.startUtc;
  final end = e.endUtc;
  if (s == null || end == null) return '';
  return '${day(zone.dateOf(s))} · ${formatEventRange(zone, s, end)} '
      '${_zoneLabel(zone, s)}';
}

/// "Tue 29 Sep 2026, 3:05 PM PDT": [now] in [zone], absolute.
String briefNowLine(DateTime now, CalendarZone zone) {
  final local = zone.toLocal(now.toUtc());
  final wall = DateTime(
      local.year, local.month, local.day, local.hour, local.minute);
  return '${DateFormat('EEE d MMM y, h:mm a').format(wall)} '
      '${_zoneLabel(zone, now)}';
}

/// The zone's abbreviation at [at] ("PDT", "PST"), else its IANA name.
String _zoneLabel(CalendarZone zone, DateTime at) {
  final abbreviation = zone.toLocal(at.toUtc()).timeZoneName.trim();
  return abbreviation.isNotEmpty ? abbreviation : zone.iana;
}

/// How long before [now] the stored stamp [iso] was: "just now", "5 minutes
/// ago", "1 hour ago", "2 days ago". "" for an empty or unreadable stamp. A
/// stamp in the future (clock skew) reads as "just now".
///
/// Worded in full rather than the list rows' "2d ago" because a model reads
/// this, and it is computed from the caller's [now] so a test can pin it.
String briefAgo(String iso, DateTime now) {
  if (iso.isEmpty) return '';
  final at = DateTime.tryParse(iso);
  if (at == null) return '';
  final elapsed = now.toUtc().difference(at.toUtc());
  String n(int count, String unit) =>
      '$count $unit${count == 1 ? '' : 's'} ago';
  if (elapsed.inMinutes < 1) return 'just now';
  if (elapsed.inHours < 1) return n(elapsed.inMinutes, 'minute');
  if (elapsed.inDays < 1) return n(elapsed.inHours, 'hour');
  return n(elapsed.inDays, 'day');
}

/// When [e] starts: its instant, or an all-day event's local midnight in
/// [zone]. Null for a row with neither.
DateTime? briefStartOf(CalendarEvent e, CalendarZone zone) {
  if (!e.isAllDay) return e.startUtc;
  final d = e.startDate;
  return d == null ? null : zone.localDateTime(d, 0, 0).toUtc();
}

/// Everyone in [e] who is not the owner and not a room: the attendees, plus
/// the organiser when it is somebody else (an attendee's copy with a hidden
/// guest list names only the organiser, and that is still a meeting with
/// someone). [owner] is lowercased; when it is unknown, an event the owner
/// organised still leaves its organiser out.
///
/// Nobody's RESPONSE is read here. Only the organiser's copy tracks
/// answers; on an attendee's copy `none` means "not known", never "hasn't
/// answered" — so the people block reads an answer only off the owner's own
/// organiser copy ([BriefPerson.response]) and says "not known" everywhere
/// else rather than risk saying something false.
List<BriefOther> briefOthers(CalendarEvent e, {required String? owner}) {
  final seen = <String>{};
  final out = <BriefOther>[];
  bool isOwner(String address) =>
      owner != null && owner.isNotEmpty && address == owner;
  for (final a in e.attendees) {
    final address = a.address.trim().toLowerCase();
    if (address.isEmpty ||
        a.type.trim().toLowerCase() == 'resource' ||
        isOwner(address)) {
      continue;
    }
    if (!seen.add(address)) continue;
    out.add((name: a.name.trim(), address: address));
  }
  final organiser = e.organizerAddress.trim().toLowerCase();
  if (organiser.isNotEmpty &&
      !e.isOrganizer &&
      !isOwner(organiser) &&
      seen.add(organiser)) {
    out.add((name: e.organizerName.trim(), address: organiser));
  }
  return out;
}

/// The eligibility rules that need no store read (D6), in the order a person
/// would give them: cancelled, declined, started, too far off, nobody else.
/// No meeting is refused for its size: a big one takes the related path
/// ([briefPathOf]) and is briefed from the threads about its subject.
/// Null when the meeting passes them all — the mail rule is the gatherer's.
///
/// [asked] — a person pressed Write a brief: the horizon does not apply (the
/// rest does).
///
/// Pure, so the planner can skip a meeting before a single read and the event
/// panel can say why a meeting has no brief before anything is stored.
BriefIneligibility? briefQuickCheck(
  CalendarEvent e, {
  required String? owner,
  required DateTime now,
  required CalendarZone zone,
  bool asked = false,
}) {
  if (e.isCancelled) return BriefIneligibility.cancelled;
  if (standingOf(e) == EventStanding.declined) {
    return BriefIneligibility.declined;
  }
  final start = briefStartOf(e, zone);
  final nowUtc = now.toUtc();
  if (start == null || !start.isAfter(nowUtc)) return BriefIneligibility.past;
  if (!asked && !start.isBefore(briefHorizonEnd(nowUtc, zone))) {
    return BriefIneligibility.tooFar;
  }
  final ownerKey = owner?.trim().toLowerCase();
  final others = briefOthers(e, owner: ownerKey);
  if (others.isEmpty) return BriefIneligibility.noOthers;
  return null;
}

/// Collects what a pre-meeting brief is written from. Deterministic and
/// model-free: with `passages: false` it is the planner's light gather —
/// the store reads the hash needs and nothing else — so the planner can
/// afford to run it for every meeting in the window just to learn whether
/// anything changed. The handler's gather (the default) also reads each
/// file's text, builds the people block and embeds the meeting once to find
/// the materials' passages — none of it hashed, so both gathers hash alike.
///
/// Always handed the OCCURRENCE to brief. A series master carries the
/// series' first meeting's times; the planner targets occurrence ids (the
/// mirror's rows) and never a master, and the handler turns a master it is
/// given into its `displayOccurrence` before it gets here.
///
/// Two paths ([briefPathOf]). The meeting's own invite mails
/// (`messagesForEvent`) are read first on both, whoever sent them, so a
/// meeting whose only mail is its invite is still briefed.
///
/// The PEOPLE path (at most [briefPeopleMax] others, or a topicless meeting
/// of at most [briefTopiclessPeopleMax]) is mail only. The people are
/// matched by ADDRESS against a conversation's `participants_json`, and a
/// Teams chat stores its people as `teams:<id>`, not addresses, so no chat
/// is ever matched; mapping them through the people directory is a
/// follow-up. `participants_json` also holds at most eight people per
/// conversation, so an attendee beyond the eighth in a busy thread is not
/// matched by that thread.
///
/// The RELATED path (everything bigger, or with a list in the room) reads
/// mail AND Teams by meaning: the conversations whose messages sit nearest
/// the meeting's subject and description ([briefQueryText]) in the message
/// index, at most [maxRelated] at cosine [relatedFloor] or better, from the
/// last [briefMailWindow], logistics left out, whoever is on them. It never
/// answers `no_mail`: a meeting it finds nothing for is briefed from its
/// invite and its people. The query is embedded once per text per run
/// ([_queryVectors]), in the light gather too, because the threads it finds
/// are hashed like any other.
///
/// With [embeddings] given, the materials carry the passages of their text
/// nearest the meeting; without it (tests, or no embedding server wired)
/// they carry the digest only, and the related path finds nothing (`off`).
/// The passage step makes a network call only when `gather` is asked for
/// passages; neither step can ever fail the brief.
class BriefGatherer {
  BriefGatherer(
    this._store,
    this._calendar, {
    required this._ownerAddress,
    required this._zone,
    this._embeddings,
  });

  final MessageStore _store;
  final CalendarStore _calendar;
  final Future<String?> Function() _ownerAddress;
  final CalendarZone Function() _zone;
  final EmbeddingsClient? _embeddings;

  static const int maxThreads = 6;
  static const int maxAsks = 4;
  static const int maxWaiting = 3;
  static const int maxStorylines = 2;
  static const int maxMaterials = 6;
  static const int maxOtherFiles = 4;
  static const int maxUnlisted = 4;

  /// How many of the six threads the meeting's own invite threads may take:
  /// a long weekly series has an invite thread per update, and must not push
  /// out the ranked mail with the people.
  static const int maxInviteThreads = 3;

  /// How many nearest passages are asked for PER material, and how many of
  /// them it keeps. One search per file, so a long deck cannot fill the
  /// shortlist and starve the others.
  static const int passageLimit = 4;
  static const int passagesPerMaterial = 2;
  static const int passageCap = 350;

  /// How many conversations are read to rank. Each costs a thread read, and
  /// twenty is more mail with a meeting's people in a month than six slots
  /// can use.
  static const int candidateLimit = 20;

  static const int snippetCap = 600;
  static const int askCap = 300;
  static const int storylineCap = 400;
  static const int invitePreviewCap = 600;

  /// How much of a file's text a material carries, cut at a word: the head
  /// of the document, where a deck's ask and a memo's point usually are.
  /// The task's budget decides how much of it the model is shown.
  static const int materialTextCap = 6000;

  /// The most people the people block lists; the rest are counted.
  static const int maxPeople = 8;

  /// How long a file still being read is waited for, from the later of its
  /// mail's arrival and its text work's first ask. A backstop: the work
  /// row's state is the rule, and a file whose extraction neither finishes
  /// nor gives up in two hours is not going to.
  static const Duration pendingMaxAge = Duration(hours: 2);

  /// The work kind that reads a file's text (`AttachmentTextHandler.kind`).
  static const String textKind = 'attachment_text';

  /// How much of a person's newest message the people block quotes.
  static const int lastWordsCap = 240;

  /// The most related threads ([BriefPath.related]) a brief is written
  /// from, after the invite threads and inside [maxThreads]: about half of
  /// what the search finds is about something else, so a few of the
  /// nearest beat many.
  static const int maxRelated = 4;

  /// The least cosine a related thread's best message may have. Calibrated
  /// on subject-and-description queries ([briefQueryText]); a longer query
  /// moves the scale and needs this measured again.
  static const double relatedFloor = 0.60;

  /// How many conversations the related search hands back to be read and
  /// filtered (invite threads, logistics) down to [maxRelated].
  static const int relatedCandidateLimit = 12;

  /// How many messages of a RELATED thread the brief quotes: the one that
  /// matched and what was said around it. Three at [relatedSnippetCap] cost
  /// what an invite or people thread's two at [snippetCap] do.
  static const int relatedShown = 3;
  static const int relatedSnippetCap = 400;

  /// How far either side of the matched message a chat's excerpt may reach:
  /// a reply the next morning is the same exchange, one a week on is not.
  static const Duration excerptSpan = Duration(hours: 24);

  /// How long after a failed query embedding the gatherer does not ask
  /// again, judged on the caller's `now`: a hung server costs one timeout,
  /// not one per meeting in the window.
  static const Duration embedRetryAfter = Duration(minutes: 2);

  /// How many query vectors [_queryVectors] holds; past it the oldest is
  /// dropped. A day's meetings are a few dozen texts.
  static const int queryCacheMax = 64;

  /// The related search's query vectors, by sha256 of the query text, for
  /// the life of the gatherer (the app run): the planner gathers every
  /// meeting in the window on every sync, and an embedding call per meeting
  /// per sync would be the one network cost of a pass that is otherwise
  /// store reads.
  final Map<String, Uint8List> _queryVectors = {};

  /// Until when a failed query embedding keeps the gatherer from asking
  /// again ([embedRetryAfter]).
  DateTime? _embedDownUntil;

  /// The intents that make an inbound message an ASK. `scheduling` is left
  /// out on purpose: the meeting being briefed is usually its answer.
  static const Set<String> askIntents = {'question', 'request', 'approval'};

  /// The display zone right now, for callers that must pick an occurrence
  /// the same way the gatherer dates things.
  CalendarZone zoneNow() => _zone();

  /// The owner's address, lowercased, or null when the account has not
  /// answered. A throwing lookup reads as unknown.
  Future<String?> owner() async {
    try {
      final a = (await _ownerAddress())?.trim().toLowerCase();
      return a == null || a.isEmpty ? null : a;
    } on Object {
      return null;
    }
  }

  /// [passages] false is the light gather, which only needs the hash and
  /// the wait: no passage embedding, no file text read, no people block. On
  /// the [BriefPath.related] path it still finds the related threads, which
  /// costs one embedding call per distinct meeting text per run (cached),
  /// because they are hashed. The inputs hash is the same either way, and
  /// so are [BriefInput.materialsPending] and [BriefEligible.unqueued],
  /// which read only the stored states and the work rows.
  ///
  /// [asked] — a person pressed Write a brief: neither the horizon nor the
  /// mail rule applies, and a meeting with no mail is briefed from the
  /// invite and its people alone. (The related path has no mail rule.)
  Future<BriefGather> gather(
    CalendarEvent event, {
    required DateTime now,
    bool passages = true,
    bool asked = false,
  }) async {
    final owner = await this.owner();
    // Unknown, the owner's own attendee row counts as somebody else, and a
    // meeting with nobody would be briefed as one with them. The worker
    // retries it; the keychain answers soon after launch.
    if (owner == null) throw const BriefOwnerUnknown();
    final zone = _zone();
    final nowUtc = now.toUtc();
    final quick = briefQuickCheck(event,
        owner: owner, now: nowUtc, zone: zone, asked: asked);
    if (quick != null) return BriefIneligible(quick);

    final others = briefOthers(event, owner: owner);
    final path = briefPathOf(event,
        otherAddresses: [for (final p in others) p.address]);
    final addresses = {for (final p in others) p.address};
    final nameOf = {
      for (final p in others)
        if (p.name.isNotEmpty) p.address: p.name,
    };

    // The meeting's own mails — the invite, its updates, and for an
    // occurrence the series' — whoever sent them and however long ago. They
    // are the likeliest place for the deck sent ahead, and the organiser's
    // assistant who sent the invite matches no attendee's address.
    final inviteKeys = <(String, String)>[];
    for (final id in [
      event.id,
      if (event.seriesMasterId.isNotEmpty) event.seriesMasterId,
    ]) {
      for (final r in await _calendar.messagesForEvent(id)) {
        final key = (r.source, r.conversationKey);
        if (!inviteKeys.contains(key)) inviteKeys.add(key);
      }
    }

    // One read per candidate: its messages, and the decision on its newest
    // inbound message, which is what the ranking turns on.
    final decisions = <String, StoredDecision?>{};
    Future<StoredDecision?> decisionOf(Message m) async {
      final key = '${m.source}\u0000${m.id}';
      if (decisions.containsKey(key)) return decisions[key];
      return decisions[key] = await _store.decisionFor(m.source, m.id);
    }

    Future<_Candidate> candidateOf(Conversation c) async {
      final messages = await _store.loadThread(c.id, sources: [c.source]);
      final latestIn = messages.lastWhereOrNull((m) => !m.outbound);
      final decision = latestIn == null ? null : await decisionOf(latestIn);
      return _Candidate(c, messages, _pressing(decision));
    }

    final invites = <_Candidate>[];
    for (final (source, key) in inviteKeys) {
      final row = await _store.getConversationRow(source, key);
      if (row == null) continue;
      invites.add(await candidateOf(Conversation.fromRow(row)));
    }

    final candidates = <_Candidate>[];
    String? relatedState;
    double? relatedBest;
    switch (path) {
      case BriefPath.people:
        final conversations = await _store.conversationsWithAddresses(
          addresses,
          sinceIso: MessageStore.isoStamp(nowUtc.subtract(briefMailWindow)),
          limit: candidateLimit,
        );
        // An invite thread alone is mail about this meeting: the rule is "no
        // threads at all", not "no address match". A person who asked gets a
        // brief anyway: every step below takes an empty thread list.
        if (!asked && invites.isEmpty && conversations.isEmpty) {
          return const BriefIneligible(BriefIneligibility.noMail);
        }
        for (final c in conversations) {
          if (inviteKeys.contains((c.source, c.id))) continue;
          candidates.add(await candidateOf(c));
        }
        // Urgent or important first, then the most recently active; the
        // conversation key breaks a tie so the same mail always ranks one
        // way.
        candidates.sort((a, b) {
          if (a.ranked != b.ranked) return a.ranked ? -1 : 1;
          final byTime =
              (b.c.lastMessageAt ?? '').compareTo(a.c.lastMessageAt ?? '');
          return byTime != 0 ? byTime : a.c.id.compareTo(b.c.id);
        });
      case BriefPath.related:
        // No mail rule: with nothing found the brief is written from the
        // invite and its people. The threads stay in score order — nearest
        // first is the ranking here, and a pressing thread about something
        // else must not jump it.
        final found = await _relatedOf(event, inviteKeys, nowUtc, candidateOf);
        candidates.addAll(found.threads);
        relatedState = found.state;
        relatedBest = found.best;
    }
    // The invite threads lead, newest first as the store returns them, and
    // count toward the six.
    final inviteChosen = invites.take(maxInviteThreads).toList();
    final chosen =
        [...inviteChosen, ...candidates].take(maxThreads).toList();

    final threads = [
      for (final (i, k) in chosen.indexed)
        BriefThread(
          source: k.c.source,
          conversationKey: k.c.id,
          subject: (k.c.subject ?? '').trim(),
          state: k.c.state.wire,
          // An excerpt is stamped and counted by what is SHOWN, so the rest
          // of the chat moving does not move the hash (see [BriefThread.
          // excerpt]).
          lastAt: k.excerpt
              ? (k.quoted.lastOrNull?.receivedAt ?? '')
              : (k.c.lastMessageAt ?? ''),
          messageCount: k.excerpt ? k.quoted.length : k.c.messageCount,
          snippets: [
            for (final m in k.quoted)
              if (_plain(m).isNotEmpty)
                wrapUntrusted(
                  'message',
                  _cap(
                    '${_who(m, nameOf)}: ${_plain(m)}',
                    k.quoted.length > 2 ? relatedSnippetCap : snippetCap,
                  ),
                ),
          ],
          ranked: k.ranked,
          invite: i < inviteChosen.length,
          excerpt: k.excerpt,
        ),
    ];

    // Open asks: inbound messages from an attendee, in a thread still waiting
    // on the owner, that the decision model says want the owner or a reply,
    // labelled by intent. Only what came AFTER the owner's last message in
    // the thread: an ask before a reply is taken to have been answered. The
    // newest qualifying one per thread.
    final asks = <BriefAsk>[];
    // Who asked each one, for the people block: the address, not the name
    // the ask carries.
    final askOf = <String, String>{};
    final needsYouThreshold = await _store.needsYouThreshold();
    for (var i = 0; i < chosen.length && asks.length < maxAsks; i++) {
      final k = chosen[i];
      // An excerpt is a few messages of a chat, not a thread with a state.
      if (k.excerpt || k.c.state != ConversationState.needsReply) continue;
      final lastOut = k.messages.lastIndexWhere((m) => m.outbound);
      for (var j = k.messages.length - 1; j > lastOut; j--) {
        final m = k.messages[j];
        final from = (m.fromAddress ?? '').trim().toLowerCase();
        if (m.outbound || !addresses.contains(from)) continue;
        final d = await decisionOf(m);
        final intent = _intentOf(d);
        if (d == null || intent == null || !_wantsOwner(d, needsYouThreshold)) {
          continue;
        }
        final text = _plain(m);
        if (text.isEmpty) continue;
        asks.add(BriefAsk(
          person: nameOf[from] ??
              ((m.fromName ?? '').trim().isNotEmpty ? m.fromName!.trim() : from),
          ask: wrapUntrusted('ask', _cap(text, askCap)),
          intent: intent,
          threadIndex: i,
          messageId: m.id,
        ));
        askOf.putIfAbsent(from, () => asks.last.ask);
        break;
      }
    }

    final waitingOn = [
      for (var i = 0; i < chosen.length; i++)
        if (!chosen[i].excerpt &&
            chosen[i].c.state == ConversationState.waiting &&
            chosen[i].messages.isNotEmpty &&
            chosen[i].messages.last.outbound)
          threads[i],
    ].take(maxWaiting).toList();

    final storylines = <BriefStoryline>[];
    final seenStorylines = <String>{};
    for (final k in chosen) {
      if (storylines.length >= maxStorylines) break;
      for (final id in await _store.storylineIdsFor(k.c.source, k.c.id)) {
        if (storylines.length >= maxStorylines) break;
        if (id.isEmpty || !seenStorylines.add(id)) continue;
        final s = await _store.getStoryline(id);
        if (s == null) continue;
        final recap = (s.recapText ?? '').trim();
        final where = recap.isNotEmpty ? recap : (s.summary ?? '').trim();
        storylines.add(BriefStoryline(
          id: s.id,
          title: s.title.trim(),
          summary: wrapUntrusted('storyline', _cap(where, storylineCap)),
        ));
      }
    }

    // Materials come from the meeting's own invite threads only; a file on
    // other mail with the same people is named, never read, as not sent for
    // this meeting.
    final found = _materialsOf(inviteChosen, nameOf, zone);
    final otherFiles = [
      for (final (_, a) in _filesOf(chosen.skip(inviteChosen.length)))
        (a.name ?? '').trim(),
    ].take(maxOtherFiles).toList();
    final (:pending, :unqueued) = await _readingOf(found, nowUtc);
    final materials = passages
        ? await _withPassages(event, await _withText(found))
        : found;

    final today = zone.dateOf(nowUtc);
    final preview = event.bodyPreview.trim();
    // The organiser first, then the attendees in the invite's order, and
    // the cap after: who called the meeting is the one person the people
    // block must not count among "+N more" (`briefOthers` appends the
    // organiser LAST, since an attendee copy's list leaves them out). A
    // deliberate departure from D14's literal "attendee order".
    final organiser = event.organizerAddress.trim().toLowerCase();
    final organiserFirst = [
      ...others.where((p) => p.address == organiser),
      ...others.where((p) => p.address != organiser),
    ];
    // On the related path the room is too big to list, so after the
    // organiser come the people who are IN the chosen threads, then the
    // rest: who is involved in the subject, before who merely got the
    // invite.
    final listed = (path == BriefPath.related
            ? [
                ...organiserFirst.where((p) => p.address == organiser),
                ...organiserFirst.where((p) =>
                    p.address != organiser &&
                    chosen.any((k) => _inThread(k, p))),
                ...organiserFirst.where((p) =>
                    p.address != organiser &&
                    !chosen.any((k) => _inThread(k, p))),
              ]
            : organiserFirst)
        .take(maxPeople)
        .toList();
    // On the related path "last met" is read for the people the block
    // lists, not the whole room: having met any one of three hundred people
    // says nothing about this meeting, and the lookup binds two variables
    // per address.
    final met = await _calendar.lastMetWith(
      path == BriefPath.related
          ? [for (final p in listed) p.address]
          : addresses,
      nowUtc: nowUtc,
    );
    final people = passages
        ? await _peopleOf(
            event,
            listed,
            chosen,
            askOf,
            nowUtc: nowUtc,
            zone: zone,
            today: today,
          )
        : const <BriefPerson>[];

    final inputsHash = _hash(
      event: event,
      owner: owner,
      path: path,
      relatedState: relatedState,
      threads: threads,
      asks: asks,
      storylines: storylines,
      materials: materials,
      otherFiles: otherFiles,
    );

    return BriefEligible(
        unlisted: _unlistedOf(chosen), unqueued: unqueued, BriefInput(
      event: event,
      whenLocal: briefWhenLine(event, zone),
      nowLocal: briefNowLine(nowUtc, zone),
      now: nowUtc,
      attendees: [
        for (final p in others) p.name.isNotEmpty ? p.name : p.address,
      ],
      threads: threads,
      openAsks: asks,
      waitingOn: waitingOn,
      storylines: storylines,
      materials: materials,
      otherFiles: otherFiles,
      materialsPending: pending,
      people: people,
      peopleMore: math.max(0, others.length - maxPeople),
      lastMet: met == null ? null : lastMetLabel(met, zone: zone, today: today),
      invitePreview: preview.isEmpty
          ? null
          : wrapUntrusted('invite', _cap(preview, invitePreviewCap)),
      path: path,
      relatedBest: relatedBest,
      inputsHash: inputsHash,
    ));
  }

  /// The [BriefPath.related] threads for [event]: the conversations nearest
  /// its [briefQueryText], best first, read through [candidateOf], at most
  /// [maxRelated]. A conversation in [inviteKeys] is left out (it already
  /// leads the list), and so is calendar logistics: a thread whose subject
  /// is an answer, an invitation or a cancellation
  /// ([briefIsLogisticsSubject]), or one carrying ANOTHER meeting's invite
  /// (a message whose `meetingEventId` is neither this occurrence nor its
  /// series master) — it sits near the subject because it repeats it, and
  /// says nothing about this meeting.
  ///
  /// [state] says how the search went, for the hash: `ok`; `off` with no
  /// embedding client; `no_query` with nothing to search by; `unavailable`
  /// when the query could not be embedded (and for [embedRetryAfter] after),
  /// the index is not there, or anything threw. A failure is never a reason
  /// for there to be no brief, and the hash moves when the search returns.
  /// [best] is the first kept thread's cosine.
  Future<({List<_Candidate> threads, String state, double? best})> _relatedOf(
    CalendarEvent event,
    List<(String, String)> inviteKeys,
    DateTime nowUtc,
    Future<_Candidate> Function(Conversation) candidateOf,
  ) async {
    const none = <_Candidate>[];
    final embeddings = _embeddings;
    if (embeddings == null) return (threads: none, state: 'off', best: null);
    final text = briefQueryText(event);
    if (text.isEmpty) return (threads: none, state: 'no_query', best: null);
    try {
      final key = sha256.convert(utf8.encode(text)).toString();
      var query = _queryVectors[key];
      if (query == null) {
        final downUntil = _embedDownUntil;
        if (downUntil != null && downUntil.isAfter(nowUtc)) {
          return (threads: none, state: 'unavailable', best: null);
        }
        final vector = (await embeddings.embedResult(
          text,
          prefix: EmbeddingsClient.searchQueryPrefix,
        ))
            .vector;
        if (vector == null) {
          _embedDownUntil = nowUtc.add(embedRetryAfter);
          return (threads: none, state: 'unavailable', best: null);
        }
        query = encodeEmbedding(vector);
        // The oldest goes, not the lot: the map keeps insertion order, and
        // clearing it would drop the vectors of meetings still in the window.
        if (_queryVectors.length >= queryCacheMax) {
          _queryVectors.remove(_queryVectors.keys.first);
        }
        _queryVectors[key] = query;
      }
      final hits = await _store.relatedConversations(
        query,
        embedModel: EmbeddingsClient.documentModelTag,
        sinceIso: MessageStore.isoStamp(nowUtc.subtract(briefRelatedWindow)),
        floor: relatedFloor,
        limit: relatedCandidateLimit,
      );
      if (hits == null) {
        return (threads: none, state: 'unavailable', best: null);
      }
      final threads = <_Candidate>[];
      double? best;
      for (final hit in hits) {
        if (threads.length >= maxRelated) break;
        if (inviteKeys.contains((hit.source, hit.conversationKey))) continue;
        final row =
            await _store.getConversationRow(hit.source, hit.conversationKey);
        if (row == null) continue;
        final conversation = Conversation.fromRow(row);
        // Judged on the row, before the thread read it would cost.
        if (briefIsLogisticsSubject(conversation.subject ?? '')) continue;
        final _Candidate k;
        if (hit.source == 'teams') {
          // A chat is a room, not a thread: only the exchange around the
          // matched message is read, never the room's history.
          final part = await _excerptOf(conversation, hit);
          if (part == null) continue;
          k = part;
        } else {
          final whole = await candidateOf(conversation);
          // Another meeting's invite thread: neither this occurrence nor its
          // series master. The exemption is a belt — a thread carrying
          // either id is already an invite key and was skipped above.
          final otherInvite = whole.messages.any((m) {
            final id = m.meetingEventId;
            return id != null &&
                id != event.id &&
                !(event.seriesMasterId.isNotEmpty &&
                    id == event.seriesMasterId);
          });
          if (otherInvite) continue;
          k = whole.showing(_aroundMatch(whole.messages, hit.messageId));
        }
        threads.add(k);
        best ??= hit.cosine;
      }
      return (threads: threads, state: 'ok', best: best);
    } on Object catch (e) {
      debugPrint('BriefGatherer: no related threads (${e.runtimeType})');
      return (threads: none, state: 'unavailable', best: null);
    }
  }

  /// The part of a chat around the message the related search matched, as a
  /// candidate whose messages ARE that part: the match, then what followed
  /// it, then (only to fill [relatedShown]) what came just before — all
  /// within [excerptSpan] of the match. Null when the matched message is no
  /// longer in the store or carries no readable stamp.
  Future<_Candidate?> _excerptOf(
    Conversation conversation,
    RelatedConversation hit,
  ) async {
    final at = DateTime.tryParse(hit.receivedAt);
    if (at == null) return null;
    final window = await _store.messagesBetween(
      hit.source,
      hit.conversationKey,
      fromIso: MessageStore.isoStamp(at.toUtc().subtract(excerptSpan)),
      toIso: MessageStore.isoStamp(at.toUtc().add(excerptSpan)),
    );
    final match = window.indexWhere((m) => m.id == hit.messageId);
    if (match < 0) return null;
    var from = match;
    var to = match;
    while (to - from + 1 < relatedShown && to + 1 < window.length) {
      to++;
    }
    while (to - from + 1 < relatedShown && from > 0) {
      from--;
    }
    final part = window.sublist(from, to + 1);
    return _Candidate(conversation, part, false, shown: part, excerpt: true);
  }

  /// What a related MAIL thread quotes, oldest first, at most
  /// [relatedShown]: the message that matched and the thread's newest —
  /// what was said on the subject, and where it stands now. A mail thread is
  /// one subject, so its tail is the follow-up. Filled from the newest
  /// backward when the match is already among them; the last
  /// [relatedShown] when the match is not in the thread as read.
  static List<Message> _aroundMatch(List<Message> messages, String matchId) {
    final n = messages.length;
    final picked = <int>{
      for (var i = math.max(0, n - 2); i < n; i++) i,
    };
    final match = messages.indexWhere((m) => m.id == matchId);
    if (match >= 0) picked.add(match);
    for (var i = n - 1; i >= 0 && picked.length < relatedShown; i--) {
      picked.add(i);
    }
    return [for (final i in picked.toList()..sort()) messages[i]];
  }

  /// Whether [m] was written by [p]. By address; and in a chat, which names
  /// its people by id and never by address, by the name the invite gives
  /// them — the one thing a chat message and an attendee have in common.
  static bool _wrote(Message m, BriefOther p) {
    if (m.outbound) return false;
    if ((m.fromAddress ?? '').trim().toLowerCase() == p.address) return true;
    return m.source == 'teams' &&
        p.name.isNotEmpty &&
        (m.fromName ?? '').trim().toLowerCase() == p.name.toLowerCase();
  }

  /// Whether [p] is in thread [k]: on its roster, or the writer of one of
  /// its messages. An excerpt has no roster of its own — being in the room
  /// is not being in the exchange.
  static bool _inThread(_Candidate k, BriefOther p) =>
      (!k.excerpt &&
          k.c.participants
              .any((x) => (x.email ?? '').trim().toLowerCase() == p.address)) ||
      k.messages.any((m) => _wrote(m, p));

  /// Whether the decision model read [d] as pressing: urgency high or
  /// urgent, or importance high — the Phase 3 invite-pinning rule.
  static bool _pressing(StoredDecision? d) {
    if (d == null) return false;
    final urgency = d.answers.fields['urgency']?.choice;
    final importance = d.answers.fields['importance']?.choice;
    return urgency == 'high' || urgency == 'urgent' || importance == 'high';
  }

  /// §1.1 point 1's threshold: needs-you at the owner's slider — the one
  /// rule Needs You itself reads (`needsYouAt`), so a brief's asks are the
  /// messages the stop would show — or reply-expected at the policy's yes
  /// line. The constants are fitted on the golden set and are read, never
  /// copied.
  static bool _wantsOwner(StoredDecision d, double needsYouThreshold) =>
      needsYouAt(d.needsYouP, needsYouThreshold) ||
      (d.replyExpectedP ?? 0) >= DecisionPolicy.replyYes;

  static String? _intentOf(StoredDecision? d) {
    final intent = d?.answers.fields['intent']?.choice;
    return intent != null && askIntents.contains(intent) ? intent : null;
  }

  /// The files on [chosen] (the meeting's own invite threads), newest mail
  /// first, at most [maxMaterials]: the people's and the owner's own (the deck the owner attached to the invite
  /// they sent is the likeliest thing the meeting is about), documents only
  /// — never an inline logo, a picture, a quoted message or a card. A file not read yet is
  /// still listed, so the brief can say it arrived. One material per file
  /// NAME (case-insensitive), the newest copy: the same deck re-attached on
  /// every reply is one thing to read, not six.
  static List<BriefMaterial> _materialsOf(
    List<_Candidate> chosen,
    Map<String, String> nameOf,
    CalendarZone zone,
  ) =>
      [
        for (final (m, a) in _filesOf(chosen).take(maxMaterials))
          BriefMaterial(
            source: m.source,
            messageId: m.id,
            attachmentId: a.attachmentId,
            name: (a.name ?? '').trim(),
            contentType: a.contentType ?? '',
            sender: m.outbound ? 'you' : _who(m, nameOf),
            date: _dayOf(m.receivedAt, zone),
            receivedAt: m.receivedAt ?? '',
            textStatus: a.textStatus,
            digestStatus: a.digestStatus,
            digest: a.digest,
          ),
      ];

  /// The documents on [threads]' mail, both directions, newest mail first,
  /// one per file NAME (case-insensitive, the newest copy) — never an inline
  /// logo, a picture, a quoted message or a card. [_materialsOf] and the
  /// other files ([BriefInput.otherFiles]) share the one filter.
  static Iterable<(Message, AttachmentRef)> _filesOf(
      Iterable<_Candidate> threads) sync* {
    final carrying = [
      for (final k in threads)
        for (final m in k.messages)
          if (m.attachments.isNotEmpty) m,
    ]..sort((a, b) {
        final byTime = (b.receivedAt ?? '').compareTo(a.receivedAt ?? '');
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    final seen = <String>{};
    for (final m in carrying) {
      for (final a in m.attachments) {
        final name = (a.name ?? '').trim();
        if (name.isEmpty || a.isInline) continue;
        if (a.kind != 'file' && a.kind != 'reference') continue;
        if ((a.contentType ?? '').toLowerCase().startsWith('image/')) continue;
        if (!seen.add(name.toLowerCase())) continue;
        yield (m, a);
      }
    }
  }

  /// Whether any of [materials] is still being read, and which are listed
  /// `pending` with no text work queued at all ([BriefInput.
  /// materialsPending], [BriefEligible.unqueued]). One work-row read per
  /// `pending` file and none for the rest.
  Future<({bool pending, List<({BriefMaterial material, bool young})> unqueued})>
      _readingOf(List<BriefMaterial> materials, DateTime nowUtc) async {
    var pending = false;
    final unqueued = <({BriefMaterial material, bool young})>[];
    for (final m in materials) {
      if (m.textStatus != 'pending') continue;
      final work = await _store.workRowOf(
          textKind, m.source, attachmentEntityId(m.messageId, m.attachmentId));
      if (work == null) {
        // Queued by the handler this run, so its reading starts now.
        unqueued.add((material: m, young: true));
        continue;
      }
      if (work.status != 'pending' && work.status != 'processing') continue;
      // The age is how long the file has been BEING READ: from the later of
      // its mail's arrival and its text work's first ask, so the owner's
      // invite sent days ago, whose file a fetch only now listed, is still
      // waited for. Unreadable stamps are never waited for: the age is the
      // backstop, and a file with neither cannot show it is young.
      final at = _later(DateTime.tryParse(m.receivedAt),
          DateTime.tryParse(work.createdAt));
      if (at != null && nowUtc.difference(at.toUtc()) < pendingMaxAge) {
        pending = true;
      }
    }
    return (pending: pending, unqueued: unqueued);
  }

  static DateTime? _later(DateTime? a, DateTime? b) =>
      a == null ? b : (b == null || a.isAfter(b) ? a : b);

  /// Queues the text work [materials] are owed, and says how many it asked
  /// for. `enqueueWork` is INSERT OR IGNORE, so a second ask changes
  /// nothing.
  Future<int> queueText(List<BriefMaterial> materials) async {
    for (final m in materials) {
      await _store.enqueueWork(
          textKind, m.source, attachmentEntityId(m.messageId, m.attachmentId));
    }
    return materials.length;
  }

  /// [materials] with the text of each file that has been read, cut at a
  /// word to [materialTextCap] with its runs of spaces and blank lines
  /// closed up (an extracted deck is mostly layout). A store error leaves
  /// that file without text: the digest still says what it is.
  Future<List<BriefMaterial>> _withText(List<BriefMaterial> materials) async {
    final out = <BriefMaterial>[];
    for (final m in materials) {
      if (m.textStatus != 'done') {
        out.add(m);
        continue;
      }
      try {
        final raw = await _store.attachmentTextOf(
            m.source, m.messageId, m.attachmentId);
        final text = (raw ?? '')
            .replaceAll(RegExp(r'[ \t]+'), ' ')
            .replaceAll(RegExp(r'\s*\n\s*\n\s*'), '\n\n')
            .trim();
        out.add(text.isEmpty
            ? m
            : m.withText(capAtWord(text, materialTextCap),
                cut: text.length > materialTextCap));
      } on Object catch (e) {
        debugPrint('BriefGatherer: no material text (${e.runtimeType})');
        out.add(m);
      }
    }
    return out;
  }

  /// The people block: [others] in the order given (the organiser first),
  /// each with what the
  /// mail and the calendar say of them. Their newest inbound message is
  /// looked for in [chosen] only — the threads the brief is written from —
  /// and its quoted history is cut off ([askOwnWords]) before it is capped,
  /// so what they last wrote is theirs.
  Future<List<BriefPerson>> _peopleOf(
    CalendarEvent event,
    List<BriefOther> others,
    List<_Candidate> chosen,
    Map<String, String> askOf, {
    required DateTime nowUtc,
    required CalendarZone zone,
    required CalendarDate today,
  }) async {
    final organiser = event.organizerAddress.trim().toLowerCase();
    final answers = {
      for (final a in event.attendees) a.address.trim().toLowerCase(): a.response,
    };
    final out = <BriefPerson>[];
    for (final p in others) {
      var threadCount = 0;
      Message? newest;
      String newestSubject = '';
      for (final k in chosen) {
        if (!_inThread(k, p)) continue;
        threadCount++;
        for (final m in k.messages) {
          if (!_wrote(m, p)) continue;
          if (newest == null ||
              (m.receivedAt ?? '').compareTo(newest.receivedAt ?? '') > 0) {
            newest = m;
            newestSubject = (k.c.subject ?? '').trim();
          }
        }
      }
      final words = newest == null ? '' : _ownWords(newest);
      final met = await _calendar.lastMetWith([p.address], nowUtc: nowUtc);
      out.add(BriefPerson(
        name: p.name.isNotEmpty ? p.name : p.address,
        address: p.address,
        org: briefOrgOf(p.address),
        isOrganizer: organiser.isNotEmpty && p.address == organiser,
        response: event.isOrganizer
            ? _answerWords(answers[p.address])
            : 'response not known',
        lastMet: met == null ? null : lastMetLabel(met, zone: zone, today: today),
        threadCount: threadCount,
        lastInboundAgo:
            newest == null ? '' : briefAgo(newest.receivedAt ?? '', nowUtc),
        lastSubject: newestSubject,
        lastWords: words.isEmpty
            ? ''
            : wrapUntrusted('last_words', capAtWord(words, lastWordsCap)),
        openAsk: askOf[p.address] ?? '',
      ));
    }
    return out;
  }

  /// An attendee's answer on the owner's organiser copy, in words.
  static String _answerWords(String? response) =>
      switch (response?.trim().toLowerCase()) {
        'accepted' => 'accepted',
        'tentativelyaccepted' => 'tentative',
        'declined' => 'declined',
        _ => 'no answer yet',
      };

  /// The mail messages on [chosen] whose files are not listed yet, newest
  /// first, at most [maxUnlisted]: the row says it carries attachments and
  /// `loadThread` hydrated none. Mail only — a chat's files arrive with the
  /// message.
  static List<({String source, String messageId})> _unlistedOf(
      List<_Candidate> chosen) {
    final unlisted = [
      for (final k in chosen)
        for (final m in k.messages)
          if (m.source == 'email' && m.hasAttachments && m.attachments.isEmpty)
            m,
    ]..sort((a, b) {
        final byTime = (b.receivedAt ?? '').compareTo(a.receivedAt ?? '');
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    return [
      for (final m in unlisted.take(maxUnlisted))
        (source: m.source, messageId: m.id),
    ];
  }

  /// `yyyy-MM-dd` of [iso] in [zone] — the day the owner saw the mail
  /// arrive, not the UTC day. '' for an empty or unreadable stamp.
  static String _dayOf(String? iso, CalendarZone zone) {
    final at = DateTime.tryParse(iso ?? '');
    if (at == null) return '';
    final d = zone.dateOf(at.toUtc());
    return DateFormat('yyyy-MM-dd').format(DateTime(d.year, d.month, d.day));
  }

  /// [materials] with the passages of their text nearest the meeting: the
  /// subject and the invite's preview embedded as a document — the
  /// retriever's rule, since chunks are documents too — and searched only
  /// among these files' chunks, never the mailbox. The digest chunk comes out
  /// (it is a model's summary, already shown as the digest), and no file
  /// keeps more than [passagesPerMaterial] of its [passageLimit] nearest.
  ///
  /// Every failure — no embedding client, no server, no index, a store
  /// error — returns [materials] as they were. Passages make a brief better;
  /// they are never a reason for there to be none.
  Future<List<BriefMaterial>> _withPassages(
    CalendarEvent event,
    List<BriefMaterial> materials,
  ) async {
    final embeddings = _embeddings;
    if (embeddings == null || materials.isEmpty) return materials;
    try {
      Uint8List? query;
      var asked = false;
      final out = <BriefMaterial>[];
      for (final m in materials) {
        // The attachment id alone scopes the read: the message's id would
        // widen it (an OR) to every other file on that message.
        if (!await _store.hasAttachmentChunks(m.source,
            attachmentIds: [m.attachmentId])) {
          out.add(m);
          continue;
        }
        // Embedded once, on the first file that has passages at all.
        if (!asked) {
          asked = true;
          final vector = (await embeddings.embedResult(
            '${event.subject}\n${event.bodyPreview}',
            prefix: EmbeddingsClient.documentPrefix,
          ))
              .vector;
          query = vector == null ? null : encodeEmbedding(vector);
        }
        final q = query;
        // No vector — the server is down or refused the text — means no
        // passages for ANY file: the same answer for the rest, so stop here
        // rather than ask the index a question with nothing to compare.
        if (q == null) return materials;
        // One search per file, so a long deck cannot fill the shortlist and
        // leave the others none.
        final hits = await _store.chunkKnn(
          q,
          embedModel: EmbeddingsClient.documentModelTag,
          source: m.source,
          attachmentIds: [m.attachmentId],
          limit: passageLimit,
        );
        final kept = <String>[];
        for (final hit in hits ?? const <AttachmentChunkHit>[]) {
          if (kept.length >= passagesPerMaterial) break;
          if (hit.locator == 'digest') continue;
          // An attachment id is not unique across messages, so the hit must
          // be THIS file, message and all.
          if (hit.ref.messageId != m.messageId ||
              hit.ref.attachmentId != m.attachmentId) {
            continue;
          }
          kept.add(wrapUntrusted(
            'passage',
            _cap('[${hit.locator}] ${hit.text}', passageCap),
          ));
        }
        out.add(kept.isEmpty ? m : m.withPassages(kept));
      }
      return out;
    } on Object catch (e) {
      debugPrint('BriefGatherer: no passages (${e.runtimeType})');
      return materials;
    }
  }

  static String _who(Message m, Map<String, String> nameOf) {
    if (m.outbound) return 'You';
    final from = (m.fromAddress ?? '').trim().toLowerCase();
    final name = nameOf[from] ?? (m.fromName ?? '').trim();
    return name.isNotEmpty ? name : (from.isNotEmpty ? from : 'Someone');
  }

  /// A message's words as one line: the body (else the sender-side preview)
  /// with the app's attachment markers and link targets out and every run of
  /// whitespace one space — a snippet is there to show what was said, not how
  /// it was laid out.
  static String _plain(Message m) {
    final raw = (m.bodyText?.isNotEmpty ?? false)
        ? m.bodyText!
        : (m.bodyPreview ?? '');
    return stripLinkTargets(stripAttachmentMarkers(raw))
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// A message's own words as one line: [_plain]'s cleaning, but cut at the
  /// first quoted-reply header first, which needs the line breaks [_plain]
  /// closes up.
  static String _ownWords(Message m) {
    final raw = (m.bodyText?.isNotEmpty ?? false)
        ? m.bodyText!
        : (m.bodyPreview ?? '');
    return askOwnWords(stripLinkTargets(stripAttachmentMarkers(raw)))
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _cap(String s, int cap) => capRunes(s, cap);

  /// sha256 over every input that could change what the brief says: the
  /// event's version and times, the owner, and the ids and stamps of every
  /// thread, ask and material. The snippets are not hashed — a thread whose
  /// newest message changed moved its stamp and its count. A storyline's
  /// text is: a recap is rewritten in place, and neither its id nor any
  /// stamp moves when it falls back to a rewritten summary. A material's
  /// text and digest states are, so a deck whose words or digest land after
  /// the first brief moves the hash; its name is not — a rename says nothing
  /// new. Passages are not: they follow from the text, which is hashed. An
  /// other file's lower-cased name is: a new file with these people changes
  /// what the brief is told.
  ///
  /// On the [BriefPath.related] path ONLY, two lines follow the owner's:
  /// `path|related` and `related|<state>` (`_relatedOf`'s `ok`, `off`,
  /// `no_query` or `unavailable`), so a search that comes back moves the
  /// hash. The people path adds nothing: its hash is byte for byte the one
  /// it was before there were two paths, and no small meeting's brief is
  /// rewritten by the upgrade.
  static String _hash({
    required CalendarEvent event,
    required String? owner,
    required BriefPath path,
    required String? relatedState,
    required List<BriefThread> threads,
    required List<BriefAsk> asks,
    required List<BriefStoryline> storylines,
    required List<BriefMaterial> materials,
    required List<String> otherFiles,
  }) {
    final lines = <String>[
      'event|${event.id}|${event.changeKey}',
      'start|${event.startUtc?.toIso8601String() ?? event.startDate?.toIso() ?? ''}',
      'end|${event.endUtc?.toIso8601String() ?? event.endDate?.toIso() ?? ''}',
      'owner|${owner ?? ''}',
      if (path == BriefPath.related) ...[
        'path|${path.wire}',
        'related|${relatedState ?? ''}',
      ],
      for (final t in threads)
        'thread|${t.source}|${t.conversationKey}|${t.lastAt}|${t.messageCount}',
      for (final a in asks) 'ask|${a.messageId}',
      for (final s in storylines)
        'storyline|${s.id}|${sha256.convert(utf8.encode(s.summary))}',
      for (final m in materials)
        'material|${m.messageId}|${m.attachmentId}|${m.textStatus}|'
            '${m.digestStatus}',
      for (final f in otherFiles) 'otherfile|${f.toLowerCase()}',
    ];
    return sha256.convert(utf8.encode(lines.join('\n'))).toString();
  }
}

class _Candidate {
  _Candidate(
    this.c,
    this.messages,
    this.ranked, {
    this.shown,
    this.excerpt = false,
  });
  final Conversation c;
  final List<Message> messages;
  final bool ranked;

  /// The messages the brief quotes, oldest first; null for the thread's
  /// last two (an invite thread, a people-path thread).
  final List<Message>? shown;

  /// Whether [messages] is a part of a chat ([BriefThread.excerpt]).
  final bool excerpt;

  List<Message> get quoted =>
      shown ?? messages.sublist(math.max(0, messages.length - 2));

  _Candidate showing(List<Message> shown) =>
      _Candidate(c, messages, ranked, shown: shown, excerpt: excerpt);
}

extension<T> on List<T> {
  T? lastWhereOrNull(bool Function(T) test) {
    for (var i = length - 1; i >= 0; i--) {
      if (test(this[i])) return this[i];
    }
    return null;
  }
}
