import 'dart:io';
import 'dart:typed_data';

import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/services/attachments/html_open.dart';
import 'package:bond_inbox/services/backend/attachment_backend.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';
import 'fixtures/fake_attachment_bytes.dart';

/// The one narrower door: a page written somewhere readable and handed to the
/// browser, with the name sanitised on the way.
///
/// No browser is launched here — the launcher is a seam and this test holds the
/// other end of it — and nothing below asserts anything about the generic Open,
/// which stays refused for a page.
///
/// The temp root is a seam too, so the sweep below runs over this test's own
/// directory and never over the machine's.
void main() {
  late FakeAttachmentBytes bytes;
  late Directory root;

  /// The parent every page directory lands in, under [root].
  Directory pages() =>
      Directory('${root.path}${Platform.pathSeparator}$pagesFolderName');

  /// The page directories that exist right now, by name.
  List<String> pageFolders() => pages()
      .listSync(followLinks: false)
      .whereType<Directory>()
      .map((d) => d.path.split(Platform.pathSeparator).last)
      .toList();

  setUp(() {
    bytes = FakeAttachmentBytes();
    // In setUp and synchronous, never awaited inside a test body (app/CLAUDE.md).
    root = Directory.systemTemp.createTempSync('bond-open-test');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('htmlFileNameFor', () {
    test('an ordinary name keeps its stem and gains the suffix once', () {
      expect(htmlFileNameFor('security-report.html'), 'security-report.html');
      expect(htmlFileNameFor('Access Review.HTM'), 'Access Review.html');
      expect(htmlFileNameFor('report.xhtml'), 'report.html');
      expect(htmlFileNameFor('report'), 'report.html');
    });

    test('a name that is a path becomes a name', () {
      // The connector stores the sender's string verbatim, and this one is a
      // write two directories up from wherever the temp folder is.
      expect(htmlFileNameFor('../../etc/passwd.html'), 'etcpasswd.html');
      expect(htmlFileNameFor('/tmp/evil.html'), 'tmpevil.html');
      expect(htmlFileNameFor(r'C:\Windows\evil.html'), 'CWindowsevil.html');
    });

    test('a hidden file is not what the browser should open', () {
      expect(htmlFileNameFor('.profile.html'), 'profile.html');
      expect(htmlFileNameFor('   .hidden'), 'hidden.html');
    });

    test('control characters go', () {
      expect(htmlFileNameFor('re\nport\u0000.html'), 'report.html');
    });

    test('nothing usable is still a page', () {
      expect(htmlFileNameFor(null), 'page.html');
      expect(htmlFileNameFor(''), 'page.html');
      expect(htmlFileNameFor('.html'), 'page.html');
      expect(htmlFileNameFor('///'), 'page.html');
    });

    test('a very long name is cut without splitting a character', () {
      final long = '${'a' * 40}🌐${'b' * 40}.html';
      final name = htmlFileNameFor(long);

      expect(name, endsWith('.html'));
      expect(name.runes.length, lessThanOrEqualTo(64 + '.html'.length));
      expect(name, isNot(contains('\uFFFD')));
    });
  });

  group('openHtmlInBrowser', () {
    test('it writes the page and launches a file url at it', () async {
      final attachment = ref(
        source: 'teams',
        name: 'security-report.html',
        contentType: 'text/html',
      );
      const page = '<html><body><h1>Access review</h1></body></html>';
      bytes.bytesByKey[FakeAttachmentBytes.keyOf(attachment)] =
          Uint8List.fromList(page.codeUnits);

      Uri? launched;
      final opened = await openHtmlInBrowser(
        attachment,
        bytes: bytes,
        tempRoot: root,
        launch: (uri) async {
          launched = uri;
          return true;
        },
      );

      expect(opened, isTrue);
      expect(launched, isNotNull);
      expect(launched!.scheme, 'file');
      expect(launched!.pathSegments.last, 'security-report.html');
      final written = File(launched!.toFilePath());
      expect(await written.readAsString(), page);
    });

    test('bytes it cannot get are a false and no launch', () async {
      final attachment = ref(name: 'page.html', contentType: 'text/html');
      bytes.throwOnBytes = const AttachmentUnavailable('gone');

      var launches = 0;
      final opened = await openHtmlInBrowser(
        attachment,
        bytes: bytes,
        tempRoot: root,
        launch: (_) async {
          launches++;
          return true;
        },
      );

      expect(opened, isFalse);
      expect(launches, 0);
    });

    test('a launcher that refuses is a false', () async {
      final attachment = ref(name: 'page.html', contentType: 'text/html');
      bytes.bytesByKey[FakeAttachmentBytes.keyOf(attachment)] =
          Uint8List.fromList([60, 112, 62]);

      final opened = await openHtmlInBrowser(
        attachment,
        bytes: bytes,
        tempRoot: root,
        launch: (uri) async => false,
      );

      expect(opened, isFalse);
    });

    test('a launcher that throws is a false, not an unhandled error', () async {
      final attachment = ref(name: 'page.html', contentType: 'text/html');
      bytes.bytesByKey[FakeAttachmentBytes.keyOf(attachment)] =
          Uint8List.fromList([60, 112, 62]);

      // What `url_launcher` does under a test binary: no plugin behind it.
      final opened = await openHtmlInBrowser(
        attachment,
        bytes: bytes,
        tempRoot: root,
        launch: (_) async => throw Exception('no plugin'),
      );

      expect(opened, isFalse);
    });

    test('a name that is a path lands inside the temp folder', () async {
      final attachment = ref(
        name: '../../escaped.html',
        contentType: 'text/html',
      );
      bytes.bytesByKey[FakeAttachmentBytes.keyOf(attachment)] =
          Uint8List.fromList([60, 112, 62]);

      Uri? launched;
      await openHtmlInBrowser(
        attachment,
        bytes: bytes,
        tempRoot: root,
        launch: (uri) async {
          launched = uri;
          return true;
        },
      );

      final path = launched!.toFilePath();
      expect(path, contains(pagesFolderName));
      expect(File(path).parent.parent.path, pages().path);
      expect(path, endsWith('escaped.html'));
      expect(path, isNot(contains('..')));
    });
  });

  /// What the copies cost. A press used to make a brand new temp directory and
  /// leave it there, so a mailbox read over a month was a month of pages lying
  /// in `/var/folders` waiting for the operating system to notice.
  group('the copies it leaves behind', () {
    /// An attachment whose bytes are ready to open.
    AttachmentRef ready({required String attachmentId, String? name}) {
      final attachment = ref(
        source: 'teams',
        attachmentId: attachmentId,
        name: name ?? 'report.html',
        contentType: 'text/html',
      );
      bytes.bytesByKey[FakeAttachmentBytes.keyOf(attachment)] =
          Uint8List.fromList('<html><body>hi</body></html>'.codeUnits);
      return attachment;
    }

    Future<Uri?> open(AttachmentRef attachment) async {
      Uri? launched;
      await openHtmlInBrowser(
        attachment,
        bytes: bytes,
        tempRoot: root,
        launch: (uri) async {
          launched = uri;
          return true;
        },
      );
      return launched;
    }

    test('the same page opened twice is one directory and one file', () async {
      final attachment = ready(attachmentId: 'att-1');

      final first = await open(attachment);
      final second = await open(attachment);

      expect(second!.toFilePath(), first!.toFilePath());
      expect(pageFolders(), hasLength(1));
      expect(
        Directory(File(first.toFilePath()).parent.path)
            .listSync()
            .whereType<File>(),
        hasLength(1),
      );
    });

    test('two pages are two directories, one each', () async {
      await open(ready(attachmentId: 'att-1', name: 'first.html'));
      await open(ready(attachmentId: 'att-2', name: 'second.html'));

      expect(pageFolders(), hasLength(2));
    });

    test('a directory nothing has touched in a day is swept', () async {
      final stale = Directory('${pages().path}${Platform.pathSeparator}old')
        ..createSync(recursive: true);
      final page = File('${stale.path}${Platform.pathSeparator}old.html')
        ..writeAsStringSync('<html></html>')
        ..setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 2)),
        );

      await open(ready(attachmentId: 'att-1'));

      expect(stale.existsSync(), isFalse, reason: 'stale page kept');
      expect(page.existsSync(), isFalse);
      expect(pageFolders(), hasLength(1));
    });

    test('a page opened this morning is left where the browser can reload it',
        () async {
      final recent = Directory('${pages().path}${Platform.pathSeparator}new')
        ..createSync(recursive: true);
      File('${recent.path}${Platform.pathSeparator}new.html')
        ..writeAsStringSync('<html></html>')
        ..setLastModifiedSync(
          DateTime.now().subtract(const Duration(hours: 3)),
        );

      await open(ready(attachmentId: 'att-1'));

      expect(recent.existsSync(), isTrue);
      expect(pageFolders(), containsAll(<String>['new']));
    });

    test('a directory it cannot remove costs a copy, never the press',
        () async {
      final stuck = Directory('${pages().path}${Platform.pathSeparator}stuck')
        ..createSync(recursive: true);
      File('${stuck.path}${Platform.pathSeparator}held.html')
        ..writeAsStringSync('<html></html>')
        ..setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 2)),
        );
      // A directory whose children cannot be unlinked — the shape of a page the
      // sweep has no business failing over. Put back in tearDown so this test's
      // own cleanup can still take it away.
      await Process.run('/bin/chmod', ['500', stuck.path]);
      addTearDown(() => Process.run('/bin/chmod', ['700', stuck.path]));

      final launched = await open(ready(attachmentId: 'att-1'));

      expect(launched, isNotNull, reason: 'the press must still open');
      expect(File(launched!.toFilePath()).existsSync(), isTrue);
      expect(stuck.existsSync(), isTrue);
    });

    test('a first press with no parent directory yet still opens', () async {
      expect(pages().existsSync(), isFalse);

      final launched = await open(ready(attachmentId: 'att-1'));

      expect(launched, isNotNull);
      expect(pageFolders(), hasLength(1));
    });

    test('the directory name is the attachment, not its name on the wire',
        () async {
      final one = ref(
        source: 'teams',
        attachmentId: 'att-1',
        name: 'report.html',
      );
      final renamed = ref(
        source: 'teams',
        attachmentId: 'att-1',
        name: 'REPORT (2).html',
      );
      final other = ref(
        source: 'teams',
        attachmentId: 'att-2',
        name: 'report.html',
      );

      expect(pageFolderNameFor(renamed), pageFolderNameFor(one));
      expect(pageFolderNameFor(other), isNot(pageFolderNameFor(one)));
      // Hashed: a message id in a path would name who is talking to whom to
      // anything that can list a temp directory.
      expect(pageFolderNameFor(one), isNot(contains(one.messageId)));
      expect(pageFolderNameFor(one), hasLength(16));
    });
  });
}
