import 'dart:async';
import 'dart:convert';

import 'package:bond_inbox/services/llm/llm_client.dart';

/// One call to a [ScriptedLlm], as the fixture saw it.
///
/// Every field is something a test in this repo already asserted on through a
/// hand-written double's parallel recorder lists. Keeping them on ONE object
/// in call order is what lets the derived getters below stay index-aligned
/// with each other: `userMessages[schemas.indexOf('storyline_name')]` is a
/// real idiom in `storyline_service_test.dart`, and it only holds while every
/// recorder is a projection of the same list.
class LlmCall {
  /// The task that asked. `complete` for a free-text completion, matching the
  /// name [LlmClient.complete] puts on the wire.
  final String schemaName;

  final String system;
  final String user;
  final double temperature;
  final int maxTokens;
  final bool think;

  /// True when the call arrived through [ScriptedLlm.completeJsonStreamed].
  final bool streamed;

  const LlmCall({
    required this.schemaName,
    required this.system,
    required this.user,
    required this.temperature,
    required this.maxTokens,
    required this.think,
    required this.streamed,
  });

  @override
  String toString() => 'LlmCall($schemaName, streamed: $streamed)';
}

/// The one scripted [LlmClient] every test uses in place of a real server.
///
/// It replaces thirty-six hand-written doubles across twenty-nine test files
/// — thirty-two direct subclasses and four built on one of those — which
/// were, between them, nine variations on the same four moves: record the
/// call, wait a tick, take the next step, return a map or throw. The
/// variations were the interesting part and each file carried its own: a
/// hold, a per-call latch, an observer record, a stream, a computed answer, a
/// double that must never be called at all. All nine are here, so a new test
/// writes `ScriptedLlm(answers: …)` instead of a class.
///
/// **The signature freeze.** Dart requires an override to accept every named
/// parameter of the method it overrides, so each of those thirty-six doubles
/// was a vote against ever adding one to [LlmClient.completeJson]. That is
/// why `completeJsonStreamed` is a separate method rather than an
/// `onText:` parameter. The rule does not go away with the doubles, it gets
/// cheaper: there is now ONE override of each signature in the test tree, so
/// a parameter added to `completeJson` is one edit here rather than
/// thirty-six elsewhere. Both methods below copy their real signatures
/// exactly; keep it that way.
///
/// **A step** is one of five things, and the type test below reads them in
/// this order because the last one is a catch-all:
///
/// - `Map<String, dynamic>` — returned from `completeJson`, JSON-encoded from
///   `complete` (which is what the wire actually carries).
/// - `String` — returned from `complete`. A `String` reached by `completeJson`
///   is a scripting mistake and says so loudly: a constrained call returns an
///   object, never text.
/// - `Future<void>` or `Completer<void>` — a HOLD. Awaited, and then the NEXT
///   step answers the call. This is how a test parks one call inside the
///   drain while it asserts on what else did or did not start.
/// - `FutureOr<Map<String, dynamic>> Function(LlmCall)` — COMPUTED. Handed the
///   call it is answering, so logic that used to live in a double's body
///   (parse the subject, write a log line, remap group numbers) moves into a
///   closure the test owns, beside the state it reads.
/// - anything else — THROWN. `Exception` and `Error` both, which is why this
///   arm is last: `LlmFormatException` and `StateError` share no supertype
///   worth testing for.
///
/// The last step of a script repeats once the script runs out, and
/// [scriptFor] copies the list it is given, both conventions borrowed from
/// `FakeLlamaServer` so a test that moves between the two fixtures reads the
/// same way. A HOLD as the last step is the one exception: it is consumed
/// rather than repeated, because a hold that repeated would never answer, and
/// the step before it repeats instead.
class ScriptedLlm extends LlmClient {
  /// `schemaName` → the steps to answer with, in order.
  final Map<String, List<Object>> _scripts = {};

  /// The last non-hold step each schema yielded. Read only when a hold was the
  /// last step in a script: after the await there is nothing left to answer
  /// with, and repeating the answer before the hold is what every held double
  /// this replaces did.
  final Map<String, Object> _repeats = {};

  /// Answers a schema that has no script of its own. Null is the strict
  /// default: an unscripted call is usually a call that landed on the wrong
  /// client, and that should fail rather than return something plausible.
  ///
  /// Any step kind but a HOLD: a hold answers with the step after it, and a
  /// fallback has none. One handed a hold says so rather than waiting first.
  final Object? fallback;

  /// Sees a record per call when [emitRecords] is set. The real client's
  /// observer parameter is private, so this is a field rather than something
  /// handed to `super`.
  final LlmCallObserver? observer;

  /// Whether to feed [observer] an [LlmCallRecord] per call. Off by default:
  /// only the activity-log tests care, and the numbers below are theirs.
  final bool emitRecords;

