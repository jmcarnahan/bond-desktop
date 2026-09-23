import 'package:flutter/foundation.dart' show immutable;

/// One of the three models this Mac would run, as a status line reads it.
///
/// The FACTS a row needs that are not live: which role it fills, what the
/// checkpoint is called, what it costs on disk, and whether the bytes are
/// there. Whether it is LOADED is deliberately not here — that is the router's
/// own answer, it changes while somebody is looking at the page, and it
/// arrives through `serverStateProvider` and is joined in the widget.
///
/// [roleId] is the page's vocabulary (`big`, `small`, `embed`) rather than
/// either of the two role enums, because the row it feeds is named that way
/// and a screen should not have to know that the manifest says `prose` where
/// the stage table says `big`. [routerId] is what the same model is called
/// inside the router's preset, which is how a row finds its own entry in
/// `ServerLoading.loaded`.
@immutable
class ManagedModelStatus {
  final String roleId;
  final String displayName;

  /// What this checkpoint costs to fetch — the weights plus any sidecar, the
  /// same number the wizard's row quotes.
  final int bytes;

  /// Whether the ledger says this file landed at today's digest AND the file
  /// is still there. Both, because a file can be deleted under a current row.
  final bool onDisk;

  final String routerId;

  /// Whether the placement's preset includes this file.
  ///
  /// False for the two chat models under the user-defined placement, where
  /// this Mac serves the embedding model alone. That is exactly the state the
  /// page has to say out loud: the weights are still on the disk, and nothing
  /// is holding them in memory.
  final bool inUse;

  const ManagedModelStatus({
    required this.roleId,
    required this.displayName,
    required this.bytes,
    required this.onDisk,
    required this.routerId,
    required this.inUse,
  });
}
