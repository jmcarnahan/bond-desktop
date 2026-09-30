import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../data/calendar_store.dart';
import '../../data/message_store.dart';
import '../../models/calendar_models.dart';
import '../activity_log.dart';
import '../backend/backend_types.dart' show NotSignedIn, ReconsentRequired;
import '../backend/calendar_backend.dart';
import '../backend/calendar_errors.dart';
import 'calendar_sync.dart';

/// Writing to the calendar: answer an invite, propose a new time, move,
/// cancel, delete, create (docs/pipeline/14-calendar.md, "Writes").
///
/// Every write runs twice. The DRY RUN answers who the real one would email,
/// and the policy (D5) reads that: a write that emails anybody, and every
/// answer, cancel or delete, waits for the person's confirm; a private write
/// goes at once and offers an Undo instead. The real write then keeps the
/// mirror honest at once — the answered row stored, the deleted rows gone,
/// the write guard noted — so the Day stop agrees before the next sync, which
/// is forced straight after.
///
/// Nothing here throws. A preview answers [PreviewResult] and a commit a
/// [WriteOutcome], each carrying the one sentence a person reads, because
/// every caller would otherwise map the same eight failures to the same
/// eight sentences.

/// What the person asked the calendar to do.
sealed class CalendarWrite {
  const CalendarWrite();

  /// The event written; `''` for a [CreateEvent], which has none yet.
  String get eventId;

  /// The activity log's word for this write.
  String get action;
}

/// An RSVP. The enum's names are the wire words.
enum RsvpResponse { accept, tentative, decline }

final class RespondToEvent extends CalendarWrite {
  const RespondToEvent(
    this.eventId,
    this.response, {
    this.comment,
    this.proposeStartUtc,
    this.proposeEndUtc,
  });

  @override
  final String eventId;
  final RsvpResponse response;

  /// A note to the organiser; sent only because every RSVP here sends.
  final String? comment;

  /// A proposed new time, both ends or neither; only with tentative or
  /// decline (the backend refuses anything else before a request).
  final DateTime? proposeStartUtc;
  final DateTime? proposeEndUtc;

  bool get proposes => proposeStartUtc != null && proposeEndUtc != null;

  @override
  String get action => proposes ? 'propose' : response.name;
}

final class MoveEvent extends CalendarWrite {
  const MoveEvent.timed(
    this.eventId, {
    required DateTime this.startUtc,
    required DateTime this.endUtc,
    this.ifMatch,
  })  : startDate = null,
        endDate = null;

  const MoveEvent.allDay(
    this.eventId, {
    required CalendarDate this.startDate,
    required CalendarDate this.endDate,
    this.ifMatch,
  })  : startUtc = null,
        endUtc = null;

  @override
  final String eventId;
  final DateTime? startUtc;
  final DateTime? endUtc;
  final CalendarDate? startDate;

  /// Exclusive, as every all-day end is.
  final CalendarDate? endDate;

  /// The change key this move was built against, sent as `if_match` in place
  /// of the one read at send time; null reads it then. An undo and a retry
  /// pin it so that any change since becomes `event_changed` on the server.
  final String? ifMatch;

  bool get isAllDay => startDate != null;

  /// The same move pinned to [key].
  MoveEvent withIfMatch(String? key) => isAllDay
      ? MoveEvent.allDay(eventId,
          startDate: startDate!, endDate: endDate!, ifMatch: key)
      : MoveEvent.timed(eventId,
          startUtc: startUtc!, endUtc: endUtc!, ifMatch: key);

  @override
  String get action => 'move';
}

final class CancelMeeting extends CalendarWrite {
  const CancelMeeting(this.eventId, {this.comment});

  @override
  final String eventId;

  /// The note every attendee gets with the cancellation.
  final String? comment;

  @override
  String get action => 'cancel';
}

final class DeleteEvent extends CalendarWrite {
  const DeleteEvent(this.eventId, {this.expectChangeKey});

  @override
  final String eventId;

  /// An undo's delete: the change key the event had when the write being
  /// undone landed. A different key now means someone changed it since, and
  /// the undo is refused rather than deleting what they did.
  final String? expectChangeKey;

  @override
  String get action => 'delete';
}

