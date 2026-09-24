import 'package:flutter/foundation.dart' show immutable;

/// The owner's own vocabulary: the words a person files their own threads
/// under, the link that says which threads each word is on, and the standing
/// rules a word can carry into the mail that has not arrived yet.
///
/// Never the same thing as `messages.label`, which is the model's verdict about
/// one message. The two are never mixed: nothing here is written by the
/// pipeline, and nothing the pipeline writes appears in the picker.
///
/// Row-shaped and defensive like the models beside it — every field reads
/// through a nullable cast with a default, so a half-written row cannot throw
/// during a render.

/// The separator between the FIELDS of one label inside a GROUP_CONCAT'd
/// column, and the one between whole labels.
///
/// Two control characters rather than a comma and a semicolon, because a label
/// name is free text the owner typed: `Waiting on legal, then finance` is a
/// perfectly good name, and a comma separator would read it as two labels.
/// ASCII has had a unit separator (0x1f) and a record separator (0x1e) for this
/// exact job since 1963, and neither survives a text field a person types into —
/// macOS gives no keystroke for either. [Label.parseConcat] is the one reader
/// and `MessageStore.loadConversations` the one writer; a name that somehow
/// carried one anyway is handled there rather than corrupting the parse.
const String labelFieldSeparator = '\u001f';
const String labelRecordSeparator = '\u001e';

/// One word in the owner's vocabulary.
@immutable
class Label {
  /// A slug minted once at creation and stable across every rename — which is
  /// what lets a rename keep every link the label already has. Nothing parses
  /// it; a slug rather than a number only so a stored id is readable in a
  /// query when somebody is debugging one.
  final String id;

  /// What the owner typed, in their own casing.
  final String name;

  /// A [BondTone] name (`neutral`, `primary`, `success`, `attention`, `error`)
  /// or null for the default. The WORD is stored and the widget resolves it, so
  /// this layer — and the store under it — knows nothing about colour.
  final String? tone;

  /// How many times this label has been applied. A POPULARITY signal and not a
  /// refcount: it orders the picker's chips, and removing a label from one
  /// thread leaves it alone (see `MessageStore.removeLabel`), because how often
  /// a word has been reached for is not undone by taking it off one thread.
  final int useCount;

  /// When it was last applied, or null for a label nobody has used yet. The
  /// picker's tie-breaker under [useCount].
  final String? lastUsedAt;

  final String createdAt;
  final String updatedAt;

  const Label({
    required this.id,
    required this.name,
    this.tone,
    this.useCount = 0,
    this.lastUsedAt,
    this.createdAt = '',
    this.updatedAt = '',
  });

  /// A row of the `labels` table.
  factory Label.fromRow(Map<String, Object?> row) => Label(
        id: row['id'] as String? ?? '',
        name: row['name'] as String? ?? '',
        tone: row['tone'] as String?,
        useCount: (row['use_count'] as num?)?.toInt() ?? 0,
        lastUsedAt: row['last_used_at'] as String?,
        createdAt: row['created_at'] as String? ?? '',
        updatedAt: row['updated_at'] as String? ?? '',
      );

  /// The labels of one conversation out of a GROUP_CONCAT'd column, in the
  /// order the subquery emitted them.
  ///
  /// Null or empty is the empty list, which is what an absent join reads as: a
  /// read that does not ask about labels must show none rather than throw.
  /// Three fields per label — id, name, tone — because that is what a chip
  /// draws; the counts and stamps belong to the picker, which reads the table
  /// itself.
  ///
  /// A label whose NAME somehow contains a separator is not allowed to shift
  /// the fields of every label after it: the split is bounded to three parts,
  /// so an extra unit separator lands inside the tone and an extra record
  /// separator costs that one label rather than the list.
  static List<Label> parseConcat(Object? value) {
    final text = value as String? ?? '';
    if (text.isEmpty) return const [];
    final labels = <Label>[];
    for (final entry in text.split(labelRecordSeparator)) {
      if (entry.isEmpty) continue;
      final parts = entry.split(labelFieldSeparator);
      if (parts.isEmpty || parts.first.isEmpty) continue;
      final tone = parts.length > 2 ? parts[2] : '';
      labels.add(
        Label(
          id: parts.first,
          name: parts.length > 1 ? parts[1] : '',
          tone: tone.isEmpty ? null : tone,
        ),
      );
    }
    return labels;
  }

