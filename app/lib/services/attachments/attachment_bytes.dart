import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;

import '../../data/message_store.dart';
import '../../models/attachment_models.dart';
import '../backend/attachment_backend.dart';
import 'attachment_cache.dart';

/// The MCP server's bytes-mode ceiling, and the number a preview test means
/// when it says "too large".
///
/// **Not the live cap.** What actually decides is
/// [AttachmentBytes.maxPreviewBytes], which comes from whichever connector is
/// wired: the server refuses above this because the payload rides back base64
/// inside one JSON reply, while the SDK path streams and can go further. This
/// const stays exported as the MCP number, so a test that wants a file over the
/// default cap has one figure to reach for.
const int attachmentTooLargeBytes = 10 * 1024 * 1024;

/// Turning a document's first page into a picture.
///
/// A typedef rather than a call, because the engine that can do it is pdfrx and
/// pdfium must never be reachable from `services/` — importing it here would
/// put a native library inside every `flutter test` that touches an attachment.
/// `main.dart` hands the real one in at startup; everything else gets null and
/// simply has no thumbnail.
typedef PdfThumbnailer = Future<Uint8List?> Function(
  Uint8List pdfBytes, {
  int maxWidth,
});

/// Bytes, paths, thumbnails and words for one attachment, cache first.
///
/// The interface exists so the UI can be handed a fake: every widget in the
/// preview stack takes this and never a backend, so a widget test renders a
/// PDF panel without a socket, an isolate or a plugin.
///
/// The throwing/not-throwing split is deliberate and load-bearing:
///
/// - [bytesFor] and [pathFor] **throw**. They run off a click, the panel has an
///   error state and a Try again button, and swallowing the reason would leave
///   a spinner that never resolves.
/// - [thumbnailFor] and [textFor] **never throw**. They run off a row
///   RENDERING. A list that threw because a picture was missing would take out
///   the thread around it, so a failure there is null and the row draws its
///   placeholder.
abstract interface class AttachmentBytes {
  /// The largest file the wired connector will hand over. A panel reads it to
  /// say how big a refused file is rather than guessing at a constant.
  int get maxPreviewBytes;

  /// The file's bytes: cache, then the connector, then the cache again.
  Future<Uint8List> bytesFor(AttachmentRef ref);

  /// Where the file is on this disk, fetching it first if it is not there.
  /// What Open hands to the operating system.
  Future<String> pathFor(AttachmentRef ref);

  /// A small picture of the file, or null when there is not going to be one.
  Future<Uint8List?> thumbnailFor(AttachmentRef ref);

  /// The words the pipeline extracted, or null while there are none.
  Future<String?> textFor(AttachmentRef ref);
}

/// The real one: an [AttachmentCache] on disk, an [AttachmentBackend] on the
/// wire, and a [MessageStore] remembering where the bytes went.
///
/// **Nothing in this file may ever be called from a timer.** Microsoft's Teams
/// terms allow this app to read a chat because a person is looking at it, and
/// every fetch here has to trace to that person: a row rendering in an open
/// thread, a chip clicked, a Save chosen. A background prefetch of a chat's
/// attachments would break the terms the whole Teams integration stands on,
/// which is why there is no warm-up method here and no schedule anywhere that
/// calls one.
class StoreAttachmentBytes implements AttachmentBytes {
  /// The three collaborators, held by their public names because Dart forbids
  /// a named parameter starting with an underscore and these are required
  /// named arguments — the alternative is three initializer-list assignments
  /// the analyzer flags.
  final MessageStore store;
  final AttachmentBackend backend;
  final AttachmentCache cache;

  /// How a PDF gets a picture, or null when nothing in this build can draw
  /// one. Optional and null by default so that no test and no provider build
  /// reaches pdfium; `main.dart` is the one place that supplies it.
  final PdfThumbnailer? pdfThumbnailer;

  StoreAttachmentBytes({
    required this.store,
    required this.backend,
    required this.cache,
    this.pdfThumbnailer,
  });

  @override
  int get maxPreviewBytes => backend.maxPreviewBytes;

  /// The widest a thumbnail gets. Two of them side by side at this width fill
  /// the row's content column on a retina display, and anything larger is
  /// pixels nobody sees paid for on every scroll.
  static const int _thumbnailWidth = 320;

  /// Kinds that are a POINTER to something that is not a file at all.
  ///
  /// A card is a rendering of a message, a `message_reference` is a quote of
  /// one, and `other` is whatever the connector could not name. None of the
  /// three has bytes anywhere, so asking for them is a category error and
  /// answers so immediately, with no request.
  ///
  /// `reference` is deliberately NOT here. A mail link is a real file that
  /// lives in OneDrive or SharePoint, and both connectors fetch it by its url
  /// — the same way a chat's shared file has always been fetched.
  static const Set<String> _linkKinds = {
    'card',
    'message_reference',
    'other',
  };

