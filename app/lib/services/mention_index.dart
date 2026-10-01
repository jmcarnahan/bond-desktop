import '../models/message_models.dart';
import 'decision/needs_you_predicate.dart';

/// Where in a long thread the owner is actually named.
///
/// A fifty-message group chat has one or two turns in it that are about the
/// reader, and the rest is other people talking. The navigator in the thread
/// header steps between those turns, so the question "which messages are mine
/// to answer" has to be answered once, from stored data, in a function that can
/// be read as a table rather than inferred from a widget.
///
/// Pure and in `services/` for the house reason: nothing here imports a widget
/// or a provider, and the transcript's scroll machinery reads the answer rather
/// than working it out while building.

/// Whether [m] names the owner — the ONE rule behind the navigator, the accent
/// marker on a row and the row that starts unfolded.
///
/// Two stored signals, both written before any of this is drawn:
///
///  * [Message.addressedMe] — the connector's own answer at ingest: sole `To:`
///    recipient of a mail, a 1:1 chat, or an `@mention` in Teams. It says
///    something about the message rather than about the model, which is why it
///    comes first.
///  * a non-empty [Message.actionItems] — the extractor's prompt writes those
///    as "things the READER must do" (`llm/message_text_task.dart`), so an action
///    item names the owner by construction. This is what catches the turn that
///    asked the group to confirm owners without typing anybody's name.
///
/// Inbound only. The owner's own message cannot mention them, and a queued
/// outbound bubble is not somewhere to be sent. An action item of nothing but
/// whitespace is not an ask: the row would draw an empty orange line and the
/// navigator would count a stop with nothing at it.
///
/// An action item stops counting once the decision model has placed the
/// message BELOW the owner's [threshold]. The extractor writes "things the
/// reader must do" off any message with a task in it — a Jira broadcast
/// describing somebody else's ticket comes back as "Review the issue…" — and
/// `@ you` over that is a mention nobody made. It is the same rule
/// `isNeedsYou` reads ([needsYouAt]); an undecided message (null) keeps its
/// items, because undecided is not a no. [Message.addressedMe] is the
/// connector's fact and no probability overrules it.
bool namesOwner(
  Message m, {
  double threshold = NeedsYouTuning.defaultThreshold,
}) {
  if (!m.inbound) return false;
  if (m.addressedMe) return true;
  if (m.needsYouP != null && !needsYouAt(m.needsYouP, threshold)) return false;
  return m.actionItems.any((item) => item.trim().isNotEmpty);
}

/// The ids of every message in [messages] that [namesOwner], in the order the
/// transcript draws them — oldest first, exactly as [MessageStore.loadThread]
/// returns the thread.
///
/// Ids rather than indices, because everything downstream is keyed by message
/// id: the per-row `GlobalKey`s the jump uses, the host's unfolded-row set, and
/// the `needs_you_reason_message_id` a thread already carries. A blank id is
/// skipped — a stop the scroll machinery could never find is not a stop.
List<String> mentionIndexOf(
  List<Message> messages, {
  double threshold = NeedsYouTuning.defaultThreshold,
}) =>
    [
      for (final m in messages)
        if (m.id.isNotEmpty && namesOwner(m, threshold: threshold)) m.id,
    ];

/// Where [messageId] sits in [index] when the reader steps, or null when there
/// is nowhere to go.
///
/// The walk STOPS at both edges rather than wrapping, the rule
/// `triage_intents.neighbourRow` already sets for `j`/`k`: a reader who pressed
/// "next" and landed back at the top of the thread has lost their place.
///
/// A null or unknown [messageId] means the reader has not stepped yet, so the
/// walk starts at the end it is walking from: the FIRST mention going forwards,
/// the last coming back. That is what makes the very first press of ↓ land on
/// the oldest thing the reader owes an answer to rather than on the second one.
String? stepMention(
  List<String> index,
  String? messageId, {
  required bool forward,
}) {
  if (index.isEmpty) return null;
  final at = messageId == null ? -1 : index.indexOf(messageId);
  if (at < 0) return forward ? index.first : index.last;
  final next = forward ? at + 1 : at - 1;
  if (next < 0 || next >= index.length) return null;
  return index[next];
}
