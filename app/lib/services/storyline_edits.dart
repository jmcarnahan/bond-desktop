import '../data/message_store.dart';
import 'activity_log.dart';
import 'pipeline_progress.dart';
import 'storyline_service.dart';

/// Everything a PERSON does to a storyline, and nothing else.
///
/// The half of the storyline work that touches no model at all: renaming,
/// keeping, dismissing, filing a thread in and pulling one out. It was lifted
/// out of `storyline_service.dart` whole, which is what makes the extraction
/// safe to read — the region dialled no client, held no embeddings and asked
/// no membership question before the move, and it asks none now.
///
/// [StorylineService] keeps every one of these as a one-line delegate, so the
/// providers and the gate repair service call exactly what they always called.
///
/// [memberHashOf] is the one thing that crosses back: four other callers in the
/// service compute the same hash, so it is shared as a callback rather than
/// copied into a second recipe that could drift.
class StorylineEdits {
  StorylineEdits(
    this._store, {
    this._progress = const PipelineProgress.disabled(),
    ActivityLog? log,
    required this._memberHashOf,
  }) : _log = log ?? ActivityLog.disabled();

  /// What the sweep and recruit WORK ROWS are labelled with. A copy of
  /// `StorylineService._workSource` rather than a reference to it: it is a
  /// constant, and every such row ever written carries `'email'`, so changing
  /// the label would strand the existing rows' idempotence keys.
  static const String _workSource = 'email';

  final MessageStore _store;

  /// Announces a hand-filed membership to an open home screen. It carries the
  /// tick and NOT the write — the stamp happens either way, see
  /// [PipelineProgress.noteStorylineLink].
  final PipelineProgress _progress;

  /// The hash of a storyline's member set, computed by the service so that the
  /// four callers there and the three here cannot answer differently.
  final Future<String> Function(String storylineId) _memberHashOf;

  final ActivityLog _log;

  /// Starts a storyline around one thread. Active immediately and titled by
  /// the user, so it never appears as something to accept — a person does not
  /// need the app's permission for a group they just made.
  ///
  /// An optional [charter] says what belongs here in the same act, which is the
  /// only way a person gets the charter and its hunt from one press. It locks
  /// like a charter saved from the About block does, and it queues one
  /// [StorylineService.recruit] AFTER [addThread] so the drain sees the handler
  /// order — the refresh the add queues runs first, against a storyline that
  /// already has its criteria. A call with no charter is what it always was: no
  /// charter, no lock, no recruit.
  Future<String> createStoryline(
    String title, {
    required String source,
    required String conversationKey,
    String? charter,
  }) async {
    final id = newStorylineId();
    final trimmed = (charter ?? '').trim();
    await _store.insertStoryline(
      id: id,
      title: title,
      charter: trimmed.isEmpty ? null : trimmed,
      status: 'active',
      createdBy: 'user',
    );
    await _store.updateStoryline(
      id,
      titleLocked: true,
      // Null, not false, on the charterless call: a null named argument is the
      // column left alone, and a create with no charter must write exactly
      // what it always wrote.
      charterLocked: trimmed.isEmpty ? null : true,
    );
    await addThread(id, source, conversationKey);
    if (trimmed.isNotEmpty) {
      await _store.requeueWork(
        'storyline_recruit',
        _workSource,
        id,
        refreshCreatedAt: true,
      );
    }
    return id;
  }

  /// A storyline the user declared before any thread was in it.
  ///
  /// The measured path this exists for: a person naming a group and saying
  /// what belongs in it beats every proposer the sweep has, because the
  /// confirm is answering a question somebody actually asked. So the title and
  /// the charter are both the user's word and both locked, and the only thing
  /// the model is asked for is the filing.
  ///
  /// No [addThread], so no refresh and no recap: there is nothing yet to
  /// describe, and the first refresh comes when [StorylineService.recruit]
  /// files a member. The recruit is revived rather than merely enqueued, for
  /// the reason every user action is — the person is sitting in front of the
  /// pane waiting for it.
  Future<String> declareStoryline({
    required String title,
    required String charter,
  }) async {
    final id = newStorylineId();
    await _store.insertStoryline(
      id: id,
      title: title,
      charter: charter.trim(),
      status: 'active',
      createdBy: 'user',
    );
    await _store.updateStoryline(id, titleLocked: true, charterLocked: true);
    await _store.requeueWork(
      'storyline_recruit',
      _workSource,
      id,
      refreshCreatedAt: true,
    );
    return id;
  }

