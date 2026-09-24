/// What a sender is CALLED on screen, as opposed to what the row stores.
///
/// A message keys its sender by address, and for Teams that address is a
/// `teams:<graph id>` pseudo-address rather than anything a person would
/// recognise — see `teamsAddress` in `teams_sync.dart`. Every place that showed
/// "the name, or the address when there is no name" therefore had one failure
/// in common: a chat sender Graph gave no display name for rendered as
/// `teams:8e55a7b1-…`, and the avatar beside it drew a "T".
///
/// This file is the one answer to that, and it is deliberately a LEAF: pure
/// functions, no imports, so the ingest path, the transcript, a list card and
/// the model prompt can all reach the same words without any of them reaching
/// each other. Ingest writes the best name it can ([botSenderName] for an
/// application Graph withheld a name for); these functions are the net under
/// it, which is what covers the rows already in the database without a
/// backfill.
library;

/// A sender nothing can be said about. The last rung of every ladder here.
const String unknownSenderName = 'Unknown sender';

/// What a bot or connector is called when it brought no name of its own.
///
/// A word rather than a name because that is the whole of what is known: the
/// message came from an application. Written at ingest by `TeamsSync` and read
/// back here by [isBotSender], which is what turns the initial into a glyph.
const String botSenderName = 'Bot';

/// The `teams:` namespace, spelled out here rather than imported from
/// `teams_sync.dart`, which would drag the whole connector — and the store it
/// imports — into every widget that needs a sender's name.
const String _teamsAddressPrefix = 'teams:';

/// Whether [address] is an internal identity key rather than something the
/// reader could write to.
///
/// Only Teams has one. A mail address is always showable, even when it is all
/// that is known about a sender.
bool isPseudoAddress(String? address) =>
    (address ?? '').trimLeft().startsWith(_teamsAddressPrefix);

/// The sender's name for the reader: the name, else the address when the
/// address is one a person would recognise, else [fallback].
///
/// The middle rung is the point. It is the behaviour every call site already
/// had — a bare mail address still identifies its sender — minus the one case
/// where it lies, a pseudo-address that identifies nobody.
///
/// [fallback] exists because the sites disagree about the last rung and are
/// right to: a transcript says `You` above the account's own message, and a
/// list card has said `(no sender)` since long before this file. Neither wants
/// its wording decided here; both want the pseudo-address gone.
String displaySenderName({
  String? name,
  String? address,
  String fallback = unknownSenderName,
}) {
  final named = (name ?? '').trim();
  if (named.isNotEmpty) return named;
  final addr = (address ?? '').trim();
  if (addr.isNotEmpty && !isPseudoAddress(addr)) return addr;
  return fallback;
}

/// Whether this sender is an application rather than a person.
///
/// Two signals, both about a Teams application. A row written since the ingest
/// ladder landed says so outright — its name IS [botSenderName], because that
/// is what `TeamsSync` writes when Graph hands over an application with no
/// display name. A row written BEFORE it is the same fact seen from the other
/// side: a Teams PERSON arrives from Graph with a display name essentially
/// always, so a chat sender that has an id and no name at all is the bot whose
/// name Graph withheld.
///
/// Deliberately a guess about presentation and nothing else. It decides which
/// glyph an avatar draws; nothing gates, files or prompts on it. A person
/// actually named `Bot` gets a robot for a face and loses nothing by it.
bool isBotSender({String? name, String? address}) {
  final named = (name ?? '').trim();
  if (named == botSenderName) return true;
  return named.isEmpty && isPseudoAddress(address);
}