  /// Value equality, unlike `AttachmentRef` next door and for the opposite
  /// reason: a label is five short fields the owner set by hand, a list of them
  /// is what a chip row rebuilds against, and two reads of the same unchanged
  /// vocabulary must compare equal or every frame redraws.
  @override
  bool operator ==(Object other) =>
      other is Label &&
      other.id == id &&
      other.name == name &&
      other.tone == tone &&
      other.useCount == useCount &&
      other.lastUsedAt == lastUsedAt &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode =>
      Object.hash(id, name, tone, useCount, lastUsedAt, createdAt, updatedAt);

  @override
  String toString() => 'Label($id, $name)';
}

/// One label on one thread: the link row, for the two callers that care who put
/// it there rather than just what it says.
///
/// [appliedBy] is `'user'` for a word the owner chose and `'rule'` for one a
/// standing rule filed; [ruleId] names which rule, and is null on every link a
/// person applied by hand.
@immutable
class ConversationLabel {
  final String source;
  final String conversationKey;
  final String labelId;
  final String appliedBy;
  final String appliedAt;

  /// The [LabelRule] that filed this link, or null when the owner did.
  ///
  /// Null is load-bearing rather than incidental: undoing a rule deletes the
  /// links carrying its id and leaves the rest, so a thread the owner had
  /// already filed under the same word keeps its chip.
  final String? ruleId;

  const ConversationLabel({
    required this.source,
    required this.conversationKey,
    required this.labelId,
    this.appliedBy = 'user',
    this.appliedAt = '',
    this.ruleId,
  });

  /// A row of the `conversation_labels` table.
  factory ConversationLabel.fromRow(Map<String, Object?> row) =>
      ConversationLabel(
        source: row['source'] as String? ?? '',
        conversationKey: row['conversation_key'] as String? ?? '',
        labelId: row['label_id'] as String? ?? '',
        appliedBy: row['applied_by'] as String? ?? 'user',
        appliedAt: row['applied_at'] as String? ?? '',
        ruleId: row['rule_id'] as String?,
      );

  /// Whether a standing rule filed this rather than the owner.
  bool get isRule => appliedBy == 'rule';

  @override
  bool operator ==(Object other) =>
      other is ConversationLabel &&
      other.source == source &&
      other.conversationKey == conversationKey &&
      other.labelId == labelId &&
      other.appliedBy == appliedBy &&
      other.appliedAt == appliedAt &&
      other.ruleId == ruleId;

  @override
  int get hashCode =>
      Object.hash(source, conversationKey, labelId, appliedBy, appliedAt, ruleId);
}

/// A label pointed at the mail that has not arrived yet: the owner's word for
/// what a kind of thread is, plus what should happen to the next one.
///
/// The whole of requirement 11b is in the two halves of that sentence. A person
/// dismisses a thread and files it under `Meeting response`; the rule is them
/// saying "and every future one of these, too". Nothing here is the model's
/// judgement — a rule exists because somebody typed a word and chose a scope.
///
/// Row-shaped and defensive like [Label] beside it: every field reads through a
/// nullable cast with a default, so a half-written row draws a rule that does
/// nothing rather than throwing inside a render.
@immutable
class LabelRule {
  /// Scope kinds, an OPEN set — `context_links.scope_kind` is the precedent.
  /// A stored kind this build does not know matches nothing, so a rule written
  /// by a later build is inert rather than fatal in an older one.
  static const String scopeSender = 'sender';
  static const String scopeDomain = 'domain';
  static const String scopeSubject = 'subject';
  static const String scopeClassification = 'classification';

  /// The dispositions, which are the sender rules' vocabulary minus `keep`:
  /// only two of these three are gates, and only one of them is about mail that
  /// has not been read yet.
  ///
  /// [dropAtGate] is the one that costs a message its model call, so it is the
  /// one a wrong rule loses something by. The other two move a thread the app
  /// has already read and can be undone by moving it back.
  static const String hideNeedsYou = 'hide_needs_you';
  static const String sendToLater = 'later';
  static const String dropAtGate = 'drop';

  /// A slug minted once at creation, like a [Label]'s. Nothing parses it.
  final String id;

  /// The word this rule files under — a [Label.id], never a name, so renaming
  /// the label keeps the rule.
  final String labelId;

