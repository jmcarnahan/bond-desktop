// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class Messages extends Table with TableInfo<Messages, Message> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  Messages(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'email\'',
    defaultValue: const CustomExpression('\'email\''),
  );
  static const VerificationMeta _sourceMessageIdMeta = const VerificationMeta(
    'sourceMessageId',
  );
  late final GeneratedColumn<String> sourceMessageId = GeneratedColumn<String>(
    'source_message_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _internetMessageIdMeta = const VerificationMeta(
    'internetMessageId',
  );
  late final GeneratedColumn<String> internetMessageId =
      GeneratedColumn<String>(
        'internet_message_id',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        $customConstraints: '',
      );
  static const VerificationMeta _conversationKeyMeta = const VerificationMeta(
    'conversationKey',
  );
  late final GeneratedColumn<String> conversationKey = GeneratedColumn<String>(
    'conversation_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _directionMeta = const VerificationMeta(
    'direction',
  );
  late final GeneratedColumn<String> direction = GeneratedColumn<String>(
    'direction',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _subjectMeta = const VerificationMeta(
    'subject',
  );
  late final GeneratedColumn<String> subject = GeneratedColumn<String>(
    'subject',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _fromNameMeta = const VerificationMeta(
    'fromName',
  );
  late final GeneratedColumn<String> fromName = GeneratedColumn<String>(
    'from_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _fromAddressMeta = const VerificationMeta(
    'fromAddress',
  );
  late final GeneratedColumn<String> fromAddress = GeneratedColumn<String>(
    'from_address',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _recipientsJsonMeta = const VerificationMeta(
    'recipientsJson',
  );
  late final GeneratedColumn<String> recipientsJson = GeneratedColumn<String>(
    'to_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'[]\'',
    defaultValue: const CustomExpression('\'[]\''),
  );
  static const VerificationMeta _receivedAtMeta = const VerificationMeta(
    'receivedAt',
  );
  late final GeneratedColumn<String> receivedAt = GeneratedColumn<String>(
    'received_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _isReadMeta = const VerificationMeta('isRead');
  late final GeneratedColumn<int> isRead = GeneratedColumn<int>(
    'is_read',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT 0',
    defaultValue: const CustomExpression('0'),
  );
  static const VerificationMeta _bodyPreviewMeta = const VerificationMeta(
    'bodyPreview',
  );
  late final GeneratedColumn<String> bodyPreview = GeneratedColumn<String>(
    'body_preview',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _bodyTextMeta = const VerificationMeta(
    'bodyText',
  );
  late final GeneratedColumn<String> bodyText = GeneratedColumn<String>(
    'body_text',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _hasAttachmentsMeta = const VerificationMeta(
    'hasAttachments',
  );
  late final GeneratedColumn<int> hasAttachments = GeneratedColumn<int>(
    'has_attachments',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT 0',
    defaultValue: const CustomExpression('0'),
  );
  static const VerificationMeta _sourceMetaJsonMeta = const VerificationMeta(
    'sourceMetaJson',
  );
  late final GeneratedColumn<String> sourceMetaJson = GeneratedColumn<String>(
    'source_meta_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _triageStatusMeta = const VerificationMeta(
    'triageStatus',
  );
  late final GeneratedColumn<String> triageStatus = GeneratedColumn<String>(
    'triage_status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'pending\'',
    defaultValue: const CustomExpression('\'pending\''),
  );
  static const VerificationMeta _triageAttemptsMeta = const VerificationMeta(
    'triageAttempts',
  );
  late final GeneratedColumn<int> triageAttempts = GeneratedColumn<int>(
    'triage_attempts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT 0',
    defaultValue: const CustomExpression('0'),
  );
  static const VerificationMeta _triageErrorMeta = const VerificationMeta(
    'triageError',
  );
  late final GeneratedColumn<String> triageError = GeneratedColumn<String>(
    'triage_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _gateReasonMeta = const VerificationMeta(
    'gateReason',
  );
  late final GeneratedColumn<String> gateReason = GeneratedColumn<String>(
    'gate_reason',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _urgencyMeta = const VerificationMeta(
    'urgency',
  );
  late final GeneratedColumn<String> urgency = GeneratedColumn<String>(
    'urgency',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _categoryMeta = const VerificationMeta(
    'category',
  );
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
    'category',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _summaryMeta = const VerificationMeta(
    'summary',
  );
  late final GeneratedColumn<String> summary = GeneratedColumn<String>(
    'summary',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _needsActionMeta = const VerificationMeta(
    'needsAction',
  );
  late final GeneratedColumn<int> needsAction = GeneratedColumn<int>(
    'needs_action',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _actionItemsJsonMeta = const VerificationMeta(
    'actionItemsJson',
  );
  late final GeneratedColumn<String> actionItemsJson = GeneratedColumn<String>(
    'action_items_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _labelMeta = const VerificationMeta('label');
  late final GeneratedColumn<String> label = GeneratedColumn<String>(
    'label',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  @override
  List<GeneratedColumn> get $columns => [
    source,
    sourceMessageId,
    internetMessageId,
    conversationKey,
    direction,
    subject,
    fromName,
    fromAddress,
    recipientsJson,
    receivedAt,
    isRead,
    bodyPreview,
    bodyText,
    hasAttachments,
    sourceMetaJson,
    triageStatus,
    triageAttempts,
    triageError,
    gateReason,
    urgency,
    category,
    summary,
    needsAction,
    actionItemsJson,
    createdAt,
    updatedAt,
    label,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<Message> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('source_message_id')) {
      context.handle(
        _sourceMessageIdMeta,
        sourceMessageId.isAcceptableOrUnknown(
          data['source_message_id']!,
          _sourceMessageIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_sourceMessageIdMeta);
    }
    if (data.containsKey('internet_message_id')) {
      context.handle(
        _internetMessageIdMeta,
        internetMessageId.isAcceptableOrUnknown(
          data['internet_message_id']!,
          _internetMessageIdMeta,
        ),
      );
    }
    if (data.containsKey('conversation_key')) {
      context.handle(
        _conversationKeyMeta,
        conversationKey.isAcceptableOrUnknown(
          data['conversation_key']!,
          _conversationKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationKeyMeta);
    }
    if (data.containsKey('direction')) {
      context.handle(
        _directionMeta,
        direction.isAcceptableOrUnknown(data['direction']!, _directionMeta),
      );
    } else if (isInserting) {
      context.missing(_directionMeta);
    }
    if (data.containsKey('subject')) {
      context.handle(
        _subjectMeta,
        subject.isAcceptableOrUnknown(data['subject']!, _subjectMeta),
      );
    }
    if (data.containsKey('from_name')) {
      context.handle(
        _fromNameMeta,
        fromName.isAcceptableOrUnknown(data['from_name']!, _fromNameMeta),
      );
    }
    if (data.containsKey('from_address')) {
      context.handle(
        _fromAddressMeta,
        fromAddress.isAcceptableOrUnknown(
          data['from_address']!,
          _fromAddressMeta,
        ),
      );
    }
    if (data.containsKey('to_json')) {
      context.handle(
        _recipientsJsonMeta,
        recipientsJson.isAcceptableOrUnknown(
          data['to_json']!,
          _recipientsJsonMeta,
        ),
      );
    }
    if (data.containsKey('received_at')) {
      context.handle(
        _receivedAtMeta,
        receivedAt.isAcceptableOrUnknown(data['received_at']!, _receivedAtMeta),
      );
    }
    if (data.containsKey('is_read')) {
      context.handle(
        _isReadMeta,
        isRead.isAcceptableOrUnknown(data['is_read']!, _isReadMeta),
      );
    }
    if (data.containsKey('body_preview')) {
      context.handle(
        _bodyPreviewMeta,
        bodyPreview.isAcceptableOrUnknown(
          data['body_preview']!,
          _bodyPreviewMeta,
        ),
      );
    }
    if (data.containsKey('body_text')) {
      context.handle(
        _bodyTextMeta,
        bodyText.isAcceptableOrUnknown(data['body_text']!, _bodyTextMeta),
      );
    }
    if (data.containsKey('has_attachments')) {
      context.handle(
        _hasAttachmentsMeta,
        hasAttachments.isAcceptableOrUnknown(
          data['has_attachments']!,
          _hasAttachmentsMeta,
        ),
      );
    }
    if (data.containsKey('source_meta_json')) {
      context.handle(
        _sourceMetaJsonMeta,
        sourceMetaJson.isAcceptableOrUnknown(
          data['source_meta_json']!,
          _sourceMetaJsonMeta,
        ),
      );
    }
    if (data.containsKey('triage_status')) {
      context.handle(
        _triageStatusMeta,
        triageStatus.isAcceptableOrUnknown(
          data['triage_status']!,
          _triageStatusMeta,
        ),
      );
    }
    if (data.containsKey('triage_attempts')) {
      context.handle(
        _triageAttemptsMeta,
        triageAttempts.isAcceptableOrUnknown(
          data['triage_attempts']!,
          _triageAttemptsMeta,
        ),
      );
    }
    if (data.containsKey('triage_error')) {
      context.handle(
        _triageErrorMeta,
        triageError.isAcceptableOrUnknown(
          data['triage_error']!,
          _triageErrorMeta,
        ),
      );
    }
    if (data.containsKey('gate_reason')) {
      context.handle(
        _gateReasonMeta,
        gateReason.isAcceptableOrUnknown(data['gate_reason']!, _gateReasonMeta),
      );
    }
    if (data.containsKey('urgency')) {
      context.handle(
        _urgencyMeta,
        urgency.isAcceptableOrUnknown(data['urgency']!, _urgencyMeta),
      );
    }
    if (data.containsKey('category')) {
      context.handle(
        _categoryMeta,
        category.isAcceptableOrUnknown(data['category']!, _categoryMeta),
      );
    }
    if (data.containsKey('summary')) {
      context.handle(
        _summaryMeta,
        summary.isAcceptableOrUnknown(data['summary']!, _summaryMeta),
      );
    }
    if (data.containsKey('needs_action')) {
      context.handle(
        _needsActionMeta,
        needsAction.isAcceptableOrUnknown(
          data['needs_action']!,
          _needsActionMeta,
        ),
      );
    }
    if (data.containsKey('action_items_json')) {
      context.handle(
        _actionItemsJsonMeta,
        actionItemsJson.isAcceptableOrUnknown(
          data['action_items_json']!,
          _actionItemsJsonMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('label')) {
      context.handle(
        _labelMeta,
        label.isAcceptableOrUnknown(data['label']!, _labelMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {source, sourceMessageId};
  @override
  Message map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Message(
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      sourceMessageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_message_id'],
      )!,
      internetMessageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}internet_message_id'],
      ),
      conversationKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_key'],
      )!,
      direction: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}direction'],
      )!,
      subject: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subject'],
      ),
      fromName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}from_name'],
      ),
      fromAddress: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}from_address'],
      ),
      recipientsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}to_json'],
      )!,
      receivedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}received_at'],
      ),
      isRead: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_read'],
      )!,
      bodyPreview: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body_preview'],
      ),
      bodyText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body_text'],
      ),
      hasAttachments: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}has_attachments'],
      )!,
      sourceMetaJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_meta_json'],
      ),
      triageStatus: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}triage_status'],
      )!,
      triageAttempts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}triage_attempts'],
      )!,
      triageError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}triage_error'],
      ),
      gateReason: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}gate_reason'],
      ),
      urgency: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}urgency'],
      ),
      category: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}category'],
      ),
      summary: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}summary'],
      ),
      needsAction: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}needs_action'],
      ),
      actionItemsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}action_items_json'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
      label: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}label'],
      ),
    );
  }

  @override
  Messages createAlias(String alias) {
    return Messages(attachedDatabase, alias);
  }

  @override
  bool get isStrict => true;
  @override
  List<String> get customConstraints => const [
    'PRIMARY KEY(source, source_message_id)',
  ];
  @override
  bool get dontWriteConstraints => true;
}

class Message extends DataClass implements Insertable<Message> {
  final String source;
  final String sourceMessageId;
  final String? internetMessageId;
  final String conversationKey;
  final String direction;
  final String? subject;
  final String? fromName;
  final String? fromAddress;

  /// `AS recipientsJson` renames drift's generated getter and nothing else:
  /// the column stays `to_json` on disk. Without it the getter would be
  /// `toJson`, which collides with the `toJson()` every drift row class
  /// inherits, and the generated file would not compile.
  final String recipientsJson;
  final String? receivedAt;
  final int isRead;
  final String? bodyPreview;
  final String? bodyText;
  final int hasAttachments;
  final String? sourceMetaJson;
  final String triageStatus;
  final int triageAttempts;
  final String? triageError;
  final String? gateReason;
  final String? urgency;
  final String? category;
  final String? summary;
  final int? needsAction;
  final String? actionItemsJson;
  final String createdAt;
  final String updatedAt;

  /// Migration-added columns sit AFTER the originals: ALTER TABLE appends, so
  /// this is the only position where an upgraded install and a fresh one get
  /// identical table_info — which the parity test compares in order.
  final String? label;
  const Message({
    required this.source,
    required this.sourceMessageId,
    this.internetMessageId,
    required this.conversationKey,
    required this.direction,
    this.subject,
    this.fromName,
    this.fromAddress,
    required this.recipientsJson,
    this.receivedAt,
    required this.isRead,
    this.bodyPreview,
    this.bodyText,
    required this.hasAttachments,
    this.sourceMetaJson,
    required this.triageStatus,
    required this.triageAttempts,
    this.triageError,
    this.gateReason,
    this.urgency,
    this.category,
    this.summary,
    this.needsAction,
    this.actionItemsJson,
    required this.createdAt,
    required this.updatedAt,
    this.label,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['source'] = Variable<String>(source);
    map['source_message_id'] = Variable<String>(sourceMessageId);
    if (!nullToAbsent || internetMessageId != null) {
      map['internet_message_id'] = Variable<String>(internetMessageId);
    }
    map['conversation_key'] = Variable<String>(conversationKey);
    map['direction'] = Variable<String>(direction);
    if (!nullToAbsent || subject != null) {
      map['subject'] = Variable<String>(subject);
    }
    if (!nullToAbsent || fromName != null) {
      map['from_name'] = Variable<String>(fromName);
    }
    if (!nullToAbsent || fromAddress != null) {
      map['from_address'] = Variable<String>(fromAddress);
    }
    map['to_json'] = Variable<String>(recipientsJson);
    if (!nullToAbsent || receivedAt != null) {
      map['received_at'] = Variable<String>(receivedAt);
    }
    map['is_read'] = Variable<int>(isRead);
    if (!nullToAbsent || bodyPreview != null) {
      map['body_preview'] = Variable<String>(bodyPreview);
    }
    if (!nullToAbsent || bodyText != null) {
      map['body_text'] = Variable<String>(bodyText);
    }
    map['has_attachments'] = Variable<int>(hasAttachments);
    if (!nullToAbsent || sourceMetaJson != null) {
      map['source_meta_json'] = Variable<String>(sourceMetaJson);
    }
    map['triage_status'] = Variable<String>(triageStatus);
    map['triage_attempts'] = Variable<int>(triageAttempts);
    if (!nullToAbsent || triageError != null) {
      map['triage_error'] = Variable<String>(triageError);
    }
    if (!nullToAbsent || gateReason != null) {
      map['gate_reason'] = Variable<String>(gateReason);
    }
    if (!nullToAbsent || urgency != null) {
      map['urgency'] = Variable<String>(urgency);
    }
    if (!nullToAbsent || category != null) {
      map['category'] = Variable<String>(category);
    }
    if (!nullToAbsent || summary != null) {
      map['summary'] = Variable<String>(summary);
    }
    if (!nullToAbsent || needsAction != null) {
      map['needs_action'] = Variable<int>(needsAction);
    }
    if (!nullToAbsent || actionItemsJson != null) {
      map['action_items_json'] = Variable<String>(actionItemsJson);
    }
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    if (!nullToAbsent || label != null) {
      map['label'] = Variable<String>(label);
    }
    return map;
  }

  MessagesCompanion toCompanion(bool nullToAbsent) {
    return MessagesCompanion(
      source: Value(source),
      sourceMessageId: Value(sourceMessageId),
      internetMessageId: internetMessageId == null && nullToAbsent
          ? const Value.absent()
          : Value(internetMessageId),
      conversationKey: Value(conversationKey),
      direction: Value(direction),
      subject: subject == null && nullToAbsent
          ? const Value.absent()
          : Value(subject),
      fromName: fromName == null && nullToAbsent
          ? const Value.absent()
          : Value(fromName),
      fromAddress: fromAddress == null && nullToAbsent
          ? const Value.absent()
          : Value(fromAddress),
      recipientsJson: Value(recipientsJson),
      receivedAt: receivedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(receivedAt),
      isRead: Value(isRead),
      bodyPreview: bodyPreview == null && nullToAbsent
          ? const Value.absent()
          : Value(bodyPreview),
      bodyText: bodyText == null && nullToAbsent
          ? const Value.absent()
          : Value(bodyText),
      hasAttachments: Value(hasAttachments),
      sourceMetaJson: sourceMetaJson == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceMetaJson),
      triageStatus: Value(triageStatus),
      triageAttempts: Value(triageAttempts),
      triageError: triageError == null && nullToAbsent
          ? const Value.absent()
          : Value(triageError),
      gateReason: gateReason == null && nullToAbsent
          ? const Value.absent()
          : Value(gateReason),
      urgency: urgency == null && nullToAbsent
          ? const Value.absent()
          : Value(urgency),
      category: category == null && nullToAbsent
          ? const Value.absent()
          : Value(category),
      summary: summary == null && nullToAbsent
          ? const Value.absent()
          : Value(summary),
      needsAction: needsAction == null && nullToAbsent
          ? const Value.absent()
          : Value(needsAction),
      actionItemsJson: actionItemsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(actionItemsJson),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      label: label == null && nullToAbsent
          ? const Value.absent()
          : Value(label),
    );
  }

  factory Message.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Message(
      source: serializer.fromJson<String>(json['source']),
      sourceMessageId: serializer.fromJson<String>(json['source_message_id']),
      internetMessageId: serializer.fromJson<String?>(
        json['internet_message_id'],
      ),
      conversationKey: serializer.fromJson<String>(json['conversation_key']),
      direction: serializer.fromJson<String>(json['direction']),
      subject: serializer.fromJson<String?>(json['subject']),
      fromName: serializer.fromJson<String?>(json['from_name']),
      fromAddress: serializer.fromJson<String?>(json['from_address']),
      recipientsJson: serializer.fromJson<String>(json['to_json']),
      receivedAt: serializer.fromJson<String?>(json['received_at']),
      isRead: serializer.fromJson<int>(json['is_read']),
      bodyPreview: serializer.fromJson<String?>(json['body_preview']),
      bodyText: serializer.fromJson<String?>(json['body_text']),
      hasAttachments: serializer.fromJson<int>(json['has_attachments']),
      sourceMetaJson: serializer.fromJson<String?>(json['source_meta_json']),
      triageStatus: serializer.fromJson<String>(json['triage_status']),
      triageAttempts: serializer.fromJson<int>(json['triage_attempts']),
      triageError: serializer.fromJson<String?>(json['triage_error']),
      gateReason: serializer.fromJson<String?>(json['gate_reason']),
      urgency: serializer.fromJson<String?>(json['urgency']),
      category: serializer.fromJson<String?>(json['category']),
      summary: serializer.fromJson<String?>(json['summary']),
      needsAction: serializer.fromJson<int?>(json['needs_action']),
      actionItemsJson: serializer.fromJson<String?>(json['action_items_json']),
      createdAt: serializer.fromJson<String>(json['created_at']),
      updatedAt: serializer.fromJson<String>(json['updated_at']),
      label: serializer.fromJson<String?>(json['label']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'source': serializer.toJson<String>(source),
      'source_message_id': serializer.toJson<String>(sourceMessageId),
      'internet_message_id': serializer.toJson<String?>(internetMessageId),
      'conversation_key': serializer.toJson<String>(conversationKey),
      'direction': serializer.toJson<String>(direction),
      'subject': serializer.toJson<String?>(subject),
      'from_name': serializer.toJson<String?>(fromName),
      'from_address': serializer.toJson<String?>(fromAddress),
      'to_json': serializer.toJson<String>(recipientsJson),
      'received_at': serializer.toJson<String?>(receivedAt),
      'is_read': serializer.toJson<int>(isRead),
      'body_preview': serializer.toJson<String?>(bodyPreview),
      'body_text': serializer.toJson<String?>(bodyText),
      'has_attachments': serializer.toJson<int>(hasAttachments),
      'source_meta_json': serializer.toJson<String?>(sourceMetaJson),
      'triage_status': serializer.toJson<String>(triageStatus),
      'triage_attempts': serializer.toJson<int>(triageAttempts),
      'triage_error': serializer.toJson<String?>(triageError),
      'gate_reason': serializer.toJson<String?>(gateReason),
      'urgency': serializer.toJson<String?>(urgency),
      'category': serializer.toJson<String?>(category),
      'summary': serializer.toJson<String?>(summary),
      'needs_action': serializer.toJson<int?>(needsAction),
      'action_items_json': serializer.toJson<String?>(actionItemsJson),
      'created_at': serializer.toJson<String>(createdAt),
      'updated_at': serializer.toJson<String>(updatedAt),
      'label': serializer.toJson<String?>(label),
    };
  }

