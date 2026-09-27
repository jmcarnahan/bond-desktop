/// A web page attached to a message: a picture of it, and the words in it.
///
/// Two readings of one file, because neither is enough on its own. The words
/// are what a reader came for and what search and the model already have, but a
/// security report is a page of tables and a wall of converted prose loses the
/// shape of it. The picture says what the page IS at a glance; the words are
/// below it, selectable, so a number can still be copied out.
///
/// **Nothing here renders HTML.** The picture is a PNG the Runner's WebKit drew
/// under `WebSnapshotChannel`'s refusals — no scripting, no resources, no
/// navigation — and this widget only draws the bytes. A page with no snapshot
/// gets the glyph card instead, which is the ordinary case on any host with no
/// channel behind it.
///
/// The whole card is the tap target, the way a chat client's link card is: a
/// small `Open` link beside a picture that also opened it would be two controls
/// doing one thing. With no [onOpenInBrowser] the card is not tappable and says
/// nothing about a browser — a dead control is worse than no control.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

class HtmlPreview extends StatelessWidget {
  /// The rendering, or null when there is not going to be one.
  final Uint8List? snapshot;

  /// The file's own glyph, for the card with no picture in it.
  final String glyph;

  final String? name;

  /// Under the card: the converted page. Built by the host, which is where the
  /// extracted words and the reasons there are none both live.
  final Widget body;

  /// Opening the page in the default browser. Null renders no control and no
  /// caution.
  final VoidCallback? onOpenInBrowser;

  /// Whether the message this file came with was sent from outside the owner's
  /// own domains. False — the default — keeps the sentence this card has always
  /// said; true swaps it for [cautionExternal].
  final bool externalSender;

  const HtmlPreview({
    super.key,
    required this.glyph,
    required this.body,
    this.snapshot,
    this.name,
    this.onOpenInBrowser,
    this.externalSender = false,
  });

  static const Key cardKey = ValueKey('html-preview-card');
  static const Key snapshotKey = ValueKey('html-preview-snapshot');
  static const Key glyphKey = ValueKey('html-preview-glyph');
  static const Key cautionKey = ValueKey('html-preview-caution');

  /// The one sentence about where the button goes and why to think first.
  ///
  /// A page opened from a file the sender chose is a page that can ask for a
  /// password, and the browser will show it as convincingly as it shows
  /// anything. This is said ON the control rather than behind a confirmation,
  /// because there are no dialogs in this app and because a warning a person
  /// reads before pressing is worth more than one they dismiss after.
  static const String caution =
      'Opens in your browser — be careful with files from people you '
      'do not know.';

  /// The same sentence when the sender is outside the owner's organisation.
  ///
  /// Stronger in the one way that helps: it names the fact the reader would have
  /// had to work out for themselves, and it names the thing an attacker
  /// actually wants, which is a password typed into a page that looks like the
  /// one they use every day. "Be careful" is advice; "do not sign in" is an
  /// instruction, and this is the only place in the app where a file somebody
  /// outside the tenant chose is about to be handed to a real browser.
  static const String cautionExternal =
      'This page came from outside your organisation. It opens in your '
      'browser — do not sign in to anything it asks you to.';

  /// Which sentence this card is showing. A getter rather than a literal at the
  /// draw site so a test can ask for the string it expects by the same rule the
  /// widget picks it by.
  String get cautionText => externalSender ? cautionExternal : caution;

  /// How tall the rendering gets. The same ceiling `_documentBody` gives
  /// OneDrive's picture, so a page and a Word file read as the same kind of
  /// thing above the same kind of words.
  static const double maxSnapshotHeight = 200;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card(),
        const SizedBox(height: BondSpacing.s12),
        Expanded(child: body),
      ],
    );
  }

  Widget _card() {
    final open = onOpenInBrowser;
    final card = Container(
      key: cardKey,
      decoration: BoxDecoration(
        color: BondColors.previewGround,
        borderRadius: BondRadii.smAll,
        border: Border.all(color: BondColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _picture(),
          if (open != null) _openLine(),
        ],
      ),
    );
    if (open == null) return card;
    return InkWell(
      onTap: open,
      borderRadius: BondRadii.smAll,
      child: card,
    );
  }

  /// The rendering, or the glyph card that stands in for it.
  Widget _picture() {
    final png = snapshot;
    if (png == null) return _glyphCard();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: maxSnapshotHeight),
      child: Image.memory(
        png,
        key: snapshotKey,
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        // Bytes that will not decode are not a picture, and a broken frame says
        // less than the glyph card the rest of this widget already knows how to
        // draw. An undecodable image throws into the tree and would take the
        // whole panel with it.
        errorBuilder: (_, _, _) => _glyphCard(),
        // The same bytes across a rebuild keep the frame that is already
        // decoded rather than blanking for one frame.
        gaplessPlayback: true,
      ),
    );
  }

  Widget _glyphCard() => Container(
    key: glyphKey,
    alignment: Alignment.center,
    padding: const EdgeInsets.all(BondSpacing.s24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(glyph, style: BondType.heading),
        if (name != null && name!.isNotEmpty) ...[
          const SizedBox(height: BondSpacing.s8),
          Text(
            name!,
            style: BondType.body,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ],
    ),
  );

  /// Where the tap goes, and the caution, under the picture rather than over
  /// it: a label on top of somebody else's rendering is a label the rendering
  /// could have drawn itself.
  Widget _openLine() => Padding(
    padding: const EdgeInsets.all(BondSpacing.s12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.open_in_new, size: 16, color: BondColors.inkMuted),
        const SizedBox(width: BondSpacing.s8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Open in browser',
                style: BondType.body.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                cautionText,
                key: cautionKey,
                // The external sentence is the one line on this card that is
                // asking to be read, so it gets ink rather than the muted grey
                // the ordinary caution wears.
                style: BondType.caption.copyWith(
                  color: externalSender
                      ? BondColors.onExternalTint
                      : BondColors.inkMuted,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