final class CreateEvent extends CalendarWrite {
  const CreateEvent({
    required this.subject,
    required this.startUtc,
    required this.endUtc,
    this.attendees = const [],
    this.isOnlineMeeting = false,
    this.body,
    required this.transactionId,
  });

  /// A new proposal: a fresh transaction id (32 lowercase hex characters
  /// from [Random.secure]). Reuse the SAME object on every retry of that
  /// proposal — the id makes the create idempotent, so a retry after a
  /// dropped answer cannot put the meeting on the calendar twice.
  factory CreateEvent.propose({
    required String subject,
    required DateTime startUtc,
    required DateTime endUtc,
    List<String> attendees = const [],
    bool isOnlineMeeting = false,
    String? body,
  }) =>
      CreateEvent(
        subject: subject,
        startUtc: startUtc,
        endUtc: endUtc,
        attendees: attendees,
        isOnlineMeeting: isOnlineMeeting,
        body: body,
        transactionId: _transactionId(),
      );

  final String subject;
  final DateTime startUtc;
  final DateTime endUtc;

  /// Bare lowercase addresses.
  final List<String> attendees;
  final bool isOnlineMeeting;
  final String? body;
  final String transactionId;

  @override
  String get eventId => '';

  @override
  String get action => 'create';

  static final Random _random = Random.secure();

  static String _transactionId() => [
        for (var i = 0; i < 16; i++)
          _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ].join();
}

/// A dry run's answer, as the confirm UI needs it. Never thrown.
sealed class PreviewResult {
  const PreviewResult();
}

final class PreviewReady extends PreviewResult {
  const PreviewReady(this.preview, {required this.needsConfirm});

  final WritePreview preview;
  final bool needsConfirm;
}

final class PreviewFailed extends PreviewResult {
  const PreviewFailed(this.message, {this.retry});

  /// A person-facing sentence.
  final String message;

  /// The same write, when trying it again may work.
  final CalendarWrite? retry;
}

/// A real write's answer. Never thrown.
class WriteOutcome {
  const WriteOutcome.ok({this.undo, this.eventId})
      : ok = true,
        message = '',
        retry = null;

  const WriteOutcome.failed(this.message, {this.retry})
      : ok = false,
        undo = null,
        eventId = null;

  final bool ok;

  /// A person-facing sentence; failures only.
  final String message;

  /// Set only for a private write whose dry run emailed nobody (a commit
  /// with no preview never gets one): a write that emailed somebody cannot
  /// be taken back by a second write, only followed by one.
  final CalendarWrite? undo;

  /// Set when trying the SAME write again may work (a transient failure).
  final CalendarWrite? retry;

  /// The written event — the new id for a create.
  final String? eventId;
}

/// The seam the widgets and the screen code against, so a test hands them a
/// fake.
abstract interface class CalendarWriter {
  Future<PreviewResult> preview(CalendarWrite write);

  /// [preview] is the dry run the person confirmed (for the activity count
  /// and the undo decision — no preview, no Undo); [isUndo] marks an Undo's
  /// own write, which offers no Undo of its own.
  Future<WriteOutcome> commit(
    CalendarWrite write, {
    WritePreview? preview,
    bool isUndo = false,
  });
}

/// Confirm whenever anyone gets email, always before destroying a meeting,
/// and always before an answer (D5).
///
/// An RSVP is named outright rather than left to [p]: every answer here is
/// sent, so every answer emails the organiser, and whether the confirm shows
/// must not hinge on the dry run happening to list them. A create with
/// anyone on it is named outright for the same reason: an invite sends mail
/// the moment it is written, and one read out of typed words (the Day
/// command bar) must never go out on the strength of the server's notifies
/// list alone.
bool needsConfirm(CalendarWrite w, WritePreview p) =>
    p.notifies.isNotEmpty ||
    w is DeleteEvent ||
    w is CancelMeeting ||
    w is RespondToEvent ||
    (w is CreateEvent && w.attendees.isNotEmpty);

/// An Undo whose dry run now emails somebody: the event gained guests since
/// the write it undoes, and an Undo is only ever a private write.
const String undoRefusedSentence =
    'Undo would email people now — open the event instead.';

