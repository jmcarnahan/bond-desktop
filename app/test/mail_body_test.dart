import 'package:bond_inbox/services/attachments/owa_links.dart';
import 'package:bond_inbox/services/mail_body.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a message body reads like once it is ours to convert.
///
/// Every fixture below is an anonymized version of a real message that was
/// unreadable in the app during manual testing, and every assertion is one of
/// the artefacts that made it so. They come in two kinds and both matter:
/// what SURVIVES (a comment somebody wrote, a table's columns, a CTA's
/// label) and what is GONE (a hundred-character tracking address on a line of
/// its own, `[Main Logo]`, `[Comment Icon]`, `[Author]`, a template
/// placeholder the sender never resolved). The second kind is the reason the
/// file exists: the noise was most of the visible body, and the useful part
/// sat below the fold.
///
/// Names, tenants and hosts are fictional and every domain is under
/// `example.com`. U+200B is spelled `zwsp` rather than written as itself: a
/// literal is a character nobody reviewing the diff can see and any editor
/// can eat.
void main() {
  const zwsp = '\u200b';

  group("entry 3 · a document mention notification", () {
    const docUrl = 'https://tenant.sharepoint.com/sites/analytics/'
        'Shared%20Documents/Findings.docx'
        '?d=w1a2b3c4&csf=1&web=1&e=AbCdEf&at=9&xdata=Xx1&sdata=Yy2';
    const commentUrl = '$docUrl&comment=42';
    const helpWrapper = 'https://eu01.safelinks.protection.outlook.com/'
        '?url=https%3A%2F%2Fsupport.example.com%2Foffice%2Fnotifications'
        '&data=05%7C01%7Cdana%40example.com';

    // The Office comment-mention mail: a linked file-type icon, the file name
    // linked to the same address, two more icons whose alt text is all they
    // are, the comment, a quoted excerpt of the document, the CTA, the
    // boilerplate question and a logo.
    const html = '<html><head><style>.b{font-family:Segoe}</style></head>'
        '<body>'
        '<table><tr>'
        '<td><a href="$docUrl">'
        '<img alt="{0} Icon" src="https://res.cdn.example.com/word.png"></a>'
        '</td>'
        '<td><a href="$docUrl">Findings.docx</a></td>'
        '</tr></table>'
        '<p><img alt="Comment Icon" src="https://res.cdn.example.com/c.png">'
        '<img alt="Author" src="https://res.cdn.example.com/avatar.png"></p>'
        '<p>Rowan Vale mentioned you</p>'
        '<p>@Dana Quill is this right? Seems off.</p>'
        '<blockquote>'
        '<p>Finding: stale credentials on the reporting host</p>'
        '<p>Severity: medium &#x2014; ticket PLAT-142</p>'
        '</blockquote>'
        '<p><a href="$commentUrl">Go to comment</a></p>'
        '<p><a href="$helpWrapper">'
        'Why am I receiving this notification from Office?</a></p>'
        '<p><img alt="Northwind Logo" src="https://cdn.example.com/logo.png">'
        '</p>'
        '<p>Northwind Analytics &#183; 1 Harbour Way</p>'
        '</body></html>';

    final text = mailTextFromHtml(html);

    test('the icon alt and the address on its own line are both gone', () {
      expect(text, isNot(contains('Icon')));
      expect(text, isNot(contains('{0}')));
      // The file's address appears once, as the target of the run that names
      // it — not a second time on the line the linked icon used to open with.
      expect('<$docUrl>'.allMatches(text).length, 1);
    });

    test('the file name is a canonical run', () {
      expect(text, contains('Findings.docx <$docUrl>'));
    });

    test('the alt-text lines are not lines any more', () {
      expect(text, isNot(contains('[Comment Icon]')));
      expect(text, isNot(contains('[Author]')));
      expect(text, isNot(contains('Author')));
      expect(text, isNot(contains('Northwind Logo')));
    });

    test('the comment and the excerpt are what the eye lands on', () {
      expect(text, contains('Rowan Vale mentioned you'));
      expect(text, contains('@Dana Quill is this right? Seems off.'));
      expect(text, contains('> Finding: stale credentials on the reporting host'));
      expect(text, contains('> Severity: medium — ticket PLAT-142'));
      // The point of all of it: the comment is in the first few lines rather
      // than below a fold of addresses.
      expect(
        text.indexOf('is this right?'),
        lessThan(text.indexOf('Why am I receiving')),
      );
      expect(text.split('\n').take(6).join('\n'), contains('mentioned you'));
    });

    test('the CTA is one space from its target, never glued to it', () {
      // Graph's own conversion writes `Go to comment<url>`, which no
      // linkifier and no reader can split.
      expect(text, contains('Go to comment <$commentUrl>'));
      expect(text, isNot(contains('Go to comment<')));
    });

    test('the boilerplate question keeps its label and its wrapper', () {
      expect(
        text,
        contains(
          'Why am I receiving this notification from Office? <$helpWrapper>',
        ),
      );
    });
  });

  group('entry 4 · a procurement approval notification', () {
    const wrapper = 'https://eu01.safelinks.protection.outlook.com/'
        '?url=https%3A%2F%2Fprocure.example.com%2Frequests%2Fdetail'
        '%2F7c9e4b21%2Foverview%23comment-4f2&data=05%7C01%7C';

    // The href as it sits in the source: every ampersand HTML-escaped, which
    // is what a well-formed mail writes and what our converter has to decode
    // before it parses the address.
    final escapedWrapper = wrapper.replaceAll('&', '&amp;');

    final html = '<table><tr>'
        '<td><img alt="Main Logo" src="https://cdn.procure.example.com/l.png">'
        '</td>'
        '<td><img alt="Organisation Logo" src="https://cdn.example.com/o.png">'
        '</td>'
        '</tr></table>'
        '<p>New comment on request Northwind Analytics Suite - '
        'Maintenance renewal by Rowan Vale <span>Rowan Vale</span> '
        '(Internal)</p>'
        '<p>Hi @Dana Quill</p>'
        '<p>You are identified as approver. Priya Raman is requesting '
        'maintenance renewal. Please, approve if you would like to '
        'proceed.</p>'
        '<p><a href="$escapedWrapper">View comment</a></p>';

    final text = mailTextFromHtml(html);

    test('the logo alt text and the run of layout spaces are gone', () {
      expect(text, isNot(contains('Main Logo')));
      expect(text, isNot(contains('Organisation Logo')));
      expect(text, isNot(contains('[')));
      expect(text, startsWith('New comment on request'));
    });

    test('the CTA is a labelled run and the wrapper is still the target', () {
      expect(text, contains('View comment <$wrapper>'));
      expect(text, isNot(contains('View comment<')));
      // An `&amp;` in the href is decoded once, before the address is parsed.
      expect(text, isNot(contains('&amp;')));
    });

    test('the prose the approver has to read is intact', () {
      expect(text, contains('Hi @Dana Quill'));
      expect(
        text,
        contains('Priya Raman is requesting maintenance renewal.'),
      );
    });
  });

  group('entry 2 · an issue tracker notification arriving as HTML', () {
    const html = '<p>New request created under PLAT-100</p>'
        '<p>Issue Key : PLAT-142</p>'
        '<p>Issue Description :</p>'
        '<p><strong>Ownership</strong></p>'
        '<p>The <code>reporting-api</code> service moves to the platform '
        'team.</p>'
        '<h2>Split</h2>'
        '<table>'
        '<tr><th>Area</th><th>Owner</th></tr>'
        '<tr><td>Ingest</td><td>Platform</td></tr>'
        '<tr><td>Reporting</td><td>Analytics</td></tr>'
        '</table>'
        '<ol><li>Confirm the on-call rota</li>'
        '<li>Update the runbook</li></ol>';

    final text = mailTextFromHtml(html);

    test('paragraphs are paragraphs again, not one wall of text', () {
      // The wall is the symptom: the tracker's own line breaks were lost, so
      // the whole description read as one long line.
      expect(text, contains('New request created under PLAT-100\n'));
      expect(text, contains('Issue Key : PLAT-142'));
      expect(text, contains('Ownership\n'));
      expect(
        text,
        contains('The reporting-api service moves to the platform team.'),
      );
    });

    test('a table is rows of tab-separated cells', () {
      expect(text, contains('Area\tOwner\nIngest\tPlatform\nReporting\tAnalytics'));
    });

    test('a numbered list is one item per line', () {
      expect(text, contains('- Confirm the on-call rota'));
      expect(text, contains('- Update the runbook'));
    });

    test('no tag reaches the reader', () {
      for (final tag in ['<table', '<tr', '<td', '<p', '<li', '<strong', '<h2']) {
        expect(text, isNot(contains(tag)), reason: tag);
      }
    });
  });

  group('entry 6 · an external vendor outreach', () {
    const mailtoTarget = 'mailto:rep@vendor.example.com'
        '?cc=assistant@vendor.example.com'
        '&subject=Yes%2C%20I%20will%20be%20there'
        '&body=Count%20me%20in.';
    const scheduleWrapper = 'https://eu01.safelinks.protection.outlook.com/'
        '?url=https%3A%2F%2Fcal.vendor.example.com%2Frowan%2F30min'
        '&data=05%7C01%7C';

    final text = mailTextFromHtml(
      '<p>&#9888; External Email &#8212; Use caution with links and '
      'attachments</p>'
      '<p>Looking forward to our meeting on Thursday to discuss how I can '
      'support you and your organization.</p>'
      '<p><a href="$mailtoTarget">Yes, I will be there</a></p>'
      '<p><a href="$scheduleWrapper">I want to choose another time</a></p>',
    );

    test('the tenant banner comes off the head of the body', () {
      // The chip on the row says it better, and the sentence is noise the
      // models pay for on every external message.
      expect(text, isNot(contains('Use caution')));
      expect(text, startsWith('Looking forward to our meeting'));
    });

    test('a mailto CTA keeps the whole prefilled message as its target', () {
      expect(text, contains('Yes, I will be there <$mailtoTarget>'));
      expect(text, contains('cc=assistant@vendor.example.com'));
      expect(text, contains('subject=Yes%2C%20I%20will%20be%20there'));
      expect(text, contains('body=Count%20me%20in.'));
    });

    test('the scheduling CTA keeps its label and its wrapper', () {
      expect(text, contains('I want to choose another time <$scheduleWrapper>'));
    });
  });

  group('the external banner is head-anchored', () {
    test('every spelling at the head goes', () {
      const variants = [
        '⚠ External Email — Use caution with links and attachments',
        'External Email - Use caution with links and attachments.',
        '[EXTERNAL EMAIL] Use caution with links and attachments',
        'CAUTION: External Sender. Use caution opening links or attachments.',
      ];

      for (final banner in variants) {
        expect(
          tidyMailText('$banner\n\nCould you look at the lease?'),
          'Could you look at the lease?',
          reason: banner,
        );
      }
    });

    test('the same sentence in the middle of a body is the writer\'s own', () {
      const body = 'Hi Dana\n\nOur tenant now prepends "External Email — Use '
          'caution with links and attachments" to every inbound message, '
          'which is why your replies look odd.';

      expect(tidyMailText(body), body);
    });

    test('a sentence that merely mentions caution is not the banner', () {
      const body = 'Use caution with the staging credentials, they rotate.';

      expect(tidyMailText(body), body);
    });
  });

  group('mailBodyFromDetail', () {
    test('an html body is converted', () {
      expect(
        mailBodyFromDetail(
          content: '<p>Hi</p><p><a href="https://x.example.com/a">Doc</a></p>',
          contentType: 'html',
        ),
        'Hi\n\nDoc <https://x.example.com/a>',
      );
    });

    test('text/html is the same answer as html', () {
      const html = '<p>Hi</p><p>There</p>';

      expect(
        mailBodyFromDetail(content: html, contentType: 'text/html'),
        mailBodyFromDetail(content: html, contentType: 'html'),
      );
    });

    test('a text body is tidied and never converted', () {
      // A sender's own angle brackets are not tags, and a converter run over
      // a text body would delete the sentence between them.
      const body = 'Set it to <YOUR-TENANT> and retry.\n\n\n\nThanks';

      expect(
        mailBodyFromDetail(content: body, contentType: 'text'),
        'Set it to <YOUR-TENANT> and retry.\n\nThanks',
      );
    });

    test('a null content type is read as text', () {
      expect(
        mailBodyFromDetail(content: '<b>keep</b>', contentType: null),
        '<b>keep</b>',
      );
    });

    test('nothing at all is the empty string, never a throw', () {
      expect(mailBodyFromDetail(content: null, contentType: 'html'), '');
      expect(mailBodyFromDetail(content: '', contentType: null), '');
    });
  });

  group('what tidyMailText must not touch', () {
    test('a canonical run, a cid token and a delimiter all survive', () {
      final body = '${zwsp}Budget.xlsx '
          '<https://contoso.sharepoint.com/:x:/s/deals/EqRs>$zwsp\n'
          'See [cid:chart001.png@01DA5F20] and '
          'Findings.docx <https://t.example.com/a/Findings.docx>';

      expect(tidyMailText(body), body);
      expect(zwsp.allMatches(tidyMailText(body)).length, 2);
    });

    test('trailing spaces go and runs of blank lines collapse', () {
      expect(
        tidyMailText('One   \n\n\n\n\nTwo\t\n'),
        'One\n\nTwo',
      );
    });

    test('CRLF is read as LF', () {
      expect(tidyMailText('One\r\n\r\nTwo\r\n'), 'One\n\nTwo');
    });
  });

  group('images and links inside a mail body', () {
    test('an inline picture is a cid token and every other picture is gone',
        () {
      final text = mailTextFromHtml(
        '<p><img src="cid:chart001.png@01DA5F20" alt="Q4 chart"> is the '
        'shape.</p>'
        '<p><img src="https://cdn.example.com/track.gif" width="1" '
        'alt="Tracker"></p>',
      );

      expect(text, '[cid:chart001.png@01DA5F20] is the shape.');
    });

    test('a scripted anchor is its label and nothing else', () {
      expect(
        mailTextFromHtml('<p><a href="javascript:alert(1)">Click here</a></p>'),
        'Click here',
      );
    });

    test('entities decode and half a surrogate pair is left as typed', () {
      final text = mailTextFromHtml(
        '<p>Fees &amp; charges &#x2014; &#xD800; &nbsp;done</p>',
      );

      expect(text, 'Fees & charges — &#xD800; done');
      expect(
        text.codeUnits.any((unit) => unit >= 0xd800 && unit <= 0xdfff),
        isFalse,
      );
    });

    test('an attach-as-link entity still parses after our conversion', () {
      // The seam WP1-B relies on: the body is converted here and handed to
      // `extractOwaLinks`, which reads the zero-width delimiters. Our
      // converter drops the icon image and writes one space before the
      // bracket, so the run it sees is a shape Graph never wrote.
      const url = 'https://contoso.sharepoint.com/:x:/s/deals/EqRsTuVwXyZ';
      final body = mailTextFromHtml(
        '<p>Please review $zwsp<a href="$url">'
        '<img src="https://res.cdn.example.com/x.png" alt="Excel Icon">'
        'Budget.xlsx</a>$zwsp today</p>',
      );

      expect(body, 'Please review ${zwsp}Budget.xlsx <$url>$zwsp today');

      final extracted = extractOwaLinks(body);

      expect(extracted.rows.single['name'], 'Budget.xlsx');
      expect(extracted.rows.single['source_url'], url);
      expect(extracted.body, contains('[[att:'));
      expect(extracted.body, isNot(contains(zwsp)));
    });
  });

  group('stripLinkTargets over a converted body', () {
    test('the labels stay and the addresses go', () {
      final text = mailTextFromHtml(
        '<p><a href="https://t.example.com/sites/a/Findings.docx?d=w1&at=9">'
        'Findings.docx</a></p>'
        '<p><a href="https://t.example.com/c?comment=42">Go to comment</a></p>'
        '<p>Or read https://status.example.com/incidents yourself.</p>',
      );

      expect(
        stripLinkTargets(text),
        'Findings.docx\n\nGo to comment\n\n'
        'Or read https://status.example.com/incidents yourself.',
      );
    });
  });
}