  /// Names this fixture in its own failure messages. Two clients that record
  /// identically are otherwise indistinguishable in an `expect` diff, and a
  /// call reaching the wrong one is the defect the routing tests exist for.
  final String label;

  /// Runs at the top of every call, inside the in-flight window and before the
  /// step is resolved. The seam for a latch, a log line, or a release.
  final FutureOr<void> Function(LlmCall call)? onCall;

  /// Awaited between [onCall] and the step. One millisecond by default, the
  /// same tick every double this replaces awaited: it is what lets a drain
  /// interleave rather than run to completion inside one microtask.
  final Duration delay;

  /// What [completeJsonStreamed] pushes through `onText`, in order. Joined,
  /// these are usually the JSON of the map the script yields, which is what
  /// lets a test assert that a stream reassembles into the same object.
  List<String> streamChunks = const [];

  /// Every call, in order.
  final List<LlmCall> calls = [];

  /// How many calls are inside the fixture right now, and the high-water mark
  /// over the whole test. The parallelism assertions read the latter: a lane
  /// configured one wide must never reach two.
  int inFlight = 0;
  int maxInFlight = 0;

  /// How many calls arrived through [completeJsonStreamed].
  int streamedCalls = 0;

  ScriptedLlm({
    Map<String, Object> answers = const {},
    this.fallback,
    this.observer,
    this.emitRecords = false,
    this.label = 'scripted',
    this.onCall,
    this.delay = const Duration(milliseconds: 1),
  }) : super(baseUrl: 'http://127.0.0.1:1/never-dialled') {
    answers.forEach(answer);
  }

  /// A client that must never be called. Any call throws, naming [label] and
  /// the schema that was asked for.
  ScriptedLlm.never({String label = 'never'}) : this(label: label);

  /// Scripts the answers for one schema name. The list is copied, so a test
  /// may reuse a `const` script across clients.
  void scriptFor(String schemaName, List<Object> steps) {
    _scripts[schemaName] = [...steps];
  }

  /// One step for one schema — an answer that repeats for every call, which is
  /// what most tests want.
  void answer(String schemaName, Object step) => scriptFor(schemaName, [step]);

  /// Which task each call was, in order. Two names for one list because that
  /// is what the doubles this replaces called it.
  List<String> get schemas => [for (final c in calls) c.schemaName];
  List<String> get schemaNames => schemas;

  /// The user message each call carried, in order. Two names, same reason.
  List<String> get userMessages => [for (final c in calls) c.user];
  List<String> get users => userMessages;

  /// The system prompt each call carried, in order.
  List<String> get systems => [for (final c in calls) c.system];

  List<double> get temperatures => [for (final c in calls) c.temperature];

  /// The completion budget each call was made with, in order.
  List<int> get tokenBudgets => [for (final c in calls) c.maxTokens];

  /// The completion budget by schema name, last call wins. Recorded because a
  /// task that measured its own ceiling has to be run at it.
  Map<String, int> get budgets => {
        for (final c in calls) c.schemaName: c.maxTokens,
      };

  int callsFor(String schemaName) =>
      calls.where((c) => c.schemaName == schemaName).length;

  @override
  Future<String> complete({
    required String system,
    required String user,
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
  }) async {
    final step = await _run(
      LlmCall(
        schemaName: 'complete',
        system: system,
        user: user,
        temperature: temperature,
        maxTokens: maxTokens,
        think: think,
        streamed: false,
      ),
    );
    if (step is String) return step;
    // A map step answers free text as the wire would: the content of a
    // constrained reply IS a JSON string.
    return jsonEncode(step);
  }

  /// Overrides `llm_client.dart`'s exact signature. No parameter is added
  /// here, ever — see the note on the class.
  @override
  Future<Map<String, dynamic>> completeJson({
    required String system,
    required String user,
    required Map<String, dynamic> schema,
    String schemaName = 'result',
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
  }) async {
    final step = await _run(
      LlmCall(
        schemaName: schemaName,
        system: system,
        user: user,
        temperature: temperature,
        maxTokens: maxTokens,
        think: think,
        streamed: false,
      ),
      wantsMap: true,
    );
    return _asMap(step);
  }

  /// The same, with [streamChunks] handed to [onText] first.
  ///
  /// The chunks go out BEFORE the step is resolved, so a script whose step
  /// throws reproduces the failure this fixture's predecessor did: a stream
  /// that delivered its words and then died. A zero-delay between chunks
  /// yields the event loop, which is what lets a listener see them arrive one
  /// at a time rather than all at once at the end.
  @override
  Future<Map<String, dynamic>> completeJsonStreamed({
    required String system,
    required String user,
    required Map<String, dynamic> schema,
    String schemaName = 'result',
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
    required void Function(String delta) onText,
  }) async {
    streamedCalls++;
    final step = await _run(
      LlmCall(
        schemaName: schemaName,
        system: system,
        user: user,
        temperature: temperature,
        maxTokens: maxTokens,
        think: think,
        streamed: true,
      ),
      emit: (chunk) => onText(chunk),
      wantsMap: true,
    );
    return _asMap(step);
  }

