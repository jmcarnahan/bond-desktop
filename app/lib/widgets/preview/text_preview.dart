/// Words on a page, selectable and never rendered as markdown.
///
/// The same rule the transcript keeps: what a document says is what it says,
/// and turning its asterisks into bold would be this app editing somebody
/// else's file in front of them. A `SelectableText` because the point of
/// reading a quote here is copying a number out of it.
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

class TextPreview extends StatelessWidget {
  final String text;

  /// Structured text — a csv, a log — is read in columns, and a proportional
  /// face throws those columns away. `monoForName` decides for the caller.
  final bool mono;

  /// A line under the words about the words: where the extractor cut them,
  /// typically. Null renders nothing.
  final String? note;

  /// What to say when there are none. The panel knows WHY better than this
  /// widget can — still reading, refused, never extracted — so it says.
  final String? emptyReason;

  const TextPreview({
    super.key,
    required this.text,
    this.mono = false,
    this.note,
    this.emptyReason,
  });

  /// The most characters ever laid out. A `SelectableText` builds one text
  /// span per rebuild, and a ten-megabyte log would spend that whole layout on
  /// every frame for a document nobody is reading past the first screen.
  static const int charCap = 200000;

  static const Key bodyKey = ValueKey('text-preview-body');
  static const Key emptyKey = ValueKey('text-preview-empty');
  static const Key noteKey = ValueKey('text-preview-note');

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) {
      return Text(
        emptyReason ?? 'No text was extracted from this file.',
        key: emptyKey,
        style: BondType.caption.copyWith(color: BondColors.inkMuted),
      );
    }

    final clamped =
        text.length > charCap ? text.substring(0, charCap) : text;
    final noteText = note;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(BondSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(
            clamped,
            key: bodyKey,
            style: mono
                ? BondType.mono
                : BondType.body.copyWith(height: 1.4),
          ),
          if (noteText != null && noteText.isNotEmpty) ...[
            const SizedBox(height: BondSpacing.s8),
            Text(
              noteText,
              key: noteKey,
              style: BondType.caption.copyWith(color: BondColors.inkMuted),
            ),
          ],
        ],
      ),
    );
  }
}
