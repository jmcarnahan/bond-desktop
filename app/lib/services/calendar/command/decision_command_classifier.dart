import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import '../../decision/decision_client.dart';
import '../../decision/decision_heads.dart' show DecisionHeads;
import '../../llm/llm_client.dart' show LlmException;
import 'command_heads.dart';
import 'command_types.dart';

/// The decision model's command head as a [CommandClassifier] (plan §1.1
/// "The command head", docs/pipeline/14-calendar.md "Commands"): the typed
/// command's raw vector from the decision server
/// ([DecisionClient.embedRaw]), through [CommandHeads.apply].
///
/// **It never stands in the way.** No heads asset (the owner has not fitted
/// one, or has not adopted the one they fitted), a refused file, a decision
/// model that is not installed or not served, a head fitted on another
/// decision model than the one installed, a decision server that is down or
/// misconfigured: every one of them is null, and the router asks the lexicon
/// as if this classifier were not there. A guess under the bar is `unknown`,
/// which the router also passes over. So the head answers only above its
/// bar; the calendar never parks on the decision model the way triage does.
///
/// **Nothing is asked that could not be answered.** With the decision role
/// not ready ([decisionReady]) or the installed heads naming another model
/// than the head's `encoder_model`, the classifier returns null BEFORE any
/// request — so no `command_head` call record, and no activity row, speaks
/// of a model nobody could have asked. The same for Your server of the
/// systemone kind (Kev), which has no raw vector to read: the client's
/// `resolvedModelTag` says so, and the lexicon reads commands alone.
///
/// The client, the heads and the two checks are closures, resolved per call:
/// the client follows Settings the way `decisionClientProvider` does, the
/// heads loader is the provider's memoised asset read, and the installed
/// decision heads are the file triage reads.
class DecisionCommandClassifier implements CommandClassifier {
  DecisionCommandClassifier({
    required this.client,
    required this.heads,
    required this.decisionReady,
    required this.installedHeads,
    this.bar = 0.80,
    this.timeout = const Duration(milliseconds: 800),
  });

  final DecisionClient Function() client;

  /// The asset, loaded once; null when it is absent or refused.
  final Future<CommandHeads?> Function() heads;

  /// Whether the decision role could answer at all: its heads file is on
  /// this Mac and its target is not marked unavailable (the managed router
  /// not serving it). False skips the head without a request.
  final bool Function() decisionReady;

  /// The installed decision heads (`decide-heads.json`), whose `model` names
  /// the encoder the server embeds with; null when there are none.
  final DecisionHeads? Function() installedHeads;

  /// The probability the head's argmax needs to be an answer.
  final double bar;

  /// How long a caller waits for a head answer, asset read included, before
  /// the lexicon reads the command instead. The decision client's own
  /// ceiling is 15 s per request, for a wedged server; an Enter must not
  /// wait that long on a refinement. The encoder answers a short command in
  /// tens of ms. Only the CALLER's wait is cut: the request itself runs on,
  /// and the preview counts it as out until it settles ([classifyPreview]).
  final Duration timeout;

  /// The failure kinds already said once, so a server that is down does not
  /// print a line per keystroke.
  final Set<Type> _said = {};

  /// The encoder models already refused, said once each.
  final Set<String> _refusedModels = {};

  /// The preview's one request out — the UNTIMED request, so a caller that
  /// stopped waiting does not free the slot while the server still works —
  /// and the newest text asked for meanwhile.
  Future<void>? _inFlight;
  String? _latest;

  @override
  Future<CommandGuess?> classify(String text) async {
    if (text.trim().isEmpty) return null;
    return _timed(_untimed(text, report: true));
  }

  /// [classify] for the live preview: at most ONE request out, and the
  /// newest text wins.
  ///
  /// A call made while a request is out starts none of its own: it waits for
  /// that request to settle — however long the server takes, since the
  /// timeout cut only that caller's wait — and then, if its text is still
  /// the newest ([_latest]), sends it, once. Every call whose text was
  /// overtaken meanwhile gets null without a request, because its text is no
  /// longer what the bar shows; so is an answer that arrives for older
  /// words. No call record: a keystroke is not a unit of work (see
  /// [DecisionClient.embedRaw]).
  Future<CommandGuess?> classifyPreview(String text) async {
    if (text.trim().isEmpty) return null;
    _latest = text;
    while (_inFlight != null) {
      await _inFlight;
      if (_latest != text) return null;
    }
    if (_latest != text) return null;
    final request = _untimed(text, report: false);
    final slot = request.then<void>((_) {});
    _inFlight = slot;
    unawaited(slot.whenComplete(() {
      if (identical(_inFlight, slot)) _inFlight = null;
    }));
    final guess = await _timed(request);
    return _latest == text ? guess : null;
  }

  /// The caller's wait on [request], cut at [timeout]. Never throws: the
  /// request's own failures were caught in [_untimed].
  Future<CommandGuess?> _timed(Future<CommandGuess?> request) async {
    try {
      return await request.timeout(timeout);
    } on TimeoutException catch (e) {
      _sayOnce(e);
      return null;
    }
  }

  /// The head's answer for [text], or null — never a throw, so a request a
  /// caller stopped waiting for cannot surface as an unhandled error.
  Future<CommandGuess?> _untimed(String text, {required bool report}) async {
    try {
      return await _guess(text, report: report);
    } on LlmException catch (e) {
      // The decision server's refusals and failures, the decision
      // subclasses (not installed, misconfigured, unauthorized) included.
      _sayOnce(e);
    } on CommandHeadsRefused catch (e) {
      // A heads file refused at load, or a vector of another width.
      _sayOnce(e);
    } on TimeoutException catch (e) {
      _sayOnce(e);
    } catch (e, stack) {
      // Nothing above: a bug, not a server's weather. Still no answer — the
      // head is a refinement, never a dependency — but loudly, in debug.
      if (kDebugMode) {
        debugPrint('calendar command: the command head failed unexpectedly: '
            '${e.runtimeType}\n$stack');
      }
    }
    return null;
  }

  Future<CommandGuess?> _guess(String text, {required bool report}) async {
    final loaded = await heads();
    if (loaded == null) return null;
    if (!decisionReady()) return null;
    final installed = installedHeads();
    if (installed == null) return null;
    if (installed.model != loaded.encoderModel) {
      if (_refusedModels.add(installed.model)) {
        debugPrint('calendar command: the command head was fitted on '
            '${loaded.encoderModel}, not the installed ${installed.model}; '
            'the lexicon reads commands alone.');
      }
      return null;
    }
    // The client's own word on whether a vector is to be had: null for a
    // target marked unavailable, heads that are missing, or Your server of
    // the systemone kind (Kev), which answers questions already calibrated
    // and gives no raw vector. One cached listing GET per address at most,
    // as any decision call pays; no request at all for a managed target.
    final decisionClient = client();
    if (await decisionClient.resolvedModelTag() == null) return null;
    final vectors = await decisionClient.embedRaw([text], report: report);
    return loaded.apply(vectors.single, bar: bar);
  }

  void _sayOnce(Object e) {
    if (_said.add(e.runtimeType)) {
      debugPrint('calendar command: the command head did not answer: '
          '${e.runtimeType}');
    }
  }
}
