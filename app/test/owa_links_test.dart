import 'package:bond_inbox/services/attachments/attachment_policy.dart'
    show maxAttachmentsPerMessage;
import 'package:bond_inbox/services/attachments/owa_links.dart';
import 'package:bond_inbox/widgets/attachment_format.dart' show webUriOf;
import 'package:flutter_test/flutter_test.dart';

/// The parse that turns Outlook's "attach as link" into a file.
///
/// The whole of this file is about ONE discrimination: an OWALink entity and
/// an ordinary hyperlink convert to the same `text<url>` shape, and only the
/// zero-width spaces around the entity say which is which. Read the shape
/// alone and every link in every mail becomes an attachment; read the
/// delimiters and only the files do.
///
/// Everything is spelled with `zwsp` rather than the character itself. A
/// literal U+200B in a test file is a character nobody reviewing the diff can
/// see, and an editor that trims it silently deletes the assertion.
void main() {
  const zwsp = '\u200b';
  const icon = 'https://res-1.cdn.office.net/files/assets/item-types/16/pdf.svg';
  const pdfUrl =
      'https://southbayequity2-my.sharepoint.com/:b:/g/personal/'
      'jane_southbayequity2_onmicrosoft_com/EaBcDeFgHiJkLmNoPqRsTuVwXyZ'
      '?e=abc123';
  const xlsxUrl =
      'https://southbayequity2.sharepoint.com/:x:/s/deals/EqRsTuVwXyZ01234';

  String run(String name, String url) => '$zwsp[$icon]$name<$url>$zwsp';

  group('one link in a body', () {
    test('a link attachment becomes a marker and a row', () {
      final body = 'Please review.\n\n'
          '${run('HARBORLIGHT TALENT AGREEMENT.pdf', pdfUrl)}'
          '\n\nThanks';

      final result = extractOwaLinks(body);

      expect(result.body, contains('[[att:link-'));
      expect(result.body, isNot(contains(zwsp)));
      expect(result.body, startsWith('Please review.'));
      expect(result.body, endsWith('Thanks'));

      final row = result.rows.single;
      expect(row['attachment_id'], linkAttachmentId(pdfUrl));
      expect(row['kind'], 'reference');
      expect(row['name'], 'HARBORLIGHT TALENT AGREEMENT.pdf');
      expect(row['source_url'], pdfUrl);
      expect(row['ordinal'], 0);
      expect(row['size'], 0);
      expect(row['content_type'], isNull);
      expect(row['is_inline'], false);
      expect(row['content_id'], isNull);
      expect(row['card_text'], isNull);
      expect(result.body, contains('[[att:${row['attachment_id']}]]'));
    });

    test('an icon is never a thumbnail', () {
      // The icon is Office's file-type glyph on a CDN, not a picture of this
      // file. Stored, it would be the url the preview fetches a thumbnail from.
      final result = extractOwaLinks(run('Quote.pdf', pdfUrl));

      expect(result.rows.single['thumbnail_url'], isNull);
      expect(result.body, isNot(contains(icon)));
    });

    test('a run with no name is cleaned and not a row', () {
      final result = extractOwaLinks('See ${run('   ', pdfUrl)} please');

      expect(result.rows, isEmpty);
      expect(result.body, 'See $pdfUrl please');
      expect(result.body, isNot(contains(zwsp)));
    });
  });

  group('more than one', () {
    test('two links keep their order and ordinals', () {
      final body = '${run('First.pdf', pdfUrl)} and ${run('Second.xlsx', xlsxUrl)}';

      final result = extractOwaLinks(body);

      expect(result.rows.map((r) => r['name']), ['First.pdf', 'Second.xlsx']);
      expect(result.rows.map((r) => r['ordinal']), [0, 1]);
      expect(
        result.body,
        '[[att:${linkAttachmentId(pdfUrl)}]] and '
        '[[att:${linkAttachmentId(xlsxUrl)}]]',
      );
    });

    test('the same file linked twice is one row', () {
      final body = '${run('Quote.pdf', pdfUrl)} — again: '
          '${run('Quote.pdf', pdfUrl)}';

      final result = extractOwaLinks(body);

      expect(result.rows.length, 1);
      final marker = '[[att:${linkAttachmentId(pdfUrl)}]]';
      expect(result.body, '$marker — again: $marker');
    });

    test('ordinals start after the real attachments', () {
      final body = '${run('First.pdf', pdfUrl)} ${run('Second.xlsx', xlsxUrl)}';

      final result = extractOwaLinks(body, startOrdinal: 2);

      expect(result.rows.map((r) => r['ordinal']), [2, 3]);
    });

    test('runs past the per-message cap are cleaned, not rows', () {
      // The body is the sender's, so the number of runs in it is too. A row
      // the policy would refuse by ordinal before any fetch is not written at
      // all — otherwise a crafted body is thousands of rows, each refused on
      // every sync and each on the shelf.
      final body = [
        for (var i = 0; i < maxAttachmentsPerMessage + 3; i++)
          run('File-$i.pdf', '$pdfUrl-$i'),
      ].join(' ');

      final result = extractOwaLinks(body, startOrdinal: 2);

      expect(result.rows.length, maxAttachmentsPerMessage - 2);
      expect(
        result.rows.map((r) => r['ordinal']),
        [for (var i = 2; i < maxAttachmentsPerMessage; i++) i],
      );
      expect(result.body, isNot(contains(zwsp)));
      // The surplus runs read as the sender wrote them, link and all.
      expect(result.body, contains('File-$maxAttachmentsPerMessage.pdf <'));
      expect(
        '[[att:'.allMatches(result.body).length,
        maxAttachmentsPerMessage - 2,
      );
    });
  });

  group('what is not an attachment', () {
    test('a link to a host the connectors cannot read is cleaned and not a row',
        () {
      const drive = 'https://drive.google.com/file/d/1AbCdEfGhIjK/view';

      final result = extractOwaLinks('Here ${run('Budget.xlsx', drive)} ok');

      expect(result.rows, isEmpty);
      expect(result.body, 'Here Budget.xlsx <$drive> ok');
      expect(result.body, isNot(contains(zwsp)));
    });

    test('an ordinary hyperlink is not touched', () {
      const body = 'see http://x<https://x>';

      final result = extractOwaLinks(body);

      expect(result.body, body);
      expect(result.rows, isEmpty);
    });

    test('a body with no zero-width space comes back byte for byte', () {
      const body = 'Nothing attached here, just [brackets] and a <chevron>.';

      final result = extractOwaLinks(body);

      expect(identical(result.body, body), isTrue);
      expect(result.rows, isEmpty);
    });

    test('a null body is empty and has no rows', () {
      final result = extractOwaLinks(null);

      expect(result.body, '');
      expect(result.rows, isEmpty);
    });

    test('a stray delimiter leaves no invisible character behind', () {
      final result = extractOwaLinks('Half a run ${zwsp}left over');

      expect(result.body, 'Half a run left over');
      expect(result.rows, isEmpty);
    });
  });

  group('the id', () {
    test('is stable and carries no pipe', () {
      final first = linkAttachmentId(pdfUrl);

      expect(linkAttachmentId(pdfUrl), first);
      expect(first, startsWith('link-'));
      expect(first.length, 21);
      // `|` is what `attachmentEntityId` splits a work item's id on.
      expect(first.contains('|'), isFalse);
      expect(linkAttachmentId(xlsxUrl), isNot(first));
    });
  });

  group('the host gate', () {
    test('a personal OneDrive host counts', () {
      expect(isCloudFileUrl(pdfUrl), isTrue);
      expect(
        isCloudFileUrl('https://southbayequity2.sharepoint.com/sites/deals/a'),
        isTrue,
      );
    });

    test('a user before the host is refused, whichever way it is read', () {
      // Dart reads the host as `evil.example`; a parser that read it as
      // `a.sharepoint.com` would be sending a stranger's address to the
      // server. No file address carries a user, so the form is refused.
      expect(isCloudFileUrl('https://a.sharepoint.com@evil.example/x'), isFalse);
      expect(
        extractOwaLinks(run('Quote.pdf', 'https://a.sharepoint.com@evil.example/x'))
            .rows,
        isEmpty,
      );
    });

    test('an uppercase host still counts', () {
      expect(isCloudFileUrl('https://A.SharePoint.COM/:b:/g/x'), isTrue);
    });

    test('a backslash before an at-sign is stored as the slash Dart read', () {
      // Passes the gate with a host of `a.sharepoint.com`; a parser that
      // treats `\\` as `/` and reads the host after the `@` would go to
      // `evil.example` if it were handed the raw string. So the raw string is
      // never stored.
      const raw = r'https://a.sharepoint.com\@evil.example/x';
      const read = 'https://a.sharepoint.com/@evil.example/x';

      final result = extractOwaLinks(run('Quote.pdf', raw));

      expect(result.rows.single['source_url'], read);
      expect(result.rows.single['attachment_id'], linkAttachmentId(read));
    });

    test('1drv.ms counts', () {
      expect(isCloudFileUrl('https://1drv.ms/b/s!AbCdEfGh'), isTrue);
    });

    test('onedrive.live.com counts', () {
      expect(
        isCloudFileUrl('https://onedrive.live.com/?cid=1&id=2'),
        isTrue,
      );
    });

    test('a host that merely contains sharepoint does not', () {
      expect(isCloudFileUrl('https://sharepoint.com.evil.example/a'), isFalse);
      expect(isCloudFileUrl('https://notsharepoint.com/a'), isFalse);
    });

    test('the host gate follows the web-address rule', () {
      // The gate re-states `webUriOf` locally because a service must not
      // import a widget file. Re-stated is only safe while the two agree.
      const cases = [
        'ftp://x.sharepoint.com/a',
        'x.sharepoint.com',
        'file:///Users/jane/x.sharepoint.com/secret.pdf',
        'https://',
        '',
        'https://x.sharepoint.com/a',
      ];
      for (final url in cases) {
        expect(
          isCloudFileUrl(url),
          webUriOf(url) != null &&
              webUriOf(url)!.host.toLowerCase().endsWith('.sharepoint.com'),
          reason: url,
        );
      }
      expect(isCloudFileUrl('ftp://x.sharepoint.com/a'), isFalse);
      expect(isCloudFileUrl('x.sharepoint.com'), isFalse);
    });
  });
}
