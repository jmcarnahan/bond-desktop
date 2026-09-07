import 'package:bond_inbox/models/attachment_models.dart';

/// One attachment, with every field defaulted to the ordinary case.
///
/// A builder rather than a const literal per test: `AttachmentRef` has thirty
/// fields and a test that only cares about a name and a size should say only
/// those two. Everything fictional — this repository is public.
AttachmentRef ref({
  String source = 'email',
  String messageId = 'm1',
  String attachmentId = 'a1',
  int ordinal = 0,
  String kind = 'file',
  String? name = 'Contract.pdf',
  String? contentType = 'application/pdf',
  int size = 240 * 1024,
  bool isInline = false,
  String? contentId,
  String? sourceUrl,
  String? cardText,
  String textStatus = 'done',
  String? textReason,
  String digestStatus = 'done',
  AttachmentDigest? digest,
  String? thumbPath,
  String? conversationKey,
  String? pinnedStorylineId,
}) {
  return AttachmentRef(
    source: source,
    messageId: messageId,
    attachmentId: attachmentId,
    ordinal: ordinal,
    kind: kind,
    name: name,
    contentType: contentType,
    size: size,
    isInline: isInline,
    contentId: contentId,
    sourceUrl: sourceUrl,
    cardText: cardText,
    textStatus: textStatus,
    textReason: textReason,
    digestStatus: digestStatus,
    digest: digest,
    thumbPath: thumbPath,
    conversationKey: conversationKey,
    pinnedStorylineId: pinnedStorylineId,
  );
}

/// A picture, the way both connectors describe one.
AttachmentRef imageRef({
  String messageId = 'm1',
  String attachmentId = 'i1',
  int ordinal = 0,
  String? name = 'Screenshot.png',
  int size = 80 * 1024,
  bool isInline = true,
  String? contentId,
  String source = 'email',
}) =>
    ref(
      source: source,
      messageId: messageId,
      attachmentId: attachmentId,
      ordinal: ordinal,
      kind: 'image',
      name: name,
      contentType: 'image/png',
      size: size,
      isInline: isInline,
      contentId: contentId,
    );

/// A 1×1 transparent PNG, for a `MemoryImage` that decodes without touching a
/// disk. Flutter's own test suite uses the same trick.
const List<int> onePixelPng = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];
