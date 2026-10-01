import 'package:bond_inbox/data/message_store.dart' show MessageStore;
import 'package:bond_inbox/providers/app_providers.dart'
    show decisionClientProvider;
import 'package:bond_inbox/services/decision/decision_client.dart';
import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:bond_inbox/services/decision/decision_input.dart';
import 'package:bond_inbox/services/decision/decision_questions.dart';
import 'package:bond_inbox/services/decision/decision_state.dart';
import 'package:bond_inbox/services/llm/model_slots.dart' show LlmTarget;
import 'package:bond_inbox/services/storyline_judge.dart'
    show StorylineJudge;
import 'package:flutter_riverpod/flutter_riverpod.dart' show Override;

import 'scripted_llm.dart';

/// Nine answers built from the handful of numbers a pipeline test cares
/// about. Two-option fields take a p(yes)/p(drop); multi-option fields take
/// the chosen word, given probability [choiceP] with the rest spread evenly.
DecisionAnswers fakeAnswers({
  double gateDrop = 0.05,
  String dropReason = 'other',
  String category = 'work',
  String urgency = 'normal',
  double needsAction = 0.2,
  double replyExpected = 0.2,
  double needsYou = 0.2,
  String intent = 'fyi',
  String importance = 'normal',
  double choiceP = 0.8,
}) {
  ChoiceAnswer binary(String yes, String no, double p) => ChoiceAnswer(
        choice: p >= 0.5 ? yes : no,
        confidence: p >= 0.5 ? p : 1 - p,
        probabilities: {yes: p, no: 1 - p},
      );
  ChoiceAnswer pick(String field, String choice) {
    final options = decisionOptions[field]!;
    final rest = (1 - choiceP) / (options.length - 1);
    return ChoiceAnswer(
      choice: choice,
      confidence: choiceP,
      probabilities: {for (final o in options) o: o == choice ? choiceP : rest},
    );
  }

  final gate = binary('drop', 'keep', gateDrop);
  return DecisionAnswers({
    'gate': ChoiceAnswer(
      choice: gate.choice,
      confidence: gate.confidence,
      // Head order: keep, drop.
      probabilities: {'keep': 1 - gateDrop, 'drop': gateDrop},
    ),
    'drop_reason': pick('drop_reason', dropReason),
    'category': pick('category', category),
    'urgency': pick('urgency', urgency),
    'needs_action': binary('yes', 'no', needsAction),
    'reply_expected': binary('yes', 'no', replyExpected),
    'needs_you': binary('yes', 'no', needsYou),
    'intent': pick('intent', intent),
    'importance': pick('importance', importance),
  });
}

/// A scripted decision. [vector] stands in for the encoder's pooled vector
/// (the owner's Needs You labels keep it); [model] is the tag it is compared
/// under.
DecisionResult fakeDecision(
  DecisionAnswers answers, {
  int latencyMs = 42,
  List<double>? vector,
  String model = 'bond-decide-fake',
}) =>
    DecisionResult(
      answers: answers,
      state: 'state',
      model: model,
      latencyMs: latencyMs,
      vector: vector,
    );

/// A [DecisionClient] that answers from a script and records what it read.
///
/// [answer] maps an input to a result, or throws — a
/// `DecisionUnavailableException` to park, an `LlmFormatException` to fail.
/// Never touches HTTP: [decide] is overridden whole.
class FakeDecisionClient extends DecisionClient {
  final DecisionResult Function(DecisionInput input) answer;
  final List<DecisionInput> calls = [];

  /// Called at the top of every [decide], before [answer]: a test hooks the
  /// order of calls here.
  final void Function()? onDecide;

  /// What [checkServer] answers: null passes every server a Connect names,
  /// a sentence refuses them all with it.
  String? serverRefusal;

  /// The `url|model` of every [checkServer] asked.
  final List<String> checks = [];

  /// What [kindOf] answers for every address: not yet known unless a test
  /// says.
  DecisionServerKind? serverKind;

  /// What [ask] answers: the p of the FIRST entry whose question matches and
  /// whose substring the state contains, else [defaultYes]. `askPairs`
  /// reaches [ask] with both orders of each pair, so a pair script matches
  /// on a substring of either thread.
  final List<({StorylineQuestion question, String contains, double p})>
      yesScript = [];

  /// [ask]'s answer for a state no [yesScript] entry matches. 0.0 by default,
  /// so an unscripted `member_of` never files anything by accident: a test
  /// that wants a yes says so.
  double defaultYes;

