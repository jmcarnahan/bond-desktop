import '../../models/calendar_models.dart';

/// Which way a brief's threads are found. [wire] is the word the hash (and,
/// later, the stored brief) carries — an enum word, never anything about the
/// meeting.
///
/// [people]: the meeting's own invite threads, then the newest mail with any
/// of its people, matched by address. Precise while the room is small; from
/// six others up it is the newest mail with anyone in the room, which says
/// little about the meeting.
///
/// [related]: the invite threads, then the threads whose text is nearest the
/// meeting's subject and description, mail and Teams alike, whoever is on
/// them.
enum BriefPath {
  people('people'),
  related('related');

  const BriefPath(this.wire);
  final String wire;
}

/// The most other people a meeting may have and still be briefed from the
/// mail with them. At six the twenty-candidate pool fills with whatever
/// anyone in the room last wrote, and the nearest threads by meaning do
/// better on both precision and recall; a blend of the two between six and
/// nine did not beat the plain switch.
const int briefPeopleMax = 5;

/// The most other people a TOPICLESS meeting ([briefIsTopicless]) may have
/// and still be briefed from the mail with them: with no subject to search
/// by, the people are all there is, which is how such a meeting was briefed
/// before there were two paths.
const int briefTopiclessPeopleMax = 15;

/// How long an invite's own words ([briefAgendaOf]) must be to count as an
/// agenda: shorter, and a generic subject leaves the meeting topicless.
const int briefAgendaMin = 40;

/// The words that make an address's local part a distribution list when they
/// are its first or last token.
const Set<String> _listTokens = {
  'dl',
  'dist',
  'team',
  'all',
  'everyone',
  'staff',
  'group',
  'grp',
  'list',
  'allhands',
  'allstaff',
};

/// Whether [address] looks like a distribution list rather than a person:
/// its local part, lowercased and split on `-`, `_`, `.` and `+`, starts or
/// ends with a list word (`dl-eng@`, `team@`, `eng-team@`, `all-hands@`) —
/// never a word that merely begins with one (`dlopez@`, `allen@`,
/// `teamster@`). One list in the room means the room is bigger than its
/// count, so the meeting takes the [BriefPath.related] path.
///
/// A heuristic chosen a priori and unmeasured, tested on fictional fixtures
/// only, and English only.
bool briefLooksLikeList(String address) {
  final at = address.indexOf('@');
  final local = (at < 0 ? address : address.substring(0, at)).toLowerCase();
  final tokens = [
    for (final t in local.split(RegExp(r'[-_.+]')))
      if (t.isNotEmpty) t,
  ];
  if (tokens.isEmpty) return false;
  return _listTokens.contains(tokens.first) ||
      _listTokens.contains(tokens.last);
}

/// Where the join boilerplate a meeting tool appends to an invite begins:
/// a rule of eight or more `_`, `-` or `=`, or one of the Teams, Zoom, Meet
/// and Webex join lines.
final RegExp _joinBoilerplate = RegExp(
  r'[_\-=]{8,}'
  r'|Microsoft Teams meeting'
  r'|Microsoft Teams Need help'
  r'|Join the meeting now'
  r'|Join on your computer'
  r'|Join Zoom Meeting'
  r'|is inviting you to a scheduled Zoom meeting'
  r'|Join with Google Meet'
  r'|Join Webex meeting'
  r'|Meeting ID:'
  r'|Click here to join'
  r'|Do not delete or change any of the following text',
  caseSensitive: false,
);

final RegExp _url = RegExp(r'https?://\S+');
final RegExp _whitespace = RegExp(r'\s+');

/// The invite's own words: [bodyPreview] cut at the first join-boilerplate
/// marker (a rule of eight or more `_`, `-` or `=`; the Teams, Zoom, Meet
/// and Webex join lines; "Meeting ID:"), its links taken out and its
/// whitespace closed up. A join block is the same few hundred characters on
/// every invite, so left in it would make every meeting look like it has an
/// agenda and pull every query toward every other meeting.
///
/// A heuristic chosen a priori and unmeasured, tested on fictional fixtures
/// only, and English only.
String briefAgendaOf(String bodyPreview) {
  final cut = _joinBoilerplate.firstMatch(bodyPreview);
  final head = cut == null ? bodyPreview : bodyPreview.substring(0, cut.start);
  return head.replaceAll(_url, ' ').replaceAll(_whitespace, ' ').trim();
}

