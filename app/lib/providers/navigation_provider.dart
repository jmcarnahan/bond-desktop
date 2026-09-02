import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/app_rail.dart' show RailSection;

/// Where something outside [InboxScreen]'s State is asking the app to go.
///
/// There is no router here: every navigation the app has ever done is a
/// `setState` inside `InboxScreen`, reachable only from widgets it built. A
/// notification is the first thing that has to navigate from outside that tree
/// — it comes from a stream, not from a tap on a row — so it asks through this
/// provider and the screen listens.
///
/// Importing `app_rail.dart` for [RailSection] puts a widget import in a
/// provider, which is accepted: the rail's four stops ARE the app's section
/// vocabulary, and re-declaring them here would be a second enum to keep in
/// step with the first.
sealed class NavIntent {}

/// Open one thread. Always carries the source as well as the key: a
/// conversation key is unique within a connector and not across them, so a
/// bare id can open a chat's mail namesake instead.
class OpenThreadIntent extends NavIntent {
  final String source;
  final String conversationKey;

  OpenThreadIntent(this.source, this.conversationKey);
}

class OpenStorylineIntent extends NavIntent {
  final String storylineId;

  OpenStorylineIntent(this.storylineId);
}

class OpenSectionIntent extends NavIntent {
  final RailSection section;

  OpenSectionIntent(this.section);
}

/// The one thing that asks, and the one thing that takes the ask back.
///
/// Deliberately no `==`/`hashCode` on the intents above: two identical asks are
/// two asks. A StateNotifier only notifies when the new state differs, so an
/// equality that made the second request equal to the first would silently drop
/// it — clicking the same ribbon twice has to open the thread twice.
class NavIntentNotifier extends StateNotifier<NavIntent?> {
  NavIntentNotifier() : super(null);

  void request(NavIntent intent) => state = intent;

  /// Called by the screen once it has acted, so a rebuild does not replay the
  /// last navigation.
  void clear() => state = null;
}

/// NOT autoDispose: a settle can be clicked in the frame before the screen
/// starts watching this, and a provider that disposed itself in between would
/// drop the one thing it exists to carry.
final navIntentProvider =
    StateNotifierProvider<NavIntentNotifier, NavIntent?>(
  (ref) => NavIntentNotifier(),
);
