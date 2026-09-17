import 'package:flutter/foundation.dart' show immutable;

import 'event_bus.dart';

/// One fragment of a draft as the model writes it.
///
/// A draft takes 20–35 s of the prose server, and until this existed the whole
/// of it was silence. The handler streams the call, reads the string values out
/// of the growing JSON, and publishes the ones a person is waiting to read:
/// the reply body and the short options. `evidence` is never published — it is
/// the model's note to the app about what it read, and nobody watches it being
/// typed.
///
/// What this is NOT is a second copy of the draft. The stored `drafts` row is
/// written exactly as it always was, once, when the call finishes; everything
/// here is a preview that the row replaces. Which is why [done] matters: it
/// says the draft call has ended — written, skipped or failed — so a listener
/// can drop its preview and read the row instead.
@immutable
class DraftStreamEvent {
  final String source;
  final String conversationKey;
  final String sourceMessageId;

  /// `reply_body`, `options[i].stance` or `options[i].reply_body`; empty when
  /// [done]. [isVisible] is the rule, and [optionPath] the pattern behind it:
  /// the publisher and the accumulator must agree on which paths exist, so
  /// both read them from here rather than each carrying a copy.
  final String path;

  /// The characters of that string that have just arrived.
  final String delta;

  /// The draft call finished. The listener re-reads the stored row.
  final bool done;

  const DraftStreamEvent({
    required this.source,
    required this.conversationKey,
    required this.sourceMessageId,
    required this.path,
    required this.delta,
    this.done = false,
  });

  const DraftStreamEvent.done({
    required this.source,
    required this.conversationKey,
    required this.sourceMessageId,
  })  : path = '',
        delta = '',
        done = true;

  /// The option paths, captured: group 1 is the index, group 2 the field.
  static final RegExp optionPath =
      RegExp(r'^options\[(\d+)\]\.(stance|reply_body)$');

  /// Whether a path from [PartialJsonStrings] is one a person reads. Said once
  /// here because two layers ask it — the handler deciding what to publish and
  /// [StreamingDraft] deciding what to fold in — and a rule that drifted
  /// between them would be a path published and then silently dropped.
  static bool isVisible(String path) =>
      path == 'reply_body' || optionPath.hasMatch(path);

  @override
  String toString() => done
      ? 'DraftStreamEvent.done($source/$sourceMessageId)'
      : 'DraftStreamEvent($source/$sourceMessageId $path +${delta.length})';
}

/// Where a draft's text is announced while it is being written.
///
/// An alias rather than a subclass: nothing about a draft's stream needs a
/// name of its own beyond the event's, and `const DraftStreamBus.disabled()` —
/// the default every handler takes — reads through the alias unchanged.
typedef DraftStreamBus = EventBus<DraftStreamEvent>;
