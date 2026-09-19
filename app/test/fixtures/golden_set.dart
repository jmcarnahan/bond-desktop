import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/llm/message_block.dart';

import 'golden_json.dart';

/// The golden set, read back into the shapes the app's own tasks take.
///
/// The set is a hundred real messages with gold labels for every stage, and it
/// lives OUTSIDE version control on the machine that made it — this repo is
/// public. So nothing here knows a path: callers pass one (`GOLDEN_SET`, which
/// the Makefile fills from `GOLDEN`), and the committed tests read the small
/// fictional fixture beside this file instead.
///
/// The job of this file is narrow on purpose: rebuild a [Message] and its
/// thread the way the app would have had them, so a replay puts the SAME
/// prompt in front of a model that the pipeline puts there. Scoring is not
/// here and never will be — `golden/tools/score_run.py` is the scorer of
/// record, and a second opinion about what "correct" means is exactly the
/// thing a bakeoff must not grow.

/// Which rung of the context ladder a stage is shown.
///
/// The set carries what all four rungs need for every item because the
/// pipeline is inconsistent about thread context today — triage and needs-you
/// see the last three messages, extraction sees the message alone — and the
/// only way to price context is to make the rung a variable.
enum GoldenCtx {
  /// The message alone.
  none,

  /// The last three messages of the thread, which is what triage and needs-you
  /// get today.
  tail3,

  /// The tail, led by the item's extractive digest of everything earlier.
  compressed,

  /// The newest three as `tail3`, plus the item's digest as its own
  /// `thread_digest` fence — `compressed` is the superseded 2026-09-14 form
  /// that rode the digest as a 300-character synthetic message.
  digest,
}

/// Reads the `GOLDEN_CTX` define. Case-insensitive; anything else is a typo
/// worth stopping for rather than silently benching the wrong rung.
GoldenCtx parseGoldenCtx(String raw) => switch (raw.trim().toLowerCase()) {
      'none' => GoldenCtx.none,
      'tail3' => GoldenCtx.tail3,
      'compressed' => GoldenCtx.compressed,
      'digest' => GoldenCtx.digest,
      _ => throw ArgumentError.value(
          raw,
          'GOLDEN_CTX',
          'must be one of none, tail3, compressed, digest',
        ),
    };

/// The nullable half of [asString]. Used wherever the app's own model takes a
/// `String?`: a field the set left as a number or an object is "not recorded",
/// which is a thing these models already express, and never a cast error
/// halfway through loading a hundred items.
String? _asStringOrNull(Object? value) => value is String ? value : null;

/// The gold labels, in the shape the harness itself needs.
///
/// Deliberately partial. The harness picks populations (gold-keep), picks
/// storyline candidates (the gold id and the forbidden neighbours), and
/// reports which context rung a label needed; every other gold field is read
/// by the Python scorer straight out of the file. [raw] is kept so a caller
/// that needs one more field does not have to widen this class to get it.
class GoldenGold {
  /// `keep` or `drop` — the population split every ledger row is quoted on.
  final String gateVerdict;

  /// The registry slug this item belongs under, or `none`.
  final String storylineId;

  /// `must`, `should` or `may`: how hard the assignment is scored.
  final String storylineStrength;

  /// Slugs (registry and `ANTI-*`) that are a hard error on this item.
  final List<String> storylineForbidden;

  /// Whether this item carries a reply rubric — the draft population.
  final bool hasReply;

  /// Gold `triage.reply_expected`, which the reply-decision stage is scored
  /// against.
  final bool replyExpected;

  /// Gold `needs_you.verdict`.
  final bool needsYou;

  /// Per stage (`triage`, `extract`, `needs_you`, `storyline`), the context
  /// rung the annotators say the label needs. This is what makes the ladder
  /// answerable: a run can be broken down by it.
  final Map<String, String> derivableFrom;

  /// `2/2` when both annotators agreed, `1/2` when adjudication settled it.
  final String annotatorAgreement;

  /// The whole gold block, untouched.
  final Map<String, dynamic> raw;

  const GoldenGold({
    required this.gateVerdict,
    required this.storylineId,
    required this.storylineStrength,
    required this.storylineForbidden,
    required this.hasReply,
    required this.replyExpected,
    required this.needsYou,
    required this.derivableFrom,
    required this.annotatorAgreement,
    required this.raw,
  });