/// One failure, mapped: the sentence, the activity log's word, and whether
/// the same write may be tried again.
typedef _Failure = ({String message, String outcome, CalendarWrite? retry});

class CalendarWrites implements CalendarWriter {
  CalendarWrites(
    this._backend,
    this._calendar,
    this._sync,
    this._store, {
    ActivityLog? activityLog,
    DateTime Function()? clock,
    this._onChanged,
  })  : _activity = activityLog ?? ActivityLog.disabled(),
        _clock = clock ?? DateTime.now;

  final CalendarBackend _backend;
  final CalendarStore _calendar;
  final CalendarSync _sync;

  /// For the cached mailbox settings only.
  final MessageStore _store;
  final ActivityLog _activity;
  final DateTime Function() _clock;

  /// Called after anything that changed the mirror, so its readers follow
  /// without waiting for a sync.
  final void Function()? _onChanged;

  static const String _transientSentence =
      "Couldn't reach the calendar. Nothing was changed.";

  /// A real write lost in transit: it may or may not be on the calendar.
  static const String _unconfirmedSentence =
      "Couldn't confirm the calendar got this — check it before trying again.";

  static const String _changedSentence =
      'This event changed in Outlook — check it and try again.';

  @override
  Future<PreviewResult> preview(CalendarWrite write) async {
    try {
      final result = await _send(write, dryRun: true);
      if (result is! WritePreview) {
        return const PreviewFailed(_transientSentence);
      }
      return PreviewReady(result, needsConfirm: needsConfirm(write, result));
    } on _NoZone {
      return const PreviewFailed(_NoZone.sentence);
    } on Object catch (e) {
      final failure = await _fail(write, e, dryRun: true);
      return PreviewFailed(failure.message, retry: failure.retry);
    }
  }

  @override
  Future<WriteOutcome> commit(
    CalendarWrite write, {
    WritePreview? preview,
    bool isUndo = false,
  }) async {
    final notified = preview?.notifies.length ?? 0;
    final started = _clock();
    // Everything before the real request only reads, so a failure there is
    // mapped as a dry run's: nothing was sent, nothing was changed, and no
    // sync is forced to find out.
    CalendarEvent? before;
    String? zone;
    try {
      // Read at commit time, never carried from the preview: an Undo runs
      // after the first move stored a new change key.
      if (write is MoveEvent) {
        before = await _eventForWrite(write.eventId);
        if (write.isAllDay) zone = await _mailboxZone();
      } else if (isUndo &&
          write is DeleteEvent &&
          (write.expectChangeKey ?? '').isNotEmpty) {
        before = await _eventForWrite(write.eventId);
      }
      if (isUndo) {
        final refused = await _refuseUndo(write, before, zone);
        if (refused != null) {
          await _record(
              write, 'refused', refused.outcome, notified, isUndo, started);
          return WriteOutcome.failed(refused.message);
        }
      }
    } on _NoZone {
      await _record(write, 'failed', 'no_zone', notified, isUndo, started);
      return const WriteOutcome.failed(_NoZone.sentence);
    } on Object catch (e) {
      final failure = await _fail(write, e, dryRun: true);
      await _record(write, 'failed', failure.outcome, notified, isUndo, started);
      return WriteOutcome.failed(failure.message, retry: failure.retry);
    }

    // The failure mapping covers the request and nothing after it: once the
    // server has answered with an ack the write HAS happened, and a throw
    // from a local step must not come back as "Couldn't confirm…" with a Try
    // again — a second RSVP emails the organiser twice.
    final EventWriteAck ack;
    try {
      final result =
          await _send(write, dryRun: false, current: before, zone: zone);
      if (result is! EventWriteAck) {
        throw StateError('a real write answered a preview');
      }
      ack = result;
    } on Object catch (e) {
      final failure = await _fail(write, e, dryRun: false, current: before);
      await _record(write, 'failed', failure.outcome, notified, isUndo, started);
      return WriteOutcome.failed(failure.message, retry: failure.retry);
    }

    // From here every step is a side effect of a write that went through,
    // each on its own guard: a failed one is logged by type and the outcome
    // stays ok, because the forced sync brings the mirror level.
    await _quietly('the local apply', () => _applyLocally(write, ack));
    await _quietly('the change callback', () => _onChanged?.call());
    // The forced read picks up what the server did beyond the one row it
    // answered (a series, the organiser's copy).
    await _quietly('the forced sync', () {
      unawaited(_sync.syncNow(force: true));
    });
    await _quietly('the activity row',
        () => _record(write, 'ok', 'ok', notified, isUndo, started));
    // An Undo only for a write the person was SHOWN to email nobody: a
    // caller that skipped the dry run cannot know that nobody was emailed,
    // and a write that emailed somebody can be followed, not taken back.
    CalendarWrite? undo;
    if (preview != null && preview.notifies.isEmpty && !isUndo) {
      await _quietly('the undo', () {
        undo = _undoFor(write, ack, before);
      });
    }
    return WriteOutcome.ok(undo: undo, eventId: ack.id);
  }