/// The subject words that say nothing about what a meeting is FOR: cadence,
/// the kind of meeting, connectives and weekdays.
const Set<String> _genericSubjectWords = {
  'sync', 'syncup', 'standup', 'stand', 'up', 'daily', 'weekly',
  'biweekly', 'bi', 'monthly', 'quarterly', 'fortnightly', 'recurring',
  'regular', 'series', '1on1', '121', 'one', 'on', 'o3', 'check', 'in',
  'checkin', 'catch', 'catchup', 'touch', 'base', 'touchpoint', 'meeting',
  'mtg', 'call', 'chat', 'connect', 'huddle', 'team', 'staff', 'tgif',
  'coffee', 'lunch', 'office', 'hours', 'hold', 'placeholder', 'intro',
  'quick', 'time', 'block', 'and', 'with', 'the', 'an', 'of', 'for', 'to',
  'vs', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday',
  'sunday',
};

final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final RegExp _allDigits = RegExp(r'^[0-9]+$');

List<String> _wordsOf(String s) => [
      for (final t in s.toLowerCase().split(_nonWord))
        if (t.isNotEmpty) t,
    ];

/// Whether [e] gives nothing to search by: its own words ([briefAgendaOf])
/// are shorter than [briefAgendaMin] AND its subject has no content word. A
/// word is not content when it is one character, all digits, part of a
/// name in the meeting (the organiser's or any attendee's, the owner's row
/// included), or one of the generic meeting words ("weekly", "sync", "1:1",
/// "catch up", a weekday). So `1:1 | Dana & Sam | Weekly` with Dana and Sam
/// in it, `Daily sync` and `TGIF` are topicless; `Budget` and `Falcon
/// weekly` are not. An empty subject is topicless.
///
/// A heuristic chosen a priori and unmeasured, tested on fictional fixtures
/// only, and English only.
bool briefIsTopicless(CalendarEvent e) {
  if (briefAgendaOf(e.bodyPreview).length >= briefAgendaMin) return false;
  final names = {
    ..._wordsOf(e.organizerName),
    for (final a in e.attendees) ..._wordsOf(a.name),
  };
  for (final t in _wordsOf(e.subject)) {
    if (t.length <= 1 || _allDigits.hasMatch(t)) continue;
    if (names.contains(t) || _genericSubjectWords.contains(t)) continue;
    return false;
  }
  return true;
}

/// The path [e]'s brief takes, given the addresses of everyone in it but the
/// owner ([otherAddresses], `briefOthers`' addresses): [BriefPath.people]
/// for at most [briefPeopleMax] others none of whom is a list
/// ([briefLooksLikeList]), and for a topicless meeting ([briefIsTopicless])
/// of at most [briefTopiclessPeopleMax] others, which has nothing else to
/// search by; [BriefPath.related] for everything else.
BriefPath briefPathOf(CalendarEvent e, {required List<String> otherAddresses}) {
  if (otherAddresses.length <= briefPeopleMax &&
      !otherAddresses.any(briefLooksLikeList)) {
    return BriefPath.people;
  }
  if (otherAddresses.length <= briefTopiclessPeopleMax && briefIsTopicless(e)) {
    return BriefPath.people;
  }
  return BriefPath.related;
}

/// What the [BriefPath.related] search embeds for [e]: its subject, then on
/// a line of its own the invite's own words ([briefAgendaOf]), each with its
/// runs of whitespace closed up; '' when both are empty. Subject and
/// description only, because that is the query the relatedness floor was
/// calibrated on: a longer one (the invite mail's body, a file's digest)
/// moves the whole cosine scale.
String briefQueryText(CalendarEvent e) {
  final subject = e.subject.replaceAll(_whitespace, ' ').trim();
  final agenda = briefAgendaOf(e.bodyPreview);
  return [
    if (subject.isNotEmpty) subject,
    if (agenda.isNotEmpty) agenda,
  ].join('\n');
}

final RegExp _replyPrefixes =
    RegExp(r'^\s*((re|fw|fwd)\s*:\s*)+', caseSensitive: false);

/// The subject openings calendar logistics mail carries: an answer, a
/// cancellation, an invitation or its update, a proposal, an auto-reply.
const List<String> _logisticsOpenings = [
  'accepted:',
  'tentative:',
  'tentatively accepted:',
  'declined:',
  'canceled:',
  'cancelled:',
  'invitation:',
  'updated invitation',
  'new time proposed',
  'automatic reply',
];

/// Whether [subject] is calendar logistics rather than talk about a topic:
/// after any leading `Re:` / `Fw:` / `Fwd:` run it opens (case-insensitive)
/// with an answer (`Accepted:`, `Tentative:`, `Declined:`), a cancellation,
/// an invitation or its update, `New time proposed` or `Automatic reply`.
/// Such a thread sits close to the meeting's subject by construction — it
/// repeats it — and says nothing about it, so the related search drops it.
///
/// A heuristic chosen a priori and unmeasured, tested on fictional fixtures
/// only, and English only.
bool briefIsLogisticsSubject(String subject) {
  final s = subject.replaceFirst(_replyPrefixes, '').trimLeft().toLowerCase();
  return _logisticsOpenings.any(s.startsWith);
}