  factory GoldenGold.fromJson(Map<String, dynamic> gold) {
    final storyline = asMap(gold['storyline']);
    final triage = asMap(gold['triage']);
    final extract = asMap(gold['extract']);
    final needsYou = asMap(gold['needs_you']);
    final storylineId = asString(storyline['id']);
    return GoldenGold(
      gateVerdict: asString(asMap(gold['gate'])['verdict']),
      // An absent or empty id is the assertion "no storyline", which is a
      // label in its own right — 35 items in the real set carry it — not a
      // missing value.
      storylineId: storylineId.isEmpty ? 'none' : storylineId,
      storylineStrength: asString(storyline['strength']),
      storylineForbidden: asStrings(storyline['forbidden']),
      hasReply: gold['reply'] != null,
      replyExpected: triage['reply_expected'] == true,
      needsYou: needsYou['verdict'] == true,
      derivableFrom: {
        'triage': asString(triage['derivable_from']),
        'extract': asString(extract['derivable_from']),
        'needs_you': asString(needsYou['derivable_from']),
        'storyline': asString(storyline['derivable_from']),
      },
      annotatorAgreement: asString(gold['annotator_agreement']),
      raw: gold,
    );
  }
}

/// One golden item, rebuilt into what a stage would have been handed.
class GoldenItem {
  final String id;

  /// Which of the nine strata this item was drawn for — what it is here to
  /// test, and the first breakdown any run is read by.
  final String stratum;

  /// `easy`, `medium` or `hard`.
  final String difficulty;

  /// Why the item was chosen, in the set author's words.
  final String note;

  /// `email` or `teams`.
  final String source;

  /// `inbound` or `outbound`.
  final String direction;

  final String conversationKey;

  /// The judged message, rebuilt from `provenance` and the stored block.
  final Message message;

  /// The thread tail, oldest first, as triage and needs-you see it today.
  final List<Message> tail;

  /// The extractive digest of everything before the tail, or null when the
  /// item has no earlier thread to compress.
  final String? digest;

  /// The day the item was packed, as a LOCAL date — the same `now` every
  /// stage was given when the gold `deadline` and `urgency` labels were
  /// written, so those labels cannot rot as the wall clock moves.
  final DateTime now;

  /// Attachment rows in the shape `TriageInput.attachments` takes.
  final List<Map<String, Object?>> attachmentRows;

  final bool addressedMe;

  /// Display names on the conversation — what a storyline candidate card is
  /// built from.
  final List<String> conversationParticipants;

  final String? conversationSubject;

  /// The thread's own state as the set recorded it — `waiting`, `needs_reply`
  /// or `done`, the column `conversations.state` holds.
  ///
  /// Read by the sweep replay, which seeds the mailbox behind the items: the
  /// sweep DIVERTS a `done` thread out of clustering, so a seeding that
  /// defaulted every thread to one state would measure a pool the app never
  /// has. `waiting` when the set records none, which is the state a thread
  /// with nothing outstanding sits in.
  final String conversationState;

  /// The app's own 2026-09-12 output for this item, untouched. The Python
  /// scorer reads it for `--baseline`; nothing here interprets it.
  final Map<String, dynamic> stored;

  final GoldenGold gold;

  /// The prompt block the set recorded, verbatim.
  final String messageBlock;

  /// The app's own statement about how directly this message came at the
  /// reader, as the set recorded it. It rides OUTSIDE the prompt's fence — it
  /// is a fact the model may act on rather than text it must only analyse —
  /// so it is a second rendered input, and a second thing that can drift.
  final String directnessLine;

  /// The first date the digest's span covers, which dates the synthetic
  /// leading message at the `compressed` rung. Null when the item carries no
  /// digest or the digest records no span.
  final String? digestStartedAt;

  const GoldenItem({
    required this.id,
    required this.stratum,
    required this.difficulty,
    required this.note,
    required this.source,
    required this.direction,
    required this.conversationKey,
    required this.message,
    required this.tail,
    required this.digest,
    required this.now,
    required this.attachmentRows,
    required this.addressedMe,
    required this.conversationParticipants,
    required this.conversationSubject,
    required this.conversationState,
    required this.stored,
    required this.gold,
    required this.messageBlock,
    required this.directnessLine,
    this.digestStartedAt,
  });

  /// Whether the app renders this item into the block the set recorded.
  ///
  /// The set's blocks were produced by mirroring `message_block.dart`, so this
  /// is the round trip that says the replay is putting the real prompt in
  /// front of the model. A false here means the renderer moved and the numbers
  /// are measuring a prompt the app no longer sends.
  bool get blockMatches => buildMessageBlock(message) == messageBlock;

  /// Whether the app renders this item into the directness line the set
  /// recorded. The same round trip as [blockMatches], for the other half of
  /// what a stage is handed: the block is the message, this is the envelope.
  bool get directnessMatches =>
      buildDirectnessLine(message) == directnessLine;