  /// Thrown by every [ask] when set — a `DecisionUnavailableException` to
  /// park the storyline lane.
  Object? askError;

  /// Every [ask], one entry per call (a batch), in order.
  final List<({StorylineQuestion question, List<String> states})> asks = [];

  FakeDecisionClient(this.answer, {this.onDecide, this.defaultYes = 0.0})
      : super(
          resolveTarget: () =>
              const LlmTarget(baseUrl: 'http://fake', model: 'fake'),
          heads: () => throw StateError('fake: heads never read'),
        );

  /// A client a test's queue must never call: any call fails the test.
  factory FakeDecisionClient.never() => FakeDecisionClient(
        (_) => throw StateError('this decision client must never be called'),
      );

  /// A client for the storyline questions alone: [decide] is never called,
  /// and [ask] answers [defaultYes] unless [yes] says otherwise.
  factory FakeDecisionClient.storyline({double defaultYes = 0.0}) =>
      FakeDecisionClient(
        (_) => throw StateError('storyline fake: decide never called'),
        defaultYes: defaultYes,
      );

  /// Scripts [ask]'s answer for [question] over a state containing
  /// [contains]. Earlier scripts win.
  void yes(StorylineQuestion question, String contains, double p) =>
      yesScript.add((question: question, contains: contains, p: p));

  /// The states of every [ask] for [question], flattened in call order.
  List<String> statesFor(StorylineQuestion question) => [
        for (final call in asks)
          if (call.question == question) ...call.states,
      ];

  /// Always answers [answers].
  factory FakeDecisionClient.fixed(DecisionAnswers answers,
          {void Function()? onDecide}) =>
      FakeDecisionClient((_) => fakeDecision(answers), onDecide: onDecide);

  @override
  Future<DecisionResult> decide(DecisionInput input) async {
    calls.add(input);
    onDecide?.call();
    return answer(input);
  }

  @override
  Future<List<double>> ask(
    StorylineQuestion question,
    List<String> states,
  ) async {
    asks.add((question: question, states: List.of(states)));
    final error = askError;
    if (error != null) throw error;
    return [for (final state in states) yesFor(question, state)];
  }

  /// How many [ensureReady] checks were made.
  int readyChecks = 0;

  /// Ready unless [askError] is set, which it throws: a client that parks
  /// every question is not ready either.
  @override
  Future<void> ensureReady() async {
    readyChecks++;
    final error = askError;
    if (error != null) throw error;
  }

  /// The scripted p for one state — [ask]'s rule, for a subclass that
  /// answers one state at a time.
  double yesFor(StorylineQuestion question, String state) {
    for (final entry in yesScript) {
      if (entry.question == question && state.contains(entry.contains)) {
        return entry.p;
      }
    }
    return defaultYes;
  }

  @override
  Future<String?> checkServer({
    required String url,
    required String model,
    String? bearer,
  }) async {
    checks.add('$url|$model');
    return serverRefusal;
  }

  /// What [detectKind] finds, which [kindOf] answers from then on; null
  /// leaves [kindOf] as it was.
  DecisionServerKind? detectedKind;

  /// The `url|model` of every [detectKind] asked.
  final List<String> detects = [];

  @override
  DecisionServerKind? kindOf({required String url, required String model}) =>
      serverKind;

  @override
  Future<DecisionServerKind?> detectKind({
    required String url,
    required String model,
    String? bearer,
  }) async {
    detects.add('$url|$model');
    serverKind = detectedKind ?? serverKind;
    return detectedKind;
  }
}

/// The ONE override every screen-level test that builds the app's providers
/// passes: a decision client that keeps every message.
///
/// Without it the real client runs, finds no heads file under `flutter test`,
/// and triage PARKS every message under `decision_unavailable` — rows stay
/// `pending` and read "· triaging" where the tests were written against a
/// triage that moved on. With it, triage reaches the text client as it did
/// before the decision model existed.
///
/// What it answers, and what that means for a screen test:
/// - gate: keep (p(drop) 0.05), so nothing is learned-gated;
/// - needs_you: 0.5, above the slider's default (0.35), so a kept message
///   reads as needing the owner and no language model is asked about it;
/// - needs_action and reply_expected: 0.2, so the triage booleans come from
///   THIS fake (no) — a screen test that needs a triaged ask seeds the
///   columns, or overrides this with its own [FakeDecisionClient];
/// - urgency `normal`, category `work`, intent `fyi`, importance `normal`.
Override keepingDecisionClient() =>
    decisionClientProvider.overrideWithValue(
      FakeDecisionClient.fixed(fakeAnswers(needsYou: 0.5)),
    );

