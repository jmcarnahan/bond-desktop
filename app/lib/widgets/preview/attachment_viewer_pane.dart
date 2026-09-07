/// The same panel, given the whole pane.
///
/// A split preview is for reading a file BESIDE the conversation about it; this
/// is for reading the file. Nothing changes but the room, which is why it is
/// the same widget underneath rather than a second renderer that could drift
/// from the first.
///
/// [PaneSurface]'s back arrow is the only way out, so the panel is told to draw
/// no header of its own. Two close controls doing different things — one back
/// to the split, one dropping the preview entirely — is exactly the confusion
/// the single arrow avoids.
library;

import 'package:flutter/material.dart';

import '../../models/attachment_models.dart';
import '../../services/attachments/attachment_bytes.dart';
import '../attachment_format.dart';
import '../chips.dart';
import '../pane_surface.dart';
import 'attachment_preview_panel.dart';
import 'preview_engines.dart';

class AttachmentViewerPane extends StatelessWidget {
  final AttachmentRef attachment;
  final AttachmentBytes bytes;
  final PreviewEngines engines;

  /// Back to the split, with the thread still underneath it.
  final VoidCallback onBack;

  /// Straight to Home, clearing the thread and the preview both. Null renders
  /// no home affordance — see [PaneSurface].
  final VoidCallback? onHome;

  final VoidCallback? onOpen;
  final VoidCallback? onSave;

  /// No `onUseInReply` here, deliberately: there is no composer on the full
  /// pane, so a draft written from it would land somewhere off screen. The
  /// split preview beside a thread is where that offer belongs.
  final VoidCallback? onPinToStoryline;
  final bool pinned;
  final void Function(String url)? onOpenLink;

  const AttachmentViewerPane({
    super.key,
    required this.attachment,
    required this.bytes,
    required this.engines,
    required this.onBack,
    this.onHome,
    this.onOpen,
    this.onSave,
    this.onPinToStoryline,
    this.pinned = false,
    this.onOpenLink,
  });

  @override
  Widget build(BuildContext context) {
    final size = formatBytes(attachment.size);
    return PaneSurface(
      title: attachment.name ?? '(unnamed attachment)',
      onBack: onBack,
      onHome: onHome,
      // The size moves into the header's trailing slot, since the panel below
      // is no longer drawing one.
      trailing: size.isEmpty ? null : BondChip.metric(size),
      child: AttachmentPreviewPanel(
        attachment: attachment,
        bytes: bytes,
        engines: engines,
        showHeader: false,
        onExpand: null,
        onClose: onBack,
        onOpen: onOpen,
        onSave: onSave,
        onPinToStoryline: onPinToStoryline,
        pinned: pinned,
        onOpenLink: onOpenLink,
      ),
    );
  }
}
