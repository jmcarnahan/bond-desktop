import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint, immutable;

import '../../data/message_store.dart';
import '../../models/calendar_models.dart' show MailboxSettings;
import '../../models/message_models.dart'
    show ConversationState, Message, localEchoPrefix;
import '../../models/reminder_models.dart';
import '../activity_log.dart';
import '../backend/backend_types.dart' show ReconsentRequired;
import '../backend/tasks_backend.dart';
import '../backend/tasks_errors.dart';
import '../calendar/ask_words.dart' show capAtWord;
import '../calendar/calendar_zone.dart';
import 'tasks_availability.dart';

/// A new reminder id: 32 hex characters from [Random.secure], the shape
/// `calendar_writes.dart` mints transaction ids in (no uuid dependency). It
/// is the row's key and the To Do task's linked-resource `external_id`.
String defaultReminderId() => [
      for (var i = 0; i < 16; i++)
        _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();

final Random _random = Random.secure();

/// A reminder asked for at an instant that is not ahead of the clock. A
/// service rule, not a carrier error: the bar's choices are worked out at
/// build, so a pane left open can offer a "5 pm today" that has passed, and
/// a task due in the past would ring at once. [message] is the toast.
class ReminderPast implements Exception {
  final String message = 'That time has passed. Nothing was set.';

  const ReminderPast();

  @override
  String toString() => message;
}

/// What a caller asks for when it sets a reminder.
@immutable
class ReminderRequest {
  final ReminderKind kind;
  final String source;
  final String conversationKey;

  /// The message the reminder is about (a `local:` echo id for a follow-up
  /// set at send, re-anchored by [ReminderService.reconcile]); `''` when
  /// none is known.
  final String anchorMessageId;
  final String title;
  final DateTime remindAtUtc;
  final ReminderOrigin createdFrom;

  /// The task's body, capped at [ReminderService.bodyCap] on a word.
  final String? bodyText;

  /// The anchor message's Outlook-on-the-web link (`Message.webLink`); the
  /// task links back to it when it is http(s), and carries no link else.
  final String? anchorWebLink;

  /// The Graph id of the message a follow-up flags; a `local:` echo id is
  /// never flagged (the flag waits for the Sent Items copy).
  final String? anchorGraphId;

  const ReminderRequest({
    required this.kind,
    required this.source,
    required this.conversationKey,
    this.anchorMessageId = '',
    required this.title,
    required this.remindAtUtc,
    required this.createdFrom,
    this.bodyText,
    this.anchorWebLink,
    this.anchorGraphId,
  });
}

/// The reminders the app places in Microsoft To Do (the calendar-automation
/// round's D7/D8): create, complete, cancel, and the poll's reconcile.
///
/// Each reminder is ONE task in the app's own list ("Bond follow-ups", its id
/// persisted under [todoListIdKey]) with a reminder at [Reminder.remindAt], a
/// due date on the owner's wall, and a link back to the mail; a follow-up is
/// `waitingOnOthers` and also flags the sent mail. To Do raises the
/// notification on every device — this app raises none.
///
/// Until the owner's consent round every To Do call answers
/// `tasks_scope_missing`, so [create] asks [availability] FIRST and throws
/// [TasksScopeMissing] (or [TasksUnavailable] in SDK mode) before anything is
/// called or written; [reconcile] does nothing at all while unavailable.
class ReminderService {
  final MessageStore _store;
  final TasksBackend _backend;
  final Future<MailboxSettings?> Function() _mailbox;
  final CalendarZone Function() _zone;
  final ActivityLog _log;
  final Future<TasksAvailability> Function() _availability;
  final DateTime Function() _clock;
  final String Function() _newId;

  ReminderService({
    required this._store,
    required this._backend,
    required this._mailbox,
    required this._zone,
    required this._log,
    required this._availability,
    this._clock = DateTime.now,
    this._newId = defaultReminderId,
  });

  /// The task body's cap, on a word.
  static const int bodyCap = 300;

  /// The most rows one [reconcile] pass changes; the rest wait a poll.
  static const int reconcileCap = 20;

  /// How far from a follow-up's creation the Sent Items copy of its sent
  /// reply may be stamped and still be taken for it (see [_reanchor]).
  static const Duration echoMatchWindow = Duration(minutes: 15);

  /// Places [r] in To Do and stores it `active`.
  ///
  /// Throws [TasksScopeMissing] / [TasksUnavailable] before any call or row
  /// when To Do cannot carry it, then [ReminderPast] (also before any call
  /// or row) when [ReminderRequest.remindAtUtc] is not after the clock, and
  /// whatever the create throws (no row is
  /// written then either). A list that is gone (deleted in To Do) is found
  /// or made again ONCE and the create retried once. The follow-up's flag is
  /// best effort: a failure is logged and never fails the reminder.
  Future<Reminder> create(ReminderRequest r) async {
    switch (await _availability()) {
      case TasksAvailability.available:
        break;
      case TasksAvailability.scopeMissing:
        throw const TasksScopeMissing();
      case TasksAvailability.sdkMode:
        throw TasksUnavailable(
            tasksUnavailableSentence(TasksAvailability.sdkMode)!);
    }
    final remindAt = r.remindAtUtc.toUtc();
    if (!remindAt.isAfter(_clock())) throw const ReminderPast();
    final id = _newId();
    final dueDate = _zone().dateOf(remindAt);
    final timeZone = await _mailboxZone();
    final webLink = r.anchorWebLink?.trim();
    final link = webLink != null && _isWebUrl(webLink)
        ? TodoLink(webUrl: webLink, displayName: r.title, externalId: id)
        : null;
    final body = r.bodyText?.trim();

    Future<TodoTask> createOn(String listId) => _backend.createTask(
          listId: listId,
          title: r.title,
          bodyText: body == null || body.isEmpty
              ? null
              : capAtWord(body, bodyCap),
          dueDate: dueDate,
          dueTimeZone: timeZone,
          reminderAtUtc: remindAt,
          status: r.kind == ReminderKind.followUp
              ? 'waitingOnOthers'
              : 'notStarted',
          link: link,
        );

    var listId = await _listId();
    TodoTask task;
    try {
      task = await createOn(listId);
    } on TasksGone {
      // The stored list was deleted in To Do: find or make it again, once,
      // and overwrite the stale id before the retry.
      listId = await _ensureList();
      task = await createOn(listId);
    }

    final now = MessageStore.isoStamp(_clock());
    var reminder = Reminder(
      id: id,
      kind: r.kind,
      source: r.source,
      conversationKey: r.conversationKey,
      anchorMessageId: r.anchorMessageId,
      title: r.title,
      remindAt: MessageStore.isoStamp(remindAt),
      dueDate: dueDate.toIso(),
      status: ReminderStatus.active,
      createdFrom: r.createdFrom,
      todoListId: listId,
      todoTaskId: task.id,
      createdAt: now,
      updatedAt: now,
    );
    // The row first, then the flag: a task that exists must have its row
    // even when the flag call never returns.
    await _store.insertReminder(reminder);

    var flagged = false;
    final graphId = r.anchorGraphId;
    if (r.kind == ReminderKind.followUp &&
        graphId != null &&
        graphId.isNotEmpty &&
        !graphId.startsWith(localEchoPrefix)) {
      flagged = await _flag(reminder, graphId);
      if (flagged) {
        reminder = (await _store.reminderById(id)) ?? reminder;
      }
    }

    await _log.record(
      'reminder',
      source: r.source,
      entityId: r.conversationKey,
      detail: {
        'action': 'create',
        'kind': r.kind.wire,
        'created_from': r.createdFrom.wire,
        'flagged': flagged,
        'linked': link != null,
      },
    );
    return reminder;
  }

  /// Completes reminder [id]: the task is marked completed (a task already
  /// deleted in To Do is fine), the flag on its mail completed best effort,
  /// and the row `done`. [reason] is `reply`, `done` or `owner`, for the
  /// activity row. A reminder that is not active is left alone.
  Future<void> complete(String id, {required String reason}) async {
    final r = await _store.reminderById(id);
    if (r == null || !r.isActive) return;
    if (r.todoListId.isNotEmpty && r.todoTaskId.isNotEmpty) {
      try {
        await _backend.completeTask(listId: r.todoListId, taskId: r.todoTaskId);
      } on TasksGone {
        // Deleted in To Do: nothing left to complete there.
      }
    }
    if (r.flagMessageId.isNotEmpty) {
      await _setFlag(r, r.flagMessageId, 'complete');
    }
    final now = MessageStore.isoStamp(_clock());
    await _store.updateReminder(
      id,
      status: ReminderStatus.done,
      doneAt: now,
      updatedAt: now,
    );
    await _log.record(
      'reminder',
      source: r.source,
      entityId: r.conversationKey,
      detail: {'action': 'complete', 'kind': r.kind.wire, 'reason': reason},
    );
  }

  /// Cancels reminder [id] (the Undo): the task is deleted (already gone is
  /// fine), the flag cleared best effort, and the row `cancelled`.
  Future<void> cancel(String id) async {
    final r = await _store.reminderById(id);
    if (r == null || !r.isActive) return;
    if (r.todoListId.isNotEmpty && r.todoTaskId.isNotEmpty) {
      try {
        await _backend.deleteTask(listId: r.todoListId, taskId: r.todoTaskId);
      } on TasksGone {
        // Already deleted in To Do.
      }
    }
    if (r.flagMessageId.isNotEmpty) {
      await _setFlag(r, r.flagMessageId, 'notflagged');
    }
    await _store.updateReminder(
      id,
      status: ReminderStatus.cancelled,
      updatedAt: MessageStore.isoStamp(_clock()),
    );
    await _log.record(
      'reminder',
      source: r.source,
      entityId: r.conversationKey,
      detail: {'action': 'cancel', 'kind': r.kind.wire},
    );
  }

  /// The poll's hook: completes what the mail has answered and re-anchors a
  /// follow-up whose sent reply has landed in Sent Items. Returns the number
  /// of rows changed (at most [reconcileCap]).
  ///
  /// The completion rules, read off the stored mail only (no To Do read):
  /// - `follow_up`: an INBOUND message on the thread received after the
  ///   reminder was made, not an auto-reply → complete `reply` (never on
  ///   Done: "sending a reply marks it done" closes the thread at the send);
  /// - `reply_by`, `deadline`, `custom`: the thread is Done → complete
  ///   `done`; the owner wrote on it after the reminder was made → complete
  ///   `reply`.
  ///
  /// Never throws but [ReconsentRequired]: each reminder is tried on its own,
  /// and a failure is printed by type and retried on the next poll. Does
  /// nothing while To Do is unavailable.
  Future<int> reconcile() async {
    if (await _availability() != TasksAvailability.available) return 0;
    var changed = 0;
    for (final r in await _store.activeReminders()) {
      if (changed >= reconcileCap) break;
      try {
        if (await _reconcileOne(r)) changed++;
      } on ReconsentRequired {
        rethrow;
      } catch (e) {
        debugPrint('reminder reconcile: ${e.runtimeType}');
      }
    }
    return changed;
  }

  Future<bool> _reconcileOne(Reminder r) async {
    final created = DateTime.parse(r.createdAt);
    var reanchored = false;
    if (r.anchorMessageId.startsWith(localEchoPrefix)) {
      reanchored = await _reanchor(r, created);
    }
    switch (r.kind) {
      case ReminderKind.followUp:
        // Done does NOT complete a follow-up: with "sending a reply marks it
        // done" on, every send closes the thread the moment the follow-up is
        // set, and the follow-up is about THEM answering, not the owner
        // closing. It ends on their reply, or the owner's Undo.
        final thread = await _store.loadThread(
          r.conversationKey,
          sources: [r.source],
        );
        final answered = thread.any((m) =>
            !m.outbound &&
            !m.isAutoReply &&
            (_instant(m.receivedAt)?.isAfter(created) ?? false));
        if (answered) {
          await complete(r.id, reason: 'reply');
          return true;
        }
      case ReminderKind.replyBy ||
            ReminderKind.deadline ||
            ReminderKind.custom:
        final row = await _store.getConversationRow(
          r.source,
          r.conversationKey,
        );
        if (row != null) {
          if (ConversationState.fromWire(row['state'] as String?) ==
              ConversationState.done) {
            await complete(r.id, reason: 'done');
            return true;
          }
          final lastOut = _instant(row['last_outbound_at'] as String?);
          if (lastOut != null && lastOut.isAfter(created)) {
            await complete(r.id, reason: 'reply');
            return true;
          }
        }
    }
    return reanchored;
  }

  /// Moves a follow-up off its `local:` echo onto the Sent Items copy, and
  /// flags that copy when nothing was flagged yet. True when it moved.
  ///
  /// The echo is DELETED in the page transaction that writes the real row
  /// (`MessageStore.deleteLocalEcho`, matched on `internet_message_id`), so
  /// by the time the copy is here the echo — and the id that matched it —
  /// is gone. The copy is found instead as the thread's outbound, non-echo
  /// message stamped closest to the reminder's creation and within
  /// [echoMatchWindow] of it: the reminder is made right after the send
  /// returns, and the copy carries the send's own time.
  Future<bool> _reanchor(Reminder r, DateTime created) async {
    if (await _store.getMessageRow(r.source, r.anchorMessageId) != null) {
      return false; // still the echo: the copy has not landed yet
    }
    final thread = await _store.loadThread(
      r.conversationKey,
      sources: [r.source],
    );
    Message? best;
    Duration? bestGap;
    for (final m in thread) {
      if (!m.outbound || m.id.startsWith(localEchoPrefix)) continue;
      final at = _instant(m.receivedAt);
      if (at == null) continue;
      final gap = at.difference(created).abs();
      if (gap > echoMatchWindow) continue;
      if (bestGap == null || gap < bestGap) {
        best = m;
        bestGap = gap;
      }
    }
    if (best == null) return false;
    await _store.updateReminder(
      r.id,
      anchorMessageId: best.id,
      updatedAt: MessageStore.isoStamp(_clock()),
    );
    if (r.kind == ReminderKind.followUp && r.flagMessageId.isEmpty) {
      await _flag(r, best.id);
    }
    return true;
  }

  /// Flags [graphId] for follow-up [r], due at its reminder, and stores it
  /// as the row's `flag_message_id` on success. Best effort: any failure is
  /// one `reminder {action: flag, status: error}` row and a false.
  Future<bool> _flag(Reminder r, String graphId) async {
    try {
      final outcome = await _backend.flagMessages(
        [graphId],
        status: 'flagged',
        dueUtc: r.remindAtUtc,
      );
      if (outcome.updated < 1) {
        throw TasksRefused(
          outcome.failed.isEmpty ? 'not_flagged' : outcome.failed.first.error,
          '',
        );
      }
      await _store.updateReminder(
        r.id,
        flagMessageId: graphId,
        updatedAt: MessageStore.isoStamp(_clock()),
      );
      return true;
    } catch (e) {
      debugPrint('reminder flag: ${e.runtimeType}');
      await _log.record(
        'reminder',
        status: 'error',
        source: r.source,
        entityId: r.conversationKey,
        detail: {'action': 'flag', 'kind': r.kind.wire},
      );
      return false;
    }
  }

  /// Completes or clears the flag on [graphId]; best effort, printed by type.
  Future<void> _setFlag(Reminder r, String graphId, String status) async {
    try {
      await _backend.flagMessages([graphId], status: status);
    } catch (e) {
      debugPrint('reminder flag $status: ${e.runtimeType}');
    }
  }

  /// The persisted list id, or a list found or made now and persisted.
  Future<String> _listId() async {
    final stored = await _store.getPref(todoListIdKey);
    if (stored != null && stored.isNotEmpty) return stored;
    return _ensureList();
  }

  Future<String> _ensureList() async {
    final list = await _backend.ensureList();
    await _store.setPref(todoListIdKey, list.id);
    return list.id;
  }

  /// The mailbox's Windows zone name for the task's due date, or null (the
  /// server's UTC default) when the settings are unknown or unreadable.
  Future<String?> _mailboxZone() async {
    try {
      final zone = (await _mailbox())?.timeZone;
      return zone == null || zone.isEmpty ? null : zone;
    } catch (_) {
      return null;
    }
  }

  static bool _isWebUrl(String s) {
    final uri = Uri.tryParse(s);
    return uri != null &&
        (uri.isScheme('https') || uri.isScheme('http')) &&
        uri.host.isNotEmpty;
  }

  static DateTime? _instant(String? iso) =>
      iso == null ? null : DateTime.tryParse(iso)?.toUtc();
}