  /// The whole body of every call: record it, hold the in-flight window open,
  /// run [onCall], wait a tick, stream what there is to stream, resolve the
  /// step, tell [observer], and either return the step or throw it.
  ///
  /// Returns the resolved step rather than a map so [complete] can serve a
  /// `String` from the same machinery. [wantsMap] is the constrained callers'
  /// flag, and it is checked BEFORE [observer] hears anything: a `String`
  /// step reaching `completeJson` is a scripting mistake, not a call that
  /// happened, so it reports no record of either shape on its way out.
  Future<Object> _run(
    LlmCall call, {
    void Function(String chunk)? emit,
    bool wantsMap = false,
  }) async {
    calls.add(call);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await onCall?.call(call);
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (emit != null) {
        for (final chunk in streamChunks) {
          emit(chunk);
          await Future<void>.delayed(Duration.zero);
        }
      }
      final step = await _stepFor(call);
      if (wantsMap && step is String) {
        throw StateError(
          '$label: the step for ${call.schemaName} is a String, and a '
          'constrained call returns an object — script a map, or call '
          'complete()',
        );
      }
      if (_throws(step)) {
        _record(call.schemaName, failure: step);
        throw step;
      }
      _record(call.schemaName);
      return step;
    } finally {
      inFlight--;
    }
  }

  /// Takes the next step for this call, awaiting any holds on the way and
  /// running a computed step against [call].
  Future<Object> _stepFor(LlmCall call) async {
    final schemaName = call.schemaName;
    while (true) {
      final steps = _scripts[schemaName];
      if (steps == null || steps.isEmpty) {
        final repeat = _repeats[schemaName];
        if (repeat != null) return _computed(repeat, call);
        final spare = fallback;
        if (spare != null) {
          // A fallback cannot be a hold. A hold answers with the step AFTER
          // it, and a fallback is the answer to a schema that has no steps at
          // all, so there is nothing for the await to hand over to — the call
          // would wait and then fail anyway. Said here, where the script is,
          // rather than as a `Future` thrown like an error further down.
          if (_isHold(spare)) {
            throw StateError(
              '$label: the fallback met by $schemaName is a hold, and a '
              'fallback has no next step to answer with — script the hold '
              'under a schema name',
            );
          }
          return _computed(spare, call);
        }
        throw StateError('$label: no script for $schemaName');
      }

      final Object step;
      if (steps.length > 1) {
        step = steps.removeAt(0);
      } else {
        step = steps.first;
        // The last step repeats — unless it is a hold, which is consumed: a
        // hold that repeated would await and then find itself again, forever.
        if (_isHold(step)) steps.removeAt(0);
      }

      if (_isHold(step)) {
        await (step is Completer ? step.future : step as Future);
        continue;
      }
      _repeats[schemaName] = step;
      return _computed(step, call);
    }
  }

  /// A computed step, run; anything else, itself.
  ///
  /// The invocation is dynamic rather than through a typed function check
  /// because a closure written inline infers the narrowest type it can —
  /// `Map<String, String> Function(LlmCall)` for a script of strings — and a
  /// test should not have to annotate its way past that. The result is
  /// checked instead, and a closure that answered with something else names
  /// itself in the failure.
  Future<Object> _computed(Object step, LlmCall call) async {
    if (step is! Function) return step;
    final produced = await (step as dynamic)(call) as Object?;
    if (produced is Map) return Map<String, dynamic>.from(produced);
    throw StateError(
      '$label: the computed step for ${call.schemaName} answered with '
      '${produced.runtimeType}, not a map',
    );
  }

  static bool _isHold(Object step) => step is Future || step is Completer;

  /// Everything that is not an answer is thrown. Last in the order, so
  /// `Exception` and `Error` need no common supertype.
  static bool _throws(Object step) => step is! Map && step is! String;

  /// The cast the constrained callers make. Only a `Map` can reach here: a
  /// `String` was refused in [_run] and everything else was thrown there.
  static Map<String, dynamic> _asMap(Object step) =>
      Map<String, dynamic>.from(step as Map);

  /// The record the real client would have emitted. The three numbers are
  /// fixed rather than measured because the activity-log tests assert on them
  /// as values, and a fixture that reported real milliseconds would make those
  /// assertions flaky for no gain.
  void _record(String schemaName, {Object? failure}) {
    if (!emitRecords) return;
    final sink = observer;
    if (sink == null) return;
    sink(
      failure == null
          ? LlmCallRecord(
              label: schemaName,
              durationMs: 5,
              outcome: 'ok',
              promptTokens: 700,
              completionTokens: 40,
            )
          : LlmCallRecord(
              label: schemaName,
              durationMs: 5,
              outcome: 'unavailable',
              error: '$failure',
            ),
    );
  }
}