  Future<void> keepSuggestion(String id) =>
      _store.updateStoryline(id, status: 'active');

  /// Retires a storyline — a suggestion the user never wanted, or a kept one
  /// they are done with. Nothing else moves: the row keeps both hashes, which
  /// is what [MessageStore.dismissedHashExistsAny] reads when the very next
  /// sweep rebuilds the same cluster, and the member rows stay as the record
  /// of what the user was actually shown.
  Future<void> dismissSuggestion(String id) =>
      _store.updateStoryline(id, status: 'dismissed');

  /// Brings a dismissed storyline back as a suggestion — the state it was in
  /// before the owner said no, so the same Keep / Dismiss question is asked
  /// again. The tombstone check keys on `status = 'dismissed'`, so restoring
  /// also lifts the block on re-proposing this member set. Members were kept
  /// on dismissal, so nothing else needs rebuilding.
  Future<void> restoreDismissed(String id) =>
      _store.updateStoryline(id, status: 'suggested');

  Future<void> rename(String id, String title) =>
      _store.updateStoryline(id, title: title, titleLocked: true);

  /// Saves the user's charter and sends the model hunting with it.
  ///
  /// A non-empty save locks the charter — the same contract a rename gives the
  /// title — and queues one [StorylineService.recruit] pass, revived rather
  /// than merely enqueued so the second edit of the day recruits again.
  /// Clearing the text unlocks and queues a [StorylineService.refresh] instead:
  /// the About block promises that clearing a charter lets the model draft a
  /// new one, and until this queued something that promise was not kept.
  /// Nothing is recruited on the strength of criteria the user just deleted —
  /// the refresh writes a charter, and the re-arm inside it is what goes
  /// looking afterwards.
  ///
  /// Both arms clear any parked suggestion. The user has just said what
  /// belongs in this storyline; an offer written against what they said
  /// before is stale by definition, and leaving it on screen would ask them
  /// to answer a question they have already answered.
  Future<void> setCharter(String id, String charter) async {
    final trimmed = charter.trim();
    if (trimmed.isEmpty) {
      await _store.updateStoryline(
        id,
        charter: null,
        charterLocked: false,
        charterSuggestion: null,
      );
      await _store.requeueWork('storyline_refresh', _workSource, id);
      return;
    }
    await _store.updateStoryline(
      id,
      charter: trimmed,
      charterLocked: true,
      charterSuggestion: null,
    );
    await _store.requeueWork('storyline_recruit', _workSource, id);
  }

  /// Throws away the charter the refresh pass parked. Nothing else moves: the
  /// user's own charter and its lock are untouched, and the next refresh that
  /// finds the group has outgrown it may park another — which is right, since
  /// by then it is a different group.
  Future<void> dismissCharterSuggestion(String id) =>
      _store.updateStoryline(id, charterSuggestion: null);

