import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/message_models.dart';
import '../services/llm/extract_task.dart' show ExtractionResult;
import 'app_providers.dart';

/// Which message the Why panel is explaining.
///
/// A record and not a class, for the equality: Riverpod caches a family by its
/// key, and records compare structurally — so re-reading the same message
/// re-renders from cache while moving to a different one is a fresh read.
///
/// The conversation key rides along because half the answer is about the
/// THREAD: the attention score, the bucket and who put it there live on
/// `conversation_ai`, and the message id alone cannot find them.
typedef WhyKey = ({String source, String conversationKey, String messageId});

/// Everything behind one verdict, read in one pass.
///
/// Three reads rather than one join, because they come from three tables with
/// three different lifetimes — the message row, its extraction blob, the
/// thread's AI state — and any of them may be absent without the others being
/// wrong. The panel says so field by field.
@immutable
class WhyFacts {
  /// The message itself, or null when the row is gone — synced away, wiped.
  /// The panel says so rather than rendering an explanation of nothing.
  final Message? message;

  /// What the model pulled out of it, or null when nothing has extracted it
  /// yet and when the stored blob does not parse.
  final ExtractionResult? extraction;

  /// The raw `conversation_ai` row for the thread, or null when no pass has
  /// ever written one. Raw because the panel reads three columns off it and a
  /// model class for three columns would be a third answer to keep in step.
  final Map<String, Object?>? ai;

  const WhyFacts({this.message, this.extraction, this.ai});
}

/// The facts behind one message's verdict.
///
/// Its own read rather than a slice of the open thread, deliberately: the
/// panel has to work for a message whose transcript is not the one loaded —
/// opened from a side thread, from a room, from a list — and a provider that
/// depended on the thread provider would show an empty panel exactly then.
///
/// `autoDispose` because it is a panel: the read is three indexed queries, and
/// keeping one alive per message anybody ever hovered is a cache nothing reads
/// twice.
final whyFactsProvider =
    FutureProvider.autoDispose.family<WhyFacts, WhyKey>((ref, key) async {
  final store = ref.watch(messageStoreProvider);
  final message = await store.messageById(key.source, key.messageId);
  final extraction = await store.extractionFor(key.source, key.messageId);
  final ai = await store.getConversationAi(key.source, key.conversationKey);
  return WhyFacts(message: message, extraction: extraction, ai: ai);
});