  /// Why an Undo must not go, or null when it may. An Undo is offered only
  /// for a write shown to email nobody and is sent with no confirm of its
  /// own, so it runs its own dry run first and is refused when that now
  /// emails anybody (a guest added since); an undo's delete is also refused
  /// when the event's key moved on from the one the undone write left. What
  /// passes is still a private write that emails nobody. A throw is a dry
  /// run's failure: nothing was sent.
  Future<({String message, String outcome})?> _refuseUndo(
    CalendarWrite write,
    CalendarEvent? before,
    String? zone,
  ) async {
    if (write is DeleteEvent) {
      final expected = write.expectChangeKey ?? '';
      final now = before?.changeKey ?? '';
      if (expected.isNotEmpty && now.isNotEmpty && now != expected) {
        return (message: _changedSentence, outcome: 'changed');
      }
    }
    final dry = await _send(write, dryRun: true, current: before, zone: zone);
    if (dry is! WritePreview) {
      throw StateError('a dry run answered an ack');
    }
    if (dry.notifies.isNotEmpty) {
      return (message: undoRefusedSentence, outcome: 'undo_emails');
    }
    return null;
  }

  /// Runs one step after a write the server took; a throw is logged by type
  /// (its text can carry the endpoint) and goes no further.
  Future<void> _quietly(String what, FutureOr<void> Function() step) async {
    try {
      await step();
    } on Object catch (e) {
      debugPrint('calendar write: $what failed: ${e.runtimeType}');
    }
  }

  /// The one backend call [write] makes, dry or real. [current] is a move's
  /// event and [zone] an all-day move's mailbox zone, when the caller already
  /// read them.
  Future<CalendarWriteResult> _send(
    CalendarWrite write, {
    required bool dryRun,
    CalendarEvent? current,
    String? zone,
  }) async {
    switch (write) {
      case RespondToEvent():
        final comment = write.comment?.trim();
        return _backend.respond(
          write.eventId,
          response: write.response.name,
          comment: comment == null || comment.isEmpty ? null : comment,
          sendResponse: true,
          proposedStartUtc: write.proposeStartUtc,
          proposedEndUtc: write.proposeEndUtc,
          dryRun: dryRun,
        );
      case MoveEvent():
        // An undo and a retry pin the key they were built against, so any
        // change since becomes `event_changed` on the server.
        final ifMatch = write.ifMatch ??
            (current ?? await _eventForWrite(write.eventId)).changeKey;
        if (!write.isAllDay) {
          return _backend.update(
            write.eventId,
            ifMatch: ifMatch,
            startUtc: write.startUtc,
            endUtc: write.endUtc,
            dryRun: dryRun,
          );
        }
        return _backend.update(
          write.eventId,
          ifMatch: ifMatch,
          startDate: write.startDate,
          endDate: write.endDate,
          allDayZone: zone ?? await _mailboxZone(),
          dryRun: dryRun,
        );
      case CancelMeeting():
        final comment = write.comment?.trim();
        return _backend.cancel(
          write.eventId,
          comment: comment == null || comment.isEmpty ? null : comment,
          dryRun: dryRun,
        );
      case DeleteEvent():
        return _backend.delete(write.eventId, dryRun: dryRun);
      case CreateEvent():
        return _backend.create(
          subject: write.subject,
          startUtc: write.startUtc,
          endUtc: write.endUtc,
          attendees: write.attendees,
          isOnlineMeeting: write.isOnlineMeeting,
          body: write.body,
          transactionId: write.transactionId,
          dryRun: dryRun,
        );
    }
  }

