import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../models/message_models.dart' show Conversation;
import '../models/person.dart';
import '../services/profile_photos.dart';
import '../providers/recipient_search_provider.dart' show RecipientResults;
import '../theme/tokens.dart';
import '../utils/debounced.dart';
import 'bond_avatar.dart';
import 'chips.dart';

/// One row the typeahead can offer. Sealed because the two halves are not
/// interchangeable: picking a person adds a chip, picking a chat leaves the
/// recipients alone and opens an existing thread instead.
///
/// Deliberately WITHOUT `==`: `RawAutocomplete._select` early-returns when the
/// picked option equals the one it last selected, so two options that compared
/// equal would make "pick, remove, pick the same person again" a silent no-op.
/// Every build makes fresh instances, so identity is exactly the right answer.
sealed class _RecipientOption {
  const _RecipientOption(this.section);

  /// The heading this option sits under. Options arrive grouped, so a heading
  /// is emitted wherever this changes.
  final String section;
}

class _PersonOption extends _RecipientOption {
  const _PersonOption(this.person, String section) : super(section);

  final Person person;
}

class _ChatOption extends _RecipientOption {
  const _ChatOption(this.chat) : super(_RecipientsFieldState.chatsSection);

  final Conversation chat;
}

/// A chips-and-typeahead recipients input.
///
/// The picked list is the PARENT's: this widget renders [value] and reports
/// every change through [onChanged], and holds nothing about the recipients
/// itself. A compose screen therefore owns one list per field (To, Cc) and can
/// pre-fill, clear, or restore it without reaching in here.
///
/// [search] is handed in rather than read from a provider so the widget stays
/// testable without a container, and so the caller decides which channel's
/// recents it wants.
class RecipientsField extends StatefulWidget {
  /// The recipients picked so far, newest last. Owned by the caller.
  final List<Person> value;

  final ValueChanged<List<Person>> onChanged;

  /// Must never throw — `RecipientSearch.search` is written that way for this.
  /// A throw is still caught here, because an exception escaping an
  /// `optionsBuilder` takes the frame with it.
  final Future<RecipientResults> Function(String query) search;

  final RecipientChannel channel;

  /// How many recipients the field accepts. Null is unlimited; 1 replaces
  /// rather than appends, which is what a 1:1 chat picker wants.
  final int? max;

  /// Whether an address the user typed may become a chip. Mail only in
  /// practice — there is no Graph id behind a typed address, so a Teams chat
  /// cannot be opened with one.
  final bool allowTypedAddress;

  final String hint;

  /// Lets a screen move focus into the field. The widget disposes only a node
  /// it created itself.
  final FocusNode? focusNode;

  /// Offered existing Teams chats. Chats are shown only when this is given AND
  /// [channel] is Teams; picking one never touches [value].
  final ValueChanged<Conversation>? onChatPicked;

  final Duration debounce;

  /// Where an offered person's face comes from. Null draws initials and asks
  /// nothing — a chat row keeps its icon either way.
  final ProfilePhotos? photos;

  const RecipientsField({
    super.key,
    required this.value,
    required this.onChanged,
    required this.search,
    required this.channel,
    this.max,
    this.allowTypedAddress = false,
    this.hint = 'Add people',
    this.focusNode,
    this.onChatPicked,
    this.debounce = const Duration(milliseconds: 250),
    this.photos,
  });

  @override
  State<RecipientsField> createState() => _RecipientsFieldState();
}

class _RecipientsFieldState extends State<RecipientsField> {
  static const String recentSection = 'Recent';
  static const String directorySection = 'Directory';
  static const String typedSection = 'Address';
  static const String chatsSection = 'Chats';

  /// The face on an offered person. Small enough that the row's height is
  /// still set by its two lines of text.
  static const double _optionAvatarSize = 24;

  /// Tall enough for about five rows; past that the list scrolls rather than
  /// swallowing the screen.
  static const double _overlayMaxHeight = 280;

