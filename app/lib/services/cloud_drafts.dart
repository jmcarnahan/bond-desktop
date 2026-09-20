import '../data/message_store.dart';
import 'llm/model_slots.dart' show LlmTargetSpec;

/// Today's count of drafts sent to a third-party target, against the cap.
///
/// Read by the three places a draft can leave the machine: the Improve
/// button, the standing rule in the draft handler, and a prefetched draft
/// whose `draft_reply` target is somebody else's machine. One line for all
/// of them, so the person sees the same sentence wherever the cap bites.
class CloudDraftLedger {
  final MessageStore _store;

  /// The cap, read at the moment it is needed. A closure and not a number
  /// because the cap is a SETTING: moving it has to move the next draft
  /// rather than wait for whatever holds this object to be rebuilt.
  final int Function() _cap;

  final DateTime Function() _now;

  CloudDraftLedger(
    this._store, {
    required int Function() cap,
    DateTime Function()? now,
  })  // A named parameter cannot be private, so the field is assigned rather
      // than taken as an initialising formal.
      // ignore: prefer_initializing_formals
      : _cap = cap,
        _now = now ?? DateTime.now;

  int get cap => _cap();

  /// Local midnight as the UTC ISO string `activity_events.created_at` is
  /// stamped in. Local, because "today" is the person's day, not UTC's.
  ///
  /// Written by the store's own [MessageStore.isoStamp], six fractional
  /// digits and all: the comparison in SQL is lexicographic, and a bound with
  /// fewer digits would sort AFTER a row stamped in the first millisecond of
  /// the day and drop it.
  static String startOfDayIso(DateTime now) {
    final local = now.toLocal();
    return MessageStore.isoStamp(
      DateTime(local.year, local.month, local.day).toUtc(),
    );
  }

  Future<int> usedToday() => _store.cloudDraftsSince(startOfDayIso(_now()));

  /// Null when one more draft may go; otherwise the one line every caller
  /// shows.
  Future<String?> refusal() async {
    final cap = _cap();
    return (await usedToday()) >= cap ? capMessage(cap) : null;
  }

  static String capMessage(int cap) =>
      "Cloud drafts are at today's cap of $cap. Raise it under Settings, "
      'Processing.';
}

/// Where the two draft stages point right now, read at the moment a draft is
/// about to be written. Closures for the handler's reason: a settings change
/// must move the NEXT draft, not rebuild the worker writing this one.
class DraftRoutes {
  /// `specForStage('draft_reply')`; never null in the app, null in tests.
  final LlmTargetSpec? Function() draftTarget;

  /// `specForStage('draft_improve')`: null when the stage points nowhere or
  /// its third-party target is still behind consent.
  final LlmTargetSpec? Function() improveTarget;

  /// `cloud_drafts_standing`.
  final bool Function() standing;

  /// Null only in [none], where nothing is routed and nothing can be sent.
  /// A THIRD-PARTY target meeting a null ledger is a wiring bug, and the
  /// handler throws on it rather than making an uncapped call.
  final CloudDraftLedger? ledger;

  const DraftRoutes({
    required this.draftTarget,
    required this.improveTarget,
    required this.standing,
    this.ledger,
  });

  /// Nothing routed and nothing standing — what a handler built without
  /// routing gets, and what keeps every construction that predates this
  /// drafting exactly as it did.
  static const DraftRoutes none = DraftRoutes(
    draftTarget: _null,
    improveTarget: _null,
    standing: _false,
  );

  static LlmTargetSpec? _null() => null;
  static bool _false() => false;
}