  /// Whether the deterministic needs-you floor already settles this item —
  /// mirrors `needsYouFloor` in `lib/services/needs_you.dart`, which reads a
  /// database row rather than an item.
  bool get floorSaysYes =>
      direction == 'inbound' && source == 'teams' && addressedMe;

  /// How many thread messages triage and needs-you read: both take the LAST
  /// three (`TriageTask._threadTailMax`, `NeedsYouTask._maxContextMessages`),
  /// dropping from the oldest end.
  static const int _threadWindow = 3;

  /// The thread a stage is shown at [ctx].
  ///
  /// At `compressed` the digest rides in as one synthetic leading message
  /// rather than as a new prompt field: the prompts are not changed by a
  /// measurement round, and the existing thread fence is the cheapest honest
  /// way to price the rung. Because both readers keep only the newest three
  /// messages, the digest takes one of those three slots and the two newest
  /// tail messages take the others — handing them four would have them drop
  /// the digest, which is the oldest, and quietly score `tail3` twice. They
  /// also clip a thread message at 300 characters, so what they see of the
  /// digest is its head — a caveat the run prints rather than hides.
  List<Message> threadFor(GoldenCtx ctx) => switch (ctx) {
        GoldenCtx.none => const [],
        GoldenCtx.tail3 => tail,
        GoldenCtx.compressed => digest == null
            ? tail
            : [
                _digestMessage(digest!),
                ...tail.skip(
                  tail.length > _threadWindow - 1
                      ? tail.length - (_threadWindow - 1)
                      : 0,
                ),
              ],
        // The digest rung does not spend a thread slot on the digest: it rides
        // in its own prompt fence, so the tail is the whole tail.
        GoldenCtx.digest => tail,
      };

  /// The digest a stage is shown at [ctx], or null when the rung carries none.
  ///
  /// Only the `digest` rung passes one as a digest. At `compressed` it rides
  /// as a synthetic thread message instead — see [threadFor] — and reading it
  /// twice would price a rung nobody ran.
  String? digestFor(GoldenCtx ctx) => ctx == GoldenCtx.digest ? digest : null;

  Message _digestMessage(String body) => Message(
        id: '$id#digest',
        outbound: false,
        source: source,
        // Named rather than attributed: the digest is the set's own extractive
        // precis of several people, and putting one of their names on it would
        // be telling the model somebody wrote a sentence they did not.
        fromName: 'Earlier in this thread',
        receivedAt: digestStartedAt,
        bodyText: body,
      );

  factory GoldenItem.fromJson(Map<String, dynamic> json) {
    final id = asString(json['id']);
    final provenance = asMap(json['provenance']);
    final stageInput = asMap(json['stage_input']);
    final conversation = asMap(json['conversation']);
    final source = asString(provenance['source'], 'email');
    final direction = asString(provenance['direction'], 'inbound');
    final block = asString(stageInput['message_block']);

    final compressed = asMap(stageInput['ctx_compressed']);
    final threadDigest = asMap(compressed['thread_digest']);
    final digest = asString(threadDigest['digest']);
    final span = asStrings(threadDigest['span']);

    return GoldenItem(
      id: id,
      stratum: asString(json['stratum']),
      difficulty: asString(json['difficulty']),
      note: asString(json['note']),
      source: source,
      direction: direction,
      conversationKey: asString(provenance['conversation_key']),
      message: _messageOf(id, provenance, block, source, direction),
      tail: _tailOf(id, source, stageInput),
      digest: digest.isEmpty ? null : digest,
      now: _nowOf(id, asString(stageInput['now'])),
      attachmentRows: [
        for (final name in asStrings(provenance['attachment_names']))
          // `_attachmentLine` reads exactly these three keys, and a size of 0
          // prints no suffix — the set records names and nothing else.
          {'name': name, 'size': 0, 'is_inline': 0},
      ],
      addressedMe: provenance['addressed_me'] == 1,
      conversationParticipants: asStrings(conversation['participants']),
      conversationSubject: _asStringOrNull(conversation['subject']),
      conversationState: _stateOf(conversation['state']),
      stored: asMap(json['stored']),
      gold: GoldenGold.fromJson(asMap(json['gold'])),
      messageBlock: block,
      directnessLine: asString(stageInput['directness_line']),
      digestStartedAt: span.isEmpty ? null : span.first,
    );
  }