  /// How wide the text box gets once a chip shares its run. Full width while
  /// the field is empty, so the hint has room.
  static const double _fieldWidthBesideChips = 240;

  final TextEditingController _text = TextEditingController();
  late final Debounced _debounce;
  FocusNode? _ownNode;
  bool _focused = false;

  /// The flags from the most recent search, or null when nothing has been
  /// searched since the query last went blank. The footer's whole input.
  ({bool directoryOffline, bool scopeMissing})? _flags;

  /// Set by [_onSelected] so [_submit] can tell whether the SDK's Enter
  /// handling picked something before it falls back to the typed address.
  bool _pickedBySubmit = false;

  /// The list as of the last change this widget reported, or [value] when the
  /// parent has rebuilt since. Every edit is derived from THIS, not from
  /// `widget.value`: two edits can land inside one frame — a click on a chip's
  /// remove target blurs the text box on pointer down, which banks a typed
  /// address, and removes on pointer up — and the second must build on the
  /// first rather than on the list the parent has not yet re-rendered.
  late List<Person> _current = widget.value;

  /// True from a pick until the next option list is built. The SDK keeps the
  /// list a pick was made from and shows it again whenever the field regains
  /// focus, over a now-empty box; while this is set the overlay stays hidden
  /// and a pick from that leftover list is ignored.
  bool _stale = false;

  FocusNode get _node => widget.focusNode ?? (_ownNode ??= FocusNode());

  bool get _full {
    final max = widget.max;
    // A single-pick field replaces rather than fills up, so it is never full.
    return max != null && max > 1 && _current.length >= max;
  }

