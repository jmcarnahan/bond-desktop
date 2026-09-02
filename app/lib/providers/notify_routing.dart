import '../services/notify/settled_event.dart';
import '../widgets/app_rail.dart' show RailSection;
import 'navigation_provider.dart';

/// Where a click on a notification lands.
///
/// It lives in `providers/` rather than beside the other notify files in
/// `services/notify/` because it answers in [NavIntent], and services never
/// import providers — that layering rule is one-way and this function is on the
/// providers side of it.
///
/// The rule is about what the user asked for, not about what is most specific:
/// one settle is one thread to read, several settles are a pile, and a pile with
/// nothing in common is a section — never a thread picked on the user's behalf
/// (the same restraint the rail's `_more()` overflow row shows).
NavIntent intentFor(List<MessageSettled> items) {
  if (items.isEmpty) {
    throw ArgumentError.value(items, 'items', 'no settles to route to');
  }

  if (items.length == 1) {
    // Its storyline is context on the way in, not the ask. The user was told a
    // message needs them; the message is what opens.
    final item = items.single;
    return OpenThreadIntent(item.source, item.conversationKey);
  }

  final storylineId = items.first.storylineId;
  if (storylineId != null && storylineId.isNotEmpty) {
    final shared = items.every((item) => item.storylineId == storylineId);
    if (shared) return OpenStorylineIntent(storylineId);
  }

  return OpenSectionIntent(RailSection.needsYou);
}