  /// The event as the mirror holds it, else as the server does: a live-read
  /// series master (gotcha 43) is not in the mirror, and its change key is
  /// only on the server.
  Future<CalendarEvent> _eventForWrite(String id) async =>
      await _calendar.event(id) ?? await _backend.getEvent(id);

  /// The mailbox zone's Windows name, which an all-day write sends as its
  /// zone: the cached settings first, then a live read.
  Future<String> _mailboxZone() async {
    final cached = (await CalendarSync.readMailboxSettings(_store))?.timeZone;
    if (cached != null && cached.trim().isNotEmpty) return cached;
    final live = (await _backend.mailboxSettings()).timeZone;
    if (live.trim().isEmpty) throw const _NoZone();
    return live;
  }

  /// What the real write changed, made true in the mirror now, with every
  /// touched id noted so a sync page read before the write cannot undo it.
  Future<void> _applyLocally(CalendarWrite write, EventWriteAck ack) async {
    switch (write) {
      case MoveEvent():
      case CreateEvent():
        final event = ack.event;
        if (event != null) {
          await _sync.storeWritten(event);
        } else {
          // A create whose row could not be placed: the next sync brings it.
          _sync.noteWrite(ack.id);
        }
      case RespondToEvent():
        final status = switch (write.response) {
          RsvpResponse.accept => 'accepted',
          RsvpResponse.tentative => 'tentativelyAccepted',
          RsvpResponse.decline => 'declined',
        };
        final ids = await _calendar.setResponseStatus(write.eventId, status);
        ids.forEach(_sync.noteWrite);
      case CancelMeeting():
      case DeleteEvent():
        final ids = await _calendar.deleteWithOccurrences(write.eventId);
        ids.forEach(_sync.noteWrite);
        _sync.noteWrite(write.eventId);
    }
  }

  /// The write that takes [write] back, for a private write only (the caller
  /// checks): a create with nobody invited is deleted, a move goes back to
  /// the times it had. An RSVP, a cancel and a delete have none — an answer
  /// is sent the moment it is written, and a deleted event cannot be put back
  /// as the same event.
  ///
  /// Each undo pins the change key the ack answered — the key the server
  /// holds now and the mirror will once the forced sync lands — so an edit in
  /// Outlook in between refuses the undo instead of being reverted.
  CalendarWrite? _undoFor(
    CalendarWrite write,
    EventWriteAck ack,
    CalendarEvent? before,
  ) {
    switch (write) {
      case CreateEvent():
        final key = ack.event?.changeKey ?? '';
        return write.attendees.isEmpty
            ? DeleteEvent(ack.id, expectChangeKey: key.isEmpty ? null : key)
            : null;
      case MoveEvent():
        if (before == null) return null;
        final key = ack.event?.changeKey ?? '';
        final ifMatch = key.isEmpty ? null : key;
        if (write.isAllDay) {
          final s = before.startDate;
          final e = before.endDate;
          if (s == null || e == null) return null;
          return MoveEvent.allDay(write.eventId,
              startDate: s, endDate: e, ifMatch: ifMatch);
        }
        final s = before.startUtc;
        final e = before.endUtc;
        if (s == null || e == null) return null;
        return MoveEvent.timed(write.eventId,
            startUtc: s, endUtc: e, ifMatch: ifMatch);
      case RespondToEvent():
      case CancelMeeting():
      case DeleteEvent():
        return null;
    }
  }

  /// Counts and enum words only: no subject, no address, no event id (the
  /// rule every activity row keeps, gotcha 27).
  Future<void> _record(
    CalendarWrite write,
    String status,
    String outcome,
    int notified,
    bool isUndo,
    DateTime started,
  ) =>
      _activity.record(
        'calendar_write',
        status: status,
        durationMs: _clock().difference(started).inMilliseconds,
        detail: {
          'action': write.action,
          'outcome': outcome,
          'notified': notified,
          if (isUndo) 'undo': true,
        },
      );