  @override
  void initState() {
    super.initState();
    _debounce = Debounced(delay: widget.debounce);
    _focused = _node.hasFocus;
    _node.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(RecipientsField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.value, widget.value)) _current = widget.value;
  }

  @override
  void dispose() {
    _node.removeListener(_onFocusChanged);
    _debounce.cancel();
    _text.dispose();
    _ownNode?.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    final focused = _node.hasFocus;
    if (focused != _focused && mounted) setState(() => _focused = focused);
    // Losing focus banks a valid typed address rather than dropping it. Text
    // that is not an address is left where it is: throwing away what somebody
    // typed because they clicked elsewhere is worse than a stale field.
    if (!focused && widget.allowTypedAddress) {
      final typed = _text.text.trim();
      if (isValidEmailAddress(typed)) _add(Person.typed(typed));
    }
  }

  // ── Options ───────────────────────────────────────────────────────────

  Future<Iterable<_RecipientOption>> _options(TextEditingValue value) async {
    final query = value.text.trim();
    if (_full) return const [];
    if (!await _debounce.settle()) return const [];
    if (!mounted) return const [];

    if (query.isEmpty) {
      _stale = false;
      _noteFlags(null);
      return const [];
    }

    RecipientResults results;
    try {
      results = await widget.search(query);
    } catch (_) {
      // `search` is documented not to throw; this is the belt to that braces,
      // because the SDK runs this method unawaited.
      results = (
        recents: const <Person>[],
        directory: const <Person>[],
        chats: const <Conversation>[],
        directoryOffline: true,
        scopeMissing: false,
      );
    }
    if (!mounted) return const [];
    _noteFlags((
      directoryOffline: results.directoryOffline,
      scopeMissing: results.scopeMissing,
    ));

    final options = <_RecipientOption>[];
    final seen = <String>{};
    for (final person in results.recents) {
      if (_isPicked(person) || !seen.add(person.id)) continue;
      options.add(_PersonOption(person, recentSection));
    }
    for (final person in results.directory) {
      if (_isPicked(person) || !seen.add(person.id)) continue;
      options.add(_PersonOption(person, directorySection));
    }

    // A typed address goes last on purpose: a recent or directory hit at the
    // same address is the better answer, and Enter takes the first option.
    if (widget.allowTypedAddress && isValidEmailAddress(query)) {
      final typed = Person.typed(query);
      final known = options.any(
        (option) =>
            option is _PersonOption &&
            option.person.addressKey == typed.addressKey,
      );
      if (!known && !_isPicked(typed)) {
        options.add(_PersonOption(typed, typedSection));
      }
    }

    if (widget.channel == RecipientChannel.teams &&
        widget.onChatPicked != null) {
      for (final chat in results.chats) {
        options.add(_ChatOption(chat));
      }
    }
    _stale = false;
    return options;
  }

  void _noteFlags(({bool directoryOffline, bool scopeMissing})? flags) {
    final current = _flags;
    if (current?.directoryOffline == flags?.directoryOffline &&
        current?.scopeMissing == flags?.scopeMissing) {
      return;
    }
    setState(() => _flags = flags);
  }

  /// Whether [person] is already a chip — by id, or by the address behind it,
  /// which is what collapses a typed address into its directory twin.
  bool _isPicked(Person person) {
    if (_current.contains(person)) return true;
    final key = person.addressKey;
    if (key.isEmpty) return false;
    return _current.any((picked) => picked.addressKey == key);
  }

  // ── Editing ───────────────────────────────────────────────────────────

  void _emit(List<Person> next) {
    _current = next;
    widget.onChanged(next);
  }

  void _add(Person person) {
    if (_isPicked(person)) {
      _text.clear();
      return;
    }
    if (widget.max == 1) {
      _emit([person]);
    } else if (_full) {
      _text.clear();
      return;
    } else {
      _emit([..._current, person]);
    }
    _text.clear();
  }

  void _remove(Person person) {
    _emit([
      for (final picked in _current)
        if (picked != person) picked,
    ]);
    _node.requestFocus();
  }

  void _onSelected(_RecipientOption option) {
    // A pick from the leftover list — Enter over a refocused, empty box —
    // would add somebody the overlay is no longer showing.
    if (_stale) return;
    _stale = true;
    _pickedBySubmit = true;
    switch (option) {
      case _PersonOption(:final person):
        _add(person);
      case _ChatOption(:final chat):
        _text.clear();
        widget.onChatPicked?.call(chat);
    }
  }

  /// A comma finishes an address, the way every mail client's To field does;
  /// so does a semicolon, which is what Outlook has taught this app's users.
  ///
  /// When what precedes the separator is not an address the separator is
  /// simply dropped and the text left alone — the alternative, refusing to
  /// type one at all, hides the rule instead of teaching it.
  void _onTextChanged(String text) {
    if (!widget.allowTypedAddress) return;
    if (!text.endsWith(',') && !text.endsWith(';')) return;
    final candidate = text.substring(0, text.length - 1).trim();
    if (isValidEmailAddress(candidate)) {
      _add(Person.typed(candidate));
    } else {
      _text.value = TextEditingValue(
        text: candidate,
        selection: TextSelection.collapsed(offset: candidate.length),
      );
    }
  }

  void _submit(VoidCallback onFieldSubmitted) {
    _pickedBySubmit = false;
    // Picks the highlighted option when the overlay is up, and does nothing
    // at all when it is not — which is the case this fall-through is for.
    onFieldSubmitted();
    if (_pickedBySubmit) return;
    final typed = _text.text.trim();
    if (widget.allowTypedAddress && isValidEmailAddress(typed)) {
      _add(Person.typed(typed));
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.backspace) {
      return KeyEventResult.ignored;
    }
    if (_text.text.isNotEmpty || _current.isEmpty) {
      return KeyEventResult.ignored;
    }
    _remove(_current.last);
    return KeyEventResult.handled;
  }

  // ── Rendering ─────────────────────────────────────────────────────────

  Widget _field(
    BuildContext context,
    TextEditingController controller,
    FocusNode focusNode,
    VoidCallback onFieldSubmitted,
  ) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => focusNode.requestFocus(),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: BondSpacing.s8,
          vertical: BondSpacing.s4,
        ),
        decoration: BoxDecoration(
          color: BondColors.surface,
          borderRadius: BondRadii.mdAll,
          border: Border.all(
            color: _focused ? BondColors.primaryDeep : BondColors.border,
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The text box needs a bounded width — a TextField inside a Wrap
            // is handed infinity and throws.
            final available = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : _fieldWidthBesideChips;
            final width = widget.value.isEmpty
                ? available
                : math.min(available, _fieldWidthBesideChips);
            return Wrap(
              spacing: BondSpacing.s4,
              runSpacing: BondSpacing.s4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final person in widget.value)
                  ConstrainedBox(
                    // A Wrap hands its children infinity, so a long name in a
                    // narrow field would spill out of the box it sits in.
                    constraints: BoxConstraints(maxWidth: available),
                    child: RecipientChip(
                      person: person,
                      onRemove: () => _remove(person),
                    ),
                  ),
                if (!_full)
                  SizedBox(
                    width: width,
                    child: Focus(
                      canRequestFocus: false,
                      skipTraversal: true,
                      onKeyEvent: _onKey,
                      child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        style: BondType.body,
                        textInputAction: TextInputAction.done,
                        keyboardType: widget.allowTypedAddress
                            ? TextInputType.emailAddress
                            : TextInputType.text,
                        decoration: InputDecoration(
                          hintText: widget.hint,
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 6,
                          ),
                        ),
                        onChanged: _onTextChanged,
                        onSubmitted: (_) => _submit(onFieldSubmitted),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _overlay(
    BuildContext context,
    AutocompleteOnSelected<_RecipientOption> onSelected,
    Iterable<_RecipientOption> options,
  ) {
    if (_stale) return const SizedBox.shrink();
    final highlighted = AutocompleteHighlightedOption.of(context);
    final rows = <Widget>[];
    String? section;
    var index = -1;
    for (final option in options) {
      index += 1;
      // The options this was built from can be a beat behind a pick, so a
      // person who became a chip in the meantime is dropped here too.
      if (option is _PersonOption && _isPicked(option.person)) continue;
      if (option.section != section) {
        section = option.section;
        rows.add(_sectionLabel(section));
      }
      rows.add(_optionRow(option, onSelected, index == highlighted));
    }
    if (rows.isEmpty) return const SizedBox.shrink();

    // The shadow sits OUTSIDE the clipping Material, as the home pane's pill
    // and the rail do it; inside, the clip would trim it to the rounded rect.
    return Align(
      alignment: Alignment.topLeft,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          boxShadow: BondShadows.overlay,
          borderRadius: BondRadii.mdAll,
        ),
        child: Material(
          color: BondColors.surface,
          elevation: 0,
          borderRadius: BondRadii.mdAll,
          clipBehavior: Clip.antiAlias,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: BondColors.border),
              borderRadius: BondRadii.mdAll,
            ),
            constraints: const BoxConstraints(maxHeight: _overlayMaxHeight),
            child: ListView(
              key: const Key('recipients-options'),
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: BondSpacing.s4),
              children: rows,
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String section) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BondSpacing.s12,
        BondSpacing.s8,
        BondSpacing.s12,
        BondSpacing.s4,
      ),
      child: Text(
        section,
        style: BondType.caption.copyWith(color: BondColors.inkMuted),
      ),
    );
  }

  Widget _optionRow(
    _RecipientOption option,
    AutocompleteOnSelected<_RecipientOption> onSelected,
    bool highlighted,
  ) {
    final (Key key, String primary, String? secondary, Widget leading) =
        switch (option) {
      // A person leads with their face; a chat leads with the icon that says
      // it is a room rather than somebody.
      _PersonOption(:final person) => (
          Key('recipient-option-${person.id}'),
          person.displayName.isNotEmpty ? person.displayName : person.address,
          _personSecondary(person),
          BondAvatar(
            name: person.displayName,
            address: person.address,
            size: _optionAvatarSize,
            photoKey: photoKeyFor(
              id: person.hasGraphId ? person.id : null,
              address: person.address,
            ),
            photos: widget.photos,
          ),
        ),
      _ChatOption(:final chat) => (
          Key('recipient-chat-${chat.id}'),
          _chatPrimary(chat),
          _chatSecondary(chat),
          const Icon(
            Icons.groups_outlined,
            size: 16,
            color: BondColors.inkSecondary,
          ),
        ),
    };

    final row = InkWell(
      key: key,
      onTap: () => onSelected(option),
      hoverColor: BondColors.faintGround,
      child: Container(
        color: highlighted ? BondColors.faintGround : Colors.transparent,
        padding: const EdgeInsets.symmetric(
          horizontal: BondSpacing.s12,
          vertical: BondSpacing.s8,
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: BondSpacing.s8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    primary,
                    style: BondType.small.copyWith(
                      color: BondColors.ink,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (secondary != null)
                    Text(
                      secondary,
                      style: BondType.caption.copyWith(
                        color: BondColors.inkSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    // Arrowing past the list's 280 px fold used to leave the highlight out of
    // sight. Scrolling it back is exactly what the SDK's own
    // `_AutocompleteOptions` does, and the `Builder` is what makes it possible:
    // the context that asks must be the ROW's, not the overlay's, or
    // `ensureVisible` scrolls the list to itself and nothing moves. EVERY row
    // wears the Builder, highlighted or not, so the highlight moving does not
    // change a slot's widget type and rebuild the row underneath it.
    //
    // The highlight moves one row per keystroke, so the row it lands on is
    // always within the list's cache extent and therefore already built. That
    // is what makes a post-frame ask from its own context enough — no
    // `ScrollController`, and no remount of the `RawAutocomplete`, which holds
    // an external `FocusNode` and leaks a listener on every one.
    return Builder(
      builder: (context) {
        if (highlighted) {
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            Scrollable.ensureVisible(context, alignment: 0.5);
          });
        }
        return row;
      },
    );
  }

  String? _personSecondary(Person person) {
    final address = person.address;
    final title = person.jobTitle;
    if (address.isEmpty) return title;
    return title == null ? address : '$address · $title';
  }

  String _chatPrimary(Conversation chat) {
    final subject = chat.subject;
    if (subject != null && subject.isNotEmpty) return subject;
    return _chatMembers(chat);
  }

  String? _chatSecondary(Conversation chat) {
    final subject = chat.subject;
    if (subject == null || subject.isEmpty) return null;
    final members = _chatMembers(chat);
    return members.isEmpty ? null : members;
  }

  String _chatMembers(Conversation chat) {
    final names = [for (final person in chat.participants) person.display];
    if (names.length <= 3) return names.join(', ');
    return '${names.take(3).join(', ')} +${names.length - 3}';
  }

  Widget? _footer() {
    final flags = _flags;
    if (flags == null) return null;
    final String message;
    if (flags.scopeMissing) {
      message = 'Directory search is not enabled for this account.';
    } else if (flags.directoryOffline) {
      message = 'The directory could not be reached; showing recent people.';
    } else {
      return null;
    }
    return Padding(
      key: const Key('recipients-footer'),
      padding: const EdgeInsets.only(top: BondSpacing.s4),
      child: Text(
        message,
        style: BondType.caption.copyWith(color: BondColors.inkMuted),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final footer = _footer();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        RawAutocomplete<_RecipientOption>(
          textEditingController: _text,
          focusNode: _node,
          // A pick leaves the field empty rather than spelling the person's
          // name into it: the chip already says who was picked, and the next
          // recipient is typed from scratch.
          displayStringForOption: (_) => '',
          optionsBuilder: _options,
          onSelected: _onSelected,
          fieldViewBuilder: _field,
          optionsViewBuilder: _overlay,
        ),
        ?footer,
      ],
    );
  }
}