  /// One in-flight fetch per attachment, keyed by identity.
  ///
  /// Two rows can want the same file in the same frame — an image quoted down
  /// a thread, a chip and its thumbnail — and without this they would each
  /// spend a download to write the same bytes to the same path. The entry is
  /// removed when the future settles, so a failure is retried rather than
  /// remembered.
  final Map<String, Future<_Blob>> _inFlight = {};

  @override
  Future<Uint8List> bytesFor(AttachmentRef ref) async =>
      (await _ensure(ref)).bytes;

  @override
  Future<String> pathFor(AttachmentRef ref) async => (await _ensure(ref)).path;

  @override
  Future<String?> textFor(AttachmentRef ref) async {
    try {
      return await store.attachmentTextOf(
        ref.source,
        ref.messageId,
        ref.attachmentId,
      );
    } on Object catch (e) {
      debugPrint('attachment text read failed for ${_keyOf(ref)}: $e');
      return null;
    }
  }

  @override
  Future<Uint8List?> thumbnailFor(AttachmentRef ref) async {
    try {
      final existing = await _storedThumbnail(ref);
      if (existing != null) return existing;

      if (_isDrawableImage(ref)) return await _imageThumbnail(ref);

      // A file that lives on a drive is rendered by the drive, which costs one
      // small fetch — so it goes FIRST for a chat's shared file and for a mail
      // link, before the PDF branch, which would download the whole document
      // just to draw its first page. The PDF branch is the fallback when the
      // drive has no rendering to give.
      if ((ref.source != 'email' && ref.kind == 'file') ||
          ref.kind == 'reference') {
        try {
          final rendered = await _renderedThumbnail(ref);
          if (rendered != null) return rendered;
        } on AttachmentUnavailable {
          // "The drive has no rendering to give" arrives as a refusal
          // (`no_thumbnail`), not as an empty answer. That is exactly the case
          // the PDF branch below exists for, so it must not end the ladder.
        }
      }

      // A mail PDF has nothing to render it but this build. The bytes are the
      // same ones the preview will want, and they are cached, so the download
      // is paid once.
      if (pdfThumbnailer != null && _isPdf(ref)) {
        return await _pdfThumbnail(ref);
      }
      return null;
    } on Object catch (e) {
      // Every failure is null. This runs while a list is building.
      debugPrint('thumbnail failed for ${_keyOf(ref)}: $e');
      return null;
    }
  }

  // ── The ladder ────────────────────────────────────────────────────────

  /// The file, however it has to be got, with its in-flight guard.
  Future<_Blob> _ensure(AttachmentRef ref) {
    final key = _keyOf(ref);
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final started = _fetch(ref);
    _inFlight[key] = started;
    return started.whenComplete(() => _inFlight.remove(key));
  }

  Future<_Blob> _fetch(AttachmentRef ref) async {
    if (_linkKinds.contains(ref.kind)) {
      throw const AttachmentUnavailable('link');
    }

    // The ref's own path, when it has one.
    final onRef = await _blobAt(ref.blobPath, ref.blobSha256);
    if (onRef != null) return onRef;

    // The row's, when it does not. A ref built before the fetch — the chip that
    // started it, a Message hydrated a frame earlier — carries no path, and
    // re-reading the row is one indexed lookup against a second download.
    final row = await store.attachmentRow(
      ref.source,
      ref.messageId,
      ref.attachmentId,
    );
    if (row != null) {
      final onRow = await _blobAt(
        row['blob_path'] as String?,
        row['blob_sha256'] as String?,
      );
      if (onRow != null) return onRow;
    }

    // Refused before the request, on the size the connector claimed and
    // against the ceiling that same connector states. The preview says how big
    // it is and offers Open instead.
    if (ref.size > backend.maxPreviewBytes) {
      throw const AttachmentUnavailable('too_large');
    }

    final fetched = await backend.fetchBytes(ref);
    final stored = await cache.put(fetched.bytes, name: ref.name ?? fetched.name);
    await store.setAttachmentBlob(
      ref.source,
      ref.messageId,
      ref.attachmentId,
      blobPath: stored.path,
      blobSha256: stored.sha256,
    );
    return _Blob(fetched.bytes, stored.path, stored.sha256);
  }

  /// A cached file, or null when the path is empty or the file is gone — which
  /// is the ordinary way an eviction is discovered.
  Future<_Blob?> _blobAt(String? path, String? sha) async {
    if (path == null || path.isEmpty) return null;
    final bytes = await cache.read(path);
    if (bytes == null) return null;
    return _Blob(bytes, path, sha ?? _shaFromPath(path));
  }

  // ── Thumbnails ────────────────────────────────────────────────────────

  /// What an earlier pass already rendered, from the ref or from the row.
  Future<Uint8List?> _storedThumbnail(AttachmentRef ref) async {
    final onRef = await cache.read(ref.thumbPath ?? '');
    if (onRef != null) return onRef;
    final row = await store.attachmentRow(
      ref.source,
      ref.messageId,
      ref.attachmentId,
    );
    final path = row?['thumb_path'] as String?;
    if (path == null || path.isEmpty) return null;
    return cache.read(path);
  }

