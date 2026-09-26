import 'package:flutter/foundation.dart' show immutable;

/// The owner's own vocabulary: the words a person files their own threads
/// under, and the link that says which threads each word is on.
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

/// One label on one thread: the link row, for the callers that care who put it
/// there rather than just what it says.
///
/// [appliedBy] is `'user'`, the only value this build writes.
@immutable
class ConversationLabel {
  final String source;
  final String conversationKey;
  final String labelId;
  final String appliedBy;
  final String appliedAt;

  const ConversationLabel({
    required this.source,
    required this.conversationKey,
    required this.labelId,
    this.appliedBy = 'user',
    this.appliedAt = '',
  });

  /// A row of the `conversation_labels` table.
  factory ConversationLabel.fromRow(Map<String, Object?> row) =>
      ConversationLabel(
        source: row['source'] as String? ?? '',
        conversationKey: row['conversation_key'] as String? ?? '',
        labelId: row['label_id'] as String? ?? '',
        appliedBy: row['applied_by'] as String? ?? 'user',
        appliedAt: row['applied_at'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is ConversationLabel &&
      other.source == source &&
      other.conversationKey == conversationKey &&
      other.labelId == labelId &&
      other.appliedBy == appliedBy &&
      other.appliedAt == appliedAt;

  @override
  int get hashCode =>
      Object.hash(source, conversationKey, labelId, appliedBy, appliedAt);
}