  /// Maps one failure to its sentence, and does what the failure says about
  /// the mirror: a changed event is re-read and stored, a gone one dropped.
  ///
  /// [dryRun] matters only for a transient failure. A dry run changes
  /// nothing whatever happened to it; a real write lost in transit may have
  /// landed, so it is never "Nothing was changed", the mirror is sent to
  /// look, and only a write whose repeat is harmless offers Try again.
  /// [current] is the event a real move was sent against (null for a dry
  /// run), whose key its retry pins.
  Future<_Failure> _fail(
    CalendarWrite write,
    Object e, {
    required bool dryRun,
    CalendarEvent? current,
  }) async {
    final id = write.eventId;
    switch (e) {
      case CalendarEventChanged():
        if (id.isNotEmpty) {
          try {
            final fresh = await _backend.getEvent(id);
            await _sync.storeWritten(fresh);
            _onChanged?.call();
          } on Object catch (reread) {
            debugPrint('calendar write: the re-read failed: '
                '${reread.runtimeType}');
          }
        }
        return (
          message: _changedSentence,
          outcome: 'changed',
          retry: null,
        );
      case CalendarNotOrganizer():
        return (
          message: 'Only the organiser can change this meeting.',
          outcome: 'not_organizer',
          retry: null,
        );
      case CalendarScopeMissing():
        return (
          message: 'Calendar write permission missing — reconnect in Settings.',
          outcome: 'scope_missing',
          retry: null,
        );
      case CalendarEventGone():
        if (id.isNotEmpty) {
          try {
            final ids = await _calendar.deleteWithOccurrences(id);
            ids.forEach(_sync.noteWrite);
            _onChanged?.call();
          } on Object catch (drop) {
            debugPrint('calendar write: the local drop failed: '
                '${drop.runtimeType}');
          }
        }
        return (
          message: 'This event no longer exists.',
          outcome: 'gone',
          retry: null,
        );
      case CalendarRefused():
        final sentence = firstSentence(e.reason);
        return (
          message: sentence.isEmpty ? e.message : sentence,
          outcome: 'refused',
          retry: null,
        );
      case CalendarUnavailable():
        return (message: e.sentence, outcome: 'unavailable', retry: null);
      case ReconsentRequired():
      case NotSignedIn():
        return (
          message: 'Reconnect Microsoft in Settings, then try again. '
              'Nothing was changed.',
          outcome: 'reconnect',
          retry: null,
        );
      case ArgumentError():
        return (
          message: "This can't be sent as it stands. Nothing was changed.",
          outcome: 'invalid',
          retry: null,
        );
      default:
        // The type only: an exception's text can carry the endpoint.
        debugPrint('calendar write failed: ${e.runtimeType}');
        if (dryRun) {
          return (
            message: _transientSentence,
            outcome: 'transient',
            retry: write,
          );
        }
        // Never throws; the forced read is how the mirror learns whether
        // the write landed.
        unawaited(_sync.syncNow(force: true));
        return (
          message: _unconfirmedSentence,
          outcome: 'transient',
          // A create repeats safely under its transaction id, and a move
          // under the if_match it was sent with, pinned here — a landed
          // first try turns the second into event_changed even after the
          // forced sync has stored the new key. An answer, a cancel or a
          // delete repeated would email everybody a second time.
          retry: switch (write) {
            CreateEvent() => write,
            MoveEvent() =>
              write.withIfMatch(write.ifMatch ?? current?.changeKey),
            _ => null,
          },
        );
    }
  }
}

/// The first sentence of [text], ending in a full stop: a server reason is
/// prose written for a developer, and its first sentence is the part a person
/// can use. `''` for blank text.
String firstSentence(String text) {
  final t = text.trim();
  if (t.isEmpty) return '';
  final stop = t.indexOf('. ');
  var first = (stop < 0 ? t : t.substring(0, stop + 1)).trim();
  if (!first.endsWith('.') && !first.endsWith('!') && !first.endsWith('?')) {
    first = '$first.';
  }
  return first;
}

/// The mailbox has no zone to send an all-day move with.
class _NoZone implements Exception {
  const _NoZone();

  static const String sentence =
      "Couldn't read your mailbox's time zone. Nothing was changed.";
}
