import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import '../providers/archive_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/message_history_provider.dart';
import '../providers/storylines_provider.dart';
import '../screens/message_history_screen.dart';

/// One message's whole story, and every lever beside it.
///
/// Everything the screen renders is a prop — see [MessageHistoryScreen] — so
/// this is the only place the history provider is read. Every notifier and
/// service is read BEFORE the awaits, the way the repair lever on the home
/// feed is: the reader can leave the pane while a write is in flight, and a
/// `ref.read` after the await is how a lever comes to throw at the end of
/// doing its job.
///
/// A widget rather than a method on one screen because two hosts seat the same
/// story: the inbox pane and the side panel. What is left to the host is what
/// only a host can answer — where Back goes, where the storyline picker is
/// drawn, and whether the pane draws its own title bar.
class MessageHistoryHost extends ConsumerWidget {
  /// The message this story is about, as `(source, sourceMessageId)`.
  final ({String source, String id}) target;

  final VoidCallback onBack;
  final VoidCallback onHome;
  final void Function(String source, String conversationKey) onOpenThread;
  final void Function(String storylineId) onOpenStoryline;

  /// Opens the host's storyline picker for the thread; null hides the lever.
  final void Function(String source, String threadKey)? onAddToStoryline;

  /// The host's own keep-in-inbox (it toasts an undo); null hides the lever.
  final Future<void> Function(String source, String threadKey)? onKeepInInbox;

  final VoidCallback? onEditRules;

  /// False renders the story without its PaneSurface chrome, for a host that
  /// draws its own header around it.
  final bool chrome;

  const MessageHistoryHost({
    super.key,
    required this.target,
    required this.onBack,
    required this.onHome,
    required this.onOpenThread,
    required this.onOpenStoryline,
    this.onAddToStoryline,
    this.onKeepInInbox,
    this.onEditRules,
    this.chrome = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = target.source;
    final id = target.id;
    final args = (source: source, id: id);
    final history = ref.watch(messageHistoryProvider(args));
    final value = history.valueOrNull;

    final reader = ref.read(messageHistoryProvider(args).notifier);
    final repair = ref.read(pipelineRepairServiceProvider);
    final restore = ref.read(restoreServiceProvider);
    final archive = ref.read(archiveProvider.notifier);
    final storylines = ref.read(storylinesProvider.notifier);
    final conversations = ref.read(conversationsProvider.notifier);

    // The pane's own re-read. Filing a thread, lifting a block and keeping a
    // thread in the inbox all move rows this screen renders without moving any
    // stage, so nothing is published and nothing would come back on its own.
    void reload() => unawaited(reader.reload());

    // The thread's key, which every thread-scoped lever needs and which is
    // only known once the first read has landed. Without it the screen is
    // handed nulls rather than buttons that would act on the empty string.
    final threadKey = value?.conversationKey ?? '';
    final threaded = threadKey.isNotEmpty;

    final addToStoryline = onAddToStoryline;
    final keepInInbox = onKeepInInbox;

    return MessageHistoryScreen(
      history: history,
      now: DateTime.now(),
      chrome: chrome,
      onBack: onBack,
      onHome: onHome,
      onOpenThread: onOpenThread,
      onOpenStoryline: onOpenStoryline,
      // The archive's own pattern: the pane sheds the row first and the
      // pipeline catches up, and the re-read is what reports whether it did.
      onRestore: () {
        archive.noteRestored(source, id);
        unawaited(restore.restore(source, id).then((_) => reload()));
      },
      onRetry: () =>
          unawaited(repair.retryOwed(source, id).then((_) => reload())),
      onRejudge: () =>
          unawaited(repair.rejudgeNeedsYou(source, id).then((_) => reload())),
      onIgnore: () =>
          unawaited(repair.ignore(source, id).then((_) => reload())),
      onAddToStoryline: threaded && addToStoryline != null
          ? () => addToStoryline(source, threadKey)
          : null,
      onRemoveFromStoryline: threaded
          ? (storylineId) => unawaited(
                storylines
                    .removeThread(storylineId, source, threadKey)
                    .then((_) => reload()),
              )
          : null,
      onAllowAgain: threaded
          ? (storylineId) => unawaited(
                storylines
                    .unblockThread(storylineId, source, threadKey)
                    .then((_) => reload()),
              )
          : null,
      onAddBack: threaded
          ? (storylineId) => unawaited(
                storylines
                    .addThread(storylineId, source, threadKey)
                    .then((_) => reload()),
              )
          : null,
      onKeepInInbox: threaded && keepInInbox != null
          ? () => unawaited(
                keepInInbox(source, threadKey).then((_) => reload()),
              )
          : null,
      onSendToLater: threaded
          ? () => unawaited(
                conversations
                    .sendThreadToLater(source, threadKey)
                    .then((_) => reload()),
              )
          : null,
      onEditRules: onEditRules,
    );
  }
}