  /// Files a thread into a storyline by hand. The member write clears any
  /// block the user's own earlier removal left, which is what makes putting a
  /// thread back work at all — see [MessageStore.addStorylineMember].
  ///
  /// It also stamps the thread's messages, which is what makes the filing
  /// VISIBLE. The home feed and the hot-storylines strip both read
  /// `message_progress.storyline_id` and know nothing about member rows, so a
  /// thread added by hand used to appear on the timeline and the rail and
  /// nowhere else.
  ///
  /// And it queues a [StorylineService.refresh], unconditionally — unlike the
  /// automatic path, which is gated. A person filing a thread by hand is saying
  /// this group is about that too, and they are looking at the description
  /// while they say it.
  ///
  /// It queues a [StorylineService.recap] for the same reason, and the two are
  /// separate requeues rather than one: the thread that just arrived brings its
  /// own messages, so where this storyline STANDS changed the moment it was
  /// filed, not only what the storyline is about. The refresh queues one of
  /// these too, but only when it gets past its own gate — and a hand-filed
  /// thread is the case where the user is watching.
  Future<void> addThread(String id, String source, String key) async {
    // Evidence, on a `user` row, and it is not decoration: this membership is
    // read back as an EXAMPLE by the confirm prompt (see
    // `StorylineService._examplesFor`), and a removal copies the member's
    // evidence onto its block. A row with none would hand a later removal a
    // negative example that says nothing.
    await _store.addStorylineMember(
      id,
      source,
      key,
      addedBy: 'user',
      evidence: 'Filed by you',
    );
    final storyline = await _store.getStoryline(id);
    await _store.updateStoryline(
      id,
      memberHash: await _memberHashOf(id),
      // Cleared with the hash, for the reason spelled out in
      // [StorylineService.assignConversation] — and this is the path it was
      // written for. A thread a person files by hand is usually one they went
      // looking for, which means an old one, and without this the recap
      // requeued below would find the mark already past every message on it and
      // return having said nothing.
      recapThrough: null,
      // Filing a thread into a suggestion is accepting it — the same write
      // [keepSuggestion] makes. Nothing is left to ask about a group the user
      // is already putting threads into.
      status: storyline?.status == 'suggested' ? 'active' : null,
    );
    await stampPointer(source, key);
    final row = await _store.getConversationRow(source, key);
    final lastMessageAt = row?['last_message_at'] as String?;
    if (lastMessageAt != null && lastMessageAt.isNotEmpty) {
      await _store.touchStorylineActivity(id, lastMessageAt);
    }
    await _store.requeueWork('storyline_refresh', _workSource, id);
    await _store.requeueWork('storyline_recap', _workSource, id);
  }

  /// Takes a thread out, and blocks it from coming back. Always blocking:
  /// there is no other way for a user to reach this, and an unblocked removal
  /// would be undone by the next assignment pass.
  ///
  /// The clear names [id] rather than blanking the column, and then whatever
  /// membership is LEFT takes the pointer over: a thread in two storylines
  /// pulled out of one still belongs to the other, and a feed row that went
  /// blank would be telling the user it belongs to nothing.
  ///
  /// A removal changes what the storyline is about as surely as an addition
  /// does, so it queues the same [StorylineService.refresh]. A storyline
  /// emptied down to nothing is safe: the pass stamps on a member set with no
  /// cards and says nothing.
  ///
  /// It is also the one membership change that adds no message anywhere, which
  /// is why clearing the recap watermark matters most here: the recap the
  /// refresh tail queues has no new mail to make it stale, and would return at
  /// its own gate still describing a thread that is gone. The stored recap is
  /// cleared with the watermark, so the recap this queues starts from the
  /// remaining threads rather than carrying the departed one forward.
  ///
  /// And it queues an [audit] as well as the refresh. A removal is the owner
  /// saying the model got this group wrong, and the threads the same reasoning
  /// filed here are still sitting in it — so the automatic members are
  /// re-judged. The audit handler is registered AFTER the refresh handler, so
  /// the two run in that order within one drain and the audit judges against
  /// the charter the refresh has just narrowed.
  Future<void> removeThread(String id, String source, String key) async {
    // `blocked_by: 'user'` — the owner's own "no", which is the only kind the
    // confirm prompt ever learns from. The evidence is copied off the member
    // row by the store, so the block records what the model thought when it
    // filed the thread the owner is now taking out.
    await _store.removeStorylineMember(
      id,
      source,
      key,
      block: true,
      blockedBy: 'user',
    );
    await _store.updateStoryline(
      id,
      memberHash: await _memberHashOf(id),
      // Cleared with the hash, for the reason spelled out in
      // [StorylineService.assignConversation].
      recapThrough: null,
      // And the recap itself goes with the members, which is what makes a
      // removal different from every other membership change. The recap pass
      // is handed the previous recap and told to carry forward what is still
      // true, and it has no way to know which sentence came from the thread
      // that just left — so a paragraph naming that thread would survive every
      // rewrite. Cleared, the recap this removal queues is written from the
      // remaining threads alone. An addition clears nothing: new mail adds
      // facts, it never invalidates the ones already written.
      recapText: null,
      recapOpenJson: null,
      recapDecisionsJson: null,
    );
    _progress.noteStorylineLink(
      source,
      await _store.stampStorylineId(source, key, clearingStorylineId: id),
    );
    await stampPointer(source, key);
    await _store.requeueWork('storyline_refresh', _workSource, id);
    await _store.requeueWork('storyline_audit', _workSource, id);
  }

