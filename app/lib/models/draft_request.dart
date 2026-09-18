import 'dart:convert';

/// What a person asked for when they queued a draft, carried on the work row's
/// `payload_json`.
///
/// One value with one encoder and one decoder, because the two ends used to be
/// written apart: `DraftNotifier.generate` built the map by hand and
/// `DraftHandler` read it back with two private readers, so a key added on one
/// side and misspelt on the other would have failed silently — the payload is
/// free-form, and "no ids named" is the ordinary answer.
///
/// [pinnedAttachmentIds] is "Use in reply", [contextFileIds] is "Consult for
/// the reply", and [asked] says a person pressed **Draft reply** rather than
/// the pipeline having prefetched this message.
class DraftRequest {
  /// The documents the user named with "Use in reply".
  final List<String> pinnedAttachmentIds;

  /// The directory files the user named with "Consult for the reply".
  final List<int> contextFileIds;

  /// Whether a person asked for this draft — **Draft reply** or **Regenerate**
  /// — rather than the pipeline having queued it on its own.
  final bool asked;

  const DraftRequest({
    this.pinnedAttachmentIds = const [],
    this.contextFileIds = const [],
    this.asked = false,
  });

  /// Nothing asked for: what an eager prefetch carries, and what every
  /// unreadable payload reads as.
  static const DraftRequest none = DraftRequest();

  /// Reads a stored payload, defensively to the point of paranoia.
  ///
  /// The payload is the one part of a work row that is free-form: anything
  /// that is not a JSON object reads as "nothing named", which is the ordinary
  /// case anyway. Each list is filtered to the values it could legitimately
  /// hold — a `pinned_attachment_ids` entry is a non-empty string, and a
  /// `context_files.id` is a positive integer, so a zero, a negative or a
  /// string is not an id — and `asked` is true only for the literal `true`, so
  /// a `"true"` somebody typed into the database by hand does not skip a
  /// judgement the model was supposed to make.
  ///
  /// A malformed payload costs the pinning, the consultation and the `asked`
  /// flag. It never costs the draft.
  factory DraftRequest.fromPayload(Object? payloadJson) {
    if (payloadJson is! String || payloadJson.isEmpty) return none;
    try {
      final decoded = jsonDecode(payloadJson);
      if (decoded is! Map) return none;
      final pinned = decoded['pinned_attachment_ids'];
      final files = decoded['context_file_ids'];
      return DraftRequest(
        pinnedAttachmentIds: pinned is! List
            ? const []
            : [
                for (final id in pinned)
                  if (id is String && id.isNotEmpty) id,
              ],
        contextFileIds: files is! List
            ? const []
            : [
                for (final id in files)
                  if (id is int && id > 0) id,
              ],
        asked: decoded['asked'] == true,
      );
    } on FormatException {
      return none;
    }
  }

  /// This request as a payload, or null when there is nothing in it.
  ///
  /// Null rather than `{}` so an eager row keeps the null payload it has
  /// always had, and only the keys that carry something are written: a
  /// consulted file and a pinned document never have to be asked for together
  /// to be asked for at all.
  String? encode() {
    if (pinnedAttachmentIds.isEmpty && contextFileIds.isEmpty && !asked) {
      return null;
    }
    return jsonEncode({
      if (pinnedAttachmentIds.isNotEmpty)
        'pinned_attachment_ids': pinnedAttachmentIds,
      if (contextFileIds.isNotEmpty) 'context_file_ids': contextFileIds,
      if (asked) 'asked': true,
    });
  }
}