  /// The judged message, rebuilt so that [buildMessageBlock] reproduces the
  /// recorded block.
  ///
  /// The body is read back OUT of the block rather than out of the database
  /// the set was built from: the block is what the model saw, marker-stripped
  /// and clipped at 4000 characters already, and re-deriving it would be a
  /// second renderer to keep in step with the first.
  static Message _messageOf(
    String id,
    Map<String, dynamic> provenance,
    String block,
    String source,
    String direction,
  ) {
    const marker = '\n\nBody:\n';
    final split = block.indexOf(marker);
    final body = split < 0 ? '' : block.substring(split + marker.length);
    return Message(
      id: id,
      outbound: direction == 'outbound',
      source: source,
      fromName: _asStringOrNull(provenance['from_name']),
      // A chat's `from_address` is `teams:<graph user id>`, which the sender
      // line never prints. Carrying it would be carrying a value nothing reads.
      fromAddress:
          source == 'teams' ? null : _asStringOrNull(provenance['from_address']),
      // The set records how many addresses were on the envelope, not which:
      // `buildDirectnessLine` counts them and nothing else reads them.
      to: List.filled(
        provenance['to_count'] is int ? provenance['to_count'] as int : 0,
        '',
      ),
      receivedAt: _asStringOrNull(provenance['received_at']),
      subject: _asStringOrNull(provenance['subject']),
      bodyText: body,
      isRead: provenance['is_read'] == 1,
      addressedMe: provenance['addressed_me'] == 1,
      triageStatus: 'pending',
    );
  }

  static List<Message> _tailOf(
    String id,
    String source,
    Map<String, dynamic> stageInput,
  ) {
    final tail = asList(asMap(stageInput['ctx_tail3'])['thread_tail']);
    return [
      for (var i = 0; i < tail.length; i++)
        () {
          final entry = asMap(tail[i]);
          final who = asString(entry['who']);
          return Message(
            // Synthetic ids: the set records a tail as text, and the thread a
            // prompt renders never needs a real one.
            id: '$id#t$i',
            outbound: who == 'You',
            source: source,
            fromName: who,
            receivedAt: _asStringOrNull(entry['received_at']),
            bodyText: asString(entry['text']),
          );
        }(),
    ];
  }

  /// The recorded thread state, or `waiting`. An empty string takes the
  /// default too: a state column the set left blank is one nobody recorded,
  /// and `conversations.state` has no empty value.
  static String _stateOf(Object? raw) {
    final state = asString(raw).trim();
    return state.isEmpty ? 'waiting' : state;
  }

  /// `2026-09-09 (Wednesday)` → local midnight on that day. Local, not UTC:
  /// every stage is given `DateTime.now()` in production, and a UTC date here
  /// would shift a deadline by a day on this machine.
  ///
  /// Throws rather than falling back to the wall clock. The whole point of the
  /// recorded date is that a `deadline` or `urgency` label cannot rot as the
  /// clock moves; quietly substituting today's date would make the run score
  /// against labels written for a different day, and nothing would say so.
  static DateTime _nowOf(String id, String raw) {
    DateTime? parsed;
    if (raw.length >= 10) {
      parsed = DateTime.tryParse(raw.substring(0, 10));
    }
    if (parsed == null) {
      throw StateError(
        'golden item $id has no usable stage_input.now: "$raw"',
      );
    }
    return DateTime(parsed.year, parsed.month, parsed.day);
  }
}

/// A whole golden set.
class GoldenSet {
  /// The day the set was packed.
  final String generated;

  final List<GoldenItem> items;

  GoldenSet({required this.generated, required this.items});

  /// The items whose gold gate says `keep` — the population a model-quality
  /// number is quoted on, because triage never ran on the others.
  ///
  /// Built once. A replay asks for these per item, and rebuilding a filtered
  /// list or a hundred-entry map on every access turns a lookup into a scan.
  late final List<GoldenItem> keep = [
    for (final item in items)
      if (item.gold.gateVerdict == 'keep') item,
  ];

  late final Map<String, GoldenItem> byId = {
    for (final item in items) item.id: item,
  };

  static GoldenSet fromJson(Map<String, dynamic> json) => GoldenSet(
        generated: asString(json['generated']),
        items: [
          for (final entry in asList(json['items']))
            GoldenItem.fromJson(asMap(entry)),
        ],
      );
}

/// Reads a golden set off disk.
///
/// Throws rather than returning an empty set when the file is not there: the
/// set is git-ignored and machine-local by design, so "no file" is the normal
/// failure and it deserves a message that says what to set.
Future<GoldenSet> loadGoldenSet(String path) async {
  final file = File(path);
  if (!await file.exists()) {
    throw StateError(
      'no golden set at $path — it is git-ignored and machine-local; '
      'point GOLDEN at it in local.mk, or pass --dart-define=GOLDEN_SET=…',
    );
  }
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map || decoded['items'] is! List) {
    throw StateError(
      'the file at $path is not a golden set — no `items` array in it',
    );
  }
  return GoldenSet.fromJson(decoded.cast<String, dynamic>());
}
