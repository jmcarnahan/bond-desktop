/// Which connector a row came from, as one character.
///
/// A text glyph and not an icon, deliberately. Every place this appears — a
/// rail row, a conversation card's subject, a storyline seam chip — is a
/// single line of text that already truncates, and an icon beside it would
/// need its own box, its own baseline alignment and its own colour decision in
/// three different layouts. A glyph is part of the string and inherits all
/// three for free.
library;

/// Mail. Only ever shown where the alternative is also shown, so a mailbox
/// with no Teams never renders it.
const String mailGlyph = '✉';

/// A Teams chat.
const String teamsGlyph = '💬';

/// [text] with a Teams glyph in front of it, and [text] untouched for anything
/// else.
///
/// Asymmetric on purpose: mail is what this app is, and a mailbox row that had
/// to announce it was mail would be marking the default. Only the exception
/// gets a mark.
String withSourceGlyph(String source, String text) =>
    source == 'teams' ? '$teamsGlyph $text' : text;

/// The prefix for a place that labels BOTH sources — the storyline timeline's
/// seam chips, where a thread and a chat sit in one merged transcript and the
/// reader has to be able to tell which is which at a glance.
String sourceChipPrefix(String source) =>
    source == 'teams' ? '$teamsGlyph ' : '$mailGlyph ';
