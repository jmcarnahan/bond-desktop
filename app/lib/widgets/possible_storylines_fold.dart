import 'package:flutter/material.dart';

import '../models/storyline_models.dart';
import '../services/llm/storyline_tasks.dart' show NameStorylineTask;
import '../theme/tokens.dart';

/// What a possible storyline says for itself where there is room to say it:
/// the Storylines overview's card, which shows the counts the rail's fold has
/// no width for.
///
/// Not on the rail row, which has the heading above it and two icons on it,
/// and not in place of anything a suggestion says: a suggestion is the model
/// offering a group, and this is the model admitting it could not tell.
const String possibleStorylineCaption =
    'The model found this group but would not vouch for it. '
    'Keep it if it is a storyline, or let it go.';

/// The caption above on one card, for a test that wants to find it without
/// matching its words.
///
/// Keyed by the storyline, not shared: every possible card carries the same
/// sentence, and one key over all of them makes `find.byKey` ambiguous the
/// moment a mailbox has two of these.
Key possibleStorylineCaptionKeyFor(String storylineId) =>
    ValueKey('possible-storyline-caption-$storylineId');

/// The groups the model found and would not vouch for, folded under the live
/// storylines and above the dismissed ones.
///
/// The sweep builds a cluster, names it, lints the charter it wrote and
/// confirms each thread against it. When any of those three declines, the
/// group used to become a member-less tombstone: a row nothing rendered,
/// written so the identical cluster would never cost a model call again. On
/// the owner's own mailbox that was every group the sweep found — four of
/// them, all recognisable, and a rail reading `Dismissed · 4` as though the
/// owner had turned each one down.
///
/// So they are filed instead, with their members, and shown here. A fold
/// rather than a live row because it asks softly: the model is not offering
/// these, it is admitting it could not tell. Each one is kept or dismissed
/// exactly as a suggestion is, and a tap on the title opens the storyline so
/// the threads in it can be read before either answer. Nobody answering is
/// also an answer: these expire on the suggestion's own 14-day clock, into a
/// dismissed row that keeps its members and can be restored.
class PossibleStorylinesFold extends StatefulWidget {
  final List<Storyline> possible;

  /// Accepts one: it becomes a live storyline and its threads leave the
  /// sweep's pool. Null leaves the Keep buttons inert.
  final void Function(String storylineId)? onKeep;

  /// Lets one go. Null leaves the Dismiss buttons inert.
  final void Function(String storylineId)? onDismiss;

  /// Opens one, so its member threads can be read before the decision. Null
  /// leaves the titles unclickable.
  final void Function(String storylineId)? onOpen;

  /// The column's fill behind each row, so the fold matches whichever rail it
  /// sits in.
  final Color fill;

  static const Key headerKey = ValueKey('possible-storylines-header');

  static Key keepKey(String storylineId) =>
      ValueKey('possible-keep-$storylineId');

  static Key dismissKey(String storylineId) =>
      ValueKey('possible-dismiss-$storylineId');

  const PossibleStorylinesFold({
    super.key,
    required this.possible,
    this.onKeep,
    this.onDismiss,
    this.onOpen,
    this.fill = BondColors.ink,
  });

  @override
  State<PossibleStorylinesFold> createState() => _PossibleStorylinesFoldState();
}

class _PossibleStorylinesFoldState extends State<PossibleStorylinesFold> {
  /// Whether the possible storylines are unfolded. Shut every time, like the
  /// dismissed fold: what is in here is a maybe, and a list of maybes opened
  /// by default would be the loudest thing on the rail.
  bool _open = false;

  static const double _rowHeight = 32;

  @override
  Widget build(BuildContext context) {
    if (widget.possible.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        if (_open)
          for (final s in widget.possible) _item(s),
      ],
    );
  }

  /// The fold over the possible storylines. Its count is in the label, the way
  /// the dismissed fold's is: it is what the row has to say for itself while
  /// it is shut.
  Widget _header() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s12),
      child: Material(
        color: widget.fill,
        borderRadius: BondRadii.smAll,
        child: InkWell(
          key: PossibleStorylinesFold.headerKey,
          onTap: () => setState(() => _open = !_open),
          borderRadius: BondRadii.smAll,
          hoverColor: BondColors.onDarkFaint,
          child: SizedBox(
            height: _rowHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Possible · ${widget.possible.length}',
                      style: BondType.caption.copyWith(
                        color: BondColors.onDarkSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  AnimatedRotation(
                    turns: _open ? 0 : -0.25,
                    duration: const Duration(milliseconds: 120),
                    child: const Icon(
                      Icons.expand_more,
                      size: 16,
                      color: BondColors.onDarkMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// One possible storyline: the title, which opens it, and the two answers.
  /// No dot and no count — the dot marks a row that is asking, and this one
  /// asks under its own heading rather than on the row.
  Widget _item(Storyline storyline) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s12),
      child: Material(
        color: widget.fill,
        borderRadius: BondRadii.smAll,
        child: InkWell(
          onTap: widget.onOpen == null
              ? null
              : () => widget.onOpen!(storyline.id),
          borderRadius: BondRadii.smAll,
          hoverColor: BondColors.onDarkFaint,
          child: SizedBox(
            height: _rowHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      storyline.title.isEmpty
                          ? NameStorylineTask.fallbackTitle
                          : storyline.title,
                      style: BondType.small.copyWith(
                        color: BondColors.onDarkSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _action(
                    PossibleStorylinesFold.keepKey(storyline.id),
                    Icons.check,
                    'Keep',
                    widget.onKeep == null
                        ? null
                        : () => widget.onKeep!(storyline.id),
                  ),
                  _action(
                    PossibleStorylinesFold.dismissKey(storyline.id),
                    Icons.close,
                    'Dismiss',
                    widget.onDismiss == null
                        ? null
                        : () => widget.onDismiss!(storyline.id),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Keep and Dismiss. Small and quiet, the way the rail's suggestion pair is:
  /// the row's main target is opening the storyline, and a button loud enough
  /// to compete with that would get mis-tapped into an answer.
  Widget _action(Key key, IconData icon, String tooltip, VoidCallback? onTap) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BondRadii.fullAll,
        hoverColor: BondColors.onDarkTint,
        child: Padding(
          padding: const EdgeInsets.all(BondSpacing.s4),
          child: Icon(icon, size: 16, color: BondColors.onDarkMuted),
        ),
      ),
    );
  }
}