  /// A picture, shrunk to [_thumbnailWidth] and kept beside its blob.
  Future<Uint8List?> _imageThumbnail(AttachmentRef ref) async {
    final blob = await _ensure(ref);
    final small = await _downscale(blob.bytes);
    final path = await cache.putThumbnail(blob.sha, small);
    await store.setAttachmentBlob(
      ref.source,
      ref.messageId,
      ref.attachmentId,
      thumbPath: path,
    );
    return small;
  }

  /// A PDF's first page, drawn by whatever engine the app wired in.
  ///
  /// Refused above the connector's ceiling BEFORE the fetch, like every other
  /// read: a thumbnail is worth a download of an ordinary document and never
  /// worth one of a hundred-megabyte scan.
  Future<Uint8List?> _pdfThumbnail(AttachmentRef ref) async {
    if (ref.size > backend.maxPreviewBytes) return null;
    final blob = await _ensure(ref);
    final drawn = await pdfThumbnailer!(blob.bytes, maxWidth: _thumbnailWidth);
    // A page the engine could not draw is not a failure worth a placeholder of
    // its own — the chip's glyph already says what the file is.
    if (drawn == null) return null;
    final path = await cache.putThumbnail(blob.sha, drawn);
    await store.setAttachmentBlob(
      ref.source,
      ref.messageId,
      ref.attachmentId,
      thumbPath: path,
    );
    return drawn;
  }

  /// OneDrive's own rendering of a file that lives on a drive — a chat's
  /// shared file, a mail link.
  ///
  /// Named by the attachment's IDENTITY rather than by a digest of its bytes:
  /// there is no blob to hash — the file itself was never downloaded, which is
  /// the entire point of asking for a rendering.
  Future<Uint8List?> _renderedThumbnail(AttachmentRef ref) async {
    final result = await backend.fetchBytes(ref, thumbnail: 'small');
    if (result.bytes.isEmpty) return null;
    final name = AttachmentCache.hashOf(
      Uint8List.fromList(utf8.encode(_keyOf(ref))),
    );
    final path = await cache.putThumbnail(name, result.bytes);
    await store.setAttachmentBlob(
      ref.source,
      ref.messageId,
      ref.attachmentId,
      thumbPath: path,
    );
    return result.bytes;
  }

  /// [bytes] as a PNG at most [_thumbnailWidth] wide.
  ///
  /// An image already that narrow is returned UNTOUCHED — never upscaled and
  /// never re-encoded. Re-encoding a 1×1 tracking pixel through the raster
  /// pipeline would produce a larger file than the original and lose whatever
  /// the original was (a GIF's animation, a JPEG's exact colours) to buy
  /// nothing.
  static Future<Uint8List> _downscale(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width <= _thumbnailWidth) return bytes;

      final codec = await descriptor.instantiateCodec(
        targetWidth: _thumbnailWidth,
      );
      final frame = await codec.getNextFrame();
      try {
        final data = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        // A frame that will not encode is not a thumbnail worth inventing; the
        // original is still a picture of the right thing.
        return data == null ? bytes : data.buffer.asUint8List();
      } finally {
        frame.image.dispose();
        codec.dispose();
      }
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  /// Whether Flutter can decode this into a picture. Narrower than the chip's
  /// glyph table on purpose — heic and tiff ARE images and are not drawable.
  static bool _isDrawableImage(AttachmentRef ref) {
    if (_linkKinds.contains(ref.kind)) return false;
    if (ref.kind == 'image') return true;
    return (ref.contentType ?? '').toLowerCase().startsWith('image/');
  }

  /// Whether this is a PDF. The content type first, because it is what the
  /// connector actually asserts; the name second, because Graph reports
  /// `application/octet-stream` for a great many real documents.
  static bool _isPdf(AttachmentRef ref) {
    if (_linkKinds.contains(ref.kind)) return false;
    final type = (ref.contentType ?? '').split(';').first.trim().toLowerCase();
    if (type == 'application/pdf') return true;
    return (ref.name ?? '').trim().toLowerCase().endsWith('.pdf');
  }

  static String _keyOf(AttachmentRef ref) =>
      '${ref.source}|${ref.messageId}|${ref.attachmentId}';

  /// The digest a cached path asserts: the file name is the hash, plus an
  /// extension the cache may have kept. Only a fallback — the row's own
  /// `blob_sha256` is the answer whenever it has one.
  static String _shaFromPath(String path) {
    final base = path.split(RegExp(r'[/\\]')).last;
    final dot = base.indexOf('.');
    return dot <= 0 ? base : base.substring(0, dot);
  }
}

/// One cached file: what it says, where it is, and what it hashes to.
class _Blob {
  final Uint8List bytes;
  final String path;
  final String sha;

  const _Blob(this.bytes, this.path, this.sha);
}
