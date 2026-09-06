import 'package:bond_inbox/widgets/preview/preview_kind.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';

/// What a preview would have to be, for one file — and the three places the
/// answer is deliberately "nothing".
void main() {
  group('previewKindFor', () {
    test('the name decides where the content type will not', () {
      // Graph says this about a great many real documents.
      expect(
        previewKindFor(ref(
          name: 'Quote.xlsx',
          contentType: 'application/octet-stream',
        )),
        PreviewKind.sheet,
      );
      expect(
        previewKindFor(ref(
          name: 'Terms.pdf',
          contentType: 'application/octet-stream',
        )),
        PreviewKind.pdf,
      );
      expect(
        previewKindFor(ref(
          name: 'Notes.txt',
          contentType: 'application/octet-stream',
        )),
        PreviewKind.text,
      );
    });

    test('a file with no name falls back to what the connector said', () {
      expect(
        previewKindFor(ref(name: null, contentType: 'application/pdf')),
        PreviewKind.pdf,
      );
      expect(
        previewKindFor(ref(name: null, contentType: 'image/png')),
        PreviewKind.image,
      );
      expect(
        previewKindFor(ref(name: null, contentType: 'text/csv')),
        PreviewKind.text,
      );
      expect(
        previewKindFor(ref(name: null, contentType: null)),
        PreviewKind.unsupported,
      );
    });

    test('heic and tiff and xls say so', () {
      for (final name in ['Photo.heic', 'Scan.tiff', 'Ledger.xls']) {
        expect(
          previewKindFor(ref(name: name, contentType: null)),
          PreviewKind.unsupported,
          reason: name,
        );
      }
    });

    test('a reference is a link and never a fetch', () {
      for (final kind in ['reference', 'card', 'message_reference']) {
        expect(
          previewKindFor(ref(kind: kind, name: 'Budget.xlsx')),
          PreviewKind.link,
          reason: kind,
        );
      }
    });

    test('an item and a .eml are mail', () {
      expect(
        previewKindFor(ref(kind: 'item', name: 'Forwarded', contentType: null)),
        PreviewKind.eml,
      );
      expect(previewKindFor(ref(name: 'Thread.eml')), PreviewKind.eml);
      expect(
        previewKindFor(ref(name: null, contentType: 'message/rfc822')),
        PreviewKind.eml,
      );
    });

    test('a Word file is read through its words, not drawn', () {
      expect(previewKindFor(ref(name: 'Letter.docx')), PreviewKind.document);
      expect(previewKindFor(ref(name: 'Deck.pptx')), PreviewKind.document);
    });

    test('a picture is a picture', () {
      expect(previewKindFor(imageRef()), PreviewKind.image);
      expect(
        previewKindFor(ref(name: 'Site.JPG', contentType: null)),
        PreviewKind.image,
      );
    });
  });

  group('monoForName', () {
    test('a csv is mono and a txt is not', () {
      expect(monoForName('Rows.csv'), isTrue);
      expect(monoForName('rows.TSV'), isTrue);
      expect(monoForName('config.yaml'), isTrue);
      expect(monoForName('Letter.txt'), isFalse);
      expect(monoForName('Letter.md'), isFalse);
      expect(monoForName(null), isFalse);
    });
  });
}