  /// One of [scopeSender], [scopeDomain], [scopeSubject],
  /// [scopeClassification], or a kind a later build added.
  final String scopeKind;

  /// The address, domain, subject prefix or classification this rule is about,
  /// stored LOWERCASED. Every comparison against it is case-insensitive, and
  /// folding once at write time is what keeps the matcher from folding per row.
  final String scopeValue;

  /// [hideNeedsYou], [sendToLater] or [dropAtGate].
  final String disposition;

  /// Whether a message that singles the owner out escapes this rule. ON by
  /// default, because the tracker case needs it: the same address sends the
  /// digest nobody reads and the @mention addressed to the reader.
  ///
  /// Spent through the needs-you FLOOR, which may only raise a verdict — see
  /// `services/needs_you.dart`. This is not the matcher's business; a rule
  /// MATCHES either way and its consumers decide what the exception costs.
  final bool unlessMentionsMe;

  /// How many threads this rule has filed — the number the Settings list shows.
  /// It counts the rule's own links, so a thread the owner had already labelled
  /// by hand is hidden without being counted twice, and undo takes back exactly
  /// what this counted.
  final int hiddenCount;

  final String createdAt;
  final String updatedAt;

  /// The label's name, JOINED rather than stored — null when the read did not
  /// ask for it.
  ///
  /// It rides on the rule because both readers need it and neither wants a
  /// second query per row: the needs-you verdict's reason is
  /// `label_rule:<name>`, and the Settings list draws the word beside the
  /// scope. The rule still points at the label by [labelId], so a rename moves
  /// this and changes nothing else.
  final String? labelName;

  const LabelRule({
    required this.id,
    required this.labelId,
    required this.scopeKind,
    required this.scopeValue,
    required this.disposition,
    this.unlessMentionsMe = true,
    this.hiddenCount = 0,
    this.createdAt = '',
    this.updatedAt = '',
    this.labelName,
  });

  /// A row of the `label_rules` table, optionally carrying `label_name` from a
  /// join.
  ///
  /// The flag comes back as the INTEGER a STRICT column holds, so it is
  /// compared against 1 rather than trusted to be truthy — `needsYouFloor`'s
  /// rule, and for the same reason: anything else on the row is a bug upstream
  /// and must not be rounded up into an exception nobody asked for. A row
  /// written before the column existed cannot happen (it is NOT NULL DEFAULT 1),
  /// so a missing value reads as the default the table declares.
  factory LabelRule.fromRow(Map<String, Object?> row) => LabelRule(
        id: row['id'] as String? ?? '',
        labelId: row['label_id'] as String? ?? '',
        scopeKind: row['scope_kind'] as String? ?? '',
        scopeValue: row['scope_value'] as String? ?? '',
        disposition: row['disposition'] as String? ?? '',
        unlessMentionsMe: (row['unless_mentions_me'] as num?)?.toInt() != 0,
        hiddenCount: (row['hidden_count'] as num?)?.toInt() ?? 0,
        createdAt: row['created_at'] as String? ?? '',
        updatedAt: row['updated_at'] as String? ?? '',
        labelName: row['label_name'] as String?,
      );

  /// What the needs-you verdict records when this rule hides a thread.
  ///
  /// The NAME rather than the id, because this string is read by a person
  /// looking at why a thread is not on their rail, and a slug with four hex
  /// digits on the end answers nothing. The id is the fallback for a rule whose
  /// read did not join the label.
  String get verdictReason =>
      'label_rule:${(labelName == null || labelName!.isEmpty) ? labelId : labelName}';

  @override
  bool operator ==(Object other) =>
      other is LabelRule &&
      other.id == id &&
      other.labelId == labelId &&
      other.scopeKind == scopeKind &&
      other.scopeValue == scopeValue &&
      other.disposition == disposition &&
      other.unlessMentionsMe == unlessMentionsMe &&
      other.hiddenCount == hiddenCount &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt &&
      other.labelName == labelName;

  @override
  int get hashCode => Object.hash(id, labelId, scopeKind, scopeValue,
      disposition, unlessMentionsMe, hiddenCount, createdAt, updatedAt,
      labelName);

  @override
  String toString() => 'LabelRule($id, $scopeKind=$scopeValue, $disposition)';
}
