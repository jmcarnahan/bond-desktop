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

    test('a card or a quoted message is a link and never a fetch', () {
      for (final kind in ['card', 'message_reference']) {
        expect(
          previewKindFor(ref(kind: kind, name: 'Budget.xlsx')),
          PreviewKind.link,
          reason: kind,
        );
      }
    });

    test('a link named .pdf previews as a PDF', () {
      // A mail link is a real file kept on a drive, so its name decides what
      // it previews as, exactly as an attached file's would.
      expect(
        previewKindFor(ref(kind: 'reference', name: 'Budget.pdf')),
        PreviewKind.pdf,
      );
      expect(
        previewKindFor(
          ref(kind: 'reference', name: 'Photo.png', contentType: null),
        ),
        PreviewKind.image,
      );
      expect(
        previewKindFor(
          ref(kind: 'reference', name: 'Budget.xlsx', contentType: null),
        ),
        PreviewKind.sheet,
      );
    });

    test('a link with no readable name stays a link', () {
      // An extensionless SharePoint url is still worth the link out, which
      // `unsupported` would not offer.
      expect(
        previewKindFor(
          ref(kind: 'reference', name: 'Shared item', contentType: null),
        ),
        PreviewKind.link,
      );
      expect(
        previewKindFor(ref(kind: 'reference', name: null, contentType: null)),
        PreviewKind.link,
      );
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

  group('openRefused', () {
    test('anything the operating system would RUN is Save-only', () {
      // macOS opens a `.command` by handing it to Terminal.
      expect(openRefused(ref(name: 'invoice.command')), isTrue);
      expect(openRefused(ref(name: 'setup.exe')), isTrue);
      expect(openRefused(ref(name: 'Installer.dmg')), isTrue);
      expect(openRefused(ref(name: 'build.sh')), isTrue);
    });

    test('a macro document runs its macros on open', () {
      expect(openRefused(ref(name: 'Budget.xlsm')), isTrue);
      expect(openRefused(ref(name: 'Letter.docm')), isTrue);
    });

    test('a web page from a local origin can ask for a password', () {
      expect(openRefused(ref(name: 'invoice.html')), isTrue);
      expect(openRefused(ref(name: 'logo.svg')), isTrue);
      expect(
        openRefused(ref(name: null, contentType: 'text/html; charset=utf-8')),
        isTrue,
      );
    });

    test('the ordinary documents are untouched', () {
      expect(openRefused(ref(name: 'Quote.pdf')), isFalse);
      expect(openRefused(ref(name: 'Letter.docx')), isFalse);
      expect(openRefused(ref(name: 'Budget.xlsx')), isFalse);
      expect(openRefused(imageRef()), isFalse);
      expect(openRefused(ref(name: 'notes.txt', contentType: 'text/plain')),
          isFalse);
      expect(
        openRefused(ref(name: null, contentType: 'application/pdf')),
        isFalse,
      );
    });

    test('a preview is not an open — the kinds are unchanged', () {
      // Reading a file is not running it, so an `.xlsm` still renders as a
      // sheet and an `.html` still shows as text.
      expect(previewKindFor(ref(name: 'Budget.xlsm')), PreviewKind.sheet);
      expect(
        previewKindFor(ref(name: 'invoice.html', contentType: 'text/html')),
        PreviewKind.text,
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
