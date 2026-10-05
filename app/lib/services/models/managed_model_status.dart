import 'package:flutter/foundation.dart' show immutable;

/// One of the three role models this Mac would run, as a status line reads it.
///
/// The FACTS a row needs that are not live: which role it fills, what the
/// checkpoint is called, what it costs on disk, and whether the bytes are
/// there. Whether it is LOADED is deliberately not here — that is the router's
/// own answer, it changes while somebody is looking at the page, and it
/// arrives through `serverStateProvider` and is joined in the widget.
///
/// [roleId] is the page's vocabulary (`decision`, `generative`, `embed`)
/// rather than either of the two role enums, because the row it feeds is named
/// that way and a screen should not have to know that the manifest says
/// `prose` or `bulk` where the stage table says `generative`. [routerId] is
/// what the same model is called
/// inside the router's preset, which is how a row finds its own entry in
/// `ServerLoading.loaded`.
@immutable
class ManagedModelStatus {
  final String roleId;
  final String displayName;

  /// What this checkpoint costs on disk — its download bytes (the weights,
  /// any sidecar, and a registry entry's heads file: the same number the
  /// wizard's row quotes), or for a hand-installed entry the weights plus its
  /// heads file.
  final int bytes;

  /// Whether the ledger says this file landed at today's digest AND the file
  /// is still there. Both, because a file can be deleted under a current row.
  /// A registry entry wants every one of its files, heads included. For a
  /// hand-installed ([local]) entry there is no ledger: it is whether every
  /// one of its files is in the models folder.
  final bool onDisk;

  /// Whether this entry is installed by hand (`source: local`) rather than
  /// downloaded, which is what a row says when it is missing.
  final bool local;

  final String routerId;

  /// Whether this entry's heads file is in the models folder, for an entry
  /// that has one (the decision model); true for every other entry. Apart
  /// from [onDisk] because the heads run in Dart on this Mac even when the
  /// decision model embeds on the owner's server (D12), so a remote decision
  /// model is only usable once this is true.
  final bool headsOnDisk;

  /// Whether the placement's preset includes this file.
  ///
  /// False for a role whose placement is the owner's own server. That is
  /// exactly the state the page has to say out loud: the weights are still on
  /// the disk, and nothing is holding them in memory.
  final bool inUse;

  const ManagedModelStatus({
    required this.roleId,
    required this.displayName,
    required this.bytes,
    required this.onDisk,
    required this.routerId,
    required this.inUse,
    this.local = false,
    this.headsOnDisk = true,
  });
}
