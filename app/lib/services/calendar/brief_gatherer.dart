import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:intl/intl.dart' show DateFormat;

import '../../data/calendar_store.dart';
import '../../data/message_store.dart';
import '../../models/calendar_models.dart';
import '../../models/message_models.dart';
import '../decision/decision_policy.dart';
import '../decision/stored_decision.dart';
import '../attachments/attachment_markers.dart';
import '../html_text.dart' show stripLinkTargets;
import '../llm/prompt_guard.dart';
import 'calendar_zone.dart';
import 'day_items.dart' show formatEventRange;
import 'event_view.dart' show lastMetLabel;

/// Why a meeting gets no brief (D6). [wire] is the word a stored row and an
/// activity row carry — an enum word, never anything about the meeting.
enum BriefIneligibility {
  past('past'),
  tooFar('too_far'),
  noOthers('no_others'),
  cancelled('cancelled'),
  declined('declined'),
  noMail('no_mail'),

  /// More than [briefMaxOthers] other people: a town hall or an all-hands,
  /// where the mail with any one of them says nothing about the meeting.
  tooMany('too_many'),

  /// The event is no longer in the mirror. Only the handler says this: the
  /// gatherer is always handed an event.
  gone('gone');

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

  const BriefThread({
    required this.source,
    required this.conversationKey,
    required this.subject,
    required this.state,
    required this.lastAt,
    this.messageCount = 0,
    this.snippets = const [],
    this.ranked = false,
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

  /// Attachment names from the attendees' messages in [threads]. Raw.
  final List<String> files;

  /// "Last met 3 days ago", or null when the mirror holds no earlier meeting
  /// with any of them.
  final String? lastMet;

  /// The invite's `body_preview`, fenced and capped; null when it has none.
  final String? invitePreview;

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
    this.files = const [],
    this.lastMet,
    this.invitePreview,
    required this.inputsHash,
  });
}

/// What [BriefGatherer.gather] found.
sealed class BriefGather {
  const BriefGather();
}