/// A [FakeDecisionClient] driven by a [ScriptedLlm] script under the schema
/// name `decision` — how a queue test HOLDS, THROWS or COUNTS decision calls
/// with the one scripting vocabulary the suite already speaks.
///
/// Each [decide] is one `completeJson` call on [llm], whose `user` is the
/// rendered decision state (what the model would read: owner line, date,
/// directness, tail, the message block), so `llm.userMessages`,
/// `llm.maxInFlight` and every hold, throw and computed step behave exactly
/// as they did when the triage queue's model was a language model.
///
/// A step's map is read by [scriptedAnswers]: `urgency`, `category`,
/// `needs_action`, `reply_expected` (booleans, as the retired triage answer
/// carried them), and optionally `gate_drop`, `drop_reason`, `needs_you`,
/// `intent`, `importance`. Keys it does not know (a summary, action items)
/// are ignored — triage writes no text now.
class ScriptedDecisionClient extends FakeDecisionClient {
  final ScriptedLlm llm;

  ScriptedDecisionClient(this.llm)
      : super((_) => throw StateError('scripted: answered by the llm'));

  @override
  Future<DecisionResult> decide(DecisionInput input) async {
    calls.add(input);
    onDecide?.call();
    final json = await llm.completeJson(
      system: '',
      user: renderDecisionState(input, toLocal: (utc) => utc),
      schema: const {},
      schemaName: 'decision',
    );
    return fakeDecision(scriptedAnswers(json));
  }

  /// A storyline question, one `completeJson` call on [llm] PER STATE under
  /// the question's id as the schema name (`member_of`, `same_effort`,
  /// `charter_specific`), whose `user` is the state. A step's map carries the
  /// answer as `p`; a missing `p` is [defaultYes]. So a storyline test holds,
  /// throws and counts judgements with the vocabulary it scripts its naming
  /// calls with, and `llm.callsFor('member_of')` counts threads judged.
  /// [asks] still records one entry per batch.
  @override
  Future<List<double>> ask(
    StorylineQuestion question,
    List<String> states,
  ) async {
    asks.add((question: question, states: List.of(states)));
    final error = askError;
    if (error != null) throw error;
    final out = <double>[];
    for (final state in states) {
      final json = await llm.completeJson(
        system: '',
        user: state,
        schema: const {},
        schemaName: question.id,
        // The decision model has no sampling; recorded as 0 so a test's
        // temperature list reads the same as when a model confirmed.
        temperature: 0,
      );
      out.add((json['p'] as num?)?.toDouble() ?? yesFor(question, state));
    }
    return out;
  }
}

/// [ScriptedDecisionClient] over a fresh [ScriptedLlm] scripted with
/// [steps] under `decision`.
ScriptedDecisionClient scriptedDecision(List<Object> steps) =>
    ScriptedDecisionClient(ScriptedLlm()..scriptFor('decision', steps));

/// A scripted step's map as the decision model's nine answers.
DecisionAnswers scriptedAnswers(Map<String, dynamic> json) {
  double yes(Object? v, double fallback) => switch (v) {
        true => 0.8,
        false => 0.2,
        num n => n.toDouble(),
        _ => fallback,
      };
  return fakeAnswers(
    gateDrop: yes(json['gate_drop'], 0.05),
    dropReason: json['drop_reason'] as String? ?? 'other',
    category: json['category'] as String? ?? 'work',
    urgency: json['urgency'] as String? ?? 'normal',
    needsAction: yes(json['needs_action'], 0.2),
    replyExpected: yes(json['reply_expected'], 0.2),
    needsYou: yes(json['needs_you'], 0.2),
    intent: json['intent'] as String? ?? 'fyi',
    importance: json['importance'] as String? ?? 'normal',
  );
}

/// A [StorylineJudge] over [store] whose `member_of` (and the other two
/// storyline questions) are answered by [llm]'s script under the question's
/// id — [ScriptedDecisionClient.ask]'s rule. How a storyline service test
/// scripts its membership answers beside its naming ones: `{'p': 0.9}` under
/// `member_of`, and `llm.callsFor('member_of')` counts the threads judged.
StorylineJudge scriptedJudge(MessageStore store, ScriptedLlm llm) =>
    StorylineJudge(decision: ScriptedDecisionClient(llm), store: store);
