import '../../models/attachment_models.dart';

/// How much of one document's record reaches a prompt. A summary is one
/// sentence and the asks are short phrases; past this a digest is a model that
/// ignored its own instruction, and the line it wrote is not worth the
/// attention it would take from the message it describes.
const int _digestLineCap = 300;

/// One line per digested document: what it says, and what it wants.
///
/// [rows] are `attachments` rows as [MessageStore.digestsForMessages] hands
/// them over — every column, `digest_json` included. Rows with no readable
/// digest are skipped rather than rendered as a name with nothing after it:
/// "this file has not been read yet" and "this file says nothing" are
/// different states, and only the second is worth a line.
///
/// **No escaping here.** The name is the sender's own text and so is the
/// summary, and both go inside the caller's fence — every caller wraps the
/// joined lines in one `wrapUntrusted`, which is the one place the escaping
/// belongs. Escaping twice would put `&amp;lt;` in front of the model.
List<String> attachmentDigestLines(List<Map<String, Object?>> rows) {
  final lines = <String>[];
  for (final row in rows) {
    final digest = decodeAttachmentDigest(row['digest_json'] as String?);
    if (digest == null) continue;
    final name = (row['name'] as String?)?.trim() ?? '';
    final asks = [
      for (final ask in digest.asks)
        if (ask.trim().isNotEmpty) ask.trim(),
    ];
    final line = '${name.isEmpty ? 'a file' : name}: ${digest.summary}'
        '${asks.isEmpty ? '' : ' Asks: ${asks.join('; ')}'}';
    lines.add(
      line.length > _digestLineCap ? line.substring(0, _digestLineCap) : line,
    );
  }
  return lines;
}