  Message copyWith({
    String? source,
    String? sourceMessageId,
    Value<String?> internetMessageId = const Value.absent(),
    String? conversationKey,
    String? direction,
    Value<String?> subject = const Value.absent(),
    Value<String?> fromName = const Value.absent(),
    Value<String?> fromAddress = const Value.absent(),
    String? recipientsJson,
    Value<String?> receivedAt = const Value.absent(),
    int? isRead,
    Value<String?> bodyPreview = const Value.absent(),
    Value<String?> bodyText = const Value.absent(),
    int? hasAttachments,
    Value<String?> sourceMetaJson = const Value.absent(),
    String? triageStatus,
    int? triageAttempts,
    Value<String?> triageError = const Value.absent(),
    Value<String?> gateReason = const Value.absent(),
    Value<String?> urgency = const Value.absent(),
    Value<String?> category = const Value.absent(),
    Value<String?> summary = const Value.absent(),
    Value<int?> needsAction = const Value.absent(),
    Value<String?> actionItemsJson = const Value.absent(),
    String? createdAt,
    String? updatedAt,
    Value<String?> label = const Value.absent(),
  }) => Message(
    source: source ?? this.source,
    sourceMessageId: sourceMessageId ?? this.sourceMessageId,
    internetMessageId: internetMessageId.present
        ? internetMessageId.value
        : this.internetMessageId,
    conversationKey: conversationKey ?? this.conversationKey,
    direction: direction ?? this.direction,
    subject: subject.present ? subject.value : this.subject,
    fromName: fromName.present ? fromName.value : this.fromName,
    fromAddress: fromAddress.present ? fromAddress.value : this.fromAddress,
    recipientsJson: recipientsJson ?? this.recipientsJson,
    receivedAt: receivedAt.present ? receivedAt.value : this.receivedAt,
    isRead: isRead ?? this.isRead,
    bodyPreview: bodyPreview.present ? bodyPreview.value : this.bodyPreview,
    bodyText: bodyText.present ? bodyText.value : this.bodyText,
    hasAttachments: hasAttachments ?? this.hasAttachments,
    sourceMetaJson: sourceMetaJson.present
        ? sourceMetaJson.value
        : this.sourceMetaJson,
    triageStatus: triageStatus ?? this.triageStatus,
    triageAttempts: triageAttempts ?? this.triageAttempts,
    triageError: triageError.present ? triageError.value : this.triageError,
    gateReason: gateReason.present ? gateReason.value : this.gateReason,
    urgency: urgency.present ? urgency.value : this.urgency,
    category: category.present ? category.value : this.category,
    summary: summary.present ? summary.value : this.summary,
    needsAction: needsAction.present ? needsAction.value : this.needsAction,
    actionItemsJson: actionItemsJson.present
        ? actionItemsJson.value
        : this.actionItemsJson,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    label: label.present ? label.value : this.label,
  );
  Message copyWithCompanion(MessagesCompanion data) {
    return Message(
      source: data.source.present ? data.source.value : this.source,
      sourceMessageId: data.sourceMessageId.present
          ? data.sourceMessageId.value
          : this.sourceMessageId,
      internetMessageId: data.internetMessageId.present
          ? data.internetMessageId.value
          : this.internetMessageId,
      conversationKey: data.conversationKey.present
          ? data.conversationKey.value
          : this.conversationKey,
      direction: data.direction.present ? data.direction.value : this.direction,
      subject: data.subject.present ? data.subject.value : this.subject,
      fromName: data.fromName.present ? data.fromName.value : this.fromName,
      fromAddress: data.fromAddress.present
          ? data.fromAddress.value
          : this.fromAddress,
      recipientsJson: data.recipientsJson.present
          ? data.recipientsJson.value
          : this.recipientsJson,
      receivedAt: data.receivedAt.present
          ? data.receivedAt.value
          : this.receivedAt,
      isRead: data.isRead.present ? data.isRead.value : this.isRead,
      bodyPreview: data.bodyPreview.present
          ? data.bodyPreview.value
          : this.bodyPreview,
      bodyText: data.bodyText.present ? data.bodyText.value : this.bodyText,
      hasAttachments: data.hasAttachments.present
          ? data.hasAttachments.value
          : this.hasAttachments,
      sourceMetaJson: data.sourceMetaJson.present
          ? data.sourceMetaJson.value
          : this.sourceMetaJson,
      triageStatus: data.triageStatus.present
          ? data.triageStatus.value
          : this.triageStatus,
      triageAttempts: data.triageAttempts.present
          ? data.triageAttempts.value
          : this.triageAttempts,
      triageError: data.triageError.present
          ? data.triageError.value
          : this.triageError,
      gateReason: data.gateReason.present
          ? data.gateReason.value
          : this.gateReason,
      urgency: data.urgency.present ? data.urgency.value : this.urgency,
      category: data.category.present ? data.category.value : this.category,
      summary: data.summary.present ? data.summary.value : this.summary,
      needsAction: data.needsAction.present
          ? data.needsAction.value
          : this.needsAction,
      actionItemsJson: data.actionItemsJson.present
          ? data.actionItemsJson.value
          : this.actionItemsJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      label: data.label.present ? data.label.value : this.label,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Message(')
          ..write('source: $source, ')
          ..write('sourceMessageId: $sourceMessageId, ')
          ..write('internetMessageId: $internetMessageId, ')
          ..write('conversationKey: $conversationKey, ')
          ..write('direction: $direction, ')
          ..write('subject: $subject, ')
          ..write('fromName: $fromName, ')
          ..write('fromAddress: $fromAddress, ')
          ..write('recipientsJson: $recipientsJson, ')
          ..write('receivedAt: $receivedAt, ')
          ..write('isRead: $isRead, ')
          ..write('bodyPreview: $bodyPreview, ')
          ..write('bodyText: $bodyText, ')
          ..write('hasAttachments: $hasAttachments, ')
          ..write('sourceMetaJson: $sourceMetaJson, ')
          ..write('triageStatus: $triageStatus, ')
          ..write('triageAttempts: $triageAttempts, ')
          ..write('triageError: $triageError, ')
          ..write('gateReason: $gateReason, ')
          ..write('urgency: $urgency, ')
          ..write('category: $category, ')
          ..write('summary: $summary, ')
          ..write('needsAction: $needsAction, ')
          ..write('actionItemsJson: $actionItemsJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('label: $label')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    source,
    sourceMessageId,
    internetMessageId,
    conversationKey,
    direction,
    subject,
    fromName,
    fromAddress,
    recipientsJson,
    receivedAt,
    isRead,
    bodyPreview,
    bodyText,
    hasAttachments,
    sourceMetaJson,
    triageStatus,
    triageAttempts,
    triageError,
    gateReason,
    urgency,
    category,
    summary,
    needsAction,
    actionItemsJson,
    createdAt,
    updatedAt,
    label,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Message &&
          other.source == this.source &&
          other.sourceMessageId == this.sourceMessageId &&
          other.internetMessageId == this.internetMessageId &&
          other.conversationKey == this.conversationKey &&
          other.direction == this.direction &&
          other.subject == this.subject &&
          other.fromName == this.fromName &&
          other.fromAddress == this.fromAddress &&
          other.recipientsJson == this.recipientsJson &&
          other.receivedAt == this.receivedAt &&
          other.isRead == this.isRead &&
          other.bodyPreview == this.bodyPreview &&
          other.bodyText == this.bodyText &&
          other.hasAttachments == this.hasAttachments &&
          other.sourceMetaJson == this.sourceMetaJson &&
          other.triageStatus == this.triageStatus &&
          other.triageAttempts == this.triageAttempts &&
          other.triageError == this.triageError &&
          other.gateReason == this.gateReason &&
          other.urgency == this.urgency &&
          other.category == this.category &&
          other.summary == this.summary &&
          other.needsAction == this.needsAction &&
          other.actionItemsJson == this.actionItemsJson &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.label == this.label);
}

class MessagesCompanion extends UpdateCompanion<Message> {
  final Value<String> source;
  final Value<String> sourceMessageId;
  final Value<String?> internetMessageId;
  final Value<String> conversationKey;
  final Value<String> direction;
  final Value<String?> subject;
  final Value<String?> fromName;
  final Value<String?> fromAddress;
  final Value<String> recipientsJson;
  final Value<String?> receivedAt;
  final Value<int> isRead;
  final Value<String?> bodyPreview;
  final Value<String?> bodyText;
  final Value<int> hasAttachments;
  final Value<String?> sourceMetaJson;
  final Value<String> triageStatus;
  final Value<int> triageAttempts;
  final Value<String?> triageError;
  final Value<String?> gateReason;
  final Value<String?> urgency;
  final Value<String?> category;
  final Value<String?> summary;
  final Value<int?> needsAction;
  final Value<String?> actionItemsJson;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  final Value<String?> label;
  final Value<int> rowid;
  const MessagesCompanion({
    this.source = const Value.absent(),
    this.sourceMessageId = const Value.absent(),
    this.internetMessageId = const Value.absent(),
    this.conversationKey = const Value.absent(),
    this.direction = const Value.absent(),
    this.subject = const Value.absent(),
    this.fromName = const Value.absent(),
    this.fromAddress = const Value.absent(),
    this.recipientsJson = const Value.absent(),
    this.receivedAt = const Value.absent(),
    this.isRead = const Value.absent(),
    this.bodyPreview = const Value.absent(),
    this.bodyText = const Value.absent(),
    this.hasAttachments = const Value.absent(),
    this.sourceMetaJson = const Value.absent(),
    this.triageStatus = const Value.absent(),
    this.triageAttempts = const Value.absent(),
    this.triageError = const Value.absent(),
    this.gateReason = const Value.absent(),
    this.urgency = const Value.absent(),
    this.category = const Value.absent(),
    this.summary = const Value.absent(),
    this.needsAction = const Value.absent(),
    this.actionItemsJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.label = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessagesCompanion.insert({
    this.source = const Value.absent(),
    required String sourceMessageId,
    this.internetMessageId = const Value.absent(),
    required String conversationKey,
    required String direction,
    this.subject = const Value.absent(),
    this.fromName = const Value.absent(),
    this.fromAddress = const Value.absent(),
    this.recipientsJson = const Value.absent(),
    this.receivedAt = const Value.absent(),
    this.isRead = const Value.absent(),
    this.bodyPreview = const Value.absent(),
    this.bodyText = const Value.absent(),
    this.hasAttachments = const Value.absent(),
    this.sourceMetaJson = const Value.absent(),
    this.triageStatus = const Value.absent(),
    this.triageAttempts = const Value.absent(),
    this.triageError = const Value.absent(),
    this.gateReason = const Value.absent(),
    this.urgency = const Value.absent(),
    this.category = const Value.absent(),
    this.summary = const Value.absent(),
    this.needsAction = const Value.absent(),
    this.actionItemsJson = const Value.absent(),
    required String createdAt,
    required String updatedAt,
    this.label = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : sourceMessageId = Value(sourceMessageId),
       conversationKey = Value(conversationKey),
       direction = Value(direction),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<Message> custom({
    Expression<String>? source,
    Expression<String>? sourceMessageId,
    Expression<String>? internetMessageId,
    Expression<String>? conversationKey,
    Expression<String>? direction,
    Expression<String>? subject,
    Expression<String>? fromName,
    Expression<String>? fromAddress,
    Expression<String>? recipientsJson,
    Expression<String>? receivedAt,
    Expression<int>? isRead,
    Expression<String>? bodyPreview,
    Expression<String>? bodyText,
    Expression<int>? hasAttachments,
    Expression<String>? sourceMetaJson,
    Expression<String>? triageStatus,
    Expression<int>? triageAttempts,
    Expression<String>? triageError,
    Expression<String>? gateReason,
    Expression<String>? urgency,
    Expression<String>? category,
    Expression<String>? summary,
    Expression<int>? needsAction,
    Expression<String>? actionItemsJson,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
    Expression<String>? label,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (source != null) 'source': source,
      if (sourceMessageId != null) 'source_message_id': sourceMessageId,
      if (internetMessageId != null) 'internet_message_id': internetMessageId,
      if (conversationKey != null) 'conversation_key': conversationKey,
      if (direction != null) 'direction': direction,
      if (subject != null) 'subject': subject,
      if (fromName != null) 'from_name': fromName,
      if (fromAddress != null) 'from_address': fromAddress,
      if (recipientsJson != null) 'to_json': recipientsJson,
      if (receivedAt != null) 'received_at': receivedAt,
      if (isRead != null) 'is_read': isRead,
      if (bodyPreview != null) 'body_preview': bodyPreview,
      if (bodyText != null) 'body_text': bodyText,
      if (hasAttachments != null) 'has_attachments': hasAttachments,
      if (sourceMetaJson != null) 'source_meta_json': sourceMetaJson,
      if (triageStatus != null) 'triage_status': triageStatus,
      if (triageAttempts != null) 'triage_attempts': triageAttempts,
      if (triageError != null) 'triage_error': triageError,
      if (gateReason != null) 'gate_reason': gateReason,
      if (urgency != null) 'urgency': urgency,
      if (category != null) 'category': category,
      if (summary != null) 'summary': summary,
      if (needsAction != null) 'needs_action': needsAction,
      if (actionItemsJson != null) 'action_items_json': actionItemsJson,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (label != null) 'label': label,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessagesCompanion copyWith({
    Value<String>? source,
    Value<String>? sourceMessageId,
    Value<String?>? internetMessageId,
    Value<String>? conversationKey,
    Value<String>? direction,
    Value<String?>? subject,
    Value<String?>? fromName,
    Value<String?>? fromAddress,
    Value<String>? recipientsJson,
    Value<String?>? receivedAt,
    Value<int>? isRead,
    Value<String?>? bodyPreview,
    Value<String?>? bodyText,
    Value<int>? hasAttachments,
    Value<String?>? sourceMetaJson,
    Value<String>? triageStatus,
    Value<int>? triageAttempts,
    Value<String?>? triageError,
    Value<String?>? gateReason,
    Value<String?>? urgency,
    Value<String?>? category,
    Value<String?>? summary,
    Value<int?>? needsAction,
    Value<String?>? actionItemsJson,
    Value<String>? createdAt,
    Value<String>? updatedAt,
    Value<String?>? label,
    Value<int>? rowid,
  }) {
    return MessagesCompanion(
      source: source ?? this.source,
      sourceMessageId: sourceMessageId ?? this.sourceMessageId,
      internetMessageId: internetMessageId ?? this.internetMessageId,
      conversationKey: conversationKey ?? this.conversationKey,
      direction: direction ?? this.direction,
      subject: subject ?? this.subject,
      fromName: fromName ?? this.fromName,
      fromAddress: fromAddress ?? this.fromAddress,
      recipientsJson: recipientsJson ?? this.recipientsJson,
      receivedAt: receivedAt ?? this.receivedAt,
      isRead: isRead ?? this.isRead,
      bodyPreview: bodyPreview ?? this.bodyPreview,
      bodyText: bodyText ?? this.bodyText,
      hasAttachments: hasAttachments ?? this.hasAttachments,
      sourceMetaJson: sourceMetaJson ?? this.sourceMetaJson,
      triageStatus: triageStatus ?? this.triageStatus,
      triageAttempts: triageAttempts ?? this.triageAttempts,
      triageError: triageError ?? this.triageError,
      gateReason: gateReason ?? this.gateReason,
      urgency: urgency ?? this.urgency,
      category: category ?? this.category,
      summary: summary ?? this.summary,
      needsAction: needsAction ?? this.needsAction,
      actionItemsJson: actionItemsJson ?? this.actionItemsJson,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      label: label ?? this.label,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (sourceMessageId.present) {
      map['source_message_id'] = Variable<String>(sourceMessageId.value);
    }
    if (internetMessageId.present) {
      map['internet_message_id'] = Variable<String>(internetMessageId.value);
    }
    if (conversationKey.present) {
      map['conversation_key'] = Variable<String>(conversationKey.value);
    }
    if (direction.present) {
      map['direction'] = Variable<String>(direction.value);
    }
    if (subject.present) {
      map['subject'] = Variable<String>(subject.value);
    }
    if (fromName.present) {
      map['from_name'] = Variable<String>(fromName.value);
    }
    if (fromAddress.present) {
      map['from_address'] = Variable<String>(fromAddress.value);
    }
    if (recipientsJson.present) {
      map['to_json'] = Variable<String>(recipientsJson.value);
    }
    if (receivedAt.present) {
      map['received_at'] = Variable<String>(receivedAt.value);
    }
    if (isRead.present) {
      map['is_read'] = Variable<int>(isRead.value);
    }
    if (bodyPreview.present) {
      map['body_preview'] = Variable<String>(bodyPreview.value);
    }
    if (bodyText.present) {
      map['body_text'] = Variable<String>(bodyText.value);
    }
    if (hasAttachments.present) {
      map['has_attachments'] = Variable<int>(hasAttachments.value);
    }
    if (sourceMetaJson.present) {
      map['source_meta_json'] = Variable<String>(sourceMetaJson.value);
    }
    if (triageStatus.present) {
      map['triage_status'] = Variable<String>(triageStatus.value);
    }
    if (triageAttempts.present) {
      map['triage_attempts'] = Variable<int>(triageAttempts.value);
    }
    if (triageError.present) {
      map['triage_error'] = Variable<String>(triageError.value);
    }
    if (gateReason.present) {
      map['gate_reason'] = Variable<String>(gateReason.value);
    }
    if (urgency.present) {
      map['urgency'] = Variable<String>(urgency.value);
    }
    if (category.present) {
      map['category'] = Variable<String>(category.value);
    }
    if (summary.present) {
      map['summary'] = Variable<String>(summary.value);
    }
    if (needsAction.present) {
      map['needs_action'] = Variable<int>(needsAction.value);
    }
    if (actionItemsJson.present) {
      map['action_items_json'] = Variable<String>(actionItemsJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (label.present) {
      map['label'] = Variable<String>(label.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessagesCompanion(')
          ..write('source: $source, ')
          ..write('sourceMessageId: $sourceMessageId, ')
          ..write('internetMessageId: $internetMessageId, ')
          ..write('conversationKey: $conversationKey, ')
          ..write('direction: $direction, ')
          ..write('subject: $subject, ')
          ..write('fromName: $fromName, ')
          ..write('fromAddress: $fromAddress, ')
          ..write('recipientsJson: $recipientsJson, ')
          ..write('receivedAt: $receivedAt, ')
          ..write('isRead: $isRead, ')
          ..write('bodyPreview: $bodyPreview, ')
          ..write('bodyText: $bodyText, ')
          ..write('hasAttachments: $hasAttachments, ')
          ..write('sourceMetaJson: $sourceMetaJson, ')
          ..write('triageStatus: $triageStatus, ')
          ..write('triageAttempts: $triageAttempts, ')
          ..write('triageError: $triageError, ')
          ..write('gateReason: $gateReason, ')
          ..write('urgency: $urgency, ')
          ..write('category: $category, ')
          ..write('summary: $summary, ')
          ..write('needsAction: $needsAction, ')
          ..write('actionItemsJson: $actionItemsJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('label: $label, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class Conversations extends Table with TableInfo<Conversations, Conversation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  Conversations(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'email\'',
    defaultValue: const CustomExpression('\'email\''),
  );
  static const VerificationMeta _conversationKeyMeta = const VerificationMeta(
    'conversationKey',
  );
  late final GeneratedColumn<String> conversationKey = GeneratedColumn<String>(
    'conversation_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _subjectMeta = const VerificationMeta(
    'subject',
  );
  late final GeneratedColumn<String> subject = GeneratedColumn<String>(
    'subject',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _participantsJsonMeta = const VerificationMeta(
    'participantsJson',
  );
  late final GeneratedColumn<String> participantsJson = GeneratedColumn<String>(
    'participants_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'[]\'',
    defaultValue: const CustomExpression('\'[]\''),
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'done\'',
    defaultValue: const CustomExpression('\'done\''),
  );
  static const VerificationMeta _categoryMeta = const VerificationMeta(
    'category',
  );
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
    'category',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _ctaTextMeta = const VerificationMeta(
    'ctaText',
  );
  late final GeneratedColumn<String> ctaText = GeneratedColumn<String>(
    'cta_text',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _ctaUrgencyMeta = const VerificationMeta(
    'ctaUrgency',
  );
  late final GeneratedColumn<String> ctaUrgency = GeneratedColumn<String>(
    'cta_urgency',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'normal\'',
    defaultValue: const CustomExpression('\'normal\''),
  );
  static const VerificationMeta _messageCountMeta = const VerificationMeta(
    'messageCount',
  );
  late final GeneratedColumn<int> messageCount = GeneratedColumn<int>(
    'message_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT 0',
    defaultValue: const CustomExpression('0'),
  );
  static const VerificationMeta _inboundCountMeta = const VerificationMeta(
    'inboundCount',
  );
  late final GeneratedColumn<int> inboundCount = GeneratedColumn<int>(
    'inbound_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT 0',
    defaultValue: const CustomExpression('0'),
  );
  static const VerificationMeta _lastInboundAtMeta = const VerificationMeta(
    'lastInboundAt',
  );
  late final GeneratedColumn<String> lastInboundAt = GeneratedColumn<String>(
    'last_inbound_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _lastOutboundAtMeta = const VerificationMeta(
    'lastOutboundAt',
  );
  late final GeneratedColumn<String> lastOutboundAt = GeneratedColumn<String>(
    'last_outbound_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _lastMessageAtMeta = const VerificationMeta(
    'lastMessageAt',
  );
  late final GeneratedColumn<String> lastMessageAt = GeneratedColumn<String>(
    'last_message_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _lastMessagePreviewMeta =
      const VerificationMeta('lastMessagePreview');
  late final GeneratedColumn<String> lastMessagePreview =
      GeneratedColumn<String>(
        'last_message_preview',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        $customConstraints: '',
      );
  static const VerificationMeta _stateChangedAtMeta = const VerificationMeta(
    'stateChangedAt',
  );
  late final GeneratedColumn<String> stateChangedAt = GeneratedColumn<String>(
    'state_changed_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  @override
  List<GeneratedColumn> get $columns => [
    source,
    conversationKey,
    subject,
    participantsJson,
    state,
    category,
    ctaText,
    ctaUrgency,
    messageCount,
    inboundCount,
    lastInboundAt,
    lastOutboundAt,
    lastMessageAt,
    lastMessagePreview,
    stateChangedAt,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conversations';
  @override
  VerificationContext validateIntegrity(
    Insertable<Conversation> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('conversation_key')) {
      context.handle(
        _conversationKeyMeta,
        conversationKey.isAcceptableOrUnknown(
          data['conversation_key']!,
          _conversationKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationKeyMeta);
    }
    if (data.containsKey('subject')) {
      context.handle(
        _subjectMeta,
        subject.isAcceptableOrUnknown(data['subject']!, _subjectMeta),
      );
    }
    if (data.containsKey('participants_json')) {
      context.handle(
        _participantsJsonMeta,
        participantsJson.isAcceptableOrUnknown(
          data['participants_json']!,
          _participantsJsonMeta,
        ),
      );
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    }
    if (data.containsKey('category')) {
      context.handle(
        _categoryMeta,
        category.isAcceptableOrUnknown(data['category']!, _categoryMeta),
      );
    }
    if (data.containsKey('cta_text')) {
      context.handle(
        _ctaTextMeta,
        ctaText.isAcceptableOrUnknown(data['cta_text']!, _ctaTextMeta),
      );
    }
    if (data.containsKey('cta_urgency')) {
      context.handle(
        _ctaUrgencyMeta,
        ctaUrgency.isAcceptableOrUnknown(data['cta_urgency']!, _ctaUrgencyMeta),
      );
    }
    if (data.containsKey('message_count')) {
      context.handle(
        _messageCountMeta,
        messageCount.isAcceptableOrUnknown(
          data['message_count']!,
          _messageCountMeta,
        ),
      );
    }
    if (data.containsKey('inbound_count')) {
      context.handle(
        _inboundCountMeta,
        inboundCount.isAcceptableOrUnknown(
          data['inbound_count']!,
          _inboundCountMeta,
        ),
      );
    }
    if (data.containsKey('last_inbound_at')) {
      context.handle(
        _lastInboundAtMeta,
        lastInboundAt.isAcceptableOrUnknown(
          data['last_inbound_at']!,
          _lastInboundAtMeta,
        ),
      );
    }
    if (data.containsKey('last_outbound_at')) {
      context.handle(
        _lastOutboundAtMeta,
        lastOutboundAt.isAcceptableOrUnknown(
          data['last_outbound_at']!,
          _lastOutboundAtMeta,
        ),
      );
    }
    if (data.containsKey('last_message_at')) {
      context.handle(
        _lastMessageAtMeta,
        lastMessageAt.isAcceptableOrUnknown(
          data['last_message_at']!,
          _lastMessageAtMeta,
        ),
      );
    }
    if (data.containsKey('last_message_preview')) {
      context.handle(
        _lastMessagePreviewMeta,
        lastMessagePreview.isAcceptableOrUnknown(
          data['last_message_preview']!,
          _lastMessagePreviewMeta,
        ),
      );
    }
    if (data.containsKey('state_changed_at')) {
      context.handle(
        _stateChangedAtMeta,
        stateChangedAt.isAcceptableOrUnknown(
          data['state_changed_at']!,
          _stateChangedAtMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {source, conversationKey};
  @override
  Conversation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Conversation(
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      conversationKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_key'],
      )!,
      subject: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subject'],
      ),
      participantsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}participants_json'],
      )!,
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      category: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}category'],
      ),
      ctaText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cta_text'],
      ),
      ctaUrgency: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cta_urgency'],
      )!,
      messageCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}message_count'],
      )!,
      inboundCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}inbound_count'],
      )!,
      lastInboundAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_inbound_at'],
      ),
      lastOutboundAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_outbound_at'],
      ),
      lastMessageAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_message_at'],
      ),
      lastMessagePreview: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_message_preview'],
      ),
      stateChangedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state_changed_at'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  Conversations createAlias(String alias) {
    return Conversations(attachedDatabase, alias);
  }

  @override
  bool get isStrict => true;
  @override
  List<String> get customConstraints => const [
    'PRIMARY KEY(source, conversation_key)',
  ];
  @override
  bool get dontWriteConstraints => true;
}

class Conversation extends DataClass implements Insertable<Conversation> {
  final String source;
  final String conversationKey;
  final String? subject;
  final String participantsJson;
  final String state;
  final String? category;
  final String? ctaText;
  final String ctaUrgency;
  final int messageCount;
  final int inboundCount;
  final String? lastInboundAt;
  final String? lastOutboundAt;
  final String? lastMessageAt;
  final String? lastMessagePreview;
  final String? stateChangedAt;
  final String createdAt;
  final String updatedAt;
  const Conversation({
    required this.source,
    required this.conversationKey,
    this.subject,
    required this.participantsJson,
    required this.state,
    this.category,
    this.ctaText,
    required this.ctaUrgency,
    required this.messageCount,
    required this.inboundCount,
    this.lastInboundAt,
    this.lastOutboundAt,
    this.lastMessageAt,
    this.lastMessagePreview,
    this.stateChangedAt,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['source'] = Variable<String>(source);
    map['conversation_key'] = Variable<String>(conversationKey);
    if (!nullToAbsent || subject != null) {
      map['subject'] = Variable<String>(subject);
    }
    map['participants_json'] = Variable<String>(participantsJson);
    map['state'] = Variable<String>(state);
    if (!nullToAbsent || category != null) {
      map['category'] = Variable<String>(category);
    }
    if (!nullToAbsent || ctaText != null) {
      map['cta_text'] = Variable<String>(ctaText);
    }
    map['cta_urgency'] = Variable<String>(ctaUrgency);
    map['message_count'] = Variable<int>(messageCount);
    map['inbound_count'] = Variable<int>(inboundCount);
    if (!nullToAbsent || lastInboundAt != null) {
      map['last_inbound_at'] = Variable<String>(lastInboundAt);
    }
    if (!nullToAbsent || lastOutboundAt != null) {
      map['last_outbound_at'] = Variable<String>(lastOutboundAt);
    }
    if (!nullToAbsent || lastMessageAt != null) {
      map['last_message_at'] = Variable<String>(lastMessageAt);
    }
    if (!nullToAbsent || lastMessagePreview != null) {
      map['last_message_preview'] = Variable<String>(lastMessagePreview);
    }
    if (!nullToAbsent || stateChangedAt != null) {
      map['state_changed_at'] = Variable<String>(stateChangedAt);
    }
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  ConversationsCompanion toCompanion(bool nullToAbsent) {
    return ConversationsCompanion(
      source: Value(source),
      conversationKey: Value(conversationKey),
      subject: subject == null && nullToAbsent
          ? const Value.absent()
          : Value(subject),
      participantsJson: Value(participantsJson),
      state: Value(state),
      category: category == null && nullToAbsent
          ? const Value.absent()
          : Value(category),
      ctaText: ctaText == null && nullToAbsent
          ? const Value.absent()
          : Value(ctaText),
      ctaUrgency: Value(ctaUrgency),
      messageCount: Value(messageCount),
      inboundCount: Value(inboundCount),
      lastInboundAt: lastInboundAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastInboundAt),
      lastOutboundAt: lastOutboundAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastOutboundAt),
      lastMessageAt: lastMessageAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastMessageAt),
      lastMessagePreview: lastMessagePreview == null && nullToAbsent
          ? const Value.absent()
          : Value(lastMessagePreview),
      stateChangedAt: stateChangedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(stateChangedAt),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory Conversation.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Conversation(
      source: serializer.fromJson<String>(json['source']),
      conversationKey: serializer.fromJson<String>(json['conversation_key']),
      subject: serializer.fromJson<String?>(json['subject']),
      participantsJson: serializer.fromJson<String>(json['participants_json']),
      state: serializer.fromJson<String>(json['state']),
      category: serializer.fromJson<String?>(json['category']),
      ctaText: serializer.fromJson<String?>(json['cta_text']),
      ctaUrgency: serializer.fromJson<String>(json['cta_urgency']),
      messageCount: serializer.fromJson<int>(json['message_count']),
      inboundCount: serializer.fromJson<int>(json['inbound_count']),
      lastInboundAt: serializer.fromJson<String?>(json['last_inbound_at']),
      lastOutboundAt: serializer.fromJson<String?>(json['last_outbound_at']),
      lastMessageAt: serializer.fromJson<String?>(json['last_message_at']),
      lastMessagePreview: serializer.fromJson<String?>(
        json['last_message_preview'],
      ),
      stateChangedAt: serializer.fromJson<String?>(json['state_changed_at']),
      createdAt: serializer.fromJson<String>(json['created_at']),
      updatedAt: serializer.fromJson<String>(json['updated_at']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'source': serializer.toJson<String>(source),
      'conversation_key': serializer.toJson<String>(conversationKey),
      'subject': serializer.toJson<String?>(subject),
      'participants_json': serializer.toJson<String>(participantsJson),
      'state': serializer.toJson<String>(state),
      'category': serializer.toJson<String?>(category),
      'cta_text': serializer.toJson<String?>(ctaText),
      'cta_urgency': serializer.toJson<String>(ctaUrgency),
      'message_count': serializer.toJson<int>(messageCount),
      'inbound_count': serializer.toJson<int>(inboundCount),
      'last_inbound_at': serializer.toJson<String?>(lastInboundAt),
      'last_outbound_at': serializer.toJson<String?>(lastOutboundAt),
      'last_message_at': serializer.toJson<String?>(lastMessageAt),
      'last_message_preview': serializer.toJson<String?>(lastMessagePreview),
      'state_changed_at': serializer.toJson<String?>(stateChangedAt),
      'created_at': serializer.toJson<String>(createdAt),
      'updated_at': serializer.toJson<String>(updatedAt),
    };
  }

  Conversation copyWith({
    String? source,
    String? conversationKey,
    Value<String?> subject = const Value.absent(),
    String? participantsJson,
    String? state,
    Value<String?> category = const Value.absent(),
    Value<String?> ctaText = const Value.absent(),
    String? ctaUrgency,
    int? messageCount,
    int? inboundCount,
    Value<String?> lastInboundAt = const Value.absent(),
    Value<String?> lastOutboundAt = const Value.absent(),
    Value<String?> lastMessageAt = const Value.absent(),
    Value<String?> lastMessagePreview = const Value.absent(),
    Value<String?> stateChangedAt = const Value.absent(),
    String? createdAt,
    String? updatedAt,
  }) => Conversation(
    source: source ?? this.source,
    conversationKey: conversationKey ?? this.conversationKey,
    subject: subject.present ? subject.value : this.subject,
    participantsJson: participantsJson ?? this.participantsJson,
    state: state ?? this.state,
    category: category.present ? category.value : this.category,
    ctaText: ctaText.present ? ctaText.value : this.ctaText,
    ctaUrgency: ctaUrgency ?? this.ctaUrgency,
    messageCount: messageCount ?? this.messageCount,
    inboundCount: inboundCount ?? this.inboundCount,
    lastInboundAt: lastInboundAt.present
        ? lastInboundAt.value
        : this.lastInboundAt,
    lastOutboundAt: lastOutboundAt.present
        ? lastOutboundAt.value
        : this.lastOutboundAt,
    lastMessageAt: lastMessageAt.present
        ? lastMessageAt.value
        : this.lastMessageAt,
    lastMessagePreview: lastMessagePreview.present
        ? lastMessagePreview.value
        : this.lastMessagePreview,
    stateChangedAt: stateChangedAt.present
        ? stateChangedAt.value
        : this.stateChangedAt,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  Conversation copyWithCompanion(ConversationsCompanion data) {
    return Conversation(
      source: data.source.present ? data.source.value : this.source,
      conversationKey: data.conversationKey.present
          ? data.conversationKey.value
          : this.conversationKey,
      subject: data.subject.present ? data.subject.value : this.subject,
      participantsJson: data.participantsJson.present
          ? data.participantsJson.value
          : this.participantsJson,
      state: data.state.present ? data.state.value : this.state,
      category: data.category.present ? data.category.value : this.category,
      ctaText: data.ctaText.present ? data.ctaText.value : this.ctaText,
      ctaUrgency: data.ctaUrgency.present
          ? data.ctaUrgency.value
          : this.ctaUrgency,
      messageCount: data.messageCount.present
          ? data.messageCount.value
          : this.messageCount,
      inboundCount: data.inboundCount.present
          ? data.inboundCount.value
          : this.inboundCount,
      lastInboundAt: data.lastInboundAt.present
          ? data.lastInboundAt.value
          : this.lastInboundAt,
      lastOutboundAt: data.lastOutboundAt.present
          ? data.lastOutboundAt.value
          : this.lastOutboundAt,
      lastMessageAt: data.lastMessageAt.present
          ? data.lastMessageAt.value
          : this.lastMessageAt,
      lastMessagePreview: data.lastMessagePreview.present
          ? data.lastMessagePreview.value
          : this.lastMessagePreview,
      stateChangedAt: data.stateChangedAt.present
          ? data.stateChangedAt.value
          : this.stateChangedAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Conversation(')
          ..write('source: $source, ')
          ..write('conversationKey: $conversationKey, ')
          ..write('subject: $subject, ')
          ..write('participantsJson: $participantsJson, ')
          ..write('state: $state, ')
          ..write('category: $category, ')
          ..write('ctaText: $ctaText, ')
          ..write('ctaUrgency: $ctaUrgency, ')
          ..write('messageCount: $messageCount, ')
          ..write('inboundCount: $inboundCount, ')
          ..write('lastInboundAt: $lastInboundAt, ')
          ..write('lastOutboundAt: $lastOutboundAt, ')
          ..write('lastMessageAt: $lastMessageAt, ')
          ..write('lastMessagePreview: $lastMessagePreview, ')
          ..write('stateChangedAt: $stateChangedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    source,
    conversationKey,
    subject,
    participantsJson,
    state,
    category,
    ctaText,
    ctaUrgency,
    messageCount,
    inboundCount,
    lastInboundAt,
    lastOutboundAt,
    lastMessageAt,
    lastMessagePreview,
    stateChangedAt,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Conversation &&
          other.source == this.source &&
          other.conversationKey == this.conversationKey &&
          other.subject == this.subject &&
          other.participantsJson == this.participantsJson &&
          other.state == this.state &&
          other.category == this.category &&
          other.ctaText == this.ctaText &&
          other.ctaUrgency == this.ctaUrgency &&
          other.messageCount == this.messageCount &&
          other.inboundCount == this.inboundCount &&
          other.lastInboundAt == this.lastInboundAt &&
          other.lastOutboundAt == this.lastOutboundAt &&
          other.lastMessageAt == this.lastMessageAt &&
          other.lastMessagePreview == this.lastMessagePreview &&
          other.stateChangedAt == this.stateChangedAt &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class ConversationsCompanion extends UpdateCompanion<Conversation> {
  final Value<String> source;
  final Value<String> conversationKey;
  final Value<String?> subject;
  final Value<String> participantsJson;
  final Value<String> state;
  final Value<String?> category;
  final Value<String?> ctaText;
  final Value<String> ctaUrgency;
  final Value<int> messageCount;
  final Value<int> inboundCount;
  final Value<String?> lastInboundAt;
  final Value<String?> lastOutboundAt;
  final Value<String?> lastMessageAt;
  final Value<String?> lastMessagePreview;
  final Value<String?> stateChangedAt;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  final Value<int> rowid;
  const ConversationsCompanion({
    this.source = const Value.absent(),
    this.conversationKey = const Value.absent(),
    this.subject = const Value.absent(),
    this.participantsJson = const Value.absent(),
    this.state = const Value.absent(),
    this.category = const Value.absent(),
    this.ctaText = const Value.absent(),
    this.ctaUrgency = const Value.absent(),
    this.messageCount = const Value.absent(),
    this.inboundCount = const Value.absent(),
    this.lastInboundAt = const Value.absent(),
    this.lastOutboundAt = const Value.absent(),
    this.lastMessageAt = const Value.absent(),
    this.lastMessagePreview = const Value.absent(),
    this.stateChangedAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConversationsCompanion.insert({
    this.source = const Value.absent(),
    required String conversationKey,
    this.subject = const Value.absent(),
    this.participantsJson = const Value.absent(),
    this.state = const Value.absent(),
    this.category = const Value.absent(),
    this.ctaText = const Value.absent(),
    this.ctaUrgency = const Value.absent(),
    this.messageCount = const Value.absent(),
    this.inboundCount = const Value.absent(),
    this.lastInboundAt = const Value.absent(),
    this.lastOutboundAt = const Value.absent(),
    this.lastMessageAt = const Value.absent(),
    this.lastMessagePreview = const Value.absent(),
    this.stateChangedAt = const Value.absent(),
    required String createdAt,
    required String updatedAt,
    this.rowid = const Value.absent(),
  }) : conversationKey = Value(conversationKey),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<Conversation> custom({
    Expression<String>? source,
    Expression<String>? conversationKey,
    Expression<String>? subject,
    Expression<String>? participantsJson,
    Expression<String>? state,
    Expression<String>? category,
    Expression<String>? ctaText,
    Expression<String>? ctaUrgency,
    Expression<int>? messageCount,
    Expression<int>? inboundCount,
    Expression<String>? lastInboundAt,
    Expression<String>? lastOutboundAt,
    Expression<String>? lastMessageAt,
    Expression<String>? lastMessagePreview,
    Expression<String>? stateChangedAt,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (source != null) 'source': source,
      if (conversationKey != null) 'conversation_key': conversationKey,
      if (subject != null) 'subject': subject,
      if (participantsJson != null) 'participants_json': participantsJson,
      if (state != null) 'state': state,
      if (category != null) 'category': category,
      if (ctaText != null) 'cta_text': ctaText,
      if (ctaUrgency != null) 'cta_urgency': ctaUrgency,
      if (messageCount != null) 'message_count': messageCount,
      if (inboundCount != null) 'inbound_count': inboundCount,
      if (lastInboundAt != null) 'last_inbound_at': lastInboundAt,
      if (lastOutboundAt != null) 'last_outbound_at': lastOutboundAt,
      if (lastMessageAt != null) 'last_message_at': lastMessageAt,
      if (lastMessagePreview != null)
        'last_message_preview': lastMessagePreview,
      if (stateChangedAt != null) 'state_changed_at': stateChangedAt,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConversationsCompanion copyWith({
    Value<String>? source,
    Value<String>? conversationKey,
    Value<String?>? subject,
    Value<String>? participantsJson,
    Value<String>? state,
    Value<String?>? category,
    Value<String?>? ctaText,
    Value<String>? ctaUrgency,
    Value<int>? messageCount,
    Value<int>? inboundCount,
    Value<String?>? lastInboundAt,
    Value<String?>? lastOutboundAt,
    Value<String?>? lastMessageAt,
    Value<String?>? lastMessagePreview,
    Value<String?>? stateChangedAt,
    Value<String>? createdAt,
    Value<String>? updatedAt,
    Value<int>? rowid,
  }) {
    return ConversationsCompanion(
      source: source ?? this.source,
      conversationKey: conversationKey ?? this.conversationKey,
      subject: subject ?? this.subject,
      participantsJson: participantsJson ?? this.participantsJson,
      state: state ?? this.state,
      category: category ?? this.category,
      ctaText: ctaText ?? this.ctaText,
      ctaUrgency: ctaUrgency ?? this.ctaUrgency,
      messageCount: messageCount ?? this.messageCount,
      inboundCount: inboundCount ?? this.inboundCount,
      lastInboundAt: lastInboundAt ?? this.lastInboundAt,
      lastOutboundAt: lastOutboundAt ?? this.lastOutboundAt,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
      stateChangedAt: stateChangedAt ?? this.stateChangedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (conversationKey.present) {
      map['conversation_key'] = Variable<String>(conversationKey.value);
    }
    if (subject.present) {
      map['subject'] = Variable<String>(subject.value);
    }
    if (participantsJson.present) {
      map['participants_json'] = Variable<String>(participantsJson.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (category.present) {
      map['category'] = Variable<String>(category.value);
    }
    if (ctaText.present) {
      map['cta_text'] = Variable<String>(ctaText.value);
    }
    if (ctaUrgency.present) {
      map['cta_urgency'] = Variable<String>(ctaUrgency.value);
    }
    if (messageCount.present) {
      map['message_count'] = Variable<int>(messageCount.value);
    }
    if (inboundCount.present) {
      map['inbound_count'] = Variable<int>(inboundCount.value);
    }
    if (lastInboundAt.present) {
      map['last_inbound_at'] = Variable<String>(lastInboundAt.value);
    }
    if (lastOutboundAt.present) {
      map['last_outbound_at'] = Variable<String>(lastOutboundAt.value);
    }
    if (lastMessageAt.present) {
      map['last_message_at'] = Variable<String>(lastMessageAt.value);
    }
    if (lastMessagePreview.present) {
      map['last_message_preview'] = Variable<String>(lastMessagePreview.value);
    }
    if (stateChangedAt.present) {
      map['state_changed_at'] = Variable<String>(stateChangedAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConversationsCompanion(')
          ..write('source: $source, ')
          ..write('conversationKey: $conversationKey, ')
          ..write('subject: $subject, ')
          ..write('participantsJson: $participantsJson, ')
          ..write('state: $state, ')
          ..write('category: $category, ')
          ..write('ctaText: $ctaText, ')
          ..write('ctaUrgency: $ctaUrgency, ')
          ..write('messageCount: $messageCount, ')
          ..write('inboundCount: $inboundCount, ')
          ..write('lastInboundAt: $lastInboundAt, ')
          ..write('lastOutboundAt: $lastOutboundAt, ')
          ..write('lastMessageAt: $lastMessageAt, ')
          ..write('lastMessagePreview: $lastMessagePreview, ')
          ..write('stateChangedAt: $stateChangedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class SyncState extends Table with TableInfo<SyncState, SyncStateData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  SyncState(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'email\'',
    defaultValue: const CustomExpression('\'email\''),
  );
  static const VerificationMeta _folderMeta = const VerificationMeta('folder');
  late final GeneratedColumn<String> folder = GeneratedColumn<String>(
    'folder',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _deltaLinkMeta = const VerificationMeta(
    'deltaLink',
  );
  late final GeneratedColumn<String> deltaLink = GeneratedColumn<String>(
    'delta_link',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _syncedAtMeta = const VerificationMeta(
    'syncedAt',
  );
  late final GeneratedColumn<String> syncedAt = GeneratedColumn<String>(
    'synced_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  @override
  List<GeneratedColumn> get $columns => [source, folder, deltaLink, syncedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_state';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncStateData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('folder')) {
      context.handle(
        _folderMeta,
        folder.isAcceptableOrUnknown(data['folder']!, _folderMeta),
      );
    } else if (isInserting) {
      context.missing(_folderMeta);
    }
    if (data.containsKey('delta_link')) {
      context.handle(
        _deltaLinkMeta,
        deltaLink.isAcceptableOrUnknown(data['delta_link']!, _deltaLinkMeta),
      );
    }
    if (data.containsKey('synced_at')) {
      context.handle(
        _syncedAtMeta,
        syncedAt.isAcceptableOrUnknown(data['synced_at']!, _syncedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {source, folder};
  @override
  SyncStateData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncStateData(
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      folder: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}folder'],
      )!,
      deltaLink: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}delta_link'],
      ),
      syncedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}synced_at'],
      ),
    );
  }

  @override
  SyncState createAlias(String alias) {
    return SyncState(attachedDatabase, alias);
  }

  @override
  bool get isStrict => true;
  @override
  List<String> get customConstraints => const ['PRIMARY KEY(source, folder)'];
  @override
  bool get dontWriteConstraints => true;
}

class SyncStateData extends DataClass implements Insertable<SyncStateData> {
  final String source;
  final String folder;
  final String? deltaLink;
  final String? syncedAt;
  const SyncStateData({
    required this.source,
    required this.folder,
    this.deltaLink,
    this.syncedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['source'] = Variable<String>(source);
    map['folder'] = Variable<String>(folder);
    if (!nullToAbsent || deltaLink != null) {
      map['delta_link'] = Variable<String>(deltaLink);
    }
    if (!nullToAbsent || syncedAt != null) {
      map['synced_at'] = Variable<String>(syncedAt);
    }
    return map;
  }

  SyncStateCompanion toCompanion(bool nullToAbsent) {
    return SyncStateCompanion(
      source: Value(source),
      folder: Value(folder),
      deltaLink: deltaLink == null && nullToAbsent
          ? const Value.absent()
          : Value(deltaLink),
      syncedAt: syncedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(syncedAt),
    );
  }

  factory SyncStateData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncStateData(
      source: serializer.fromJson<String>(json['source']),
      folder: serializer.fromJson<String>(json['folder']),
      deltaLink: serializer.fromJson<String?>(json['delta_link']),
      syncedAt: serializer.fromJson<String?>(json['synced_at']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'source': serializer.toJson<String>(source),
      'folder': serializer.toJson<String>(folder),
      'delta_link': serializer.toJson<String?>(deltaLink),
      'synced_at': serializer.toJson<String?>(syncedAt),
    };
  }

  SyncStateData copyWith({
    String? source,
    String? folder,
    Value<String?> deltaLink = const Value.absent(),
    Value<String?> syncedAt = const Value.absent(),
  }) => SyncStateData(
    source: source ?? this.source,
    folder: folder ?? this.folder,
    deltaLink: deltaLink.present ? deltaLink.value : this.deltaLink,
    syncedAt: syncedAt.present ? syncedAt.value : this.syncedAt,
  );
  SyncStateData copyWithCompanion(SyncStateCompanion data) {
    return SyncStateData(
      source: data.source.present ? data.source.value : this.source,
      folder: data.folder.present ? data.folder.value : this.folder,
      deltaLink: data.deltaLink.present ? data.deltaLink.value : this.deltaLink,
      syncedAt: data.syncedAt.present ? data.syncedAt.value : this.syncedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncStateData(')
          ..write('source: $source, ')
          ..write('folder: $folder, ')
          ..write('deltaLink: $deltaLink, ')
          ..write('syncedAt: $syncedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(source, folder, deltaLink, syncedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncStateData &&
          other.source == this.source &&
          other.folder == this.folder &&
          other.deltaLink == this.deltaLink &&
          other.syncedAt == this.syncedAt);
}

class SyncStateCompanion extends UpdateCompanion<SyncStateData> {
  final Value<String> source;
  final Value<String> folder;
  final Value<String?> deltaLink;
  final Value<String?> syncedAt;
  final Value<int> rowid;
  const SyncStateCompanion({
    this.source = const Value.absent(),
    this.folder = const Value.absent(),
    this.deltaLink = const Value.absent(),
    this.syncedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncStateCompanion.insert({
    this.source = const Value.absent(),
    required String folder,
    this.deltaLink = const Value.absent(),
    this.syncedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : folder = Value(folder);
  static Insertable<SyncStateData> custom({
    Expression<String>? source,
    Expression<String>? folder,
    Expression<String>? deltaLink,
    Expression<String>? syncedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (source != null) 'source': source,
      if (folder != null) 'folder': folder,
      if (deltaLink != null) 'delta_link': deltaLink,
      if (syncedAt != null) 'synced_at': syncedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncStateCompanion copyWith({
    Value<String>? source,
    Value<String>? folder,
    Value<String?>? deltaLink,
    Value<String?>? syncedAt,
    Value<int>? rowid,
  }) {
    return SyncStateCompanion(
      source: source ?? this.source,
      folder: folder ?? this.folder,
      deltaLink: deltaLink ?? this.deltaLink,
      syncedAt: syncedAt ?? this.syncedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (folder.present) {
      map['folder'] = Variable<String>(folder.value);
    }
    if (deltaLink.present) {
      map['delta_link'] = Variable<String>(deltaLink.value);
    }
    if (syncedAt.present) {
      map['synced_at'] = Variable<String>(syncedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncStateCompanion(')
          ..write('source: $source, ')
          ..write('folder: $folder, ')
          ..write('deltaLink: $deltaLink, ')
          ..write('syncedAt: $syncedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class WorkItems extends Table with TableInfo<WorkItems, WorkItem> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  WorkItems(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _taskKindMeta = const VerificationMeta(
    'taskKind',
  );
  late final GeneratedColumn<String> taskKind = GeneratedColumn<String>(
    'task_kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'email\'',
    defaultValue: const CustomExpression('\'email\''),
  );
  static const VerificationMeta _entityIdMeta = const VerificationMeta(
    'entityId',
  );
  late final GeneratedColumn<String> entityId = GeneratedColumn<String>(
    'entity_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'pending\'',
    defaultValue: const CustomExpression('\'pending\''),
  );
  static const VerificationMeta _attemptsMeta = const VerificationMeta(
    'attempts',
  );
  late final GeneratedColumn<int> attempts = GeneratedColumn<int>(
    'attempts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT 0',
    defaultValue: const CustomExpression('0'),
  );
  static const VerificationMeta _errorMeta = const VerificationMeta('error');
  late final GeneratedColumn<String> error = GeneratedColumn<String>(
    'error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _payloadJsonMeta = const VerificationMeta(
    'payloadJson',
  );
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
    'payload_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  @override
  List<GeneratedColumn> get $columns => [
    taskKind,
    source,
    entityId,
    status,
    attempts,
    error,
    payloadJson,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'work_items';
  @override
  VerificationContext validateIntegrity(
    Insertable<WorkItem> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('task_kind')) {
      context.handle(
        _taskKindMeta,
        taskKind.isAcceptableOrUnknown(data['task_kind']!, _taskKindMeta),
      );
    } else if (isInserting) {
      context.missing(_taskKindMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('entity_id')) {
      context.handle(
        _entityIdMeta,
        entityId.isAcceptableOrUnknown(data['entity_id']!, _entityIdMeta),
      );
    } else if (isInserting) {
      context.missing(_entityIdMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('attempts')) {
      context.handle(
        _attemptsMeta,
        attempts.isAcceptableOrUnknown(data['attempts']!, _attemptsMeta),
      );
    }
    if (data.containsKey('error')) {
      context.handle(
        _errorMeta,
        error.isAcceptableOrUnknown(data['error']!, _errorMeta),
      );
    }
    if (data.containsKey('payload_json')) {
      context.handle(
        _payloadJsonMeta,
        payloadJson.isAcceptableOrUnknown(
          data['payload_json']!,
          _payloadJsonMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {taskKind, source, entityId};
  @override
  WorkItem map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return WorkItem(
      taskKind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}task_kind'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      entityId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_id'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      attempts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempts'],
      )!,
      error: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error'],
      ),
      payloadJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_json'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  WorkItems createAlias(String alias) {
    return WorkItems(attachedDatabase, alias);
  }

  @override
  bool get isStrict => true;
  @override
  List<String> get customConstraints => const [
    'PRIMARY KEY(task_kind, source, entity_id)',
  ];
  @override
  bool get dontWriteConstraints => true;
}

class WorkItem extends DataClass implements Insertable<WorkItem> {
  final String taskKind;
  final String source;
  final String entityId;
  final String status;
  final int attempts;
  final String? error;
  final String? payloadJson;
  final String createdAt;
  final String updatedAt;
  const WorkItem({
    required this.taskKind,
    required this.source,
    required this.entityId,
    required this.status,
    required this.attempts,
    this.error,
    this.payloadJson,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['task_kind'] = Variable<String>(taskKind);
    map['source'] = Variable<String>(source);
    map['entity_id'] = Variable<String>(entityId);
    map['status'] = Variable<String>(status);
    map['attempts'] = Variable<int>(attempts);
    if (!nullToAbsent || error != null) {
      map['error'] = Variable<String>(error);
    }
    if (!nullToAbsent || payloadJson != null) {
      map['payload_json'] = Variable<String>(payloadJson);
    }
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  WorkItemsCompanion toCompanion(bool nullToAbsent) {
    return WorkItemsCompanion(
      taskKind: Value(taskKind),
      source: Value(source),
      entityId: Value(entityId),
      status: Value(status),
      attempts: Value(attempts),
      error: error == null && nullToAbsent
          ? const Value.absent()
          : Value(error),
      payloadJson: payloadJson == null && nullToAbsent
          ? const Value.absent()
          : Value(payloadJson),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory WorkItem.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return WorkItem(
      taskKind: serializer.fromJson<String>(json['task_kind']),
      source: serializer.fromJson<String>(json['source']),
      entityId: serializer.fromJson<String>(json['entity_id']),
      status: serializer.fromJson<String>(json['status']),
      attempts: serializer.fromJson<int>(json['attempts']),
      error: serializer.fromJson<String?>(json['error']),
      payloadJson: serializer.fromJson<String?>(json['payload_json']),
      createdAt: serializer.fromJson<String>(json['created_at']),
      updatedAt: serializer.fromJson<String>(json['updated_at']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'task_kind': serializer.toJson<String>(taskKind),
      'source': serializer.toJson<String>(source),
      'entity_id': serializer.toJson<String>(entityId),
      'status': serializer.toJson<String>(status),
      'attempts': serializer.toJson<int>(attempts),
      'error': serializer.toJson<String?>(error),
      'payload_json': serializer.toJson<String?>(payloadJson),
      'created_at': serializer.toJson<String>(createdAt),
      'updated_at': serializer.toJson<String>(updatedAt),
    };
  }

  WorkItem copyWith({
    String? taskKind,
    String? source,
    String? entityId,
    String? status,
    int? attempts,
    Value<String?> error = const Value.absent(),
    Value<String?> payloadJson = const Value.absent(),
    String? createdAt,
    String? updatedAt,
  }) => WorkItem(
    taskKind: taskKind ?? this.taskKind,
    source: source ?? this.source,
    entityId: entityId ?? this.entityId,
    status: status ?? this.status,
    attempts: attempts ?? this.attempts,
    error: error.present ? error.value : this.error,
    payloadJson: payloadJson.present ? payloadJson.value : this.payloadJson,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  WorkItem copyWithCompanion(WorkItemsCompanion data) {
    return WorkItem(
      taskKind: data.taskKind.present ? data.taskKind.value : this.taskKind,
      source: data.source.present ? data.source.value : this.source,
      entityId: data.entityId.present ? data.entityId.value : this.entityId,
      status: data.status.present ? data.status.value : this.status,
      attempts: data.attempts.present ? data.attempts.value : this.attempts,
      error: data.error.present ? data.error.value : this.error,
      payloadJson: data.payloadJson.present
          ? data.payloadJson.value
          : this.payloadJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('WorkItem(')
          ..write('taskKind: $taskKind, ')
          ..write('source: $source, ')
          ..write('entityId: $entityId, ')
          ..write('status: $status, ')
          ..write('attempts: $attempts, ')
          ..write('error: $error, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    taskKind,
    source,
    entityId,
    status,
    attempts,
    error,
    payloadJson,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is WorkItem &&
          other.taskKind == this.taskKind &&
          other.source == this.source &&
          other.entityId == this.entityId &&
          other.status == this.status &&
          other.attempts == this.attempts &&
          other.error == this.error &&
          other.payloadJson == this.payloadJson &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class WorkItemsCompanion extends UpdateCompanion<WorkItem> {
  final Value<String> taskKind;
  final Value<String> source;
  final Value<String> entityId;
  final Value<String> status;
  final Value<int> attempts;
  final Value<String?> error;
  final Value<String?> payloadJson;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  final Value<int> rowid;
  const WorkItemsCompanion({
    this.taskKind = const Value.absent(),
    this.source = const Value.absent(),
    this.entityId = const Value.absent(),
    this.status = const Value.absent(),
    this.attempts = const Value.absent(),
    this.error = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  WorkItemsCompanion.insert({
    required String taskKind,
    this.source = const Value.absent(),
    required String entityId,
    this.status = const Value.absent(),
    this.attempts = const Value.absent(),
    this.error = const Value.absent(),
    this.payloadJson = const Value.absent(),
    required String createdAt,
    required String updatedAt,
    this.rowid = const Value.absent(),
  }) : taskKind = Value(taskKind),
       entityId = Value(entityId),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<WorkItem> custom({
    Expression<String>? taskKind,
    Expression<String>? source,
    Expression<String>? entityId,
    Expression<String>? status,
    Expression<int>? attempts,
    Expression<String>? error,
    Expression<String>? payloadJson,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (taskKind != null) 'task_kind': taskKind,
      if (source != null) 'source': source,
      if (entityId != null) 'entity_id': entityId,
      if (status != null) 'status': status,
      if (attempts != null) 'attempts': attempts,
      if (error != null) 'error': error,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  WorkItemsCompanion copyWith({
    Value<String>? taskKind,
    Value<String>? source,
    Value<String>? entityId,
    Value<String>? status,
    Value<int>? attempts,
    Value<String?>? error,
    Value<String?>? payloadJson,
    Value<String>? createdAt,
    Value<String>? updatedAt,
    Value<int>? rowid,
  }) {
    return WorkItemsCompanion(
      taskKind: taskKind ?? this.taskKind,
      source: source ?? this.source,
      entityId: entityId ?? this.entityId,
      status: status ?? this.status,
      attempts: attempts ?? this.attempts,
      error: error ?? this.error,
      payloadJson: payloadJson ?? this.payloadJson,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (taskKind.present) {
      map['task_kind'] = Variable<String>(taskKind.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (entityId.present) {
      map['entity_id'] = Variable<String>(entityId.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (attempts.present) {
      map['attempts'] = Variable<int>(attempts.value);
    }
    if (error.present) {
      map['error'] = Variable<String>(error.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('WorkItemsCompanion(')
          ..write('taskKind: $taskKind, ')
          ..write('source: $source, ')
          ..write('entityId: $entityId, ')
          ..write('status: $status, ')
          ..write('attempts: $attempts, ')
          ..write('error: $error, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class MessageAi extends Table with TableInfo<MessageAi, MessageAiData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  MessageAi(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'email\'',
    defaultValue: const CustomExpression('\'email\''),
  );
  static const VerificationMeta _sourceMessageIdMeta = const VerificationMeta(
    'sourceMessageId',
  );
  late final GeneratedColumn<String> sourceMessageId = GeneratedColumn<String>(
    'source_message_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _extractionJsonMeta = const VerificationMeta(
    'extractionJson',
  );
  late final GeneratedColumn<String> extractionJson = GeneratedColumn<String>(
    'extraction_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _extractedAtMeta = const VerificationMeta(
    'extractedAt',
  );
  late final GeneratedColumn<String> extractedAt = GeneratedColumn<String>(
    'extracted_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  @override
  List<GeneratedColumn> get $columns => [
    source,
    sourceMessageId,
    extractionJson,
    extractedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'message_ai';
  @override
  VerificationContext validateIntegrity(
    Insertable<MessageAiData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('source_message_id')) {
      context.handle(
        _sourceMessageIdMeta,
        sourceMessageId.isAcceptableOrUnknown(
          data['source_message_id']!,
          _sourceMessageIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_sourceMessageIdMeta);
    }
    if (data.containsKey('extraction_json')) {
      context.handle(
        _extractionJsonMeta,
        extractionJson.isAcceptableOrUnknown(
          data['extraction_json']!,
          _extractionJsonMeta,
        ),
      );
    }
    if (data.containsKey('extracted_at')) {
      context.handle(
        _extractedAtMeta,
        extractedAt.isAcceptableOrUnknown(
          data['extracted_at']!,
          _extractedAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {source, sourceMessageId};
  @override
  MessageAiData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MessageAiData(
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      sourceMessageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_message_id'],
      )!,
      extractionJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}extraction_json'],
      ),
      extractedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}extracted_at'],
      ),
    );
  }

  @override
  MessageAi createAlias(String alias) {
    return MessageAi(attachedDatabase, alias);
  }

  @override
  bool get isStrict => true;
  @override
  List<String> get customConstraints => const [
    'PRIMARY KEY(source, source_message_id)',
  ];
  @override
  bool get dontWriteConstraints => true;
}

class MessageAiData extends DataClass implements Insertable<MessageAiData> {
  final String source;
  final String sourceMessageId;
  final String? extractionJson;
  final String? extractedAt;
  const MessageAiData({
    required this.source,
    required this.sourceMessageId,
    this.extractionJson,
    this.extractedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['source'] = Variable<String>(source);
    map['source_message_id'] = Variable<String>(sourceMessageId);
    if (!nullToAbsent || extractionJson != null) {
      map['extraction_json'] = Variable<String>(extractionJson);
    }
    if (!nullToAbsent || extractedAt != null) {
      map['extracted_at'] = Variable<String>(extractedAt);
    }
    return map;
  }

  MessageAiCompanion toCompanion(bool nullToAbsent) {
    return MessageAiCompanion(
      source: Value(source),
      sourceMessageId: Value(sourceMessageId),
      extractionJson: extractionJson == null && nullToAbsent
          ? const Value.absent()
          : Value(extractionJson),
      extractedAt: extractedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(extractedAt),
    );
  }

  factory MessageAiData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MessageAiData(
      source: serializer.fromJson<String>(json['source']),
      sourceMessageId: serializer.fromJson<String>(json['source_message_id']),
      extractionJson: serializer.fromJson<String?>(json['extraction_json']),
      extractedAt: serializer.fromJson<String?>(json['extracted_at']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'source': serializer.toJson<String>(source),
      'source_message_id': serializer.toJson<String>(sourceMessageId),
      'extraction_json': serializer.toJson<String?>(extractionJson),
      'extracted_at': serializer.toJson<String?>(extractedAt),
    };
  }

  MessageAiData copyWith({
    String? source,
    String? sourceMessageId,
    Value<String?> extractionJson = const Value.absent(),
    Value<String?> extractedAt = const Value.absent(),
  }) => MessageAiData(
    source: source ?? this.source,
    sourceMessageId: sourceMessageId ?? this.sourceMessageId,
    extractionJson: extractionJson.present
        ? extractionJson.value
        : this.extractionJson,
    extractedAt: extractedAt.present ? extractedAt.value : this.extractedAt,
  );
  MessageAiData copyWithCompanion(MessageAiCompanion data) {
    return MessageAiData(
      source: data.source.present ? data.source.value : this.source,
      sourceMessageId: data.sourceMessageId.present
          ? data.sourceMessageId.value
          : this.sourceMessageId,
      extractionJson: data.extractionJson.present
          ? data.extractionJson.value
          : this.extractionJson,
      extractedAt: data.extractedAt.present
          ? data.extractedAt.value
          : this.extractedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MessageAiData(')
          ..write('source: $source, ')
          ..write('sourceMessageId: $sourceMessageId, ')
          ..write('extractionJson: $extractionJson, ')
          ..write('extractedAt: $extractedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(source, sourceMessageId, extractionJson, extractedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageAiData &&
          other.source == this.source &&
          other.sourceMessageId == this.sourceMessageId &&
          other.extractionJson == this.extractionJson &&
          other.extractedAt == this.extractedAt);
}

class MessageAiCompanion extends UpdateCompanion<MessageAiData> {
  final Value<String> source;
  final Value<String> sourceMessageId;
  final Value<String?> extractionJson;
  final Value<String?> extractedAt;
  final Value<int> rowid;
  const MessageAiCompanion({
    this.source = const Value.absent(),
    this.sourceMessageId = const Value.absent(),
    this.extractionJson = const Value.absent(),
    this.extractedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessageAiCompanion.insert({
    this.source = const Value.absent(),
    required String sourceMessageId,
    this.extractionJson = const Value.absent(),
    this.extractedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : sourceMessageId = Value(sourceMessageId);
  static Insertable<MessageAiData> custom({
    Expression<String>? source,
    Expression<String>? sourceMessageId,
    Expression<String>? extractionJson,
    Expression<String>? extractedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (source != null) 'source': source,
      if (sourceMessageId != null) 'source_message_id': sourceMessageId,
      if (extractionJson != null) 'extraction_json': extractionJson,
      if (extractedAt != null) 'extracted_at': extractedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessageAiCompanion copyWith({
    Value<String>? source,
    Value<String>? sourceMessageId,
    Value<String?>? extractionJson,
    Value<String?>? extractedAt,
    Value<int>? rowid,
  }) {
    return MessageAiCompanion(
      source: source ?? this.source,
      sourceMessageId: sourceMessageId ?? this.sourceMessageId,
      extractionJson: extractionJson ?? this.extractionJson,
      extractedAt: extractedAt ?? this.extractedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (sourceMessageId.present) {
      map['source_message_id'] = Variable<String>(sourceMessageId.value);
    }
    if (extractionJson.present) {
      map['extraction_json'] = Variable<String>(extractionJson.value);
    }
    if (extractedAt.present) {
      map['extracted_at'] = Variable<String>(extractedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessageAiCompanion(')
          ..write('source: $source, ')
          ..write('sourceMessageId: $sourceMessageId, ')
          ..write('extractionJson: $extractionJson, ')
          ..write('extractedAt: $extractedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class ConversationAi extends Table
    with TableInfo<ConversationAi, ConversationAiData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  ConversationAi(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'email\'',
    defaultValue: const CustomExpression('\'email\''),
  );
  static const VerificationMeta _conversationKeyMeta = const VerificationMeta(
    'conversationKey',
  );
  late final GeneratedColumn<String> conversationKey = GeneratedColumn<String>(
    'conversation_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _embeddingMeta = const VerificationMeta(
    'embedding',
  );
  late final GeneratedColumn<Uint8List> embedding = GeneratedColumn<Uint8List>(
    'embedding',
    aliasedName,
    true,
    type: DriftSqlType.blob,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _embeddedHashMeta = const VerificationMeta(
    'embeddedHash',
  );
  late final GeneratedColumn<String> embeddedHash = GeneratedColumn<String>(
    'embedded_hash',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _embedModelMeta = const VerificationMeta(
    'embedModel',
  );
  late final GeneratedColumn<String> embedModel = GeneratedColumn<String>(
    'embed_model',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _bucketMeta = const VerificationMeta('bucket');
  late final GeneratedColumn<String> bucket = GeneratedColumn<String>(
    'bucket',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _bucketReasonMeta = const VerificationMeta(
    'bucketReason',
  );
  late final GeneratedColumn<String> bucketReason = GeneratedColumn<String>(
    'bucket_reason',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _attentionScoreMeta = const VerificationMeta(
    'attentionScore',
  );
  late final GeneratedColumn<double> attentionScore = GeneratedColumn<double>(
    'attention_score',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _snoozedUntilMeta = const VerificationMeta(
    'snoozedUntil',
  );
  late final GeneratedColumn<String> snoozedUntil = GeneratedColumn<String>(
    'snoozed_until',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  @override
  List<GeneratedColumn> get $columns => [
    source,
    conversationKey,
    embedding,
    embeddedHash,
    embedModel,
    bucket,
    bucketReason,
    attentionScore,
    snoozedUntil,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conversation_ai';
  @override
  VerificationContext validateIntegrity(
    Insertable<ConversationAiData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('conversation_key')) {
      context.handle(
        _conversationKeyMeta,
        conversationKey.isAcceptableOrUnknown(
          data['conversation_key']!,
          _conversationKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationKeyMeta);
    }
    if (data.containsKey('embedding')) {
      context.handle(
        _embeddingMeta,
        embedding.isAcceptableOrUnknown(data['embedding']!, _embeddingMeta),
      );
    }
    if (data.containsKey('embedded_hash')) {
      context.handle(
        _embeddedHashMeta,
        embeddedHash.isAcceptableOrUnknown(
          data['embedded_hash']!,
          _embeddedHashMeta,
        ),
      );
    }
    if (data.containsKey('embed_model')) {
      context.handle(
        _embedModelMeta,
        embedModel.isAcceptableOrUnknown(data['embed_model']!, _embedModelMeta),
      );
    }
    if (data.containsKey('bucket')) {
      context.handle(
        _bucketMeta,
        bucket.isAcceptableOrUnknown(data['bucket']!, _bucketMeta),
      );
    }
    if (data.containsKey('bucket_reason')) {
      context.handle(
        _bucketReasonMeta,
        bucketReason.isAcceptableOrUnknown(
          data['bucket_reason']!,
          _bucketReasonMeta,
        ),
      );
    }
    if (data.containsKey('attention_score')) {
      context.handle(
        _attentionScoreMeta,
        attentionScore.isAcceptableOrUnknown(
          data['attention_score']!,
          _attentionScoreMeta,
        ),
      );
    }
    if (data.containsKey('snoozed_until')) {
      context.handle(
        _snoozedUntilMeta,
        snoozedUntil.isAcceptableOrUnknown(
          data['snoozed_until']!,
          _snoozedUntilMeta,
        ),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {source, conversationKey};
  @override
  ConversationAiData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConversationAiData(
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      conversationKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_key'],
      )!,
      embedding: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}embedding'],
      ),
      embeddedHash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}embedded_hash'],
      ),
      embedModel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}embed_model'],
      ),
      bucket: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}bucket'],
      ),
      bucketReason: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}bucket_reason'],
      ),
      attentionScore: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}attention_score'],
      ),
      snoozedUntil: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}snoozed_until'],
      ),
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  ConversationAi createAlias(String alias) {
    return ConversationAi(attachedDatabase, alias);
  }

  @override
  bool get isStrict => true;
  @override
  List<String> get customConstraints => const [
    'PRIMARY KEY(source, conversation_key)',
  ];
  @override
  bool get dontWriteConstraints => true;
}

class ConversationAiData extends DataClass
    implements Insertable<ConversationAiData> {
  final String source;
  final String conversationKey;
  final Uint8List? embedding;
  final String? embeddedHash;
  final String? embedModel;
  final String? bucket;
  final String? bucketReason;
  final double? attentionScore;
  final String? snoozedUntil;
  final String updatedAt;
  const ConversationAiData({
    required this.source,
    required this.conversationKey,
    this.embedding,
    this.embeddedHash,
    this.embedModel,
    this.bucket,
    this.bucketReason,
    this.attentionScore,
    this.snoozedUntil,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['source'] = Variable<String>(source);
    map['conversation_key'] = Variable<String>(conversationKey);
    if (!nullToAbsent || embedding != null) {
      map['embedding'] = Variable<Uint8List>(embedding);
    }
    if (!nullToAbsent || embeddedHash != null) {
      map['embedded_hash'] = Variable<String>(embeddedHash);
    }
    if (!nullToAbsent || embedModel != null) {
      map['embed_model'] = Variable<String>(embedModel);
    }
    if (!nullToAbsent || bucket != null) {
      map['bucket'] = Variable<String>(bucket);
    }
    if (!nullToAbsent || bucketReason != null) {
      map['bucket_reason'] = Variable<String>(bucketReason);
    }
    if (!nullToAbsent || attentionScore != null) {
      map['attention_score'] = Variable<double>(attentionScore);
    }
    if (!nullToAbsent || snoozedUntil != null) {
      map['snoozed_until'] = Variable<String>(snoozedUntil);
    }
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  ConversationAiCompanion toCompanion(bool nullToAbsent) {
    return ConversationAiCompanion(
      source: Value(source),
      conversationKey: Value(conversationKey),
      embedding: embedding == null && nullToAbsent
          ? const Value.absent()
          : Value(embedding),
      embeddedHash: embeddedHash == null && nullToAbsent
          ? const Value.absent()
          : Value(embeddedHash),
      embedModel: embedModel == null && nullToAbsent
          ? const Value.absent()
          : Value(embedModel),
      bucket: bucket == null && nullToAbsent
          ? const Value.absent()
          : Value(bucket),
      bucketReason: bucketReason == null && nullToAbsent
          ? const Value.absent()
          : Value(bucketReason),
      attentionScore: attentionScore == null && nullToAbsent
          ? const Value.absent()
          : Value(attentionScore),
      snoozedUntil: snoozedUntil == null && nullToAbsent
          ? const Value.absent()
          : Value(snoozedUntil),
      updatedAt: Value(updatedAt),
    );
  }

  factory ConversationAiData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConversationAiData(
      source: serializer.fromJson<String>(json['source']),
      conversationKey: serializer.fromJson<String>(json['conversation_key']),
      embedding: serializer.fromJson<Uint8List?>(json['embedding']),
      embeddedHash: serializer.fromJson<String?>(json['embedded_hash']),
      embedModel: serializer.fromJson<String?>(json['embed_model']),
      bucket: serializer.fromJson<String?>(json['bucket']),
      bucketReason: serializer.fromJson<String?>(json['bucket_reason']),
      attentionScore: serializer.fromJson<double?>(json['attention_score']),
      snoozedUntil: serializer.fromJson<String?>(json['snoozed_until']),
      updatedAt: serializer.fromJson<String>(json['updated_at']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'source': serializer.toJson<String>(source),
      'conversation_key': serializer.toJson<String>(conversationKey),
      'embedding': serializer.toJson<Uint8List?>(embedding),
      'embedded_hash': serializer.toJson<String?>(embeddedHash),
      'embed_model': serializer.toJson<String?>(embedModel),
      'bucket': serializer.toJson<String?>(bucket),
      'bucket_reason': serializer.toJson<String?>(bucketReason),
      'attention_score': serializer.toJson<double?>(attentionScore),
      'snoozed_until': serializer.toJson<String?>(snoozedUntil),
      'updated_at': serializer.toJson<String>(updatedAt),
    };
  }

  ConversationAiData copyWith({
    String? source,
    String? conversationKey,
    Value<Uint8List?> embedding = const Value.absent(),
    Value<String?> embeddedHash = const Value.absent(),
    Value<String?> embedModel = const Value.absent(),
    Value<String?> bucket = const Value.absent(),
    Value<String?> bucketReason = const Value.absent(),
    Value<double?> attentionScore = const Value.absent(),
    Value<String?> snoozedUntil = const Value.absent(),
    String? updatedAt,
  }) => ConversationAiData(
    source: source ?? this.source,
    conversationKey: conversationKey ?? this.conversationKey,
    embedding: embedding.present ? embedding.value : this.embedding,
    embeddedHash: embeddedHash.present ? embeddedHash.value : this.embeddedHash,
    embedModel: embedModel.present ? embedModel.value : this.embedModel,
    bucket: bucket.present ? bucket.value : this.bucket,
    bucketReason: bucketReason.present ? bucketReason.value : this.bucketReason,
    attentionScore: attentionScore.present
        ? attentionScore.value
        : this.attentionScore,
    snoozedUntil: snoozedUntil.present ? snoozedUntil.value : this.snoozedUntil,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  ConversationAiData copyWithCompanion(ConversationAiCompanion data) {
    return ConversationAiData(
      source: data.source.present ? data.source.value : this.source,
      conversationKey: data.conversationKey.present
          ? data.conversationKey.value
          : this.conversationKey,
      embedding: data.embedding.present ? data.embedding.value : this.embedding,
      embeddedHash: data.embeddedHash.present
          ? data.embeddedHash.value
          : this.embeddedHash,
      embedModel: data.embedModel.present
          ? data.embedModel.value
          : this.embedModel,
      bucket: data.bucket.present ? data.bucket.value : this.bucket,
      bucketReason: data.bucketReason.present
          ? data.bucketReason.value
          : this.bucketReason,
      attentionScore: data.attentionScore.present
          ? data.attentionScore.value
          : this.attentionScore,
      snoozedUntil: data.snoozedUntil.present
          ? data.snoozedUntil.value
          : this.snoozedUntil,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConversationAiData(')
          ..write('source: $source, ')
          ..write('conversationKey: $conversationKey, ')
          ..write('embedding: $embedding, ')
          ..write('embeddedHash: $embeddedHash, ')
          ..write('embedModel: $embedModel, ')
          ..write('bucket: $bucket, ')
          ..write('bucketReason: $bucketReason, ')
          ..write('attentionScore: $attentionScore, ')
          ..write('snoozedUntil: $snoozedUntil, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    source,
    conversationKey,
    $driftBlobEquality.hash(embedding),
    embeddedHash,
    embedModel,
    bucket,
    bucketReason,
    attentionScore,
    snoozedUntil,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConversationAiData &&
          other.source == this.source &&
          other.conversationKey == this.conversationKey &&
          $driftBlobEquality.equals(other.embedding, this.embedding) &&
          other.embeddedHash == this.embeddedHash &&
          other.embedModel == this.embedModel &&
          other.bucket == this.bucket &&
          other.bucketReason == this.bucketReason &&
          other.attentionScore == this.attentionScore &&
          other.snoozedUntil == this.snoozedUntil &&
          other.updatedAt == this.updatedAt);
}

class ConversationAiCompanion extends UpdateCompanion<ConversationAiData> {
  final Value<String> source;
  final Value<String> conversationKey;
  final Value<Uint8List?> embedding;
  final Value<String?> embeddedHash;
  final Value<String?> embedModel;
  final Value<String?> bucket;
  final Value<String?> bucketReason;
  final Value<double?> attentionScore;
  final Value<String?> snoozedUntil;
  final Value<String> updatedAt;
  final Value<int> rowid;
  const ConversationAiCompanion({
    this.source = const Value.absent(),
    this.conversationKey = const Value.absent(),
    this.embedding = const Value.absent(),
    this.embeddedHash = const Value.absent(),
    this.embedModel = const Value.absent(),
    this.bucket = const Value.absent(),
    this.bucketReason = const Value.absent(),
    this.attentionScore = const Value.absent(),
    this.snoozedUntil = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConversationAiCompanion.insert({
    this.source = const Value.absent(),
    required String conversationKey,
    this.embedding = const Value.absent(),
    this.embeddedHash = const Value.absent(),
    this.embedModel = const Value.absent(),
    this.bucket = const Value.absent(),
    this.bucketReason = const Value.absent(),
    this.attentionScore = const Value.absent(),
    this.snoozedUntil = const Value.absent(),
    required String updatedAt,
    this.rowid = const Value.absent(),
  }) : conversationKey = Value(conversationKey),
       updatedAt = Value(updatedAt);
  static Insertable<ConversationAiData> custom({
    Expression<String>? source,
    Expression<String>? conversationKey,
    Expression<Uint8List>? embedding,
    Expression<String>? embeddedHash,
    Expression<String>? embedModel,
    Expression<String>? bucket,
    Expression<String>? bucketReason,
    Expression<double>? attentionScore,
    Expression<String>? snoozedUntil,
    Expression<String>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (source != null) 'source': source,
      if (conversationKey != null) 'conversation_key': conversationKey,
      if (embedding != null) 'embedding': embedding,
      if (embeddedHash != null) 'embedded_hash': embeddedHash,
      if (embedModel != null) 'embed_model': embedModel,
      if (bucket != null) 'bucket': bucket,
      if (bucketReason != null) 'bucket_reason': bucketReason,
      if (attentionScore != null) 'attention_score': attentionScore,
      if (snoozedUntil != null) 'snoozed_until': snoozedUntil,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConversationAiCompanion copyWith({
    Value<String>? source,
    Value<String>? conversationKey,
    Value<Uint8List?>? embedding,
    Value<String?>? embeddedHash,
    Value<String?>? embedModel,
    Value<String?>? bucket,
    Value<String?>? bucketReason,
    Value<double?>? attentionScore,
    Value<String?>? snoozedUntil,
    Value<String>? updatedAt,
    Value<int>? rowid,
  }) {
    return ConversationAiCompanion(
      source: source ?? this.source,
      conversationKey: conversationKey ?? this.conversationKey,
      embedding: embedding ?? this.embedding,
      embeddedHash: embeddedHash ?? this.embeddedHash,
      embedModel: embedModel ?? this.embedModel,
      bucket: bucket ?? this.bucket,
      bucketReason: bucketReason ?? this.bucketReason,
      attentionScore: attentionScore ?? this.attentionScore,
      snoozedUntil: snoozedUntil ?? this.snoozedUntil,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (conversationKey.present) {
      map['conversation_key'] = Variable<String>(conversationKey.value);
    }
    if (embedding.present) {
      map['embedding'] = Variable<Uint8List>(embedding.value);
    }
    if (embeddedHash.present) {
      map['embedded_hash'] = Variable<String>(embeddedHash.value);
    }
    if (embedModel.present) {
      map['embed_model'] = Variable<String>(embedModel.value);
    }
    if (bucket.present) {
      map['bucket'] = Variable<String>(bucket.value);
    }
    if (bucketReason.present) {
      map['bucket_reason'] = Variable<String>(bucketReason.value);
    }
    if (attentionScore.present) {
      map['attention_score'] = Variable<double>(attentionScore.value);
    }
    if (snoozedUntil.present) {
      map['snoozed_until'] = Variable<String>(snoozedUntil.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConversationAiCompanion(')
          ..write('source: $source, ')
          ..write('conversationKey: $conversationKey, ')
          ..write('embedding: $embedding, ')
          ..write('embeddedHash: $embeddedHash, ')
          ..write('embedModel: $embedModel, ')
          ..write('bucket: $bucket, ')
          ..write('bucketReason: $bucketReason, ')
          ..write('attentionScore: $attentionScore, ')
          ..write('snoozedUntil: $snoozedUntil, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class Storylines extends Table with TableInfo<Storylines, Storyline> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  Storylines(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'PRIMARY KEY',
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _summaryMeta = const VerificationMeta(
    'summary',
  );
  late final GeneratedColumn<String> summary = GeneratedColumn<String>(
    'summary',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'suggested\'',
    defaultValue: const CustomExpression('\'suggested\''),
  );
  static const VerificationMeta _createdByMeta = const VerificationMeta(
    'createdBy',
  );
  late final GeneratedColumn<String> createdBy = GeneratedColumn<String>(
    'created_by',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'auto\'',
    defaultValue: const CustomExpression('\'auto\''),
  );
  static const VerificationMeta _titleLockedMeta = const VerificationMeta(
    'titleLocked',
  );
  late final GeneratedColumn<int> titleLocked = GeneratedColumn<int>(
    'title_locked',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT 0',
    defaultValue: const CustomExpression('0'),
  );
  static const VerificationMeta _pinnedMeta = const VerificationMeta('pinned');
  late final GeneratedColumn<int> pinned = GeneratedColumn<int>(
    'pinned',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT 0',
    defaultValue: const CustomExpression('0'),
  );
  static const VerificationMeta _memberHashMeta = const VerificationMeta(
    'memberHash',
  );
  late final GeneratedColumn<String> memberHash = GeneratedColumn<String>(
    'member_hash',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _lastActivityAtMeta = const VerificationMeta(
    'lastActivityAt',
  );
  late final GeneratedColumn<String> lastActivityAt = GeneratedColumn<String>(
    'last_activity_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    summary,
    status,
    createdBy,
    titleLocked,
    pinned,
    memberHash,
    lastActivityAt,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'storylines';
  @override
  VerificationContext validateIntegrity(
    Insertable<Storyline> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('summary')) {
      context.handle(
        _summaryMeta,
        summary.isAcceptableOrUnknown(data['summary']!, _summaryMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('created_by')) {
      context.handle(
        _createdByMeta,
        createdBy.isAcceptableOrUnknown(data['created_by']!, _createdByMeta),
      );
    }
    if (data.containsKey('title_locked')) {
      context.handle(
        _titleLockedMeta,
        titleLocked.isAcceptableOrUnknown(
          data['title_locked']!,
          _titleLockedMeta,
        ),
      );
    }
    if (data.containsKey('pinned')) {
      context.handle(
        _pinnedMeta,
        pinned.isAcceptableOrUnknown(data['pinned']!, _pinnedMeta),
      );
    }
    if (data.containsKey('member_hash')) {
      context.handle(
        _memberHashMeta,
        memberHash.isAcceptableOrUnknown(data['member_hash']!, _memberHashMeta),
      );
    }
    if (data.containsKey('last_activity_at')) {
      context.handle(
        _lastActivityAtMeta,
        lastActivityAt.isAcceptableOrUnknown(
          data['last_activity_at']!,
          _lastActivityAtMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Storyline map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Storyline(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      summary: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}summary'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      createdBy: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_by'],
      )!,
      titleLocked: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}title_locked'],
      )!,
      pinned: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}pinned'],
      )!,
      memberHash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}member_hash'],
      ),
      lastActivityAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_activity_at'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  Storylines createAlias(String alias) {
    return Storylines(attachedDatabase, alias);
  }

  @override
  bool get isStrict => true;
  @override
  bool get dontWriteConstraints => true;
}

class Storyline extends DataClass implements Insertable<Storyline> {
  final String id;
  final String title;
  final String? summary;
  final String status;
  final String createdBy;
  final int titleLocked;
  final int pinned;
  final String? memberHash;
  final String? lastActivityAt;
  final String createdAt;
  final String updatedAt;
  const Storyline({
    required this.id,
    required this.title,
    this.summary,
    required this.status,
    required this.createdBy,
    required this.titleLocked,
    required this.pinned,
    this.memberHash,
    this.lastActivityAt,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || summary != null) {
      map['summary'] = Variable<String>(summary);
    }
    map['status'] = Variable<String>(status);
    map['created_by'] = Variable<String>(createdBy);
    map['title_locked'] = Variable<int>(titleLocked);
    map['pinned'] = Variable<int>(pinned);
    if (!nullToAbsent || memberHash != null) {
      map['member_hash'] = Variable<String>(memberHash);
    }
    if (!nullToAbsent || lastActivityAt != null) {
      map['last_activity_at'] = Variable<String>(lastActivityAt);
    }
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  StorylinesCompanion toCompanion(bool nullToAbsent) {
    return StorylinesCompanion(
      id: Value(id),
      title: Value(title),
      summary: summary == null && nullToAbsent
          ? const Value.absent()
          : Value(summary),
      status: Value(status),
      createdBy: Value(createdBy),
      titleLocked: Value(titleLocked),
      pinned: Value(pinned),
      memberHash: memberHash == null && nullToAbsent
          ? const Value.absent()
          : Value(memberHash),
      lastActivityAt: lastActivityAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastActivityAt),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory Storyline.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Storyline(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      summary: serializer.fromJson<String?>(json['summary']),
      status: serializer.fromJson<String>(json['status']),
      createdBy: serializer.fromJson<String>(json['created_by']),
      titleLocked: serializer.fromJson<int>(json['title_locked']),
      pinned: serializer.fromJson<int>(json['pinned']),
      memberHash: serializer.fromJson<String?>(json['member_hash']),
      lastActivityAt: serializer.fromJson<String?>(json['last_activity_at']),
      createdAt: serializer.fromJson<String>(json['created_at']),
      updatedAt: serializer.fromJson<String>(json['updated_at']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'summary': serializer.toJson<String?>(summary),
      'status': serializer.toJson<String>(status),
      'created_by': serializer.toJson<String>(createdBy),
      'title_locked': serializer.toJson<int>(titleLocked),
      'pinned': serializer.toJson<int>(pinned),
      'member_hash': serializer.toJson<String?>(memberHash),
      'last_activity_at': serializer.toJson<String?>(lastActivityAt),
      'created_at': serializer.toJson<String>(createdAt),
      'updated_at': serializer.toJson<String>(updatedAt),
    };
  }

  Storyline copyWith({
    String? id,
    String? title,
    Value<String?> summary = const Value.absent(),
    String? status,
    String? createdBy,
    int? titleLocked,
    int? pinned,
    Value<String?> memberHash = const Value.absent(),
    Value<String?> lastActivityAt = const Value.absent(),
    String? createdAt,
    String? updatedAt,
  }) => Storyline(
    id: id ?? this.id,
    title: title ?? this.title,
    summary: summary.present ? summary.value : this.summary,
    status: status ?? this.status,
    createdBy: createdBy ?? this.createdBy,
    titleLocked: titleLocked ?? this.titleLocked,
    pinned: pinned ?? this.pinned,
    memberHash: memberHash.present ? memberHash.value : this.memberHash,
    lastActivityAt: lastActivityAt.present
        ? lastActivityAt.value
        : this.lastActivityAt,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  Storyline copyWithCompanion(StorylinesCompanion data) {
    return Storyline(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      summary: data.summary.present ? data.summary.value : this.summary,
      status: data.status.present ? data.status.value : this.status,
      createdBy: data.createdBy.present ? data.createdBy.value : this.createdBy,
      titleLocked: data.titleLocked.present
          ? data.titleLocked.value
          : this.titleLocked,
      pinned: data.pinned.present ? data.pinned.value : this.pinned,
      memberHash: data.memberHash.present
          ? data.memberHash.value
          : this.memberHash,
      lastActivityAt: data.lastActivityAt.present
          ? data.lastActivityAt.value
          : this.lastActivityAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Storyline(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('summary: $summary, ')
          ..write('status: $status, ')
          ..write('createdBy: $createdBy, ')
          ..write('titleLocked: $titleLocked, ')
          ..write('pinned: $pinned, ')
          ..write('memberHash: $memberHash, ')
          ..write('lastActivityAt: $lastActivityAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    summary,
    status,
    createdBy,
    titleLocked,
    pinned,
    memberHash,
    lastActivityAt,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Storyline &&
          other.id == this.id &&
          other.title == this.title &&
          other.summary == this.summary &&
          other.status == this.status &&
          other.createdBy == this.createdBy &&
          other.titleLocked == this.titleLocked &&
          other.pinned == this.pinned &&
          other.memberHash == this.memberHash &&
          other.lastActivityAt == this.lastActivityAt &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class StorylinesCompanion extends UpdateCompanion<Storyline> {
  final Value<String> id;
  final Value<String> title;
  final Value<String?> summary;
  final Value<String> status;
  final Value<String> createdBy;
  final Value<int> titleLocked;
  final Value<int> pinned;
  final Value<String?> memberHash;
  final Value<String?> lastActivityAt;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  final Value<int> rowid;
  const StorylinesCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.summary = const Value.absent(),
    this.status = const Value.absent(),
    this.createdBy = const Value.absent(),
    this.titleLocked = const Value.absent(),
    this.pinned = const Value.absent(),
    this.memberHash = const Value.absent(),
    this.lastActivityAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  StorylinesCompanion.insert({
    required String id,
    required String title,
    this.summary = const Value.absent(),
    this.status = const Value.absent(),
    this.createdBy = const Value.absent(),
    this.titleLocked = const Value.absent(),
    this.pinned = const Value.absent(),
    this.memberHash = const Value.absent(),
    this.lastActivityAt = const Value.absent(),
    required String createdAt,
    required String updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<Storyline> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? summary,
    Expression<String>? status,
    Expression<String>? createdBy,
    Expression<int>? titleLocked,
    Expression<int>? pinned,
    Expression<String>? memberHash,
    Expression<String>? lastActivityAt,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (summary != null) 'summary': summary,
      if (status != null) 'status': status,
      if (createdBy != null) 'created_by': createdBy,
      if (titleLocked != null) 'title_locked': titleLocked,
      if (pinned != null) 'pinned': pinned,
      if (memberHash != null) 'member_hash': memberHash,
      if (lastActivityAt != null) 'last_activity_at': lastActivityAt,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  StorylinesCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<String?>? summary,
    Value<String>? status,
    Value<String>? createdBy,
    Value<int>? titleLocked,
    Value<int>? pinned,
    Value<String?>? memberHash,
    Value<String?>? lastActivityAt,
    Value<String>? createdAt,
    Value<String>? updatedAt,
    Value<int>? rowid,
  }) {
    return StorylinesCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      summary: summary ?? this.summary,
      status: status ?? this.status,
      createdBy: createdBy ?? this.createdBy,
      titleLocked: titleLocked ?? this.titleLocked,
      pinned: pinned ?? this.pinned,
      memberHash: memberHash ?? this.memberHash,
      lastActivityAt: lastActivityAt ?? this.lastActivityAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (summary.present) {
      map['summary'] = Variable<String>(summary.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (createdBy.present) {
      map['created_by'] = Variable<String>(createdBy.value);
    }
    if (titleLocked.present) {
      map['title_locked'] = Variable<int>(titleLocked.value);
    }
    if (pinned.present) {
      map['pinned'] = Variable<int>(pinned.value);
    }
    if (memberHash.present) {
      map['member_hash'] = Variable<String>(memberHash.value);
    }
    if (lastActivityAt.present) {
      map['last_activity_at'] = Variable<String>(lastActivityAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StorylinesCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('summary: $summary, ')
          ..write('status: $status, ')
          ..write('createdBy: $createdBy, ')
          ..write('titleLocked: $titleLocked, ')
          ..write('pinned: $pinned, ')
          ..write('memberHash: $memberHash, ')
          ..write('lastActivityAt: $lastActivityAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class StorylineMembers extends Table
    with TableInfo<StorylineMembers, StorylineMember> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  StorylineMembers(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _storylineIdMeta = const VerificationMeta(
    'storylineId',
  );
  late final GeneratedColumn<String> storylineId = GeneratedColumn<String>(
    'storyline_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'email\'',
    defaultValue: const CustomExpression('\'email\''),
  );
  static const VerificationMeta _conversationKeyMeta = const VerificationMeta(
    'conversationKey',
  );
  late final GeneratedColumn<String> conversationKey = GeneratedColumn<String>(
    'conversation_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _addedByMeta = const VerificationMeta(
    'addedBy',
  );
  late final GeneratedColumn<String> addedBy = GeneratedColumn<String>(
    'added_by',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'auto\'',
    defaultValue: const CustomExpression('\'auto\''),
  );
  static const VerificationMeta _evidenceMeta = const VerificationMeta(
    'evidence',
  );
  late final GeneratedColumn<String> evidence = GeneratedColumn<String>(
    'evidence',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _addedAtMeta = const VerificationMeta(
    'addedAt',
  );
  late final GeneratedColumn<String> addedAt = GeneratedColumn<String>(
    'added_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  @override
  List<GeneratedColumn> get $columns => [
    storylineId,
    source,
    conversationKey,
    addedBy,
    evidence,
    addedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'storyline_members';
  @override
  VerificationContext validateIntegrity(
    Insertable<StorylineMember> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('storyline_id')) {
      context.handle(
        _storylineIdMeta,
        storylineId.isAcceptableOrUnknown(
          data['storyline_id']!,
          _storylineIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_storylineIdMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('conversation_key')) {
      context.handle(
        _conversationKeyMeta,
        conversationKey.isAcceptableOrUnknown(
          data['conversation_key']!,
          _conversationKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationKeyMeta);
    }
    if (data.containsKey('added_by')) {
      context.handle(
        _addedByMeta,
        addedBy.isAcceptableOrUnknown(data['added_by']!, _addedByMeta),
      );
    }
    if (data.containsKey('evidence')) {
      context.handle(
        _evidenceMeta,
        evidence.isAcceptableOrUnknown(data['evidence']!, _evidenceMeta),
      );
    }
    if (data.containsKey('added_at')) {
      context.handle(
        _addedAtMeta,
        addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_addedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {
    storylineId,
    source,
    conversationKey,
  };
  @override
  StorylineMember map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StorylineMember(
      storylineId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}storyline_id'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      conversationKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_key'],
      )!,
      addedBy: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}added_by'],
      )!,
      evidence: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}evidence'],
      ),
      addedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}added_at'],
      )!,
    );
  }

  @override
  StorylineMembers createAlias(String alias) {
    return StorylineMembers(attachedDatabase, alias);
  }

  @override
  bool get isStrict => true;
  @override
  List<String> get customConstraints => const [
    'PRIMARY KEY(storyline_id, source, conversation_key)',
  ];
  @override
  bool get dontWriteConstraints => true;
}

class StorylineMember extends DataClass implements Insertable<StorylineMember> {
  final String storylineId;
  final String source;
  final String conversationKey;
  final String addedBy;
  final String? evidence;
  final String addedAt;
  const StorylineMember({
    required this.storylineId,
    required this.source,
    required this.conversationKey,
    required this.addedBy,
    this.evidence,
    required this.addedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['storyline_id'] = Variable<String>(storylineId);
    map['source'] = Variable<String>(source);
    map['conversation_key'] = Variable<String>(conversationKey);
    map['added_by'] = Variable<String>(addedBy);
    if (!nullToAbsent || evidence != null) {
      map['evidence'] = Variable<String>(evidence);
    }
    map['added_at'] = Variable<String>(addedAt);
    return map;
  }

  StorylineMembersCompanion toCompanion(bool nullToAbsent) {
    return StorylineMembersCompanion(
      storylineId: Value(storylineId),
      source: Value(source),
      conversationKey: Value(conversationKey),
      addedBy: Value(addedBy),
      evidence: evidence == null && nullToAbsent
          ? const Value.absent()
          : Value(evidence),
      addedAt: Value(addedAt),
    );
  }

  factory StorylineMember.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StorylineMember(
      storylineId: serializer.fromJson<String>(json['storyline_id']),
      source: serializer.fromJson<String>(json['source']),
      conversationKey: serializer.fromJson<String>(json['conversation_key']),
      addedBy: serializer.fromJson<String>(json['added_by']),
      evidence: serializer.fromJson<String?>(json['evidence']),
      addedAt: serializer.fromJson<String>(json['added_at']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'storyline_id': serializer.toJson<String>(storylineId),
      'source': serializer.toJson<String>(source),
      'conversation_key': serializer.toJson<String>(conversationKey),
      'added_by': serializer.toJson<String>(addedBy),
      'evidence': serializer.toJson<String?>(evidence),
      'added_at': serializer.toJson<String>(addedAt),
    };
  }

  StorylineMember copyWith({
    String? storylineId,
    String? source,
    String? conversationKey,
    String? addedBy,
    Value<String?> evidence = const Value.absent(),
    String? addedAt,
  }) => StorylineMember(
    storylineId: storylineId ?? this.storylineId,
    source: source ?? this.source,
    conversationKey: conversationKey ?? this.conversationKey,
    addedBy: addedBy ?? this.addedBy,
    evidence: evidence.present ? evidence.value : this.evidence,
    addedAt: addedAt ?? this.addedAt,
  );
  StorylineMember copyWithCompanion(StorylineMembersCompanion data) {
    return StorylineMember(
      storylineId: data.storylineId.present
          ? data.storylineId.value
          : this.storylineId,
      source: data.source.present ? data.source.value : this.source,
      conversationKey: data.conversationKey.present
          ? data.conversationKey.value
          : this.conversationKey,
      addedBy: data.addedBy.present ? data.addedBy.value : this.addedBy,
      evidence: data.evidence.present ? data.evidence.value : this.evidence,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StorylineMember(')
          ..write('storylineId: $storylineId, ')
          ..write('source: $source, ')
          ..write('conversationKey: $conversationKey, ')
          ..write('addedBy: $addedBy, ')
          ..write('evidence: $evidence, ')
          ..write('addedAt: $addedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    storylineId,
    source,
    conversationKey,
    addedBy,
    evidence,
    addedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StorylineMember &&
          other.storylineId == this.storylineId &&
          other.source == this.source &&
          other.conversationKey == this.conversationKey &&
          other.addedBy == this.addedBy &&
          other.evidence == this.evidence &&
          other.addedAt == this.addedAt);
}

class StorylineMembersCompanion extends UpdateCompanion<StorylineMember> {
  final Value<String> storylineId;
  final Value<String> source;
  final Value<String> conversationKey;
  final Value<String> addedBy;
  final Value<String?> evidence;
  final Value<String> addedAt;
  final Value<int> rowid;
  const StorylineMembersCompanion({
    this.storylineId = const Value.absent(),
    this.source = const Value.absent(),
    this.conversationKey = const Value.absent(),
    this.addedBy = const Value.absent(),
    this.evidence = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  StorylineMembersCompanion.insert({
    required String storylineId,
    this.source = const Value.absent(),
    required String conversationKey,
    this.addedBy = const Value.absent(),
    this.evidence = const Value.absent(),
    required String addedAt,
    this.rowid = const Value.absent(),
  }) : storylineId = Value(storylineId),
       conversationKey = Value(conversationKey),
       addedAt = Value(addedAt);
  static Insertable<StorylineMember> custom({
    Expression<String>? storylineId,
    Expression<String>? source,
    Expression<String>? conversationKey,
    Expression<String>? addedBy,
    Expression<String>? evidence,
    Expression<String>? addedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (storylineId != null) 'storyline_id': storylineId,
      if (source != null) 'source': source,
      if (conversationKey != null) 'conversation_key': conversationKey,
      if (addedBy != null) 'added_by': addedBy,
      if (evidence != null) 'evidence': evidence,
      if (addedAt != null) 'added_at': addedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  StorylineMembersCompanion copyWith({
    Value<String>? storylineId,
    Value<String>? source,
    Value<String>? conversationKey,
    Value<String>? addedBy,
    Value<String?>? evidence,
    Value<String>? addedAt,
    Value<int>? rowid,
  }) {
    return StorylineMembersCompanion(
      storylineId: storylineId ?? this.storylineId,
      source: source ?? this.source,
      conversationKey: conversationKey ?? this.conversationKey,
      addedBy: addedBy ?? this.addedBy,
      evidence: evidence ?? this.evidence,
      addedAt: addedAt ?? this.addedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (storylineId.present) {
      map['storyline_id'] = Variable<String>(storylineId.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (conversationKey.present) {
      map['conversation_key'] = Variable<String>(conversationKey.value);
    }
    if (addedBy.present) {
      map['added_by'] = Variable<String>(addedBy.value);
    }
    if (evidence.present) {
      map['evidence'] = Variable<String>(evidence.value);
    }
    if (addedAt.present) {
      map['added_at'] = Variable<String>(addedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StorylineMembersCompanion(')
          ..write('storylineId: $storylineId, ')
          ..write('source: $source, ')
          ..write('conversationKey: $conversationKey, ')
          ..write('addedBy: $addedBy, ')
          ..write('evidence: $evidence, ')
          ..write('addedAt: $addedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class StorylineMemberBlocks extends Table
    with TableInfo<StorylineMemberBlocks, StorylineMemberBlock> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  StorylineMemberBlocks(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _storylineIdMeta = const VerificationMeta(
    'storylineId',
  );
  late final GeneratedColumn<String> storylineId = GeneratedColumn<String>(
    'storyline_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'email\'',
    defaultValue: const CustomExpression('\'email\''),
  );
  static const VerificationMeta _conversationKeyMeta = const VerificationMeta(
    'conversationKey',
  );
  late final GeneratedColumn<String> conversationKey = GeneratedColumn<String>(
    'conversation_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _blockedAtMeta = const VerificationMeta(
    'blockedAt',
  );
  late final GeneratedColumn<String> blockedAt = GeneratedColumn<String>(
    'blocked_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  @override
  List<GeneratedColumn> get $columns => [
    storylineId,
    source,
    conversationKey,
    blockedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'storyline_member_blocks';
  @override
  VerificationContext validateIntegrity(
    Insertable<StorylineMemberBlock> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('storyline_id')) {
      context.handle(
        _storylineIdMeta,
        storylineId.isAcceptableOrUnknown(
          data['storyline_id']!,
          _storylineIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_storylineIdMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('conversation_key')) {
      context.handle(
        _conversationKeyMeta,
        conversationKey.isAcceptableOrUnknown(
          data['conversation_key']!,
          _conversationKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationKeyMeta);
    }
    if (data.containsKey('blocked_at')) {
      context.handle(
        _blockedAtMeta,
        blockedAt.isAcceptableOrUnknown(data['blocked_at']!, _blockedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_blockedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {
    storylineId,
    source,
    conversationKey,
  };
  @override
  StorylineMemberBlock map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StorylineMemberBlock(
      storylineId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}storyline_id'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      conversationKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_key'],
      )!,
      blockedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}blocked_at'],
      )!,
    );
  }

  @override
  StorylineMemberBlocks createAlias(String alias) {
    return StorylineMemberBlocks(attachedDatabase, alias);
  }

  @override
  bool get isStrict => true;
  @override
  List<String> get customConstraints => const [
    'PRIMARY KEY(storyline_id, source, conversation_key)',
  ];
  @override
  bool get dontWriteConstraints => true;
}

class StorylineMemberBlock extends DataClass
    implements Insertable<StorylineMemberBlock> {
  final String storylineId;
  final String source;
  final String conversationKey;
  final String blockedAt;
  const StorylineMemberBlock({
    required this.storylineId,
    required this.source,
    required this.conversationKey,
    required this.blockedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['storyline_id'] = Variable<String>(storylineId);
    map['source'] = Variable<String>(source);
    map['conversation_key'] = Variable<String>(conversationKey);
    map['blocked_at'] = Variable<String>(blockedAt);
    return map;
  }

  StorylineMemberBlocksCompanion toCompanion(bool nullToAbsent) {
    return StorylineMemberBlocksCompanion(
      storylineId: Value(storylineId),
      source: Value(source),
      conversationKey: Value(conversationKey),
      blockedAt: Value(blockedAt),
    );
  }

  factory StorylineMemberBlock.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StorylineMemberBlock(
      storylineId: serializer.fromJson<String>(json['storyline_id']),
      source: serializer.fromJson<String>(json['source']),
      conversationKey: serializer.fromJson<String>(json['conversation_key']),
      blockedAt: serializer.fromJson<String>(json['blocked_at']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'storyline_id': serializer.toJson<String>(storylineId),
      'source': serializer.toJson<String>(source),
      'conversation_key': serializer.toJson<String>(conversationKey),
      'blocked_at': serializer.toJson<String>(blockedAt),
    };
  }

  StorylineMemberBlock copyWith({
    String? storylineId,
    String? source,
    String? conversationKey,
    String? blockedAt,
  }) => StorylineMemberBlock(
    storylineId: storylineId ?? this.storylineId,
    source: source ?? this.source,
    conversationKey: conversationKey ?? this.conversationKey,
    blockedAt: blockedAt ?? this.blockedAt,
  );
  StorylineMemberBlock copyWithCompanion(StorylineMemberBlocksCompanion data) {
    return StorylineMemberBlock(
      storylineId: data.storylineId.present
          ? data.storylineId.value
          : this.storylineId,
      source: data.source.present ? data.source.value : this.source,
      conversationKey: data.conversationKey.present
          ? data.conversationKey.value
          : this.conversationKey,
      blockedAt: data.blockedAt.present ? data.blockedAt.value : this.blockedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StorylineMemberBlock(')
          ..write('storylineId: $storylineId, ')
          ..write('source: $source, ')
          ..write('conversationKey: $conversationKey, ')
          ..write('blockedAt: $blockedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(storylineId, source, conversationKey, blockedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StorylineMemberBlock &&
          other.storylineId == this.storylineId &&
          other.source == this.source &&
          other.conversationKey == this.conversationKey &&
          other.blockedAt == this.blockedAt);
}

class StorylineMemberBlocksCompanion
    extends UpdateCompanion<StorylineMemberBlock> {
  final Value<String> storylineId;
  final Value<String> source;
  final Value<String> conversationKey;
  final Value<String> blockedAt;
  final Value<int> rowid;
  const StorylineMemberBlocksCompanion({
    this.storylineId = const Value.absent(),
    this.source = const Value.absent(),
    this.conversationKey = const Value.absent(),
    this.blockedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  StorylineMemberBlocksCompanion.insert({
    required String storylineId,
    this.source = const Value.absent(),
    required String conversationKey,
    required String blockedAt,
    this.rowid = const Value.absent(),
  }) : storylineId = Value(storylineId),
       conversationKey = Value(conversationKey),
       blockedAt = Value(blockedAt);
  static Insertable<StorylineMemberBlock> custom({
    Expression<String>? storylineId,
    Expression<String>? source,
    Expression<String>? conversationKey,
    Expression<String>? blockedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (storylineId != null) 'storyline_id': storylineId,
      if (source != null) 'source': source,
      if (conversationKey != null) 'conversation_key': conversationKey,
      if (blockedAt != null) 'blocked_at': blockedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  StorylineMemberBlocksCompanion copyWith({
    Value<String>? storylineId,
    Value<String>? source,
    Value<String>? conversationKey,
    Value<String>? blockedAt,
    Value<int>? rowid,
  }) {
    return StorylineMemberBlocksCompanion(
      storylineId: storylineId ?? this.storylineId,
      source: source ?? this.source,
      conversationKey: conversationKey ?? this.conversationKey,
      blockedAt: blockedAt ?? this.blockedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (storylineId.present) {
      map['storyline_id'] = Variable<String>(storylineId.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (conversationKey.present) {
      map['conversation_key'] = Variable<String>(conversationKey.value);
    }
    if (blockedAt.present) {
      map['blocked_at'] = Variable<String>(blockedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StorylineMemberBlocksCompanion(')
          ..write('storylineId: $storylineId, ')
          ..write('source: $source, ')
          ..write('conversationKey: $conversationKey, ')
          ..write('blockedAt: $blockedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class FeedbackEvents extends Table
    with TableInfo<FeedbackEvents, FeedbackEvent> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  FeedbackEvents(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'PRIMARY KEY',
  );
  static const VerificationMeta _scopeMeta = const VerificationMeta('scope');
  late final GeneratedColumn<String> scope = GeneratedColumn<String>(
    'scope',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _scopeKeyMeta = const VerificationMeta(
    'scopeKey',
  );
  late final GeneratedColumn<String> scopeKey = GeneratedColumn<String>(
    'scope_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _directionMeta = const VerificationMeta(
    'direction',
  );
  late final GeneratedColumn<String> direction = GeneratedColumn<String>(
    'direction',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _originMeta = const VerificationMeta('origin');
  late final GeneratedColumn<String> origin = GeneratedColumn<String>(
    'origin',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    scope,
    scopeKey,
    direction,
    origin,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'feedback_events';
  @override
  VerificationContext validateIntegrity(
    Insertable<FeedbackEvent> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('scope')) {
      context.handle(
        _scopeMeta,
        scope.isAcceptableOrUnknown(data['scope']!, _scopeMeta),
      );
    } else if (isInserting) {
      context.missing(_scopeMeta);
    }
    if (data.containsKey('scope_key')) {
      context.handle(
        _scopeKeyMeta,
        scopeKey.isAcceptableOrUnknown(data['scope_key']!, _scopeKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_scopeKeyMeta);
    }
    if (data.containsKey('direction')) {
      context.handle(
        _directionMeta,
        direction.isAcceptableOrUnknown(data['direction']!, _directionMeta),
      );
    } else if (isInserting) {
      context.missing(_directionMeta);
    }
    if (data.containsKey('origin')) {
      context.handle(
        _originMeta,
        origin.isAcceptableOrUnknown(data['origin']!, _originMeta),
      );
    } else if (isInserting) {
      context.missing(_originMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  FeedbackEvent map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return FeedbackEvent(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      scope: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scope'],
      )!,
      scopeKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scope_key'],
      )!,
      direction: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}direction'],
      )!,
      origin: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}origin'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  FeedbackEvents createAlias(String alias) {
    return FeedbackEvents(attachedDatabase, alias);
  }

  @override
  bool get isStrict => true;
  @override
  bool get dontWriteConstraints => true;
}

class FeedbackEvent extends DataClass implements Insertable<FeedbackEvent> {
  final int id;
  final String scope;
  final String scopeKey;
  final String direction;
  final String origin;
  final String createdAt;
  const FeedbackEvent({
    required this.id,
    required this.scope,
    required this.scopeKey,
    required this.direction,
    required this.origin,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['scope'] = Variable<String>(scope);
    map['scope_key'] = Variable<String>(scopeKey);
    map['direction'] = Variable<String>(direction);
    map['origin'] = Variable<String>(origin);
    map['created_at'] = Variable<String>(createdAt);
    return map;
  }

  FeedbackEventsCompanion toCompanion(bool nullToAbsent) {
    return FeedbackEventsCompanion(
      id: Value(id),
      scope: Value(scope),
      scopeKey: Value(scopeKey),
      direction: Value(direction),
      origin: Value(origin),
      createdAt: Value(createdAt),
    );
  }

  factory FeedbackEvent.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return FeedbackEvent(
      id: serializer.fromJson<int>(json['id']),
      scope: serializer.fromJson<String>(json['scope']),
      scopeKey: serializer.fromJson<String>(json['scope_key']),
      direction: serializer.fromJson<String>(json['direction']),
      origin: serializer.fromJson<String>(json['origin']),
      createdAt: serializer.fromJson<String>(json['created_at']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'scope': serializer.toJson<String>(scope),
      'scope_key': serializer.toJson<String>(scopeKey),
      'direction': serializer.toJson<String>(direction),
      'origin': serializer.toJson<String>(origin),
      'created_at': serializer.toJson<String>(createdAt),
    };
  }

  FeedbackEvent copyWith({
    int? id,
    String? scope,
    String? scopeKey,
    String? direction,
    String? origin,
    String? createdAt,
  }) => FeedbackEvent(
    id: id ?? this.id,
    scope: scope ?? this.scope,
    scopeKey: scopeKey ?? this.scopeKey,
    direction: direction ?? this.direction,
    origin: origin ?? this.origin,
    createdAt: createdAt ?? this.createdAt,
  );
  FeedbackEvent copyWithCompanion(FeedbackEventsCompanion data) {
    return FeedbackEvent(
      id: data.id.present ? data.id.value : this.id,
      scope: data.scope.present ? data.scope.value : this.scope,
      scopeKey: data.scopeKey.present ? data.scopeKey.value : this.scopeKey,
      direction: data.direction.present ? data.direction.value : this.direction,
      origin: data.origin.present ? data.origin.value : this.origin,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('FeedbackEvent(')
          ..write('id: $id, ')
          ..write('scope: $scope, ')
          ..write('scopeKey: $scopeKey, ')
          ..write('direction: $direction, ')
          ..write('origin: $origin, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, scope, scopeKey, direction, origin, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FeedbackEvent &&
          other.id == this.id &&
          other.scope == this.scope &&
          other.scopeKey == this.scopeKey &&
          other.direction == this.direction &&
          other.origin == this.origin &&
          other.createdAt == this.createdAt);
}

class FeedbackEventsCompanion extends UpdateCompanion<FeedbackEvent> {
  final Value<int> id;
  final Value<String> scope;
  final Value<String> scopeKey;
  final Value<String> direction;
  final Value<String> origin;
  final Value<String> createdAt;
  const FeedbackEventsCompanion({
    this.id = const Value.absent(),
    this.scope = const Value.absent(),
    this.scopeKey = const Value.absent(),
    this.direction = const Value.absent(),
    this.origin = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  FeedbackEventsCompanion.insert({
    this.id = const Value.absent(),
    required String scope,
    required String scopeKey,
    required String direction,
    required String origin,
    required String createdAt,
  }) : scope = Value(scope),
       scopeKey = Value(scopeKey),
       direction = Value(direction),
       origin = Value(origin),
       createdAt = Value(createdAt);
  static Insertable<FeedbackEvent> custom({
    Expression<int>? id,
    Expression<String>? scope,
    Expression<String>? scopeKey,
    Expression<String>? direction,
    Expression<String>? origin,
    Expression<String>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (scope != null) 'scope': scope,
      if (scopeKey != null) 'scope_key': scopeKey,
      if (direction != null) 'direction': direction,
      if (origin != null) 'origin': origin,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  FeedbackEventsCompanion copyWith({
    Value<int>? id,
    Value<String>? scope,
    Value<String>? scopeKey,
    Value<String>? direction,
    Value<String>? origin,
    Value<String>? createdAt,
  }) {
    return FeedbackEventsCompanion(
      id: id ?? this.id,
      scope: scope ?? this.scope,
      scopeKey: scopeKey ?? this.scopeKey,
      direction: direction ?? this.direction,
      origin: origin ?? this.origin,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (scope.present) {
      map['scope'] = Variable<String>(scope.value);
    }
    if (scopeKey.present) {
      map['scope_key'] = Variable<String>(scopeKey.value);
    }
    if (direction.present) {
      map['direction'] = Variable<String>(direction.value);
    }
    if (origin.present) {
      map['origin'] = Variable<String>(origin.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FeedbackEventsCompanion(')
          ..write('id: $id, ')
          ..write('scope: $scope, ')
          ..write('scopeKey: $scopeKey, ')
          ..write('direction: $direction, ')
          ..write('origin: $origin, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class ActivityEvents extends Table
    with TableInfo<ActivityEvents, ActivityEvent> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  ActivityEvents(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'PRIMARY KEY',
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _entityIdMeta = const VerificationMeta(
    'entityId',
  );
  late final GeneratedColumn<String> entityId = GeneratedColumn<String>(
    'entity_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _countMeta = const VerificationMeta('count');
  late final GeneratedColumn<int> count = GeneratedColumn<int>(
    'count',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _durationMsMeta = const VerificationMeta(
    'durationMs',
  );
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
    'duration_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _detailJsonMeta = const VerificationMeta(
    'detailJson',
  );
  late final GeneratedColumn<String> detailJson = GeneratedColumn<String>(
    'detail_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    kind,
    source,
    status,
    entityId,
    count,
    durationMs,
    detailJson,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'activity_events';
  @override
  VerificationContext validateIntegrity(
    Insertable<ActivityEvent> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('entity_id')) {
      context.handle(
        _entityIdMeta,
        entityId.isAcceptableOrUnknown(data['entity_id']!, _entityIdMeta),
      );
    }
    if (data.containsKey('count')) {
      context.handle(
        _countMeta,
        count.isAcceptableOrUnknown(data['count']!, _countMeta),
      );
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
        _durationMsMeta,
        durationMs.isAcceptableOrUnknown(data['duration_ms']!, _durationMsMeta),
      );
    }
    if (data.containsKey('detail_json')) {
      context.handle(
        _detailJsonMeta,
        detailJson.isAcceptableOrUnknown(data['detail_json']!, _detailJsonMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ActivityEvent map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ActivityEvent(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      entityId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_id'],
      ),
      count: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}count'],
      ),
      durationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_ms'],
      ),
      detailJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}detail_json'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  ActivityEvents createAlias(String alias) {
    return ActivityEvents(attachedDatabase, alias);
  }

  @override
  bool get isStrict => true;
  @override
  bool get dontWriteConstraints => true;
}

class ActivityEvent extends DataClass implements Insertable<ActivityEvent> {
  final int id;
  final String kind;
  final String? source;
  final String status;
  final String? entityId;
  final int? count;
  final int? durationMs;
  final String? detailJson;
  final String createdAt;
  const ActivityEvent({
    required this.id,
    required this.kind,
    this.source,
    required this.status,
    this.entityId,
    this.count,
    this.durationMs,
    this.detailJson,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['kind'] = Variable<String>(kind);
    if (!nullToAbsent || source != null) {
      map['source'] = Variable<String>(source);
    }
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || entityId != null) {
      map['entity_id'] = Variable<String>(entityId);
    }
    if (!nullToAbsent || count != null) {
      map['count'] = Variable<int>(count);
    }
    if (!nullToAbsent || durationMs != null) {
      map['duration_ms'] = Variable<int>(durationMs);
    }
    if (!nullToAbsent || detailJson != null) {
      map['detail_json'] = Variable<String>(detailJson);
    }
    map['created_at'] = Variable<String>(createdAt);
    return map;
  }

  ActivityEventsCompanion toCompanion(bool nullToAbsent) {
    return ActivityEventsCompanion(
      id: Value(id),
      kind: Value(kind),
      source: source == null && nullToAbsent
          ? const Value.absent()
          : Value(source),
      status: Value(status),
      entityId: entityId == null && nullToAbsent
          ? const Value.absent()
          : Value(entityId),
      count: count == null && nullToAbsent
          ? const Value.absent()
          : Value(count),
      durationMs: durationMs == null && nullToAbsent
          ? const Value.absent()
          : Value(durationMs),
      detailJson: detailJson == null && nullToAbsent
          ? const Value.absent()
          : Value(detailJson),
      createdAt: Value(createdAt),
    );
  }

  factory ActivityEvent.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ActivityEvent(
      id: serializer.fromJson<int>(json['id']),
      kind: serializer.fromJson<String>(json['kind']),
      source: serializer.fromJson<String?>(json['source']),
      status: serializer.fromJson<String>(json['status']),
      entityId: serializer.fromJson<String?>(json['entity_id']),
      count: serializer.fromJson<int?>(json['count']),
      durationMs: serializer.fromJson<int?>(json['duration_ms']),
      detailJson: serializer.fromJson<String?>(json['detail_json']),
      createdAt: serializer.fromJson<String>(json['created_at']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'kind': serializer.toJson<String>(kind),
      'source': serializer.toJson<String?>(source),
      'status': serializer.toJson<String>(status),
      'entity_id': serializer.toJson<String?>(entityId),
      'count': serializer.toJson<int?>(count),
      'duration_ms': serializer.toJson<int?>(durationMs),
      'detail_json': serializer.toJson<String?>(detailJson),
      'created_at': serializer.toJson<String>(createdAt),
    };
  }

  ActivityEvent copyWith({
    int? id,
    String? kind,
    Value<String?> source = const Value.absent(),
    String? status,
    Value<String?> entityId = const Value.absent(),
    Value<int?> count = const Value.absent(),
    Value<int?> durationMs = const Value.absent(),
    Value<String?> detailJson = const Value.absent(),
    String? createdAt,
  }) => ActivityEvent(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    source: source.present ? source.value : this.source,
    status: status ?? this.status,
    entityId: entityId.present ? entityId.value : this.entityId,
    count: count.present ? count.value : this.count,
    durationMs: durationMs.present ? durationMs.value : this.durationMs,
    detailJson: detailJson.present ? detailJson.value : this.detailJson,
    createdAt: createdAt ?? this.createdAt,
  );
  ActivityEvent copyWithCompanion(ActivityEventsCompanion data) {
    return ActivityEvent(
      id: data.id.present ? data.id.value : this.id,
      kind: data.kind.present ? data.kind.value : this.kind,
      source: data.source.present ? data.source.value : this.source,
      status: data.status.present ? data.status.value : this.status,
      entityId: data.entityId.present ? data.entityId.value : this.entityId,
      count: data.count.present ? data.count.value : this.count,
      durationMs: data.durationMs.present
          ? data.durationMs.value
          : this.durationMs,
      detailJson: data.detailJson.present
          ? data.detailJson.value
          : this.detailJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ActivityEvent(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('source: $source, ')
          ..write('status: $status, ')
          ..write('entityId: $entityId, ')
          ..write('count: $count, ')
          ..write('durationMs: $durationMs, ')
          ..write('detailJson: $detailJson, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    source,
    status,
    entityId,
    count,
    durationMs,
    detailJson,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ActivityEvent &&
          other.id == this.id &&
          other.kind == this.kind &&
          other.source == this.source &&
          other.status == this.status &&
          other.entityId == this.entityId &&
          other.count == this.count &&
          other.durationMs == this.durationMs &&
          other.detailJson == this.detailJson &&
          other.createdAt == this.createdAt);
}

class ActivityEventsCompanion extends UpdateCompanion<ActivityEvent> {
  final Value<int> id;
  final Value<String> kind;
  final Value<String?> source;
  final Value<String> status;
  final Value<String?> entityId;
  final Value<int?> count;
  final Value<int?> durationMs;
  final Value<String?> detailJson;
  final Value<String> createdAt;
  const ActivityEventsCompanion({
    this.id = const Value.absent(),
    this.kind = const Value.absent(),
    this.source = const Value.absent(),
    this.status = const Value.absent(),
    this.entityId = const Value.absent(),
    this.count = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.detailJson = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  ActivityEventsCompanion.insert({
    this.id = const Value.absent(),
    required String kind,
    this.source = const Value.absent(),
    required String status,
    this.entityId = const Value.absent(),
    this.count = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.detailJson = const Value.absent(),
    required String createdAt,
  }) : kind = Value(kind),
       status = Value(status),
       createdAt = Value(createdAt);
  static Insertable<ActivityEvent> custom({
    Expression<int>? id,
    Expression<String>? kind,
    Expression<String>? source,
    Expression<String>? status,
    Expression<String>? entityId,
    Expression<int>? count,
    Expression<int>? durationMs,
    Expression<String>? detailJson,
    Expression<String>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (kind != null) 'kind': kind,
      if (source != null) 'source': source,
      if (status != null) 'status': status,
      if (entityId != null) 'entity_id': entityId,
      if (count != null) 'count': count,
      if (durationMs != null) 'duration_ms': durationMs,
      if (detailJson != null) 'detail_json': detailJson,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  ActivityEventsCompanion copyWith({
    Value<int>? id,
    Value<String>? kind,
    Value<String?>? source,
    Value<String>? status,
    Value<String?>? entityId,
    Value<int?>? count,
    Value<int?>? durationMs,
    Value<String?>? detailJson,
    Value<String>? createdAt,
  }) {
    return ActivityEventsCompanion(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      source: source ?? this.source,
      status: status ?? this.status,
      entityId: entityId ?? this.entityId,
      count: count ?? this.count,
      durationMs: durationMs ?? this.durationMs,
      detailJson: detailJson ?? this.detailJson,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (entityId.present) {
      map['entity_id'] = Variable<String>(entityId.value);
    }
    if (count.present) {
      map['count'] = Variable<int>(count.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    if (detailJson.present) {
      map['detail_json'] = Variable<String>(detailJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ActivityEventsCompanion(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('source: $source, ')
          ..write('status: $status, ')
          ..write('entityId: $entityId, ')
          ..write('count: $count, ')
          ..write('durationMs: $durationMs, ')
          ..write('detailJson: $detailJson, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class SenderPrefs extends Table with TableInfo<SenderPrefs, SenderPref> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  SenderPrefs(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _addressMeta = const VerificationMeta(
    'address',
  );
  late final GeneratedColumn<String> address = GeneratedColumn<String>(
    'address',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'PRIMARY KEY',
  );
  static const VerificationMeta _dispositionMeta = const VerificationMeta(
    'disposition',
  );
  late final GeneratedColumn<String> disposition = GeneratedColumn<String>(
    'disposition',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  @override
  List<GeneratedColumn> get $columns => [address, disposition, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sender_prefs';
  @override
  VerificationContext validateIntegrity(
    Insertable<SenderPref> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('address')) {
      context.handle(
        _addressMeta,
        address.isAcceptableOrUnknown(data['address']!, _addressMeta),
      );
    } else if (isInserting) {
      context.missing(_addressMeta);
    }
    if (data.containsKey('disposition')) {
      context.handle(
        _dispositionMeta,
        disposition.isAcceptableOrUnknown(
          data['disposition']!,
          _dispositionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_dispositionMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {address};
  @override
  SenderPref map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SenderPref(
      address: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}address'],
      )!,
      disposition: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}disposition'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  SenderPrefs createAlias(String alias) {
    return SenderPrefs(attachedDatabase, alias);
  }

  @override
  bool get isStrict => true;
  @override
  bool get dontWriteConstraints => true;
}

class SenderPref extends DataClass implements Insertable<SenderPref> {
  final String address;
  final String disposition;
  final String updatedAt;
  const SenderPref({
    required this.address,
    required this.disposition,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['address'] = Variable<String>(address);
    map['disposition'] = Variable<String>(disposition);
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  SenderPrefsCompanion toCompanion(bool nullToAbsent) {
    return SenderPrefsCompanion(
      address: Value(address),
      disposition: Value(disposition),
      updatedAt: Value(updatedAt),
    );
  }

  factory SenderPref.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SenderPref(
      address: serializer.fromJson<String>(json['address']),
      disposition: serializer.fromJson<String>(json['disposition']),
      updatedAt: serializer.fromJson<String>(json['updated_at']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'address': serializer.toJson<String>(address),
      'disposition': serializer.toJson<String>(disposition),
      'updated_at': serializer.toJson<String>(updatedAt),
    };
  }

  SenderPref copyWith({
    String? address,
    String? disposition,
    String? updatedAt,
  }) => SenderPref(
    address: address ?? this.address,
    disposition: disposition ?? this.disposition,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  SenderPref copyWithCompanion(SenderPrefsCompanion data) {
    return SenderPref(
      address: data.address.present ? data.address.value : this.address,
      disposition: data.disposition.present
          ? data.disposition.value
          : this.disposition,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SenderPref(')
          ..write('address: $address, ')
          ..write('disposition: $disposition, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(address, disposition, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SenderPref &&
          other.address == this.address &&
          other.disposition == this.disposition &&
          other.updatedAt == this.updatedAt);
}

class SenderPrefsCompanion extends UpdateCompanion<SenderPref> {
  final Value<String> address;
  final Value<String> disposition;
  final Value<String> updatedAt;
  final Value<int> rowid;
  const SenderPrefsCompanion({
    this.address = const Value.absent(),
    this.disposition = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SenderPrefsCompanion.insert({
    required String address,
    required String disposition,
    required String updatedAt,
    this.rowid = const Value.absent(),
  }) : address = Value(address),
       disposition = Value(disposition),
       updatedAt = Value(updatedAt);
  static Insertable<SenderPref> custom({
    Expression<String>? address,
    Expression<String>? disposition,
    Expression<String>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (address != null) 'address': address,
      if (disposition != null) 'disposition': disposition,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SenderPrefsCompanion copyWith({
    Value<String>? address,
    Value<String>? disposition,
    Value<String>? updatedAt,
    Value<int>? rowid,
  }) {
    return SenderPrefsCompanion(
      address: address ?? this.address,
      disposition: disposition ?? this.disposition,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (address.present) {
      map['address'] = Variable<String>(address.value);
    }
    if (disposition.present) {
      map['disposition'] = Variable<String>(disposition.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SenderPrefsCompanion(')
          ..write('address: $address, ')
          ..write('disposition: $disposition, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class AppPrefs extends Table with TableInfo<AppPrefs, AppPref> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  AppPrefs(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'PRIMARY KEY',
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_prefs';
  @override
  VerificationContext validateIntegrity(
    Insertable<AppPref> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  AppPref map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppPref(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  AppPrefs createAlias(String alias) {
    return AppPrefs(attachedDatabase, alias);
  }

  @override
  bool get isStrict => true;
  @override
  bool get dontWriteConstraints => true;
}

class AppPref extends DataClass implements Insertable<AppPref> {
  final String key;
  final String value;
  const AppPref({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  AppPrefsCompanion toCompanion(bool nullToAbsent) {
    return AppPrefsCompanion(key: Value(key), value: Value(value));
  }

  factory AppPref.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppPref(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  AppPref copyWith({String? key, String? value}) =>
      AppPref(key: key ?? this.key, value: value ?? this.value);
  AppPref copyWithCompanion(AppPrefsCompanion data) {
    return AppPref(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppPref(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppPref && other.key == this.key && other.value == this.value);
}

class AppPrefsCompanion extends UpdateCompanion<AppPref> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const AppPrefsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AppPrefsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<AppPref> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AppPrefsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return AppPrefsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppPrefsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class Drafts extends Table with TableInfo<Drafts, Draft> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  Drafts(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'email\'',
    defaultValue: const CustomExpression('\'email\''),
  );
  static const VerificationMeta _conversationKeyMeta = const VerificationMeta(
    'conversationKey',
  );
  late final GeneratedColumn<String> conversationKey = GeneratedColumn<String>(
    'conversation_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _replyToMessageIdMeta = const VerificationMeta(
    'replyToMessageId',
  );
  late final GeneratedColumn<String> replyToMessageId = GeneratedColumn<String>(
    'reply_to_message_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
    'body',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _evidenceMeta = const VerificationMeta(
    'evidence',
  );
  late final GeneratedColumn<String> evidence = GeneratedColumn<String>(
    'evidence',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'suggested\'',
    defaultValue: const CustomExpression('\'suggested\''),
  );
  static const VerificationMeta _graphDraftIdMeta = const VerificationMeta(
    'graphDraftId',
  );
  late final GeneratedColumn<String> graphDraftId = GeneratedColumn<String>(
    'graph_draft_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _webLinkMeta = const VerificationMeta(
    'webLink',
  );
  late final GeneratedColumn<String> webLink = GeneratedColumn<String>(
    'web_link',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  @override
  List<GeneratedColumn> get $columns => [
    source,
    conversationKey,
    replyToMessageId,
    body,
    evidence,
    status,
    graphDraftId,
    webLink,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'drafts';
  @override
  VerificationContext validateIntegrity(
    Insertable<Draft> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('conversation_key')) {
      context.handle(
        _conversationKeyMeta,
        conversationKey.isAcceptableOrUnknown(
          data['conversation_key']!,
          _conversationKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationKeyMeta);
    }
    if (data.containsKey('reply_to_message_id')) {
      context.handle(
        _replyToMessageIdMeta,
        replyToMessageId.isAcceptableOrUnknown(
          data['reply_to_message_id']!,
          _replyToMessageIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_replyToMessageIdMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
        _bodyMeta,
        body.isAcceptableOrUnknown(data['body']!, _bodyMeta),
      );
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    if (data.containsKey('evidence')) {
      context.handle(
        _evidenceMeta,
        evidence.isAcceptableOrUnknown(data['evidence']!, _evidenceMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('graph_draft_id')) {
      context.handle(
        _graphDraftIdMeta,
        graphDraftId.isAcceptableOrUnknown(
          data['graph_draft_id']!,
          _graphDraftIdMeta,
        ),
      );
    }
    if (data.containsKey('web_link')) {
      context.handle(
        _webLinkMeta,
        webLink.isAcceptableOrUnknown(data['web_link']!, _webLinkMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {source, conversationKey};
  @override
  Draft map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Draft(
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      conversationKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_key'],
      )!,
      replyToMessageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reply_to_message_id'],
      )!,
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body'],
      )!,
      evidence: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}evidence'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      graphDraftId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}graph_draft_id'],
      ),
      webLink: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}web_link'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  Drafts createAlias(String alias) {
    return Drafts(attachedDatabase, alias);
  }

  @override
  bool get isStrict => true;
  @override
  List<String> get customConstraints => const [
    'PRIMARY KEY(source, conversation_key)',
  ];
  @override
  bool get dontWriteConstraints => true;
}

class Draft extends DataClass implements Insertable<Draft> {
  final String source;
  final String conversationKey;
  final String replyToMessageId;
  final String body;
  final String? evidence;
  final String status;
  final String? graphDraftId;
  final String? webLink;
  final String createdAt;
  final String updatedAt;
  const Draft({
    required this.source,
    required this.conversationKey,
    required this.replyToMessageId,
    required this.body,
    this.evidence,
    required this.status,
    this.graphDraftId,
    this.webLink,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['source'] = Variable<String>(source);
    map['conversation_key'] = Variable<String>(conversationKey);
    map['reply_to_message_id'] = Variable<String>(replyToMessageId);
    map['body'] = Variable<String>(body);
    if (!nullToAbsent || evidence != null) {
      map['evidence'] = Variable<String>(evidence);
    }
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || graphDraftId != null) {
      map['graph_draft_id'] = Variable<String>(graphDraftId);
    }
    if (!nullToAbsent || webLink != null) {
      map['web_link'] = Variable<String>(webLink);
    }
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    return map;
  }

  DraftsCompanion toCompanion(bool nullToAbsent) {
    return DraftsCompanion(
      source: Value(source),
      conversationKey: Value(conversationKey),
      replyToMessageId: Value(replyToMessageId),
      body: Value(body),
      evidence: evidence == null && nullToAbsent
          ? const Value.absent()
          : Value(evidence),
      status: Value(status),
      graphDraftId: graphDraftId == null && nullToAbsent
          ? const Value.absent()
          : Value(graphDraftId),
      webLink: webLink == null && nullToAbsent
          ? const Value.absent()
          : Value(webLink),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory Draft.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Draft(
      source: serializer.fromJson<String>(json['source']),
      conversationKey: serializer.fromJson<String>(json['conversation_key']),
      replyToMessageId: serializer.fromJson<String>(
        json['reply_to_message_id'],
      ),
      body: serializer.fromJson<String>(json['body']),
      evidence: serializer.fromJson<String?>(json['evidence']),
      status: serializer.fromJson<String>(json['status']),
      graphDraftId: serializer.fromJson<String?>(json['graph_draft_id']),
      webLink: serializer.fromJson<String?>(json['web_link']),
      createdAt: serializer.fromJson<String>(json['created_at']),
      updatedAt: serializer.fromJson<String>(json['updated_at']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'source': serializer.toJson<String>(source),
      'conversation_key': serializer.toJson<String>(conversationKey),
      'reply_to_message_id': serializer.toJson<String>(replyToMessageId),
      'body': serializer.toJson<String>(body),
      'evidence': serializer.toJson<String?>(evidence),
      'status': serializer.toJson<String>(status),
      'graph_draft_id': serializer.toJson<String?>(graphDraftId),
      'web_link': serializer.toJson<String?>(webLink),
      'created_at': serializer.toJson<String>(createdAt),
      'updated_at': serializer.toJson<String>(updatedAt),
    };
  }

  Draft copyWith({
    String? source,
    String? conversationKey,
    String? replyToMessageId,
    String? body,
    Value<String?> evidence = const Value.absent(),
    String? status,
    Value<String?> graphDraftId = const Value.absent(),
    Value<String?> webLink = const Value.absent(),
    String? createdAt,
    String? updatedAt,
  }) => Draft(
    source: source ?? this.source,
    conversationKey: conversationKey ?? this.conversationKey,
    replyToMessageId: replyToMessageId ?? this.replyToMessageId,
    body: body ?? this.body,
    evidence: evidence.present ? evidence.value : this.evidence,
    status: status ?? this.status,
    graphDraftId: graphDraftId.present ? graphDraftId.value : this.graphDraftId,
    webLink: webLink.present ? webLink.value : this.webLink,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  Draft copyWithCompanion(DraftsCompanion data) {
    return Draft(
      source: data.source.present ? data.source.value : this.source,
      conversationKey: data.conversationKey.present
          ? data.conversationKey.value
          : this.conversationKey,
      replyToMessageId: data.replyToMessageId.present
          ? data.replyToMessageId.value
          : this.replyToMessageId,
      body: data.body.present ? data.body.value : this.body,
      evidence: data.evidence.present ? data.evidence.value : this.evidence,
      status: data.status.present ? data.status.value : this.status,
      graphDraftId: data.graphDraftId.present
          ? data.graphDraftId.value
          : this.graphDraftId,
      webLink: data.webLink.present ? data.webLink.value : this.webLink,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Draft(')
          ..write('source: $source, ')
          ..write('conversationKey: $conversationKey, ')
          ..write('replyToMessageId: $replyToMessageId, ')
          ..write('body: $body, ')
          ..write('evidence: $evidence, ')
          ..write('status: $status, ')
          ..write('graphDraftId: $graphDraftId, ')
          ..write('webLink: $webLink, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    source,
    conversationKey,
    replyToMessageId,
    body,
    evidence,
    status,
    graphDraftId,
    webLink,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Draft &&
          other.source == this.source &&
          other.conversationKey == this.conversationKey &&
          other.replyToMessageId == this.replyToMessageId &&
          other.body == this.body &&
          other.evidence == this.evidence &&
          other.status == this.status &&
          other.graphDraftId == this.graphDraftId &&
          other.webLink == this.webLink &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class DraftsCompanion extends UpdateCompanion<Draft> {
  final Value<String> source;
  final Value<String> conversationKey;
  final Value<String> replyToMessageId;
  final Value<String> body;
  final Value<String?> evidence;
  final Value<String> status;
  final Value<String?> graphDraftId;
  final Value<String?> webLink;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  final Value<int> rowid;
  const DraftsCompanion({
    this.source = const Value.absent(),
    this.conversationKey = const Value.absent(),
    this.replyToMessageId = const Value.absent(),
    this.body = const Value.absent(),
    this.evidence = const Value.absent(),
    this.status = const Value.absent(),
    this.graphDraftId = const Value.absent(),
    this.webLink = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DraftsCompanion.insert({
    this.source = const Value.absent(),
    required String conversationKey,
    required String replyToMessageId,
    required String body,
    this.evidence = const Value.absent(),
    this.status = const Value.absent(),
    this.graphDraftId = const Value.absent(),
    this.webLink = const Value.absent(),
    required String createdAt,
    required String updatedAt,
    this.rowid = const Value.absent(),
  }) : conversationKey = Value(conversationKey),
       replyToMessageId = Value(replyToMessageId),
       body = Value(body),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<Draft> custom({
    Expression<String>? source,
    Expression<String>? conversationKey,
    Expression<String>? replyToMessageId,
    Expression<String>? body,
    Expression<String>? evidence,
    Expression<String>? status,
    Expression<String>? graphDraftId,
    Expression<String>? webLink,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (source != null) 'source': source,
      if (conversationKey != null) 'conversation_key': conversationKey,
      if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
      if (body != null) 'body': body,
      if (evidence != null) 'evidence': evidence,
      if (status != null) 'status': status,
      if (graphDraftId != null) 'graph_draft_id': graphDraftId,
      if (webLink != null) 'web_link': webLink,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DraftsCompanion copyWith({
    Value<String>? source,
    Value<String>? conversationKey,
    Value<String>? replyToMessageId,
    Value<String>? body,
    Value<String?>? evidence,
    Value<String>? status,
    Value<String?>? graphDraftId,
    Value<String?>? webLink,
    Value<String>? createdAt,
    Value<String>? updatedAt,
    Value<int>? rowid,
  }) {
    return DraftsCompanion(
      source: source ?? this.source,
      conversationKey: conversationKey ?? this.conversationKey,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      body: body ?? this.body,
      evidence: evidence ?? this.evidence,
      status: status ?? this.status,
      graphDraftId: graphDraftId ?? this.graphDraftId,
      webLink: webLink ?? this.webLink,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (conversationKey.present) {
      map['conversation_key'] = Variable<String>(conversationKey.value);
    }
    if (replyToMessageId.present) {
      map['reply_to_message_id'] = Variable<String>(replyToMessageId.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (evidence.present) {
      map['evidence'] = Variable<String>(evidence.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (graphDraftId.present) {
      map['graph_draft_id'] = Variable<String>(graphDraftId.value);
    }
    if (webLink.present) {
      map['web_link'] = Variable<String>(webLink.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DraftsCompanion(')
          ..write('source: $source, ')
          ..write('conversationKey: $conversationKey, ')
          ..write('replyToMessageId: $replyToMessageId, ')
          ..write('body: $body, ')
          ..write('evidence: $evidence, ')
          ..write('status: $status, ')
          ..write('graphDraftId: $graphDraftId, ')
          ..write('webLink: $webLink, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$BondDatabase extends GeneratedDatabase {
  _$BondDatabase(QueryExecutor e) : super(e);
  $BondDatabaseManager get managers => $BondDatabaseManager(this);
  late final Messages messages = Messages(this);
  late final Index ixMessagesConv = Index(
    'ix_messages_conv',
    'CREATE INDEX ix_messages_conv ON messages (source, conversation_key, received_at)',
  );
  late final Index ixMessagesTriage = Index(
    'ix_messages_triage',
    'CREATE INDEX ix_messages_triage ON messages (triage_status, received_at DESC)',
  );
  late final Conversations conversations = Conversations(this);
  late final Index ixConvLast = Index(
    'ix_conv_last',
    'CREATE INDEX ix_conv_last ON conversations (last_message_at DESC)',
  );
  late final SyncState syncState = SyncState(this);
  late final WorkItems workItems = WorkItems(this);
  late final Index ixWorkPending = Index(
    'ix_work_pending',
    'CREATE INDEX ix_work_pending ON work_items (task_kind, status, created_at DESC)',
  );
  late final MessageAi messageAi = MessageAi(this);
  late final ConversationAi conversationAi = ConversationAi(this);
  late final Storylines storylines = Storylines(this);
  late final Index ixStorylinesStatus = Index(
    'ix_storylines_status',
    'CREATE INDEX ix_storylines_status ON storylines (status, last_activity_at DESC)',
  );
  late final StorylineMembers storylineMembers = StorylineMembers(this);
  late final Index ixStorylineMembersConv = Index(
    'ix_storyline_members_conv',
    'CREATE INDEX ix_storyline_members_conv ON storyline_members (source, conversation_key)',
  );
  late final StorylineMemberBlocks storylineMemberBlocks =
      StorylineMemberBlocks(this);
  late final FeedbackEvents feedbackEvents = FeedbackEvents(this);
  late final Index ixFeedbackScope = Index(
    'ix_feedback_scope',
    'CREATE INDEX ix_feedback_scope ON feedback_events (scope, scope_key, created_at DESC)',
  );
  late final ActivityEvents activityEvents = ActivityEvents(this);
  late final Index ixActivityCreated = Index(
    'ix_activity_created',
    'CREATE INDEX ix_activity_created ON activity_events (created_at DESC)',
  );
  late final Index ixActivityKind = Index(
    'ix_activity_kind',
    'CREATE INDEX ix_activity_kind ON activity_events (kind, created_at DESC)',
  );
  late final SenderPrefs senderPrefs = SenderPrefs(this);
  late final AppPrefs appPrefs = AppPrefs(this);
  late final Drafts drafts = Drafts(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    messages,
    ixMessagesConv,
    ixMessagesTriage,
    conversations,
    ixConvLast,
    syncState,
    workItems,
    ixWorkPending,
    messageAi,
    conversationAi,
    storylines,
    ixStorylinesStatus,
    storylineMembers,
    ixStorylineMembersConv,
    storylineMemberBlocks,
    feedbackEvents,
    ixFeedbackScope,
    activityEvents,
    ixActivityCreated,
    ixActivityKind,
    senderPrefs,
    appPrefs,
    drafts,
  ];
}

typedef $MessagesCreateCompanionBuilder =
    MessagesCompanion Function({
      Value<String> source,
      required String sourceMessageId,
      Value<String?> internetMessageId,
      required String conversationKey,
      required String direction,
      Value<String?> subject,
      Value<String?> fromName,
      Value<String?> fromAddress,
      Value<String> recipientsJson,
      Value<String?> receivedAt,
      Value<int> isRead,
      Value<String?> bodyPreview,
      Value<String?> bodyText,
      Value<int> hasAttachments,
      Value<String?> sourceMetaJson,
      Value<String> triageStatus,
      Value<int> triageAttempts,
      Value<String?> triageError,
      Value<String?> gateReason,
      Value<String?> urgency,
      Value<String?> category,
      Value<String?> summary,
      Value<int?> needsAction,
      Value<String?> actionItemsJson,
      required String createdAt,
      required String updatedAt,
      Value<String?> label,
      Value<int> rowid,
    });
typedef $MessagesUpdateCompanionBuilder =
    MessagesCompanion Function({
      Value<String> source,
      Value<String> sourceMessageId,
      Value<String?> internetMessageId,
      Value<String> conversationKey,
      Value<String> direction,
      Value<String?> subject,
      Value<String?> fromName,
      Value<String?> fromAddress,
      Value<String> recipientsJson,
      Value<String?> receivedAt,
      Value<int> isRead,
      Value<String?> bodyPreview,
      Value<String?> bodyText,
      Value<int> hasAttachments,
      Value<String?> sourceMetaJson,
      Value<String> triageStatus,
      Value<int> triageAttempts,
      Value<String?> triageError,
      Value<String?> gateReason,
      Value<String?> urgency,
      Value<String?> category,
      Value<String?> summary,
      Value<int?> needsAction,
      Value<String?> actionItemsJson,
      Value<String> createdAt,
      Value<String> updatedAt,
      Value<String?> label,
      Value<int> rowid,
    });

class $MessagesFilterComposer extends Composer<_$BondDatabase, Messages> {
  $MessagesFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceMessageId => $composableBuilder(
    column: $table.sourceMessageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get internetMessageId => $composableBuilder(
    column: $table.internetMessageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get conversationKey => $composableBuilder(
    column: $table.conversationKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get direction => $composableBuilder(
    column: $table.direction,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get subject => $composableBuilder(
    column: $table.subject,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fromName => $composableBuilder(
    column: $table.fromName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fromAddress => $composableBuilder(
    column: $table.fromAddress,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recipientsJson => $composableBuilder(
    column: $table.recipientsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get receivedAt => $composableBuilder(
    column: $table.receivedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isRead => $composableBuilder(
    column: $table.isRead,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bodyPreview => $composableBuilder(
    column: $table.bodyPreview,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bodyText => $composableBuilder(
    column: $table.bodyText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get hasAttachments => $composableBuilder(
    column: $table.hasAttachments,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceMetaJson => $composableBuilder(
    column: $table.sourceMetaJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get triageStatus => $composableBuilder(
    column: $table.triageStatus,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get triageAttempts => $composableBuilder(
    column: $table.triageAttempts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get triageError => $composableBuilder(
    column: $table.triageError,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get gateReason => $composableBuilder(
    column: $table.gateReason,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get urgency => $composableBuilder(
    column: $table.urgency,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get summary => $composableBuilder(
    column: $table.summary,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get needsAction => $composableBuilder(
    column: $table.needsAction,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get actionItemsJson => $composableBuilder(
    column: $table.actionItemsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get label => $composableBuilder(
    column: $table.label,
    builder: (column) => ColumnFilters(column),
  );
}

class $MessagesOrderingComposer extends Composer<_$BondDatabase, Messages> {
  $MessagesOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceMessageId => $composableBuilder(
    column: $table.sourceMessageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get internetMessageId => $composableBuilder(
    column: $table.internetMessageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get conversationKey => $composableBuilder(
    column: $table.conversationKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get direction => $composableBuilder(
    column: $table.direction,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get subject => $composableBuilder(
    column: $table.subject,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fromName => $composableBuilder(
    column: $table.fromName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fromAddress => $composableBuilder(
    column: $table.fromAddress,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recipientsJson => $composableBuilder(
    column: $table.recipientsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get receivedAt => $composableBuilder(
    column: $table.receivedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isRead => $composableBuilder(
    column: $table.isRead,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bodyPreview => $composableBuilder(
    column: $table.bodyPreview,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bodyText => $composableBuilder(
    column: $table.bodyText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get hasAttachments => $composableBuilder(
    column: $table.hasAttachments,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceMetaJson => $composableBuilder(
    column: $table.sourceMetaJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get triageStatus => $composableBuilder(
    column: $table.triageStatus,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get triageAttempts => $composableBuilder(
    column: $table.triageAttempts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get triageError => $composableBuilder(
    column: $table.triageError,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get gateReason => $composableBuilder(
    column: $table.gateReason,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get urgency => $composableBuilder(
    column: $table.urgency,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get summary => $composableBuilder(
    column: $table.summary,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get needsAction => $composableBuilder(
    column: $table.needsAction,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get actionItemsJson => $composableBuilder(
    column: $table.actionItemsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get label => $composableBuilder(
    column: $table.label,
    builder: (column) => ColumnOrderings(column),
  );
}

class $MessagesAnnotationComposer extends Composer<_$BondDatabase, Messages> {
  $MessagesAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get sourceMessageId => $composableBuilder(
    column: $table.sourceMessageId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get internetMessageId => $composableBuilder(
    column: $table.internetMessageId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get conversationKey => $composableBuilder(
    column: $table.conversationKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get direction =>
      $composableBuilder(column: $table.direction, builder: (column) => column);

  GeneratedColumn<String> get subject =>
      $composableBuilder(column: $table.subject, builder: (column) => column);

  GeneratedColumn<String> get fromName =>
      $composableBuilder(column: $table.fromName, builder: (column) => column);

  GeneratedColumn<String> get fromAddress => $composableBuilder(
    column: $table.fromAddress,
    builder: (column) => column,
  );

  GeneratedColumn<String> get recipientsJson => $composableBuilder(
    column: $table.recipientsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get receivedAt => $composableBuilder(
    column: $table.receivedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get isRead =>
      $composableBuilder(column: $table.isRead, builder: (column) => column);

  GeneratedColumn<String> get bodyPreview => $composableBuilder(
    column: $table.bodyPreview,
    builder: (column) => column,
  );

  GeneratedColumn<String> get bodyText =>
      $composableBuilder(column: $table.bodyText, builder: (column) => column);

  GeneratedColumn<int> get hasAttachments => $composableBuilder(
    column: $table.hasAttachments,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sourceMetaJson => $composableBuilder(
    column: $table.sourceMetaJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get triageStatus => $composableBuilder(
    column: $table.triageStatus,
    builder: (column) => column,
  );

  GeneratedColumn<int> get triageAttempts => $composableBuilder(
    column: $table.triageAttempts,
    builder: (column) => column,
  );

  GeneratedColumn<String> get triageError => $composableBuilder(
    column: $table.triageError,
    builder: (column) => column,
  );

  GeneratedColumn<String> get gateReason => $composableBuilder(
    column: $table.gateReason,
    builder: (column) => column,
  );

  GeneratedColumn<String> get urgency =>
      $composableBuilder(column: $table.urgency, builder: (column) => column);

  GeneratedColumn<String> get category =>
      $composableBuilder(column: $table.category, builder: (column) => column);

  GeneratedColumn<String> get summary =>
      $composableBuilder(column: $table.summary, builder: (column) => column);

  GeneratedColumn<int> get needsAction => $composableBuilder(
    column: $table.needsAction,
    builder: (column) => column,
  );

  GeneratedColumn<String> get actionItemsJson => $composableBuilder(
    column: $table.actionItemsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get label =>
      $composableBuilder(column: $table.label, builder: (column) => column);
}

class $MessagesTableManager
    extends
        RootTableManager<
          _$BondDatabase,
          Messages,
          Message,
          $MessagesFilterComposer,
          $MessagesOrderingComposer,
          $MessagesAnnotationComposer,
          $MessagesCreateCompanionBuilder,
          $MessagesUpdateCompanionBuilder,
          (Message, BaseReferences<_$BondDatabase, Messages, Message>),
          Message,
          PrefetchHooks Function()
        > {
  $MessagesTableManager(_$BondDatabase db, Messages table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $MessagesFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $MessagesOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $MessagesAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> source = const Value.absent(),
                Value<String> sourceMessageId = const Value.absent(),
                Value<String?> internetMessageId = const Value.absent(),
                Value<String> conversationKey = const Value.absent(),
                Value<String> direction = const Value.absent(),
                Value<String?> subject = const Value.absent(),
                Value<String?> fromName = const Value.absent(),
                Value<String?> fromAddress = const Value.absent(),
                Value<String> recipientsJson = const Value.absent(),
                Value<String?> receivedAt = const Value.absent(),
                Value<int> isRead = const Value.absent(),
                Value<String?> bodyPreview = const Value.absent(),
                Value<String?> bodyText = const Value.absent(),
                Value<int> hasAttachments = const Value.absent(),
                Value<String?> sourceMetaJson = const Value.absent(),
                Value<String> triageStatus = const Value.absent(),
                Value<int> triageAttempts = const Value.absent(),
                Value<String?> triageError = const Value.absent(),
                Value<String?> gateReason = const Value.absent(),
                Value<String?> urgency = const Value.absent(),
                Value<String?> category = const Value.absent(),
                Value<String?> summary = const Value.absent(),
                Value<int?> needsAction = const Value.absent(),
                Value<String?> actionItemsJson = const Value.absent(),
                Value<String> createdAt = const Value.absent(),
                Value<String> updatedAt = const Value.absent(),
                Value<String?> label = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessagesCompanion(
                source: source,
                sourceMessageId: sourceMessageId,
                internetMessageId: internetMessageId,
                conversationKey: conversationKey,
                direction: direction,
                subject: subject,
                fromName: fromName,
                fromAddress: fromAddress,
                recipientsJson: recipientsJson,
                receivedAt: receivedAt,
                isRead: isRead,
                bodyPreview: bodyPreview,
                bodyText: bodyText,
                hasAttachments: hasAttachments,
                sourceMetaJson: sourceMetaJson,
                triageStatus: triageStatus,
                triageAttempts: triageAttempts,
                triageError: triageError,
                gateReason: gateReason,
                urgency: urgency,
                category: category,
                summary: summary,
                needsAction: needsAction,
                actionItemsJson: actionItemsJson,
                createdAt: createdAt,
                updatedAt: updatedAt,
                label: label,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                Value<String> source = const Value.absent(),
                required String sourceMessageId,
                Value<String?> internetMessageId = const Value.absent(),
                required String conversationKey,
                required String direction,
                Value<String?> subject = const Value.absent(),
                Value<String?> fromName = const Value.absent(),
                Value<String?> fromAddress = const Value.absent(),
                Value<String> recipientsJson = const Value.absent(),
                Value<String?> receivedAt = const Value.absent(),
                Value<int> isRead = const Value.absent(),
                Value<String?> bodyPreview = const Value.absent(),
                Value<String?> bodyText = const Value.absent(),
                Value<int> hasAttachments = const Value.absent(),
                Value<String?> sourceMetaJson = const Value.absent(),
                Value<String> triageStatus = const Value.absent(),
                Value<int> triageAttempts = const Value.absent(),
                Value<String?> triageError = const Value.absent(),
                Value<String?> gateReason = const Value.absent(),
                Value<String?> urgency = const Value.absent(),
                Value<String?> category = const Value.absent(),
                Value<String?> summary = const Value.absent(),
                Value<int?> needsAction = const Value.absent(),
                Value<String?> actionItemsJson = const Value.absent(),
                required String createdAt,
                required String updatedAt,
                Value<String?> label = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessagesCompanion.insert(
                source: source,
                sourceMessageId: sourceMessageId,
                internetMessageId: internetMessageId,
                conversationKey: conversationKey,
                direction: direction,
                subject: subject,
                fromName: fromName,
                fromAddress: fromAddress,
                recipientsJson: recipientsJson,
                receivedAt: receivedAt,
                isRead: isRead,
                bodyPreview: bodyPreview,
                bodyText: bodyText,
                hasAttachments: hasAttachments,
                sourceMetaJson: sourceMetaJson,
                triageStatus: triageStatus,
                triageAttempts: triageAttempts,
                triageError: triageError,
                gateReason: gateReason,
                urgency: urgency,
                category: category,
                summary: summary,
                needsAction: needsAction,
                actionItemsJson: actionItemsJson,
                createdAt: createdAt,
                updatedAt: updatedAt,
                label: label,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $MessagesProcessedTableManager =
    ProcessedTableManager<
      _$BondDatabase,
      Messages,
      Message,
      $MessagesFilterComposer,
      $MessagesOrderingComposer,
      $MessagesAnnotationComposer,
      $MessagesCreateCompanionBuilder,
      $MessagesUpdateCompanionBuilder,
      (Message, BaseReferences<_$BondDatabase, Messages, Message>),
      Message,
      PrefetchHooks Function()
    >;
typedef $ConversationsCreateCompanionBuilder =
    ConversationsCompanion Function({
      Value<String> source,
      required String conversationKey,
      Value<String?> subject,
      Value<String> participantsJson,
      Value<String> state,
      Value<String?> category,
      Value<String?> ctaText,
      Value<String> ctaUrgency,
      Value<int> messageCount,
      Value<int> inboundCount,
      Value<String?> lastInboundAt,
      Value<String?> lastOutboundAt,
      Value<String?> lastMessageAt,
      Value<String?> lastMessagePreview,
      Value<String?> stateChangedAt,
      required String createdAt,
      required String updatedAt,
      Value<int> rowid,
    });
typedef $ConversationsUpdateCompanionBuilder =
    ConversationsCompanion Function({
      Value<String> source,
      Value<String> conversationKey,
      Value<String?> subject,
      Value<String> participantsJson,
      Value<String> state,
      Value<String?> category,
      Value<String?> ctaText,
      Value<String> ctaUrgency,
      Value<int> messageCount,
      Value<int> inboundCount,
      Value<String?> lastInboundAt,
      Value<String?> lastOutboundAt,
      Value<String?> lastMessageAt,
      Value<String?> lastMessagePreview,
      Value<String?> stateChangedAt,
      Value<String> createdAt,
      Value<String> updatedAt,
      Value<int> rowid,
    });

class $ConversationsFilterComposer
    extends Composer<_$BondDatabase, Conversations> {
  $ConversationsFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get conversationKey => $composableBuilder(
    column: $table.conversationKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get subject => $composableBuilder(
    column: $table.subject,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get participantsJson => $composableBuilder(
    column: $table.participantsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ctaText => $composableBuilder(
    column: $table.ctaText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ctaUrgency => $composableBuilder(
    column: $table.ctaUrgency,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get messageCount => $composableBuilder(
    column: $table.messageCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get inboundCount => $composableBuilder(
    column: $table.inboundCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastInboundAt => $composableBuilder(
    column: $table.lastInboundAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastOutboundAt => $composableBuilder(
    column: $table.lastOutboundAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastMessageAt => $composableBuilder(
    column: $table.lastMessageAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastMessagePreview => $composableBuilder(
    column: $table.lastMessagePreview,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stateChangedAt => $composableBuilder(
    column: $table.stateChangedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $ConversationsOrderingComposer
    extends Composer<_$BondDatabase, Conversations> {
  $ConversationsOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get conversationKey => $composableBuilder(
    column: $table.conversationKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get subject => $composableBuilder(
    column: $table.subject,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get participantsJson => $composableBuilder(
    column: $table.participantsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ctaText => $composableBuilder(
    column: $table.ctaText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ctaUrgency => $composableBuilder(
    column: $table.ctaUrgency,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get messageCount => $composableBuilder(
    column: $table.messageCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get inboundCount => $composableBuilder(
    column: $table.inboundCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastInboundAt => $composableBuilder(
    column: $table.lastInboundAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastOutboundAt => $composableBuilder(
    column: $table.lastOutboundAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastMessageAt => $composableBuilder(
    column: $table.lastMessageAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastMessagePreview => $composableBuilder(
    column: $table.lastMessagePreview,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stateChangedAt => $composableBuilder(
    column: $table.stateChangedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $ConversationsAnnotationComposer
    extends Composer<_$BondDatabase, Conversations> {
  $ConversationsAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get conversationKey => $composableBuilder(
    column: $table.conversationKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get subject =>
      $composableBuilder(column: $table.subject, builder: (column) => column);

  GeneratedColumn<String> get participantsJson => $composableBuilder(
    column: $table.participantsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<String> get category =>
      $composableBuilder(column: $table.category, builder: (column) => column);

  GeneratedColumn<String> get ctaText =>
      $composableBuilder(column: $table.ctaText, builder: (column) => column);

  GeneratedColumn<String> get ctaUrgency => $composableBuilder(
    column: $table.ctaUrgency,
    builder: (column) => column,
  );

  GeneratedColumn<int> get messageCount => $composableBuilder(
    column: $table.messageCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get inboundCount => $composableBuilder(
    column: $table.inboundCount,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastInboundAt => $composableBuilder(
    column: $table.lastInboundAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastOutboundAt => $composableBuilder(
    column: $table.lastOutboundAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastMessageAt => $composableBuilder(
    column: $table.lastMessageAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastMessagePreview => $composableBuilder(
    column: $table.lastMessagePreview,
    builder: (column) => column,
  );

  GeneratedColumn<String> get stateChangedAt => $composableBuilder(
    column: $table.stateChangedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $ConversationsTableManager
    extends
        RootTableManager<
          _$BondDatabase,
          Conversations,
          Conversation,
          $ConversationsFilterComposer,
          $ConversationsOrderingComposer,
          $ConversationsAnnotationComposer,
          $ConversationsCreateCompanionBuilder,
          $ConversationsUpdateCompanionBuilder,
          (
            Conversation,
            BaseReferences<_$BondDatabase, Conversations, Conversation>,
          ),
          Conversation,
          PrefetchHooks Function()
        > {
  $ConversationsTableManager(_$BondDatabase db, Conversations table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $ConversationsFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $ConversationsOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $ConversationsAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> source = const Value.absent(),
                Value<String> conversationKey = const Value.absent(),
                Value<String?> subject = const Value.absent(),
                Value<String> participantsJson = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<String?> category = const Value.absent(),
                Value<String?> ctaText = const Value.absent(),
                Value<String> ctaUrgency = const Value.absent(),
                Value<int> messageCount = const Value.absent(),
                Value<int> inboundCount = const Value.absent(),
                Value<String?> lastInboundAt = const Value.absent(),
                Value<String?> lastOutboundAt = const Value.absent(),
                Value<String?> lastMessageAt = const Value.absent(),
                Value<String?> lastMessagePreview = const Value.absent(),
                Value<String?> stateChangedAt = const Value.absent(),
                Value<String> createdAt = const Value.absent(),
                Value<String> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConversationsCompanion(
                source: source,
                conversationKey: conversationKey,
                subject: subject,
                participantsJson: participantsJson,
                state: state,
                category: category,
                ctaText: ctaText,
                ctaUrgency: ctaUrgency,
                messageCount: messageCount,
                inboundCount: inboundCount,
                lastInboundAt: lastInboundAt,
                lastOutboundAt: lastOutboundAt,
                lastMessageAt: lastMessageAt,
                lastMessagePreview: lastMessagePreview,
                stateChangedAt: stateChangedAt,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                Value<String> source = const Value.absent(),
                required String conversationKey,
                Value<String?> subject = const Value.absent(),
                Value<String> participantsJson = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<String?> category = const Value.absent(),
                Value<String?> ctaText = const Value.absent(),
                Value<String> ctaUrgency = const Value.absent(),
                Value<int> messageCount = const Value.absent(),
                Value<int> inboundCount = const Value.absent(),
                Value<String?> lastInboundAt = const Value.absent(),
                Value<String?> lastOutboundAt = const Value.absent(),
                Value<String?> lastMessageAt = const Value.absent(),
                Value<String?> lastMessagePreview = const Value.absent(),
                Value<String?> stateChangedAt = const Value.absent(),
                required String createdAt,
                required String updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => ConversationsCompanion.insert(
                source: source,
                conversationKey: conversationKey,
                subject: subject,
                participantsJson: participantsJson,
                state: state,
                category: category,
                ctaText: ctaText,
                ctaUrgency: ctaUrgency,
                messageCount: messageCount,
                inboundCount: inboundCount,
                lastInboundAt: lastInboundAt,
                lastOutboundAt: lastOutboundAt,
                lastMessageAt: lastMessageAt,
                lastMessagePreview: lastMessagePreview,
                stateChangedAt: stateChangedAt,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $ConversationsProcessedTableManager =
    ProcessedTableManager<
      _$BondDatabase,
      Conversations,
      Conversation,
      $ConversationsFilterComposer,
      $ConversationsOrderingComposer,
      $ConversationsAnnotationComposer,
      $ConversationsCreateCompanionBuilder,
      $ConversationsUpdateCompanionBuilder,
      (
        Conversation,
        BaseReferences<_$BondDatabase, Conversations, Conversation>,
      ),
      Conversation,
      PrefetchHooks Function()
    >;
typedef $SyncStateCreateCompanionBuilder =
    SyncStateCompanion Function({
      Value<String> source,
      required String folder,
      Value<String?> deltaLink,
      Value<String?> syncedAt,
      Value<int> rowid,
    });
typedef $SyncStateUpdateCompanionBuilder =
    SyncStateCompanion Function({
      Value<String> source,
      Value<String> folder,
      Value<String?> deltaLink,
      Value<String?> syncedAt,
      Value<int> rowid,
    });

class $SyncStateFilterComposer extends Composer<_$BondDatabase, SyncState> {
  $SyncStateFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get folder => $composableBuilder(
    column: $table.folder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deltaLink => $composableBuilder(
    column: $table.deltaLink,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get syncedAt => $composableBuilder(
    column: $table.syncedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $SyncStateOrderingComposer extends Composer<_$BondDatabase, SyncState> {
  $SyncStateOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get folder => $composableBuilder(
    column: $table.folder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deltaLink => $composableBuilder(
    column: $table.deltaLink,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get syncedAt => $composableBuilder(
    column: $table.syncedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $SyncStateAnnotationComposer extends Composer<_$BondDatabase, SyncState> {
  $SyncStateAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get folder =>
      $composableBuilder(column: $table.folder, builder: (column) => column);

  GeneratedColumn<String> get deltaLink =>
      $composableBuilder(column: $table.deltaLink, builder: (column) => column);

  GeneratedColumn<String> get syncedAt =>
      $composableBuilder(column: $table.syncedAt, builder: (column) => column);
}

class $SyncStateTableManager
    extends
        RootTableManager<
          _$BondDatabase,
          SyncState,
          SyncStateData,
          $SyncStateFilterComposer,
          $SyncStateOrderingComposer,
          $SyncStateAnnotationComposer,
          $SyncStateCreateCompanionBuilder,
          $SyncStateUpdateCompanionBuilder,
          (
            SyncStateData,
            BaseReferences<_$BondDatabase, SyncState, SyncStateData>,
          ),
          SyncStateData,
          PrefetchHooks Function()
        > {
  $SyncStateTableManager(_$BondDatabase db, SyncState table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $SyncStateFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $SyncStateOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $SyncStateAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> source = const Value.absent(),
                Value<String> folder = const Value.absent(),
                Value<String?> deltaLink = const Value.absent(),
                Value<String?> syncedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncStateCompanion(
                source: source,
                folder: folder,
                deltaLink: deltaLink,
                syncedAt: syncedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                Value<String> source = const Value.absent(),
                required String folder,
                Value<String?> deltaLink = const Value.absent(),
                Value<String?> syncedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncStateCompanion.insert(
                source: source,
                folder: folder,
                deltaLink: deltaLink,
                syncedAt: syncedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $SyncStateProcessedTableManager =
    ProcessedTableManager<
      _$BondDatabase,
      SyncState,
      SyncStateData,
      $SyncStateFilterComposer,
      $SyncStateOrderingComposer,
      $SyncStateAnnotationComposer,
      $SyncStateCreateCompanionBuilder,
      $SyncStateUpdateCompanionBuilder,
      (SyncStateData, BaseReferences<_$BondDatabase, SyncState, SyncStateData>),
      SyncStateData,
      PrefetchHooks Function()
    >;
typedef $WorkItemsCreateCompanionBuilder =
    WorkItemsCompanion Function({
      required String taskKind,
      Value<String> source,
      required String entityId,
      Value<String> status,
      Value<int> attempts,
      Value<String?> error,
      Value<String?> payloadJson,
      required String createdAt,
      required String updatedAt,
      Value<int> rowid,
    });
typedef $WorkItemsUpdateCompanionBuilder =
    WorkItemsCompanion Function({
      Value<String> taskKind,
      Value<String> source,
      Value<String> entityId,
      Value<String> status,
      Value<int> attempts,
      Value<String?> error,
      Value<String?> payloadJson,
      Value<String> createdAt,
      Value<String> updatedAt,
      Value<int> rowid,
    });

class $WorkItemsFilterComposer extends Composer<_$BondDatabase, WorkItems> {
  $WorkItemsFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get taskKind => $composableBuilder(
    column: $table.taskKind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get error => $composableBuilder(
    column: $table.error,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $WorkItemsOrderingComposer extends Composer<_$BondDatabase, WorkItems> {
  $WorkItemsOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get taskKind => $composableBuilder(
    column: $table.taskKind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get error => $composableBuilder(
    column: $table.error,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $WorkItemsAnnotationComposer extends Composer<_$BondDatabase, WorkItems> {
  $WorkItemsAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get taskKind =>
      $composableBuilder(column: $table.taskKind, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get entityId =>
      $composableBuilder(column: $table.entityId, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get attempts =>
      $composableBuilder(column: $table.attempts, builder: (column) => column);

  GeneratedColumn<String> get error =>
      $composableBuilder(column: $table.error, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $WorkItemsTableManager
    extends
        RootTableManager<
          _$BondDatabase,
          WorkItems,
          WorkItem,
          $WorkItemsFilterComposer,
          $WorkItemsOrderingComposer,
          $WorkItemsAnnotationComposer,
          $WorkItemsCreateCompanionBuilder,
          $WorkItemsUpdateCompanionBuilder,
          (WorkItem, BaseReferences<_$BondDatabase, WorkItems, WorkItem>),
          WorkItem,
          PrefetchHooks Function()
        > {
  $WorkItemsTableManager(_$BondDatabase db, WorkItems table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $WorkItemsFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $WorkItemsOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $WorkItemsAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> taskKind = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String> entityId = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> attempts = const Value.absent(),
                Value<String?> error = const Value.absent(),
                Value<String?> payloadJson = const Value.absent(),
                Value<String> createdAt = const Value.absent(),
                Value<String> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => WorkItemsCompanion(
                taskKind: taskKind,
                source: source,
                entityId: entityId,
                status: status,
                attempts: attempts,
                error: error,
                payloadJson: payloadJson,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String taskKind,
                Value<String> source = const Value.absent(),
                required String entityId,
                Value<String> status = const Value.absent(),
                Value<int> attempts = const Value.absent(),
                Value<String?> error = const Value.absent(),
                Value<String?> payloadJson = const Value.absent(),
                required String createdAt,
                required String updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => WorkItemsCompanion.insert(
                taskKind: taskKind,
                source: source,
                entityId: entityId,
                status: status,
                attempts: attempts,
                error: error,
                payloadJson: payloadJson,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $WorkItemsProcessedTableManager =
    ProcessedTableManager<
      _$BondDatabase,
      WorkItems,
      WorkItem,
      $WorkItemsFilterComposer,
      $WorkItemsOrderingComposer,
      $WorkItemsAnnotationComposer,
      $WorkItemsCreateCompanionBuilder,
      $WorkItemsUpdateCompanionBuilder,
      (WorkItem, BaseReferences<_$BondDatabase, WorkItems, WorkItem>),
      WorkItem,
      PrefetchHooks Function()
    >;
typedef $MessageAiCreateCompanionBuilder =
    MessageAiCompanion Function({
      Value<String> source,
      required String sourceMessageId,
      Value<String?> extractionJson,
      Value<String?> extractedAt,
      Value<int> rowid,
    });
typedef $MessageAiUpdateCompanionBuilder =
    MessageAiCompanion Function({
      Value<String> source,
      Value<String> sourceMessageId,
      Value<String?> extractionJson,
      Value<String?> extractedAt,
      Value<int> rowid,
    });

class $MessageAiFilterComposer extends Composer<_$BondDatabase, MessageAi> {
  $MessageAiFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceMessageId => $composableBuilder(
    column: $table.sourceMessageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get extractionJson => $composableBuilder(
    column: $table.extractionJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get extractedAt => $composableBuilder(
    column: $table.extractedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $MessageAiOrderingComposer extends Composer<_$BondDatabase, MessageAi> {
  $MessageAiOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceMessageId => $composableBuilder(
    column: $table.sourceMessageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get extractionJson => $composableBuilder(
    column: $table.extractionJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get extractedAt => $composableBuilder(
    column: $table.extractedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $MessageAiAnnotationComposer extends Composer<_$BondDatabase, MessageAi> {
  $MessageAiAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get sourceMessageId => $composableBuilder(
    column: $table.sourceMessageId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get extractionJson => $composableBuilder(
    column: $table.extractionJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get extractedAt => $composableBuilder(
    column: $table.extractedAt,
    builder: (column) => column,
  );
}

class $MessageAiTableManager
    extends
        RootTableManager<
          _$BondDatabase,
          MessageAi,
          MessageAiData,
          $MessageAiFilterComposer,
          $MessageAiOrderingComposer,
          $MessageAiAnnotationComposer,
          $MessageAiCreateCompanionBuilder,
          $MessageAiUpdateCompanionBuilder,
          (
            MessageAiData,
            BaseReferences<_$BondDatabase, MessageAi, MessageAiData>,
          ),
          MessageAiData,
          PrefetchHooks Function()
        > {
  $MessageAiTableManager(_$BondDatabase db, MessageAi table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $MessageAiFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $MessageAiOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $MessageAiAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> source = const Value.absent(),
                Value<String> sourceMessageId = const Value.absent(),
                Value<String?> extractionJson = const Value.absent(),
                Value<String?> extractedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessageAiCompanion(
                source: source,
                sourceMessageId: sourceMessageId,
                extractionJson: extractionJson,
                extractedAt: extractedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                Value<String> source = const Value.absent(),
                required String sourceMessageId,
                Value<String?> extractionJson = const Value.absent(),
                Value<String?> extractedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessageAiCompanion.insert(
                source: source,
                sourceMessageId: sourceMessageId,
                extractionJson: extractionJson,
                extractedAt: extractedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $MessageAiProcessedTableManager =
    ProcessedTableManager<
      _$BondDatabase,
      MessageAi,
      MessageAiData,
      $MessageAiFilterComposer,
      $MessageAiOrderingComposer,
      $MessageAiAnnotationComposer,
      $MessageAiCreateCompanionBuilder,
      $MessageAiUpdateCompanionBuilder,
      (MessageAiData, BaseReferences<_$BondDatabase, MessageAi, MessageAiData>),
      MessageAiData,
      PrefetchHooks Function()
    >;
typedef $ConversationAiCreateCompanionBuilder =
    ConversationAiCompanion Function({
      Value<String> source,
      required String conversationKey,
      Value<Uint8List?> embedding,
      Value<String?> embeddedHash,
      Value<String?> embedModel,
      Value<String?> bucket,
      Value<String?> bucketReason,
      Value<double?> attentionScore,
      Value<String?> snoozedUntil,
      required String updatedAt,
      Value<int> rowid,
    });
typedef $ConversationAiUpdateCompanionBuilder =
    ConversationAiCompanion Function({
      Value<String> source,
      Value<String> conversationKey,
      Value<Uint8List?> embedding,
      Value<String?> embeddedHash,
      Value<String?> embedModel,
      Value<String?> bucket,
      Value<String?> bucketReason,
      Value<double?> attentionScore,
      Value<String?> snoozedUntil,
      Value<String> updatedAt,
      Value<int> rowid,
    });

class $ConversationAiFilterComposer
    extends Composer<_$BondDatabase, ConversationAi> {
  $ConversationAiFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get conversationKey => $composableBuilder(
    column: $table.conversationKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get embedding => $composableBuilder(
    column: $table.embedding,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get embeddedHash => $composableBuilder(
    column: $table.embeddedHash,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get embedModel => $composableBuilder(
    column: $table.embedModel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bucket => $composableBuilder(
    column: $table.bucket,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bucketReason => $composableBuilder(
    column: $table.bucketReason,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get attentionScore => $composableBuilder(
    column: $table.attentionScore,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get snoozedUntil => $composableBuilder(
    column: $table.snoozedUntil,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $ConversationAiOrderingComposer
    extends Composer<_$BondDatabase, ConversationAi> {
  $ConversationAiOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get conversationKey => $composableBuilder(
    column: $table.conversationKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get embedding => $composableBuilder(
    column: $table.embedding,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get embeddedHash => $composableBuilder(
    column: $table.embeddedHash,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get embedModel => $composableBuilder(
    column: $table.embedModel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bucket => $composableBuilder(
    column: $table.bucket,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bucketReason => $composableBuilder(
    column: $table.bucketReason,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get attentionScore => $composableBuilder(
    column: $table.attentionScore,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get snoozedUntil => $composableBuilder(
    column: $table.snoozedUntil,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $ConversationAiAnnotationComposer
    extends Composer<_$BondDatabase, ConversationAi> {
  $ConversationAiAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get conversationKey => $composableBuilder(
    column: $table.conversationKey,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get embedding =>
      $composableBuilder(column: $table.embedding, builder: (column) => column);

  GeneratedColumn<String> get embeddedHash => $composableBuilder(
    column: $table.embeddedHash,
    builder: (column) => column,
  );

  GeneratedColumn<String> get embedModel => $composableBuilder(
    column: $table.embedModel,
    builder: (column) => column,
  );

  GeneratedColumn<String> get bucket =>
      $composableBuilder(column: $table.bucket, builder: (column) => column);

  GeneratedColumn<String> get bucketReason => $composableBuilder(
    column: $table.bucketReason,
    builder: (column) => column,
  );

  GeneratedColumn<double> get attentionScore => $composableBuilder(
    column: $table.attentionScore,
    builder: (column) => column,
  );

  GeneratedColumn<String> get snoozedUntil => $composableBuilder(
    column: $table.snoozedUntil,
    builder: (column) => column,
  );

  GeneratedColumn<String> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $ConversationAiTableManager
    extends
        RootTableManager<
          _$BondDatabase,
          ConversationAi,
          ConversationAiData,
          $ConversationAiFilterComposer,
          $ConversationAiOrderingComposer,
          $ConversationAiAnnotationComposer,
          $ConversationAiCreateCompanionBuilder,
          $ConversationAiUpdateCompanionBuilder,
          (
            ConversationAiData,
            BaseReferences<_$BondDatabase, ConversationAi, ConversationAiData>,
          ),
          ConversationAiData,
          PrefetchHooks Function()
        > {
  $ConversationAiTableManager(_$BondDatabase db, ConversationAi table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $ConversationAiFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $ConversationAiOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $ConversationAiAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> source = const Value.absent(),
                Value<String> conversationKey = const Value.absent(),
                Value<Uint8List?> embedding = const Value.absent(),
                Value<String?> embeddedHash = const Value.absent(),
                Value<String?> embedModel = const Value.absent(),
                Value<String?> bucket = const Value.absent(),
                Value<String?> bucketReason = const Value.absent(),
                Value<double?> attentionScore = const Value.absent(),
                Value<String?> snoozedUntil = const Value.absent(),
                Value<String> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConversationAiCompanion(
                source: source,
                conversationKey: conversationKey,
                embedding: embedding,
                embeddedHash: embeddedHash,
                embedModel: embedModel,
                bucket: bucket,
                bucketReason: bucketReason,
                attentionScore: attentionScore,
                snoozedUntil: snoozedUntil,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                Value<String> source = const Value.absent(),
                required String conversationKey,
                Value<Uint8List?> embedding = const Value.absent(),
                Value<String?> embeddedHash = const Value.absent(),
                Value<String?> embedModel = const Value.absent(),
                Value<String?> bucket = const Value.absent(),
                Value<String?> bucketReason = const Value.absent(),
                Value<double?> attentionScore = const Value.absent(),
                Value<String?> snoozedUntil = const Value.absent(),
                required String updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => ConversationAiCompanion.insert(
                source: source,
                conversationKey: conversationKey,
                embedding: embedding,
                embeddedHash: embeddedHash,
                embedModel: embedModel,
                bucket: bucket,
                bucketReason: bucketReason,
                attentionScore: attentionScore,
                snoozedUntil: snoozedUntil,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $ConversationAiProcessedTableManager =
    ProcessedTableManager<
      _$BondDatabase,
      ConversationAi,
      ConversationAiData,
      $ConversationAiFilterComposer,
      $ConversationAiOrderingComposer,
      $ConversationAiAnnotationComposer,
      $ConversationAiCreateCompanionBuilder,
      $ConversationAiUpdateCompanionBuilder,
      (
        ConversationAiData,
        BaseReferences<_$BondDatabase, ConversationAi, ConversationAiData>,
      ),
      ConversationAiData,
      PrefetchHooks Function()
    >;
typedef $StorylinesCreateCompanionBuilder =
    StorylinesCompanion Function({
      required String id,
      required String title,
      Value<String?> summary,
      Value<String> status,
      Value<String> createdBy,
      Value<int> titleLocked,
      Value<int> pinned,
      Value<String?> memberHash,
      Value<String?> lastActivityAt,
      required String createdAt,
      required String updatedAt,
      Value<int> rowid,
    });
typedef $StorylinesUpdateCompanionBuilder =
    StorylinesCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<String?> summary,
      Value<String> status,
      Value<String> createdBy,
      Value<int> titleLocked,
      Value<int> pinned,
      Value<String?> memberHash,
      Value<String?> lastActivityAt,
      Value<String> createdAt,
      Value<String> updatedAt,
      Value<int> rowid,
    });

class $StorylinesFilterComposer extends Composer<_$BondDatabase, Storylines> {
  $StorylinesFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get summary => $composableBuilder(
    column: $table.summary,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get createdBy => $composableBuilder(
    column: $table.createdBy,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get titleLocked => $composableBuilder(
    column: $table.titleLocked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get pinned => $composableBuilder(
    column: $table.pinned,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get memberHash => $composableBuilder(
    column: $table.memberHash,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastActivityAt => $composableBuilder(
    column: $table.lastActivityAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $StorylinesOrderingComposer extends Composer<_$BondDatabase, Storylines> {
  $StorylinesOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get summary => $composableBuilder(
    column: $table.summary,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get createdBy => $composableBuilder(
    column: $table.createdBy,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get titleLocked => $composableBuilder(
    column: $table.titleLocked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get pinned => $composableBuilder(
    column: $table.pinned,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get memberHash => $composableBuilder(
    column: $table.memberHash,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastActivityAt => $composableBuilder(
    column: $table.lastActivityAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $StorylinesAnnotationComposer
    extends Composer<_$BondDatabase, Storylines> {
  $StorylinesAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get summary =>
      $composableBuilder(column: $table.summary, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get createdBy =>
      $composableBuilder(column: $table.createdBy, builder: (column) => column);

  GeneratedColumn<int> get titleLocked => $composableBuilder(
    column: $table.titleLocked,
    builder: (column) => column,
  );

  GeneratedColumn<int> get pinned =>
      $composableBuilder(column: $table.pinned, builder: (column) => column);

  GeneratedColumn<String> get memberHash => $composableBuilder(
    column: $table.memberHash,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastActivityAt => $composableBuilder(
    column: $table.lastActivityAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $StorylinesTableManager
    extends
        RootTableManager<
          _$BondDatabase,
          Storylines,
          Storyline,
          $StorylinesFilterComposer,
          $StorylinesOrderingComposer,
          $StorylinesAnnotationComposer,
          $StorylinesCreateCompanionBuilder,
          $StorylinesUpdateCompanionBuilder,
          (Storyline, BaseReferences<_$BondDatabase, Storylines, Storyline>),
          Storyline,
          PrefetchHooks Function()
        > {
  $StorylinesTableManager(_$BondDatabase db, Storylines table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $StorylinesFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $StorylinesOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $StorylinesAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> summary = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String> createdBy = const Value.absent(),
                Value<int> titleLocked = const Value.absent(),
                Value<int> pinned = const Value.absent(),
                Value<String?> memberHash = const Value.absent(),
                Value<String?> lastActivityAt = const Value.absent(),
                Value<String> createdAt = const Value.absent(),
                Value<String> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => StorylinesCompanion(
                id: id,
                title: title,
                summary: summary,
                status: status,
                createdBy: createdBy,
                titleLocked: titleLocked,
                pinned: pinned,
                memberHash: memberHash,
                lastActivityAt: lastActivityAt,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                Value<String?> summary = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String> createdBy = const Value.absent(),
                Value<int> titleLocked = const Value.absent(),
                Value<int> pinned = const Value.absent(),
                Value<String?> memberHash = const Value.absent(),
                Value<String?> lastActivityAt = const Value.absent(),
                required String createdAt,
                required String updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => StorylinesCompanion.insert(
                id: id,
                title: title,
                summary: summary,
                status: status,
                createdBy: createdBy,
                titleLocked: titleLocked,
                pinned: pinned,
                memberHash: memberHash,
                lastActivityAt: lastActivityAt,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $StorylinesProcessedTableManager =
    ProcessedTableManager<
      _$BondDatabase,
      Storylines,
      Storyline,
      $StorylinesFilterComposer,
      $StorylinesOrderingComposer,
      $StorylinesAnnotationComposer,
      $StorylinesCreateCompanionBuilder,
      $StorylinesUpdateCompanionBuilder,
      (Storyline, BaseReferences<_$BondDatabase, Storylines, Storyline>),
      Storyline,
      PrefetchHooks Function()
    >;
typedef $StorylineMembersCreateCompanionBuilder =
    StorylineMembersCompanion Function({
      required String storylineId,
      Value<String> source,
      required String conversationKey,
      Value<String> addedBy,
      Value<String?> evidence,
      required String addedAt,
      Value<int> rowid,
    });
typedef $StorylineMembersUpdateCompanionBuilder =
    StorylineMembersCompanion Function({
      Value<String> storylineId,
      Value<String> source,
      Value<String> conversationKey,
      Value<String> addedBy,
      Value<String?> evidence,
      Value<String> addedAt,
      Value<int> rowid,
    });

class $StorylineMembersFilterComposer
    extends Composer<_$BondDatabase, StorylineMembers> {
  $StorylineMembersFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get storylineId => $composableBuilder(
    column: $table.storylineId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get conversationKey => $composableBuilder(
    column: $table.conversationKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get addedBy => $composableBuilder(
    column: $table.addedBy,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get evidence => $composableBuilder(
    column: $table.evidence,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $StorylineMembersOrderingComposer
    extends Composer<_$BondDatabase, StorylineMembers> {
  $StorylineMembersOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get storylineId => $composableBuilder(
    column: $table.storylineId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get conversationKey => $composableBuilder(
    column: $table.conversationKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get addedBy => $composableBuilder(
    column: $table.addedBy,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get evidence => $composableBuilder(
    column: $table.evidence,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $StorylineMembersAnnotationComposer
    extends Composer<_$BondDatabase, StorylineMembers> {
  $StorylineMembersAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get storylineId => $composableBuilder(
    column: $table.storylineId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get conversationKey => $composableBuilder(
    column: $table.conversationKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get addedBy =>
      $composableBuilder(column: $table.addedBy, builder: (column) => column);

  GeneratedColumn<String> get evidence =>
      $composableBuilder(column: $table.evidence, builder: (column) => column);

  GeneratedColumn<String> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => column);
}

class $StorylineMembersTableManager
    extends
        RootTableManager<
          _$BondDatabase,
          StorylineMembers,
          StorylineMember,
          $StorylineMembersFilterComposer,
          $StorylineMembersOrderingComposer,
          $StorylineMembersAnnotationComposer,
          $StorylineMembersCreateCompanionBuilder,
          $StorylineMembersUpdateCompanionBuilder,
          (
            StorylineMember,
            BaseReferences<_$BondDatabase, StorylineMembers, StorylineMember>,
          ),
          StorylineMember,
          PrefetchHooks Function()
        > {
  $StorylineMembersTableManager(_$BondDatabase db, StorylineMembers table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $StorylineMembersFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $StorylineMembersOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $StorylineMembersAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> storylineId = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String> conversationKey = const Value.absent(),
                Value<String> addedBy = const Value.absent(),
                Value<String?> evidence = const Value.absent(),
                Value<String> addedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => StorylineMembersCompanion(
                storylineId: storylineId,
                source: source,
                conversationKey: conversationKey,
                addedBy: addedBy,
                evidence: evidence,
                addedAt: addedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String storylineId,
                Value<String> source = const Value.absent(),
                required String conversationKey,
                Value<String> addedBy = const Value.absent(),
                Value<String?> evidence = const Value.absent(),
                required String addedAt,
                Value<int> rowid = const Value.absent(),
              }) => StorylineMembersCompanion.insert(
                storylineId: storylineId,
                source: source,
                conversationKey: conversationKey,
                addedBy: addedBy,
                evidence: evidence,
                addedAt: addedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $StorylineMembersProcessedTableManager =
    ProcessedTableManager<
      _$BondDatabase,
      StorylineMembers,
      StorylineMember,
      $StorylineMembersFilterComposer,
      $StorylineMembersOrderingComposer,
      $StorylineMembersAnnotationComposer,
      $StorylineMembersCreateCompanionBuilder,
      $StorylineMembersUpdateCompanionBuilder,
      (
        StorylineMember,
        BaseReferences<_$BondDatabase, StorylineMembers, StorylineMember>,
      ),
      StorylineMember,
      PrefetchHooks Function()
    >;
typedef $StorylineMemberBlocksCreateCompanionBuilder =
    StorylineMemberBlocksCompanion Function({
      required String storylineId,
      Value<String> source,
      required String conversationKey,
      required String blockedAt,
      Value<int> rowid,
    });
typedef $StorylineMemberBlocksUpdateCompanionBuilder =
    StorylineMemberBlocksCompanion Function({
      Value<String> storylineId,
      Value<String> source,
      Value<String> conversationKey,
      Value<String> blockedAt,
      Value<int> rowid,
    });

class $StorylineMemberBlocksFilterComposer
    extends Composer<_$BondDatabase, StorylineMemberBlocks> {
  $StorylineMemberBlocksFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get storylineId => $composableBuilder(
    column: $table.storylineId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get conversationKey => $composableBuilder(
    column: $table.conversationKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get blockedAt => $composableBuilder(
    column: $table.blockedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $StorylineMemberBlocksOrderingComposer
    extends Composer<_$BondDatabase, StorylineMemberBlocks> {
  $StorylineMemberBlocksOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get storylineId => $composableBuilder(
    column: $table.storylineId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get conversationKey => $composableBuilder(
    column: $table.conversationKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get blockedAt => $composableBuilder(
    column: $table.blockedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $StorylineMemberBlocksAnnotationComposer
    extends Composer<_$BondDatabase, StorylineMemberBlocks> {
  $StorylineMemberBlocksAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get storylineId => $composableBuilder(
    column: $table.storylineId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get conversationKey => $composableBuilder(
    column: $table.conversationKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get blockedAt =>
      $composableBuilder(column: $table.blockedAt, builder: (column) => column);
}

class $StorylineMemberBlocksTableManager
    extends
        RootTableManager<
          _$BondDatabase,
          StorylineMemberBlocks,
          StorylineMemberBlock,
          $StorylineMemberBlocksFilterComposer,
          $StorylineMemberBlocksOrderingComposer,
          $StorylineMemberBlocksAnnotationComposer,
          $StorylineMemberBlocksCreateCompanionBuilder,
          $StorylineMemberBlocksUpdateCompanionBuilder,
          (
            StorylineMemberBlock,
            BaseReferences<
              _$BondDatabase,
              StorylineMemberBlocks,
              StorylineMemberBlock
            >,
          ),
          StorylineMemberBlock,
          PrefetchHooks Function()
        > {
  $StorylineMemberBlocksTableManager(
    _$BondDatabase db,
    StorylineMemberBlocks table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $StorylineMemberBlocksFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $StorylineMemberBlocksOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $StorylineMemberBlocksAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> storylineId = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String> conversationKey = const Value.absent(),
                Value<String> blockedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => StorylineMemberBlocksCompanion(
                storylineId: storylineId,
                source: source,
                conversationKey: conversationKey,
                blockedAt: blockedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String storylineId,
                Value<String> source = const Value.absent(),
                required String conversationKey,
                required String blockedAt,
                Value<int> rowid = const Value.absent(),
              }) => StorylineMemberBlocksCompanion.insert(
                storylineId: storylineId,
                source: source,
                conversationKey: conversationKey,
                blockedAt: blockedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $StorylineMemberBlocksProcessedTableManager =
    ProcessedTableManager<
      _$BondDatabase,
      StorylineMemberBlocks,
      StorylineMemberBlock,
      $StorylineMemberBlocksFilterComposer,
      $StorylineMemberBlocksOrderingComposer,
      $StorylineMemberBlocksAnnotationComposer,
      $StorylineMemberBlocksCreateCompanionBuilder,
      $StorylineMemberBlocksUpdateCompanionBuilder,
      (
        StorylineMemberBlock,
        BaseReferences<
          _$BondDatabase,
          StorylineMemberBlocks,
          StorylineMemberBlock
        >,
      ),
      StorylineMemberBlock,
      PrefetchHooks Function()
    >;
typedef $FeedbackEventsCreateCompanionBuilder =
    FeedbackEventsCompanion Function({
      Value<int> id,
      required String scope,
      required String scopeKey,
      required String direction,
      required String origin,
      required String createdAt,
    });
typedef $FeedbackEventsUpdateCompanionBuilder =
    FeedbackEventsCompanion Function({
      Value<int> id,
      Value<String> scope,
      Value<String> scopeKey,
      Value<String> direction,
      Value<String> origin,
      Value<String> createdAt,
    });

class $FeedbackEventsFilterComposer
    extends Composer<_$BondDatabase, FeedbackEvents> {
  $FeedbackEventsFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get scope => $composableBuilder(
    column: $table.scope,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get scopeKey => $composableBuilder(
    column: $table.scopeKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get direction => $composableBuilder(
    column: $table.direction,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get origin => $composableBuilder(
    column: $table.origin,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $FeedbackEventsOrderingComposer
    extends Composer<_$BondDatabase, FeedbackEvents> {
  $FeedbackEventsOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get scope => $composableBuilder(
    column: $table.scope,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get scopeKey => $composableBuilder(
    column: $table.scopeKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get direction => $composableBuilder(
    column: $table.direction,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get origin => $composableBuilder(
    column: $table.origin,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $FeedbackEventsAnnotationComposer
    extends Composer<_$BondDatabase, FeedbackEvents> {
  $FeedbackEventsAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get scope =>
      $composableBuilder(column: $table.scope, builder: (column) => column);

  GeneratedColumn<String> get scopeKey =>
      $composableBuilder(column: $table.scopeKey, builder: (column) => column);

  GeneratedColumn<String> get direction =>
      $composableBuilder(column: $table.direction, builder: (column) => column);

  GeneratedColumn<String> get origin =>
      $composableBuilder(column: $table.origin, builder: (column) => column);

  GeneratedColumn<String> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $FeedbackEventsTableManager
    extends
        RootTableManager<
          _$BondDatabase,
          FeedbackEvents,
          FeedbackEvent,
          $FeedbackEventsFilterComposer,
          $FeedbackEventsOrderingComposer,
          $FeedbackEventsAnnotationComposer,
          $FeedbackEventsCreateCompanionBuilder,
          $FeedbackEventsUpdateCompanionBuilder,
          (
            FeedbackEvent,
            BaseReferences<_$BondDatabase, FeedbackEvents, FeedbackEvent>,
          ),
          FeedbackEvent,
          PrefetchHooks Function()
        > {
  $FeedbackEventsTableManager(_$BondDatabase db, FeedbackEvents table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $FeedbackEventsFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $FeedbackEventsOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $FeedbackEventsAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> scope = const Value.absent(),
                Value<String> scopeKey = const Value.absent(),
                Value<String> direction = const Value.absent(),
                Value<String> origin = const Value.absent(),
                Value<String> createdAt = const Value.absent(),
              }) => FeedbackEventsCompanion(
                id: id,
                scope: scope,
                scopeKey: scopeKey,
                direction: direction,
                origin: origin,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String scope,
                required String scopeKey,
                required String direction,
                required String origin,
                required String createdAt,
              }) => FeedbackEventsCompanion.insert(
                id: id,
                scope: scope,
                scopeKey: scopeKey,
                direction: direction,
                origin: origin,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $FeedbackEventsProcessedTableManager =
    ProcessedTableManager<
      _$BondDatabase,
      FeedbackEvents,
      FeedbackEvent,
      $FeedbackEventsFilterComposer,
      $FeedbackEventsOrderingComposer,
      $FeedbackEventsAnnotationComposer,
      $FeedbackEventsCreateCompanionBuilder,
      $FeedbackEventsUpdateCompanionBuilder,
      (
        FeedbackEvent,
        BaseReferences<_$BondDatabase, FeedbackEvents, FeedbackEvent>,
      ),
      FeedbackEvent,
      PrefetchHooks Function()
    >;
typedef $ActivityEventsCreateCompanionBuilder =
    ActivityEventsCompanion Function({
      Value<int> id,
      required String kind,
      Value<String?> source,
      required String status,
      Value<String?> entityId,
      Value<int?> count,
      Value<int?> durationMs,
      Value<String?> detailJson,
      required String createdAt,
    });
typedef $ActivityEventsUpdateCompanionBuilder =
    ActivityEventsCompanion Function({
      Value<int> id,
      Value<String> kind,
      Value<String?> source,
      Value<String> status,
      Value<String?> entityId,
      Value<int?> count,
      Value<int?> durationMs,
      Value<String?> detailJson,
      Value<String> createdAt,
    });

class $ActivityEventsFilterComposer
    extends Composer<_$BondDatabase, ActivityEvents> {
  $ActivityEventsFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get count => $composableBuilder(
    column: $table.count,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get detailJson => $composableBuilder(
    column: $table.detailJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $ActivityEventsOrderingComposer
    extends Composer<_$BondDatabase, ActivityEvents> {
  $ActivityEventsOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get count => $composableBuilder(
    column: $table.count,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get detailJson => $composableBuilder(
    column: $table.detailJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $ActivityEventsAnnotationComposer
    extends Composer<_$BondDatabase, ActivityEvents> {
  $ActivityEventsAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get entityId =>
      $composableBuilder(column: $table.entityId, builder: (column) => column);

  GeneratedColumn<int> get count =>
      $composableBuilder(column: $table.count, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get detailJson => $composableBuilder(
    column: $table.detailJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $ActivityEventsTableManager
    extends
        RootTableManager<
          _$BondDatabase,
          ActivityEvents,
          ActivityEvent,
          $ActivityEventsFilterComposer,
          $ActivityEventsOrderingComposer,
          $ActivityEventsAnnotationComposer,
          $ActivityEventsCreateCompanionBuilder,
          $ActivityEventsUpdateCompanionBuilder,
          (
            ActivityEvent,
            BaseReferences<_$BondDatabase, ActivityEvents, ActivityEvent>,
          ),
          ActivityEvent,
          PrefetchHooks Function()
        > {
  $ActivityEventsTableManager(_$BondDatabase db, ActivityEvents table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $ActivityEventsFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $ActivityEventsOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $ActivityEventsAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String?> source = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String?> entityId = const Value.absent(),
                Value<int?> count = const Value.absent(),
                Value<int?> durationMs = const Value.absent(),
                Value<String?> detailJson = const Value.absent(),
                Value<String> createdAt = const Value.absent(),
              }) => ActivityEventsCompanion(
                id: id,
                kind: kind,
                source: source,
                status: status,
                entityId: entityId,
                count: count,
                durationMs: durationMs,
                detailJson: detailJson,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String kind,
                Value<String?> source = const Value.absent(),
                required String status,
                Value<String?> entityId = const Value.absent(),
                Value<int?> count = const Value.absent(),
                Value<int?> durationMs = const Value.absent(),
                Value<String?> detailJson = const Value.absent(),
                required String createdAt,
              }) => ActivityEventsCompanion.insert(
                id: id,
                kind: kind,
                source: source,
                status: status,
                entityId: entityId,
                count: count,
                durationMs: durationMs,
                detailJson: detailJson,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $ActivityEventsProcessedTableManager =
    ProcessedTableManager<
      _$BondDatabase,
      ActivityEvents,
      ActivityEvent,
      $ActivityEventsFilterComposer,
      $ActivityEventsOrderingComposer,
      $ActivityEventsAnnotationComposer,
      $ActivityEventsCreateCompanionBuilder,
      $ActivityEventsUpdateCompanionBuilder,
      (
        ActivityEvent,
        BaseReferences<_$BondDatabase, ActivityEvents, ActivityEvent>,
      ),
      ActivityEvent,
      PrefetchHooks Function()
    >;
typedef $SenderPrefsCreateCompanionBuilder =
    SenderPrefsCompanion Function({
      required String address,
      required String disposition,
      required String updatedAt,
      Value<int> rowid,
    });
typedef $SenderPrefsUpdateCompanionBuilder =
    SenderPrefsCompanion Function({
      Value<String> address,
      Value<String> disposition,
      Value<String> updatedAt,
      Value<int> rowid,
    });

class $SenderPrefsFilterComposer extends Composer<_$BondDatabase, SenderPrefs> {
  $SenderPrefsFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get disposition => $composableBuilder(
    column: $table.disposition,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $SenderPrefsOrderingComposer
    extends Composer<_$BondDatabase, SenderPrefs> {
  $SenderPrefsOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get disposition => $composableBuilder(
    column: $table.disposition,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $SenderPrefsAnnotationComposer
    extends Composer<_$BondDatabase, SenderPrefs> {
  $SenderPrefsAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get address =>
      $composableBuilder(column: $table.address, builder: (column) => column);

  GeneratedColumn<String> get disposition => $composableBuilder(
    column: $table.disposition,
    builder: (column) => column,
  );

  GeneratedColumn<String> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $SenderPrefsTableManager
    extends
        RootTableManager<
          _$BondDatabase,
          SenderPrefs,
          SenderPref,
          $SenderPrefsFilterComposer,
          $SenderPrefsOrderingComposer,
          $SenderPrefsAnnotationComposer,
          $SenderPrefsCreateCompanionBuilder,
          $SenderPrefsUpdateCompanionBuilder,
          (SenderPref, BaseReferences<_$BondDatabase, SenderPrefs, SenderPref>),
          SenderPref,
          PrefetchHooks Function()
        > {
  $SenderPrefsTableManager(_$BondDatabase db, SenderPrefs table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $SenderPrefsFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $SenderPrefsOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $SenderPrefsAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> address = const Value.absent(),
                Value<String> disposition = const Value.absent(),
                Value<String> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SenderPrefsCompanion(
                address: address,
                disposition: disposition,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String address,
                required String disposition,
                required String updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => SenderPrefsCompanion.insert(
                address: address,
                disposition: disposition,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $SenderPrefsProcessedTableManager =
    ProcessedTableManager<
      _$BondDatabase,
      SenderPrefs,
      SenderPref,
      $SenderPrefsFilterComposer,
      $SenderPrefsOrderingComposer,
      $SenderPrefsAnnotationComposer,
      $SenderPrefsCreateCompanionBuilder,
      $SenderPrefsUpdateCompanionBuilder,
      (SenderPref, BaseReferences<_$BondDatabase, SenderPrefs, SenderPref>),
      SenderPref,
      PrefetchHooks Function()
    >;
typedef $AppPrefsCreateCompanionBuilder =
    AppPrefsCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $AppPrefsUpdateCompanionBuilder =
    AppPrefsCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $AppPrefsFilterComposer extends Composer<_$BondDatabase, AppPrefs> {
  $AppPrefsFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $AppPrefsOrderingComposer extends Composer<_$BondDatabase, AppPrefs> {
  $AppPrefsOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $AppPrefsAnnotationComposer extends Composer<_$BondDatabase, AppPrefs> {
  $AppPrefsAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $AppPrefsTableManager
    extends
        RootTableManager<
          _$BondDatabase,
          AppPrefs,
          AppPref,
          $AppPrefsFilterComposer,
          $AppPrefsOrderingComposer,
          $AppPrefsAnnotationComposer,
          $AppPrefsCreateCompanionBuilder,
          $AppPrefsUpdateCompanionBuilder,
          (AppPref, BaseReferences<_$BondDatabase, AppPrefs, AppPref>),
          AppPref,
          PrefetchHooks Function()
        > {
  $AppPrefsTableManager(_$BondDatabase db, AppPrefs table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $AppPrefsFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $AppPrefsOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $AppPrefsAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AppPrefsCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => AppPrefsCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $AppPrefsProcessedTableManager =
    ProcessedTableManager<
      _$BondDatabase,
      AppPrefs,
      AppPref,
      $AppPrefsFilterComposer,
      $AppPrefsOrderingComposer,
      $AppPrefsAnnotationComposer,
      $AppPrefsCreateCompanionBuilder,
      $AppPrefsUpdateCompanionBuilder,
      (AppPref, BaseReferences<_$BondDatabase, AppPrefs, AppPref>),
      AppPref,
      PrefetchHooks Function()
    >;
typedef $DraftsCreateCompanionBuilder =
    DraftsCompanion Function({
      Value<String> source,
      required String conversationKey,
      required String replyToMessageId,
      required String body,
      Value<String?> evidence,
      Value<String> status,
      Value<String?> graphDraftId,
      Value<String?> webLink,
      required String createdAt,
      required String updatedAt,
      Value<int> rowid,
    });
typedef $DraftsUpdateCompanionBuilder =
    DraftsCompanion Function({
      Value<String> source,
      Value<String> conversationKey,
      Value<String> replyToMessageId,
      Value<String> body,
      Value<String?> evidence,
      Value<String> status,
      Value<String?> graphDraftId,
      Value<String?> webLink,
      Value<String> createdAt,
      Value<String> updatedAt,
      Value<int> rowid,
    });

class $DraftsFilterComposer extends Composer<_$BondDatabase, Drafts> {
  $DraftsFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get conversationKey => $composableBuilder(
    column: $table.conversationKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get replyToMessageId => $composableBuilder(
    column: $table.replyToMessageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get evidence => $composableBuilder(
    column: $table.evidence,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get graphDraftId => $composableBuilder(
    column: $table.graphDraftId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get webLink => $composableBuilder(
    column: $table.webLink,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $DraftsOrderingComposer extends Composer<_$BondDatabase, Drafts> {
  $DraftsOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get conversationKey => $composableBuilder(
    column: $table.conversationKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get replyToMessageId => $composableBuilder(
    column: $table.replyToMessageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get evidence => $composableBuilder(
    column: $table.evidence,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get graphDraftId => $composableBuilder(
    column: $table.graphDraftId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get webLink => $composableBuilder(
    column: $table.webLink,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $DraftsAnnotationComposer extends Composer<_$BondDatabase, Drafts> {
  $DraftsAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get conversationKey => $composableBuilder(
    column: $table.conversationKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get replyToMessageId => $composableBuilder(
    column: $table.replyToMessageId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<String> get evidence =>
      $composableBuilder(column: $table.evidence, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get graphDraftId => $composableBuilder(
    column: $table.graphDraftId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get webLink =>
      $composableBuilder(column: $table.webLink, builder: (column) => column);

  GeneratedColumn<String> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $DraftsTableManager
    extends
        RootTableManager<
          _$BondDatabase,
          Drafts,
          Draft,
          $DraftsFilterComposer,
          $DraftsOrderingComposer,
          $DraftsAnnotationComposer,
          $DraftsCreateCompanionBuilder,
          $DraftsUpdateCompanionBuilder,
          (Draft, BaseReferences<_$BondDatabase, Drafts, Draft>),
          Draft,
          PrefetchHooks Function()
        > {
  $DraftsTableManager(_$BondDatabase db, Drafts table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $DraftsFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $DraftsOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $DraftsAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> source = const Value.absent(),
                Value<String> conversationKey = const Value.absent(),
                Value<String> replyToMessageId = const Value.absent(),
                Value<String> body = const Value.absent(),
                Value<String?> evidence = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String?> graphDraftId = const Value.absent(),
                Value<String?> webLink = const Value.absent(),
                Value<String> createdAt = const Value.absent(),
                Value<String> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DraftsCompanion(
                source: source,
                conversationKey: conversationKey,
                replyToMessageId: replyToMessageId,
                body: body,
                evidence: evidence,
                status: status,
                graphDraftId: graphDraftId,
                webLink: webLink,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                Value<String> source = const Value.absent(),
                required String conversationKey,
                required String replyToMessageId,
                required String body,
                Value<String?> evidence = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String?> graphDraftId = const Value.absent(),
                Value<String?> webLink = const Value.absent(),
                required String createdAt,
                required String updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => DraftsCompanion.insert(
                source: source,
                conversationKey: conversationKey,
                replyToMessageId: replyToMessageId,
                body: body,
                evidence: evidence,
                status: status,
                graphDraftId: graphDraftId,
                webLink: webLink,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $DraftsProcessedTableManager =
    ProcessedTableManager<
      _$BondDatabase,
      Drafts,
      Draft,
      $DraftsFilterComposer,
      $DraftsOrderingComposer,
      $DraftsAnnotationComposer,
      $DraftsCreateCompanionBuilder,
      $DraftsUpdateCompanionBuilder,
      (Draft, BaseReferences<_$BondDatabase, Drafts, Draft>),
      Draft,
      PrefetchHooks Function()
    >;

class $BondDatabaseManager {
  final _$BondDatabase _db;
  $BondDatabaseManager(this._db);
  $MessagesTableManager get messages =>
      $MessagesTableManager(_db, _db.messages);
  $ConversationsTableManager get conversations =>
      $ConversationsTableManager(_db, _db.conversations);
  $SyncStateTableManager get syncState =>
      $SyncStateTableManager(_db, _db.syncState);
  $WorkItemsTableManager get workItems =>
      $WorkItemsTableManager(_db, _db.workItems);
  $MessageAiTableManager get messageAi =>
      $MessageAiTableManager(_db, _db.messageAi);
  $ConversationAiTableManager get conversationAi =>
      $ConversationAiTableManager(_db, _db.conversationAi);
  $StorylinesTableManager get storylines =>
      $StorylinesTableManager(_db, _db.storylines);
  $StorylineMembersTableManager get storylineMembers =>
      $StorylineMembersTableManager(_db, _db.storylineMembers);
  $StorylineMemberBlocksTableManager get storylineMemberBlocks =>
      $StorylineMemberBlocksTableManager(_db, _db.storylineMemberBlocks);
  $FeedbackEventsTableManager get feedbackEvents =>
      $FeedbackEventsTableManager(_db, _db.feedbackEvents);
  $ActivityEventsTableManager get activityEvents =>
      $ActivityEventsTableManager(_db, _db.activityEvents);
  $SenderPrefsTableManager get senderPrefs =>
      $SenderPrefsTableManager(_db, _db.senderPrefs);
  $AppPrefsTableManager get appPrefs =>
      $AppPrefsTableManager(_db, _db.appPrefs);
  $DraftsTableManager get drafts => $DraftsTableManager(_db, _db.drafts);
}
