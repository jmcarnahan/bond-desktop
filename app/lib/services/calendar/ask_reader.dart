import 'package:flutter/foundation.dart' show debugPrint, immutable;

import '../../data/message_store.dart';
import '../activity_log.dart';
import '../llm/ask_read_task.dart';
import '../llm/json_task.dart';
import '../llm/llm_client.dart';
import 'calendar_zone.dart';

/// One ask's reading by the model, as [AskReader.readFor] hands it back.
@immutable
class AskReading {
  /// The copied phrases; `asksForTime` false for a `none` reading.
  final AskRead read;

  /// `ready` (phrases worth resolving) or `none` (not asking for a time, or
  /// nothing copied).
  final String status;

  /// True when the reading came from `ask_readings` rather than a call.
  final bool fromCache;

  const AskReading({
    required this.read,
    required this.status,
    required this.fromCache,
  });
}

/// Reads a scheduling ask's own words with the generative model
/// (docs/pipeline/14-calendar.md "Reading the ask"), once per message.
///
/// On demand, never a lane (the round's D9): the Day column asks when an ask
/// opens, and a draft answering an ask asks first (`draft_slots.dart`), which
/// pre-warms it, so there is no work kind and no claim. A reading is stored
/// as the model's PHRASES in `ask_readings` and the caller resolves it
/// against today with `readAskHintsFromRead`; a
/// stored reading is never asked again, a failed one is never stored, so a
/// later call retries. Whatever goes wrong, the answer is null and the
/// caller keeps the rules' reading.
class AskReader {
  AskReader({
    required this._store,
    required this._client,
    required this._log,
    required this._zone,
    this._clock = DateTime.now,
    this._enabled = true,
  });

  final MessageStore _store;

  /// The `ask_read` stage's client, asked for at the call, so a prefs write
  /// rebuilds nothing.
  final LlmClient Function() _client;
  final ActivityLog _log;

  /// The display zone, read at the call: it resolves after the first sync.
  final CalendarZone Function() _zone;

  /// Services never read the clock directly.
  final DateTime Function() _clock;

  /// Off: every read answers null and nothing is asked.
  final bool _enabled;

  /// The read in flight per `'$source|$messageId'`, so callers that ask
  /// together share one call.
  final Map<String, Future<AskReading?>> _inFlight = {};

  /// The model's reading of [source]/[messageId]'s words, cached per message;
  /// null when the model could not be asked (off, unavailable, a bad answer)
  /// or the message is gone.
  Future<AskReading?> readFor(String source, String messageId) {
    if (!_enabled) return Future.value(null);
    final key = '$source|$messageId';
    final running = _inFlight[key];
    if (running != null) return running;
    final future = _read(source, messageId);
    _inFlight[key] = future;
    return future.whenComplete(() => _inFlight.remove(key));
  }

  /// [_readUnguarded] with every failure — the store's, the log's, the
  /// model's — answered null, so a caller never sees a throw and keeps the
  /// rules' reading. Only a bad model answer leaves an activity row.
  Future<AskReading?> _read(String source, String messageId) async {
    try {
      return await _readUnguarded(source, messageId);
    } on Object catch (e) {
      debugPrint('ask reading: could not read: ${e.runtimeType}');
      return null;
    }
  }

  Future<AskReading?> _readUnguarded(String source, String messageId) async {
    final cached = await _store.askReading(source, messageId);
    if (cached != null) {
      // A ready row whose phrases no longer decode reads as nothing asked.
      final read = cached.read;
      final ready = cached.status == 'ready' && read != null;
      return AskReading(
        read: ready ? read : AskRead(evidence: read?.evidence ?? ''),
        status: ready ? 'ready' : 'none',
        fromCache: true,
      );
    }
    final row = await _store.getMessageRow(source, messageId);
    if (row == null) return null;
    final text = (row['body_text'] as String? ?? '').trim();
    final body =
        text.isNotEmpty ? text : (row['body_preview'] as String? ?? '').trim();
    final subject = (row['subject'] as String? ?? '').trim();
    // No words at all: nothing to read, and no call.
    if (subject.isEmpty && body.isEmpty) return null;
    final received = row['received_at'];
    final input = AskReadInput.at(
      subject: subject,
      body: body,
      now: _clock(),
      sentAt: received is String ? DateTime.tryParse(received) : null,
      zone: _zone(),
    );
    final client = _client();
    final AskRead read;
    try {
      read = await runTask(client, const AskReadTask(), input,
          temperature: AskReadTask.temperature,
          maxTokens: AskReadTask.maxTokens);
    } on LlmUnavailableException {
      // No model to ask right now: nothing stored, no row — the caller keeps
      // the rules' reading and a later open asks again.
      return null;
    } on Object catch (e) {
      // A bad answer: noted (the type only), nothing stored, so a later
      // call retries.
      await _log.record('ask_read',
          status: 'error',
          source: source,
          detail: {'error': e.runtimeType.toString()});
      return null;
    }
    final status = read.asksForTime &&
            (read.when.isNotEmpty ||
                read.time.isNotEmpty ||
                read.duration.isNotEmpty ||
                read.meal != AskMeal.none)
        ? 'ready'
        : 'none';
    await _store.putAskReading(
      source: source,
      messageId: messageId,
      status: status,
      read: read,
      model: client.model,
      readAt: MessageStore.isoStamp(_clock()),
    );
    // Counts and enum words only, never a phrase: the phrases are somebody
    // else's words.
    await _log.record('ask_read',
        source: source,
        detail: {
          'status': status,
          'when': read.when.length,
          'meal': read.meal.wire,
        });
    return AskReading(
      read: status == 'ready' ? read : AskRead(evidence: read.evidence),
      status: status,
      fromCache: false,
    );
  }
}
