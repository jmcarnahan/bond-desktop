import 'dart:convert';
import 'dart:typed_data';

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

    test('an Internet shortcut is text whatever its type says', () {
      // Gmail labels its Drive-link shortcut this way.
      expect(
        previewKindFor(ref(name: 'open.url', contentType: 'application/pdf')),
        PreviewKind.text,
      );
      expect(
        previewKindFor(ref(name: 'Deck.webloc', contentType: null)),
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

    test('a web page is its own kind, by name and by type', () {
      expect(
        previewKindFor(ref(name: 'security-report.html', contentType: null)),
        PreviewKind.html,
      );
      expect(previewKindFor(ref(name: 'Report.HTM')), PreviewKind.html);
      expect(previewKindFor(ref(name: 'page.xhtml')), PreviewKind.html);
      expect(
        previewKindFor(ref(name: null, contentType: 'text/html; charset=utf-8')),
        PreviewKind.html,
      );
      expect(
        previewKindFor(ref(name: null, contentType: 'application/xhtml+xml')),
        PreviewKind.html,
      );
    });

    test('text/html is answered before the text/ prefix rule', () {
      // `text/html` IS a text type, and reading it as one would show the reader
      // the markup rather than the report.
      expect(
        previewKindFor(ref(name: null, contentType: 'text/html')),
        PreviewKind.html,
        reason: 'not PreviewKind.text',
      );
      expect(
        previewKindFor(ref(name: null, contentType: 'text/plain')),
        PreviewKind.text,
        reason: 'the prefix rule still answers everything else',
      );
    });

    test('a chat file named .html is a page like any other', () {
      expect(
        previewKindFor(ref(
          source: 'teams',
          name: 'security-report.html',
          contentType: 'application/octet-stream',
          conversationKey: 'chat-1',
        )),
        PreviewKind.html,
        reason: 'Graph names a great many real files octet-stream',
      );
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
      // sheet and an `.html` still previews — drawn by the Runner's WebKit with
      // scripting and the network off, which is not the same act as handing the
      // file to whatever the operating system would run it with.
      expect(previewKindFor(ref(name: 'Budget.xlsm')), PreviewKind.sheet);
      expect(
        previewKindFor(ref(name: 'invoice.html', contentType: 'text/html')),
        PreviewKind.html,
      );
      expect(openRefused(ref(name: 'invoice.html')), isTrue);
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

  group('looksLikePdf', () {
    test('reads the header within the first 1024 bytes', () {
      expect(looksLikePdf(Uint8List.fromList(utf8.encode('%PDF-1.7\n'))), isTrue);
      expect(
        looksLikePdf(Uint8List.fromList(utf8.encode('\uFEFF  %PDF-1.4'))),
        isTrue,
      );
      expect(
        looksLikePdf(Uint8List.fromList(
          utf8.encode('${' ' * 1024}%PDF-1.4'),
        )),
        isFalse,
      );
      expect(
        looksLikePdf(Uint8List.fromList(
          utf8.encode('[InternetShortcut]\nURL=https://docs.example.com/x'),
        )),
        isFalse,
      );
      expect(looksLikePdf(Uint8List(0)), isFalse);
    });
  });

  group('shortcutUrlOf', () {
    test('a .url names its URL= line, in any case and either line ending', () {
      expect(
        shortcutUrlOf(
          'open.url',
          '[InternetShortcut]\r\nIDList=\r\nurl = https://docs.example.com/x \r\n',
        ),
        'https://docs.example.com/x',
      );
    });

    test('a .webloc names the string under its URL key', () {
      expect(
        shortcutUrlOf(
          'Deck.webloc',
          '<plist version="1.0"><dict><key>URL</key>\n<string>'
              'https://docs.example.com/d?a=1&amp;b=2</string></dict></plist>',
        ),
        'https://docs.example.com/d?a=1&b=2',
      );
    });

    test('anything but a web address names nothing', () {
      for (final target in [
        'javascript:alert(1)',
        'file:///Applications/x.app',
        'smb://fileserver/share',
      ]) {
        expect(
          shortcutUrlOf('open.url', '[InternetShortcut]\nURL=$target\n'),
          isNull,
          reason: target,
        );
      }
      // And a text file is not a shortcut, whatever it says.
      expect(shortcutUrlOf('notes.txt', 'URL=https://docs.example.com/x'),
          isNull);
    });
  });

  group('textOfBytes', () {
    test('words are words; a binary is not', () {
      expect(textOfBytes(Uint8List.fromList(utf8.encode('a\tb\r\n'))),
          'a\tb\r\n');
      expect(textOfBytes(Uint8List.fromList([0x61, 0xff])), isNull);
      expect(textOfBytes(Uint8List.fromList([0x61, 0x00, 0x62])), isNull);
    });
  });
}
