/// Text that Exchange adds to a message and the sender never wrote.
///
/// The one case today is the "first contact" safety tip. When mail arrives
/// from an address the mailbox has not heard from before, Exchange prepends
/// a line to the BODY — not a header, not a property, the body itself:
///
/// ```text
/// You don't often get email from dana@example.com. Learn why this is important<https://aka.ms/LearnAboutSenderIdentification>
/// ```
///
/// Outlook draws it as a banner; every other reader gets it as the opening
/// sentence. Here it opened every first message from a new sender in the
/// transcript, the preview on the rail, the search index, and — worse — the
/// prompts: a triage that summarises "the sender says you don't often get
/// email from them" has been handed a sentence the sender did not say. So it
/// is stripped at ingest, where the body first exists, and once over the
/// rows stored before this build.
library;

/// The tip, at the very start of a body or a preview. The link is rendered
/// three ways depending on which converter produced the text — angle
/// brackets, parentheses, or bare — and sometimes not at all; the apostrophe
/// is straight or curly; the whole line is sometimes wrapped in brackets.
/// Anything after "Learn why this is important" on that line goes with it,
/// and so do the blank lines under it, so the sender's first sentence comes
/// first.
///
/// Between "from" and "Learn why" Exchange puts ONE address and nothing else,
/// so that is all the pattern allows: a single run with no whitespace in it.
/// Anything looser matched a sender's own sentence — "You don't often get
/// email from me, so here is the update. Learn why this is important to us"
/// — and deleted it, in place, at ingest.
final RegExp _senderTip = RegExp(
  r"^\s*\[?You don['’]t often get email from \S{1,200}?\.?\s*"
  r"Learn why this is important[ \t]*(?:<[^>\n]*>|\([^)\n]*\)|https?://\S+)?"
  r"\]?[ \t.]*(?:\r?\n)*",
  caseSensitive: false,
);

/// [text] without Exchange's first-contact tip at its head. Unchanged when
/// the tip is not there — and unchanged when the words appear anywhere BUT
/// the head, because a person quoting the banner in a reply wrote those words
/// on purpose.
String stripSenderIdentification(String text) {
  final match = _senderTip.firstMatch(text);
  if (match == null) return text;
  return text.substring(match.end);
}