final class BriefEligible extends BriefGather {
  final BriefInput input;
  const BriefEligible(this.input);
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

/// One other person in a meeting.
typedef BriefPerson = ({String name, String address});

/// How far ahead a meeting is briefed (D6).
const Duration briefHorizon = Duration(hours: 36);

/// How far back the mail with its people is read (D6).
const Duration briefMailWindow = Duration(days: 30);

/// The most other people a briefed meeting may have. Past it the meeting is
/// a broadcast, and a brief built from whoever the owner last wrote to among
/// forty people would misdescribe it.
const int briefMaxOthers = 15;

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
/// Nobody's RESPONSE is read here or anywhere in a brief. Only the
/// organiser's copy tracks answers; on an attendee's copy `none` means "not
/// known", never "hasn't answered", so the brief says nothing about who is
/// coming rather than risk saying something false.
List<BriefPerson> briefOthers(CalendarEvent e, {required String? owner}) {
  final seen = <String>{};
  final out = <BriefPerson>[];
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
/// would give them: cancelled, declined, started, too far off, nobody else,
/// too many people.
/// Null when the meeting passes them all — the mail rule is the gatherer's.
///
/// Pure, so the planner can skip a meeting before a single read and the event
/// panel can say why a meeting has no brief before anything is stored.
BriefIneligibility? briefQuickCheck(
  CalendarEvent e, {
  required String? owner,
  required DateTime now,
  required CalendarZone zone,
}) {
  if (e.isCancelled) return BriefIneligibility.cancelled;
  if (e.responseStatus.trim().toLowerCase() == 'declined') {
    return BriefIneligibility.declined;
  }
  final start = briefStartOf(e, zone);
  final nowUtc = now.toUtc();
  if (start == null || !start.isAfter(nowUtc)) return BriefIneligibility.past;
  if (start.isAfter(nowUtc.add(briefHorizon))) return BriefIneligibility.tooFar;
  final ownerKey = owner?.trim().toLowerCase();
  final others = briefOthers(e, owner: ownerKey);
  if (others.isEmpty) return BriefIneligibility.noOthers;
  if (others.length > briefMaxOthers) return BriefIneligibility.tooMany;
  return null;
}

/// Collects what a pre-meeting brief is written from. Deterministic and
/// model-free: store reads only, so the planner can afford to run it for
/// every meeting in the window just to learn whether anything changed.
///
/// Always handed the OCCURRENCE to brief. A series master carries the
/// series' first meeting's times; the planner targets occurrence ids (the
/// mirror's rows) and never a master, and the handler turns a master it is
/// given into its `displayOccurrence` before it gets here.
///
/// Mail only for now. The people are matched by ADDRESS against a
/// conversation's `participants_json`, and a Teams chat stores its people as
/// `teams:<id>`, not addresses, so no chat is ever matched; mapping them
/// through the people directory is a follow-up. `participants_json` also
/// holds at most eight people per conversation, so an attendee beyond the
/// eighth in a busy thread is not matched by that thread.
class BriefGatherer {
  BriefGatherer(
    this._store,
    this._calendar, {
    required this._ownerAddress,
    required this._zone,
  });

  final MessageStore _store;
  final CalendarStore _calendar;
  final Future<String?> Function() _ownerAddress;
  final CalendarZone Function() _zone;

  static const int maxThreads = 6;
  static const int maxAsks = 4;
  static const int maxWaiting = 3;
  static const int maxStorylines = 2;
  static const int maxFiles = 8;

  /// How many conversations are read to rank. Each costs a thread read, and
  /// twenty is more mail with a meeting's people in a month than six slots
  /// can use.
  static const int candidateLimit = 20;

  static const int snippetCap = 600;
  static const int askCap = 300;
  static const int storylineCap = 400;
  static const int invitePreviewCap = 600;

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

  Future<BriefGather> gather(
    CalendarEvent event, {
    required DateTime now,
  }) async {
    final owner = await this.owner();
    // Unknown, the owner's own attendee row counts as somebody else, and a
    // meeting with nobody would be briefed as one with them. The worker
    // retries it; the keychain answers soon after launch.
    if (owner == null) throw const BriefOwnerUnknown();
    final zone = _zone();
    final nowUtc = now.toUtc();
    final quick = briefQuickCheck(event, owner: owner, now: nowUtc, zone: zone);
    if (quick != null) return BriefIneligible(quick);

    final others = briefOthers(event, owner: owner);
    final addresses = {for (final p in others) p.address};
    final nameOf = {
      for (final p in others)
        if (p.name.isNotEmpty) p.address: p.name,
    };

    final conversations = await _store.conversationsWithAddresses(
      addresses,
      sinceIso: MessageStore.isoStamp(nowUtc.subtract(briefMailWindow)),
      limit: candidateLimit,
    );
    if (conversations.isEmpty) return const BriefIneligible(BriefIneligibility.noMail);

    // One read per candidate: its messages, and the decision on its newest
    // inbound message, which is what the ranking turns on.
    final decisions = <String, StoredDecision?>{};
    Future<StoredDecision?> decisionOf(Message m) async {
      final key = '${m.source}\u0000${m.id}';
      if (decisions.containsKey(key)) return decisions[key];
      return decisions[key] = await _store.decisionFor(m.source, m.id);
    }

    final candidates = <_Candidate>[];
    for (final c in conversations) {
      final messages = await _store.loadThread(c.id, sources: [c.source]);
      final latestIn = messages.lastWhereOrNull((m) => !m.outbound);
      final decision = latestIn == null ? null : await decisionOf(latestIn);
      candidates.add(_Candidate(c, messages, _pressing(decision)));
    }
    // Urgent or important first, then the most recently active; the
    // conversation key breaks a tie so the same mail always ranks one way.
    candidates.sort((a, b) {
      if (a.ranked != b.ranked) return a.ranked ? -1 : 1;
      final byTime =
          (b.c.lastMessageAt ?? '').compareTo(a.c.lastMessageAt ?? '');
      return byTime != 0 ? byTime : a.c.id.compareTo(b.c.id);
    });
    final chosen = candidates.take(maxThreads).toList();

    final threads = [
      for (final k in chosen)
        BriefThread(
          source: k.c.source,
          conversationKey: k.c.id,
          subject: (k.c.subject ?? '').trim(),
          state: k.c.state.wire,
          lastAt: k.c.lastMessageAt ?? '',
          messageCount: k.c.messageCount,
          snippets: [
            for (final m in k.messages.sublist(math.max(0, k.messages.length - 2)))
              if (_plain(m).isNotEmpty)
                wrapUntrusted(
                  'message',
                  _cap('${_who(m, nameOf)}: ${_plain(m)}', snippetCap),
                ),
          ],
          ranked: k.ranked,
        ),
    ];

    // Open asks: inbound messages from an attendee, in a thread still waiting
    // on the owner, that the decision model says want the owner or a reply,
    // labelled by intent. Only what came AFTER the owner's last message in
    // the thread: an ask before a reply is taken to have been answered. The
    // newest qualifying one per thread.
    final asks = <BriefAsk>[];
    for (var i = 0; i < chosen.length && asks.length < maxAsks; i++) {
      final k = chosen[i];
      if (k.c.state != ConversationState.needsReply) continue;
      final lastOut = k.messages.lastIndexWhere((m) => m.outbound);
      for (var j = k.messages.length - 1; j > lastOut; j--) {
        final m = k.messages[j];
        final from = (m.fromAddress ?? '').trim().toLowerCase();
        if (m.outbound || !addresses.contains(from)) continue;
        final d = await decisionOf(m);
        final intent = _intentOf(d);
        if (d == null || intent == null || !_wantsOwner(d)) continue;
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
        break;
      }
    }

    final waitingOn = [
      for (var i = 0; i < chosen.length; i++)
        if (chosen[i].c.state == ConversationState.waiting &&
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

    // The files the attendees sent — never the owner's own, and never an
    // inline logo, a quoted message or a card, which are not documents.
    final files = <String>[];
    final seenFiles = <String>{};
    for (final k in chosen) {
      for (final m in k.messages) {
        if (m.outbound) continue;
        for (final a in m.attachments) {
          final name = (a.name ?? '').trim();
          if (name.isEmpty || a.isInline) continue;
          if (a.kind == 'message_reference' || a.kind == 'card') continue;
          if (files.length < maxFiles && seenFiles.add(name.toLowerCase())) {
            files.add(name);
          }
        }
      }
    }

    final today = zone.dateOf(nowUtc);
    final met = await _calendar.lastMetWith(addresses, nowUtc: nowUtc);
    final preview = event.bodyPreview.trim();

    final inputsHash = _hash(
      event: event,
      owner: owner,
      threads: threads,
      asks: asks,
      storylines: storylines,
      files: files,
    );

    return BriefEligible(BriefInput(
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
      files: files,
      lastMet: met == null ? null : lastMetLabel(met, zone: zone, today: today),
      invitePreview: preview.isEmpty
          ? null
          : wrapUntrusted('invite', _cap(preview, invitePreviewCap)),
      inputsHash: inputsHash,
    ));
  }

  /// Whether the decision model read [d] as pressing: urgency high or
  /// urgent, or importance high — the Phase 3 invite-pinning rule.
  static bool _pressing(StoredDecision? d) {
    if (d == null) return false;
    final urgency = d.answers.fields['urgency']?.choice;
    final importance = d.answers.fields['importance']?.choice;
    return urgency == 'high' || urgency == 'urgent' || importance == 'high';
  }

  /// §1.1 point 1's threshold: needs-you or reply-expected at the policy's
  /// yes line. The constants are fitted on the golden set and are read, never
  /// copied.
  static bool _wantsOwner(StoredDecision d) =>
      (d.needsYouP ?? 0) >= DecisionPolicy.needsYouYes ||
      (d.replyExpectedP ?? 0) >= DecisionPolicy.replyYes;

  static String? _intentOf(StoredDecision? d) {
    final intent = d?.answers.fields['intent']?.choice;
    return intent != null && askIntents.contains(intent) ? intent : null;
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

  static String _cap(String s, int cap) => capRunes(s, cap);

  /// sha256 over every input that could change what the brief says: the
  /// event's version and times, the owner, and the ids and stamps of every
  /// thread, ask and file. The snippets are not hashed — a thread whose
  /// newest message changed moved its stamp and its count. A storyline's
  /// text is: a recap is rewritten in place, and neither its id nor any
  /// stamp moves when it falls back to a rewritten summary.
  static String _hash({
    required CalendarEvent event,
    required String? owner,
    required List<BriefThread> threads,
    required List<BriefAsk> asks,
    required List<BriefStoryline> storylines,
    required List<String> files,
  }) {
    final lines = <String>[
      'event|${event.id}|${event.changeKey}',
      'start|${event.startUtc?.toIso8601String() ?? event.startDate?.toIso() ?? ''}',
      'end|${event.endUtc?.toIso8601String() ?? event.endDate?.toIso() ?? ''}',
      'owner|${owner ?? ''}',
      for (final t in threads)
        'thread|${t.source}|${t.conversationKey}|${t.lastAt}|${t.messageCount}',
      for (final a in asks) 'ask|${a.messageId}',
      for (final s in storylines)
        'storyline|${s.id}|${sha256.convert(utf8.encode(s.summary))}',
      for (final f in files) 'file|$f',
    ];
    return sha256.convert(utf8.encode(lines.join('\n'))).toString();
  }
}

class _Candidate {
  _Candidate(this.c, this.messages, this.ranked);
  final Conversation c;
  final List<Message> messages;
  final bool ranked;
}

extension<T> on List<T> {
  T? lastWhereOrNull(bool Function(T) test) {
    for (var i = length - 1; i >= 0; i--) {
      if (test(this[i])) return this[i];
    }
    return null;
  }
}
