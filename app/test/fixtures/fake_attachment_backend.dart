import 'dart:typed_data';

import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/services/backend/attachment_backend.dart';

/// A connector that answers from maps and counts what it was asked.
///
/// The counters are the point of most tests that use it: "a second read costs
/// no fetch" and "two readers asking at once fetch once" are both statements
/// about [fetchCalls] and about nothing else, and neither could be made against
/// a real backend without a socket.
///
/// Keyed by `'<source>|<message id>|<attachment id>'`, the same identity
/// `StoreAttachmentBytes` de-duplicates on.
class FakeAttachmentBackend implements AttachmentBackend {
  /// What each attachment's bytes are. A key with no entry answers with an
  /// empty payload rather than throwing — a test about counting fetches should
  /// not have to describe the file.
  final Map<String, Uint8List> bytesByKey = {};

  /// What each attachment says. Absent means [AttachmentText.skipped] with
  /// `empty`.
  final Map<String, AttachmentText> textByKey = {};

  int fetchCalls = 0;
  int textCalls = 0;

  /// Every `thumbnail` argument seen, in order — `''` for the file itself and
  /// a size word for a rendering.
  final List<String> thumbnailWords = [];

  /// Thrown by the next [fetchBytes], whatever it is. Set to an
  /// `AttachmentUnavailable` for a refusal or a `GraphMailException` for a
  /// transport failure; left null for the ordinary case.
  Object? throwOnFetch;

  /// The ceiling this connector claims. Settable because the cap is a property
  /// of the connector now — the MCP server answers 10 MiB and the SDK path
  /// 25 MiB — and a test about the cap has to be able to be either of them.
  @override
  int maxPreviewBytes = 10 * 1024 * 1024;

  static String keyOf(AttachmentRef ref) =>
      '${ref.source}|${ref.messageId}|${ref.attachmentId}';

  @override
  Future<AttachmentText> extractText(AttachmentRef ref) async {
    textCalls++;
    return textByKey[keyOf(ref)] ?? const AttachmentText.skipped('empty');
  }

  @override
  Future<AttachmentBytesResult> fetchBytes(
    AttachmentRef ref, {
    String thumbnail = '',
  }) async {
    fetchCalls++;
    thumbnailWords.add(thumbnail);
    final failure = throwOnFetch;
    if (failure != null) throw failure;
    return AttachmentBytesResult(
      bytesByKey[keyOf(ref)] ?? Uint8List(0),
      contentType: ref.contentType,
      name: ref.name,
    );
  }
}
