import 'dart:typed_data';

import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/services/attachments/attachment_bytes.dart';
import 'package:bond_inbox/services/backend/attachment_backend.dart';

/// The bytes seam, scripted, for every widget above it.
///
/// A preview panel takes an [AttachmentBytes] and never a backend, a cache or a
/// store, which is what lets a widget test render a PDF panel with no socket,
/// no isolate and no plugin. This is the thing it is handed.
///
/// The counters exist for the tests that are about how OFTEN something is
/// asked: Try again re-running a failed fetch, a rebuild not re-fetching what
/// it already drew.
class FakeAttachmentBytes implements AttachmentBytes {
  final Map<String, Uint8List> bytesByKey = {};
  final Map<String, Uint8List> thumbnailsByKey = {};
  final Map<String, String> textByKey = {};
  final Map<String, String> pathsByKey = {};

  int bytesCalls = 0;
  int pathCalls = 0;
  int thumbnailCalls = 0;
  int textCalls = 0;

  /// Thrown by the next [bytesFor] or [pathFor]. The panel's error state and
  /// its Try again button are the only reason this exists.
  Object? throwOnBytes;

  /// What a panel reads to say how big a refused file was. Settable for the
  /// same reason the backend's is: the cap belongs to the connector.
  @override
  int maxPreviewBytes = 10 * 1024 * 1024;

  static String keyOf(AttachmentRef ref) =>
      '${ref.source}|${ref.messageId}|${ref.attachmentId}';

  @override
  Future<Uint8List> bytesFor(AttachmentRef ref) async {
    bytesCalls++;
    final failure = throwOnBytes;
    if (failure != null) throw failure;
    final bytes = bytesByKey[keyOf(ref)];
    if (bytes == null) throw const AttachmentUnavailable('empty');
    return bytes;
  }

  @override
  Future<String> pathFor(AttachmentRef ref) async {
    pathCalls++;
    final failure = throwOnBytes;
    if (failure != null) throw failure;
    final path = pathsByKey[keyOf(ref)];
    if (path == null) throw const AttachmentUnavailable('empty');
    return path;
  }

  /// Never throws, exactly like the real one: a row rendering must not be able
  /// to take out the list around it.
  @override
  Future<Uint8List?> thumbnailFor(AttachmentRef ref) async {
    thumbnailCalls++;
    return thumbnailsByKey[keyOf(ref)];
  }

  @override
  Future<String?> textFor(AttachmentRef ref) async {
    textCalls++;
    return textByKey[keyOf(ref)];
  }
}
