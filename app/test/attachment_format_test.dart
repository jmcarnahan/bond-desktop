import 'package:bond_inbox/widgets/attachment_format.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';

/// How a file says how big it is, what it is, and which file it is.
void main() {
  group('formatBytes', () {
    test('says nothing when nobody said how big', () {
      expect(formatBytes(null), '');
      expect(formatBytes(0), '');
      expect(formatBytes(-1), '');
    });

    test('one unit, never two', () {
      expect(formatBytes(900), '900 B');
      expect(formatBytes(2048), '2 KB');
      expect(formatBytes(1468006), '1.4 MB');
      expect(formatBytes(23 * 1024 * 1024), '23 MB');
      expect(formatBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    });

    test('a decimal only while it means something', () {
      expect(formatBytes(1536), '2 KB');
      expect(formatBytes((9.5 * 1024 * 1024).round()), '9.5 MB');
      expect(formatBytes((10.4 * 1024 * 1024).round()), '10 MB');
    });

    test('a size just shy of the next unit does not overflow into it', () {
      expect(formatBytes(1024 * 1024 - 1), '1.0 MB');
      expect(formatBytes(1024 * 1024 * 1024 - 1), '1.0 GB');
    });
  });

  group('attachmentGlyph', () {
    test('reads the name before the content type', () {
      // What Graph actually says about a great many real documents.
      expect(
        attachmentGlyph('file', 'application/octet-stream',
            name: 'Q3 forecast.xlsx'),
        '📊',
      );
      expect(
        attachmentGlyph('file', 'application/octet-stream', name: 'Terms.pdf'),
        '📕',
      );
    });

    test('falls back to the content type when the name says nothing', () {
      expect(attachmentGlyph('file', 'application/pdf', name: 'download'), '📕');
      expect(attachmentGlyph('file', 'image/png'), '🖼');
      expect(attachmentGlyph('file', 'message/rfc822'), '✉');
    });

    test('and to the kind when neither says anything', () {
      expect(attachmentGlyph('reference', null), '🔗');
      expect(attachmentGlyph('message_reference', null), '🔗');
      expect(attachmentGlyph('card', null), '🔗');
      expect(attachmentGlyph('item', null), '✉');
      expect(attachmentGlyph('image', null), '🖼');
      expect(attachmentGlyph('file', null), '📎');
      expect(attachmentGlyph('unknown', 'application/octet-stream'), '📎');
    });

    test('an upper-case name is the same file', () {
      expect(attachmentGlyph('file', null, name: 'DECK.PPTX'), '📽');
    });
  });

  group('isImageAttachment', () {
    test('the kind, the content type or the name will do', () {
      expect(isImageAttachment(ref(kind: 'image', contentType: null)), isTrue);
      expect(
        isImageAttachment(ref(name: 'no-extension', contentType: 'image/jpeg')),
        isTrue,
      );
      expect(
        isImageAttachment(
            ref(name: 'photo.JPG', contentType: 'application/octet-stream')),
        isTrue,
      );
    });

    test('a document is not a picture, whatever it is called', () {
      expect(isImageAttachment(ref()), isFalse);
      expect(isImageAttachment(ref(name: 'notes.txt', contentType: null)),
          isFalse);
    });

    test('what Flutter cannot decode is not drawn from its name alone', () {
      expect(
        isImageAttachment(ref(name: 'scan.heic', contentType: null, kind: 'file')),
        isFalse,
      );
    });
  });

  group('sameAttachment', () {
    test('compares the pair of ids and nothing else', () {
      final a = ref(digestStatus: 'pending');
      final b = ref(digestStatus: 'done', name: 'Contract (final).pdf');
      expect(sameAttachment(a, b), isTrue);
    });

    test('a different file on the same message is a different file', () {
      expect(sameAttachment(ref(), ref(attachmentId: 'a2')), isFalse);
      expect(sameAttachment(ref(), ref(messageId: 'm2')), isFalse);
    });

    test('nothing selected matches nothing', () {
      expect(sameAttachment(null, ref()), isFalse);
      expect(sameAttachment(ref(), null), isFalse);
      expect(sameAttachment(null, null), isFalse);
    });
  });

  group('attachmentKey', () {
    test('is the message and the attachment, never the ordinal', () {
      expect(
        attachmentKey('preview', ref(ordinal: 7)),
        attachmentKey('preview', ref(ordinal: 2)),
      );
    });

    test('the prefix keeps two widgets over one file apart', () {
      expect(
        attachmentKey('preview', ref()) == attachmentKey('viewer', ref()),
        isFalse,
      );
    });
  });

  group('extensionOf', () {
    test('lower-cased, without the dot', () {
      expect(extensionOf('Report.PDF'), 'pdf');
      expect(extensionOf('archive.tar.gz'), 'gz');
    });

    test('nothing for a name that has none', () {
      expect(extensionOf(null), '');
      expect(extensionOf('README'), '');
      expect(extensionOf('.gitignore'), '');
      expect(extensionOf('trailing.'), '');
    });
  });
}
