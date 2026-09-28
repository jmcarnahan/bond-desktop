import 'package:bond_inbox/providers/app_providers.dart'
    show decisionClientProvider;
import 'package:bond_inbox/services/decision/decision_client.dart';
import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:bond_inbox/services/decision/decision_input.dart';
import 'package:bond_inbox/services/llm/model_slots.dart' show LlmTarget;
import 'package:flutter_riverpod/flutter_riverpod.dart' show Override;

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

DecisionResult fakeDecision(DecisionAnswers answers, {int latencyMs = 42}) =>
    DecisionResult(
      answers: answers,
      state: 'state',
      model: 'bond-decide-fake',
      latencyMs: latencyMs,
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

  FakeDecisionClient(this.answer, {this.onDecide})
      : super(
          resolveTarget: () =>
              const LlmTarget(baseUrl: 'http://fake', model: 'fake'),
          heads: () => throw StateError('fake: heads never read'),
        );

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
/// - needs_you: 0.5, INSIDE the band, so the needs-you pass still asks the
///   language model and a scripted needs-you answer decides as before;
/// - needs_action and reply_expected: 0.2, so the triage booleans come from
///   THIS fake (no) and not from a scripted TriageTask answer — a screen test
///   that needs a triaged ask seeds the columns, or overrides this with its
///   own [FakeDecisionClient];
/// - urgency `normal`, category `work`, intent `fyi`, importance `normal`.
Override keepingDecisionClient() =>
    decisionClientProvider.overrideWithValue(
      FakeDecisionClient.fixed(fakeAnswers(needsYou: 0.5)),
    );
