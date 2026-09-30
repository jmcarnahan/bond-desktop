import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/command/command_lexicon.dart';
import 'package:bond_inbox/services/calendar/command/command_types.dart';
import 'package:bond_inbox/services/calendar/when_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

/// The command bar's first reader: which action a phrasing names, and how
/// sure the rules are. Fictional phrasings only.
void main() {
  setUpAll(() async {
    await initCalendarZones();
  });

  // ~60 phrasings, at least five per action, plus the non-commands.
  const table = <String, CommandAction>{
    // create
    'schedule a design sync with Dana Thursday 3pm': CommandAction.create,
    'book lunch with Lee tomorrow': CommandAction.create,
    'set up a call with the fabrikam team next week': CommandAction.create,
    'Please setup a 1:1 with Dana': CommandAction.create,
    'block off Friday afternoon for focus': CommandAction.create,
    'put in a review with Priya on Monday': CommandAction.create,
    'new meeting with Sam at 2pm': CommandAction.create,
    'can you book "Quarterly plan" Tue 10am': CommandAction.create,
    // move
    'move my 3pm to Thursday': CommandAction.move,
    'push the design sync to 4pm': CommandAction.move,
    'reschedule tomorrow\'s 1:1 with Dana': CommandAction.move,
    'shift my standup to 9:30': CommandAction.move,
    'bump the contoso call to next week': CommandAction.move,
    'postpone Friday\'s review': CommandAction.move,
    'could you move my 3pm with Dana to tomorrow morning': CommandAction.move,
    'maybe move my 3pm': CommandAction.move,
    // cancel
    'cancel my 4pm': CommandAction.cancel,
    'drop the design sync on Thursday': CommandAction.cancel,
    'delete tomorrow\'s standup': CommandAction.cancel,
    'call off the offsite': CommandAction.cancel,
    'remove the fabrikam review': CommandAction.cancel,
    // rsvp yes
    'accept the design review invite': CommandAction.rsvpYes,
    'yes to Dana\'s offsite': CommandAction.rsvpYes,
    'I\'ll be there for the Thursday sync': CommandAction.rsvpYes,
    'say yes to the contoso kickoff': CommandAction.rsvpYes,
    'I will be there Friday': CommandAction.rsvpYes,
    // rsvp no
    'decline the budget review': CommandAction.rsvpNo,
    'can\'t make the 3pm with Lee': CommandAction.rsvpNo,
    'I cannot make Friday\'s retro': CommandAction.rsvpNo,
    'say no to the fabrikam lunch': CommandAction.rsvpNo,
    'turn down the Tuesday invite': CommandAction.rsvpNo,
    'I can’t make tomorrow’s standup': CommandAction.rsvpNo,
    // rsvp maybe
    'tentative for the design review': CommandAction.rsvpMaybe,
    'tentatively accept the offsite': CommandAction.rsvpMaybe,
    'say maybe to Dana\'s invite': CommandAction.rsvpMaybe,
    'maybe to the Thursday sync': CommandAction.rsvpMaybe,
    'mark the kickoff tentative': CommandAction.rsvpMaybe,
    // find a time
    'find time with Dana next week': CommandAction.findTime,
    'find a time with Lee and Priya': CommandAction.findTime,
    'find 30 min with Dana tomorrow': CommandAction.findTime,
    'find an hour with the contoso folks': CommandAction.findTime,
    'when can Dana and I meet': CommandAction.findTime,
    'what\'s a good time for Sam this week': CommandAction.findTime,
    'when am I free with Dana': CommandAction.findTime,
    // ask free
    'am I free Thursday at 3': CommandAction.askFree,
    'what\'s free tomorrow afternoon': CommandAction.askFree,
    'do I have time for lunch Friday': CommandAction.askFree,
    'when am I free tomorrow': CommandAction.askFree,
    'any time on Monday?': CommandAction.askFree,
    // ask agenda
    'what\'s on tomorrow': CommandAction.askAgenda,
    'what do I have Friday': CommandAction.askAgenda,
    'agenda for Monday': CommandAction.askAgenda,
    'what\'s on my schedule next week': CommandAction.askAgenda,
    'anything on Thursday?': CommandAction.askAgenda,
    'what\'s my day look like': CommandAction.askAgenda,
    // ask person
    'when did I last meet Dana': CommandAction.askPerson,
    'next meeting with Lee': CommandAction.askPerson,
    'when am I seeing Priya': CommandAction.askPerson,
    'when is my next meeting with Sam': CommandAction.askPerson,
    'last met with the fabrikam team': CommandAction.askPerson,
    // not commands
    'invoice from contoso': CommandAction.unknown,
    '>later': CommandAction.unknown,
    'thanks for the update': CommandAction.unknown,
    'booking confirmation from fabrikam': CommandAction.unknown,
    'project status': CommandAction.unknown,
    'lunch with Dana': CommandAction.unknown,
  };

  test('the phrase table', () {
    final wrong = <String>[];
    for (final MapEntry(key: text, value: want) in table.entries) {
      final got = classifyByLexicon(text).action;
      if (got != want) wrong.add('$text → ${got.wire}, wanted ${want.wire}');
    }
    expect(wrong, isEmpty);
    // At least five phrasings per action, and six non-commands.
    for (final a in CommandAction.values) {
      final n = table.values.where((v) => v == a).length;
      expect(n, greaterThanOrEqualTo(a == CommandAction.unknown ? 6 : 5),
          reason: a.wire);
    }
  });

  group('confidence tiers', () {
    test('a leading verb is 0.9, after a polite prefix too', () {
      expect(classifyByLexicon('move my 3pm').confidence, lexiconLeading);
      expect(classifyByLexicon('please move my 3pm').confidence,
          lexiconLeading);
      expect(classifyByLexicon('Can you cancel my 4pm').confidence,
          lexiconLeading);
    });

    test('a verb further in is 0.75', () {
      final g = classifyByLexicon('the design sync — push it to 4pm');
      expect(g.action, CommandAction.move);
      expect(g.confidence, lexiconInside);
    });

    test('a weak cue is 0.6 wherever it sits', () {
      expect(classifyByLexicon('invite Dana to lunch Friday').confidence,
          lexiconWeak);
      expect(classifyByLexicon('maybe to the sync').confidence, lexiconWeak);
      expect(classifyByLexicon('agenda for Monday').confidence, lexiconWeak);
    });

    test('nothing matched is unknown at 0.0, on the lexicon path', () {
      final g = classifyByLexicon('project status');
      expect(g, CommandGuess.none);
      expect(g.path, CommandPath.lexicon);
    });

    test('a strong phrase beats an earlier weak cue', () {
      final g = classifyByLexicon('maybe move my 3pm');
      expect(g.action, CommandAction.move);
      expect(g.confidence, lexiconInside);
    });
  });

  test('the mode follows the action', () {
    expect(classifyByLexicon('am I free Wednesday').mode, WhenMode.question);
    expect(classifyByLexicon('what\'s on Wednesday').mode, WhenMode.question);
    expect(classifyByLexicon('book Wednesday').mode, WhenMode.booking);
    expect(CommandGuess.none.mode, WhenMode.booking);
  });

  test('the verb phrase span is the one that won', () {
    const text = 'please tentatively accept the offsite';
    final spans = lexiconSpans(text);
    expect(spans, hasLength(1));
    final (s, e) = spans.single;
    expect(text.substring(s, e), 'tentatively accept');
    expect(lexiconSpans('project status'), isEmpty);
  });

  test('wire words round-trip, and a stranger is unknown', () {
    for (final a in CommandAction.values) {
      expect(CommandActionWire.parse(a.wire), a);
    }
    expect(CommandActionWire.parse('RSVP_YES'), CommandAction.rsvpYes);
    expect(CommandActionWire.parse('reschedule'), CommandAction.unknown);
  });

  test('the classifier interface answers the lexicon', () async {
    const c = LexiconClassifier();
    expect(await c.classify('cancel my 4pm'),
        const CommandGuess(CommandAction.cancel, 0.9, CommandPath.lexicon));
  });

  group('looksLikeCalendarCommand', () {
    test('positives', () {
      for (final t in [
        'move my 3pm to Thursday',
        'tomorrow\'s meeting',
        'what\'s on tomorrow',
        'am I free Friday',
        'invite Dana Friday',
        'standup on Monday',
        'cancel the standup',
        'move my 3pm to Thursday',
        'book lunch with Dana Friday',
        'am I free Thursday at 3',
        'find 30 min with Sam next week',
      ]) {
        expect(looksLikeCalendarCommand(t), isTrue, reason: t);
      }
    });

    test('negatives', () {
      for (final t in [
        'invoice from contoso',
        '>later',
        '',
        'maybe',
        'add',
        'thanks for the update',
        'the 30 min recap',
        // A verb alone, however strong, is a search for mail.
        'push notifications',
        'cancel subscription',
        'book club',
        'delete account',
        'remove me from list',
        'accept offer letter',
        'block party',
        'drop box',
        'cancel the offsite',
        // A Find facet is a search being built.
        'label:invoices meeting',
        'from:dana tomorrow\'s meeting',
      ]) {
        expect(looksLikeCalendarCommand(t), isFalse, reason: t);
      }
    });
  });
}