  /// A gate's removal of one thread from every live storyline it is in, and
  /// how many memberships that came to.
  ///
  /// The sibling of [removeThread], and everything that method does to keep a
  /// storyline honest about its members is done here too: the member row goes,
  /// a block goes in its place, the member hash is recomputed, the recap and
  /// its watermark are cleared for the reason [removeThread] spells out, the
  /// per-thread pointer is re-stamped onto whatever membership is left, and a
  /// refresh is queued because a group that lost a thread describes something
  /// slightly different now.
  ///
  /// Three things differ, and each of them is the point:
  ///
  /// - `blocked_by: 'gate'` with an explicit evidence string. A block's
  ///   evidence defaults to the MEMBER's own — what the model thought when it
  ///   filed the thread — and that is the wrong sentence here, because this
  ///   removal is not a judgement about the group at all. The block says why
  ///   the thread left: nothing in it was ever meant for a model.
  /// - no audit. [removeThread] queues one because the owner removing a thread
  ///   is the owner saying the model got this group wrong, and the threads the
  ///   same reasoning filed here deserve re-judging. A gate says nothing about
  ///   the model's reasoning — the thread should never have reached it — so
  ///   there is no lesson to spread.
  /// - a `user`-added membership is left exactly where it is. The owner filed
  ///   that thread by hand, and a gate does not overrule a person.
  ///
  /// The block outlives a Restore, deliberately. Restoring one message puts it
  /// back in front of the model; whether its thread belongs in this storyline
  /// is a separate question, and "Allow again" is where the owner answers it.
  Future<int> evictGatedThread(String source, String key) async {
    var evicted = 0;
    for (final id in await _store.storylineIdsFor(source, key)) {
      final member = (await _store.membersOf(id)).where(
        (m) => m.source == source && m.conversationKey == key,
      );
      if (member.isEmpty) continue;
      if (member.first.addedBy == 'user') continue;
      await _store.removeStorylineMember(
        id,
        source,
        key,
        block: true,
        blockedBy: 'gate',
        evidence: 'every inbound message in this thread was gated',
      );
      await _store.updateStoryline(
        id,
        memberHash: await _memberHashOf(id),
        recapThrough: null,
        recapText: null,
        recapOpenJson: null,
        recapDecisionsJson: null,
      );
      _progress.noteStorylineLink(
        source,
        await _store.stampStorylineId(source, key, clearingStorylineId: id),
      );
      await stampPointer(source, key);
      await _store.requeueWork('storyline_refresh', _workSource, id);
      evicted++;
    }
    return evicted;
  }

  /// Lifts a block and nothing else — "Allow again".
  ///
  /// The thread is NOT re-filed: the owner is withdrawing a veto, not making a
  /// membership. Whether it belongs is a question the model may now answer on
  /// its own judgement the next time a pass considers the thread, which is
  /// what makes this different from [addThread].
  ///
  /// Nothing is queued. There is no membership change to re-describe and
  /// nothing new to recap — the storyline is exactly as it was a moment ago,
  /// and only the set of threads a future pass may look at has widened.
  Future<void> unblockThread(String id, String source, String key) async {
    await _store.unblockStorylineMember(id, source, key);
    await _log.record(
      'storyline_unblock',
      source: source,
      entityId: key,
      detail: {'storyline_id': id},
    );
  }

  /// Points a thread's messages at the storyline the rest of the app would
  /// say it is in, or leaves them alone when it is in none.
  ///
  /// The id is `storylineIdsFor(...).first` — deliberately the same pick
  /// [PipelineProgress.assignedStorylineId] makes, which is oldest membership
  /// first. So filing a thread into a SECOND storyline stamps the first one it
  /// joined, not the one just chosen: the two answers must agree, or the feed
  /// row and the automatic pass would fight over the column every time the
  /// thread was touched.
  Future<void> stampPointer(String source, String key) async {
    final ids = await _store.storylineIdsFor(source, key);
    if (ids.isEmpty) return;
    _progress.noteStorylineLink(
      source,
      await _store.stampStorylineId(source, key, storylineId: ids.first),
    );
  }
}
