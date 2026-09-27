import 'package:bond_inbox/services/html_text.dart';
import 'package:bond_inbox/widgets/attachment_format.dart' show webUriOf;
import 'package:flutter_test/flutter_test.dart';

/// One converter, two readers, and the difference between them.
///
/// The whole of this file is about a page that means two different things
/// depending on who is about to read it. In a rendered analysis the owner
/// keeps on disk, a chart's `alt` is the one indexable sentence saying what
/// the picture shows. In a notification mail, the same attribute is
/// `[Main Logo]`, `[Comment Icon]` or a template placeholder the sender never
/// resolved — the top of the message, spent. So the tests below feed ONE
/// string to both profiles and assert what each keeps and what each drops.
///
/// U+200B is spelled `zwsp` throughout rather than written as itself: a
/// literal in a test file is a character nobody reviewing the diff can see,
/// and an editor that trims it silently deletes the assertion.
void main() {
  const zwsp = '\u200b';

  group('the two profiles over one page', () {
    const page = '<h2>Q4 revenue</h2>'
        '<p><img alt="Revenue by month" src="https://cdn.example.com/c.png"> '
        'Revenue was 4.2M.</p>'
        '<p><a href="https://reports.example.com/q4">The report</a></p>';

    String asDocument() => htmlToText(page, profile: HtmlProfile.document);
    String asMail() => htmlToText(page, profile: HtmlProfile.mail);

    test('a document lifts the picture label and loses the href', () {
      final text = asDocument();

      // The chunker cuts markdown on `#`, so an HTML analysis chunks by its
      // own headings.
      expect(text, contains('## Q4 revenue'));
      expect(text, contains('Revenue was 4.2M.'));
      expect(text, contains('Revenue by month'));
      expect(text, contains('The report'));
      expect(text, isNot(contains('https://reports.example.com/q4')));
    });

    test('mail drops the picture label and keeps the href as a run', () {
      final text = asMail();

      expect(text, isNot(contains('Revenue by month')));
      expect(text, isNot(contains('[')));
      expect(text, contains('The report <https://reports.example.com/q4>'));
      expect(text, contains('Revenue was 4.2M.'));
      // A mail body is never markdown-rendered, so it is never given markdown
      // it did not have.
      expect(text, isNot(contains('##')));
      expect(text, contains('Q4 revenue'));
    });

    test('both profiles drop the script and the style before any tag', () {
      const withScript = '<style>.a{color:#123456}</style>'
          '<h1>Churn</h1><p>Retention held.</p>'
          '<script>Plotly.newPlot("chart", data);</script>';

      for (final profile in HtmlProfile.values) {
        final text = htmlToText(withScript, profile: profile);
        expect(text, contains('Retention held.'), reason: '$profile');
        expect(text, isNot(contains('Plotly')), reason: '$profile');
        expect(text, isNot(contains('123456')), reason: '$profile');
      }
    });
  });

  group('a whole self-contained document', () {
    /// What a security tool actually exports, and what the owner saw printed as
    /// text in the preview before the conversion reached it: a doctype, a head
    /// with a `<meta charset>` and a page of CSS in it, then the report.
    const report = '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Scorecard</title>
<style>
  body { font-family: -apple-system, sans-serif; margin: 0 auto; }
  table.findings { border-collapse: collapse; width: 100%; }
  table.findings td { border: 1px solid #333333; padding: 6px 8px; }
</style>
</head>
<body>
<h1>Scorecard</h1>
<table class="findings">
<tr><th>Control</th><th>Score</th></tr>
<tr><td>Password age</td><td>62</td></tr>
</table>
<p>Two accounts need a password change.</p>
<script>document.querySelectorAll('td').forEach(sortRows);</script>
</body>
</html>
''';

    test('the reader gets the report and none of the file', () {
      final text = htmlToText(report, profile: HtmlProfile.document);

      expect(text, contains('Scorecard'));
      expect(text, contains('Password age'));
      expect(text, contains('Two accounts need a password change.'));

      // The head goes whole, contents included — a `<meta charset>` and three
      // CSS rules are not sentences a search should ever answer with.
      expect(text, isNot(contains('DOCTYPE')));
      expect(text, isNot(contains('charset')));
      expect(text, isNot(contains('viewport')));
      expect(text, isNot(contains('font-family')));
      expect(text, isNot(contains('border-collapse')));
      expect(text, isNot(contains('#333333')));
      expect(text, isNot(contains('querySelectorAll')));
      // And no tag of any kind survives as text.
      expect(text, isNot(contains('<')));
      expect(text, isNot(contains('>')));
    });

    test('a page whose head was never closed still reads', () {
      // Legal HTML, and common in generated files: the omitted `</head>` must
      // end at the body rather than eat the document.
      const unclosed = '<!DOCTYPE html><html><head><style>p{color:red}</style>'
          '<body><p>Two accounts need a password change.</p></body></html>';

      final text = htmlToText(unclosed, profile: HtmlProfile.document);

      expect(text, contains('Two accounts need a password change.'));
      expect(text, isNot(contains('color:red')));
    });
  });

  group('the mail profile on structure', () {
    test('a table row is a line and its cells are tab separated', () {
      final text = htmlToText(
        '<table><tr><th>Area</th><th>Owner</th></tr>'
        '<tr><td>Ingest</td><td>Platform</td></tr></table>',
        profile: HtmlProfile.mail,
      );

      expect(text, 'Area\tOwner\nIngest\tPlatform');
    });

    test('a list item leads with a dash', () {
      final text = htmlToText(
        '<ol><li>Confirm the rota</li><li>Update the runbook</li></ol>',
        profile: HtmlProfile.mail,
      );

      expect(text, '- Confirm the rota\n\n- Update the runbook');
    });

    test('a quote is prefixed a level deep, and a nested one two', () {
      final text = htmlToText(
        '<p>Mine.</p>'
        '<blockquote><p>Theirs.</p>'
        '<blockquote><p>Older still.</p></blockquote>'
        '</blockquote>',
        profile: HtmlProfile.mail,
      );

      expect(text, contains('Mine.'));
      expect(text, contains('> Theirs.'));
      expect(text, contains('> > Older still.'));
    });

    test('runs of blank lines collapse to one', () {
      final text = htmlToText(
        '<p>One</p><div></div><div></div><div></div><p>Two</p>',
        profile: HtmlProfile.mail,
      );

      expect(text, 'One\n\nTwo');
    });
  });

  group('images in mail', () {
    test('an inline picture becomes its cid token and nothing else', () {
      final text = htmlToText(
        '<p>See the chart: '
        '<img src="cid:chart001.png@01DA5F20.7A3B1C40" alt="Q4 chart"></p>',
        profile: HtmlProfile.mail,
      );

      expect(text, 'See the chart: [cid:chart001.png@01DA5F20.7A3B1C40]');
      expect(text, isNot(contains('Q4 chart')));
    });

    test('a cid written with angle brackets keeps only the id', () {
      // Some senders write the Content-ID with the brackets the header form
      // has. The token downstream splices on carries the id alone.
      final text = htmlToText(
        '<img src="cid:&lt;image001.png@01DA5F20&gt;">',
        profile: HtmlProfile.mail,
      );

      expect(text, '[cid:image001.png@01DA5F20]');
    });

    test('a remote picture leaves no placeholder at all', () {
      final text = htmlToText(
        '<p><img alt="Main Logo" src="https://cdn.example.com/logo.png">'
        '<img alt="Author" src="https://cdn.example.com/a.png"></p>'
        '<p>New comment on request</p>',
        profile: HtmlProfile.mail,
      );

      expect(text, 'New comment on request');
    });

    test('a spacer with no src leaves nothing', () {
      expect(htmlToText('<img width="1">a', profile: HtmlProfile.mail), 'a');
    });
  });

  group('canonicalLinkRun', () {
    test('a label and a web target are one space apart', () {
      expect(
        canonicalLinkRun(
          label: 'Findings.docx',
          target: 'https://tenant.example.com/sites/a/Findings.docx',
        ),
        'Findings.docx <https://tenant.example.com/sites/a/Findings.docx>',
      );
    });

    test('a label that is the address again is dropped for the address', () {
      expect(
        canonicalLinkRun(
          label: 'https://example.com/x/',
          target: 'https://example.com/x',
        ),
        'https://example.com/x',
      );
      expect(
        canonicalLinkRun(
          label: 'www.example.com',
          target: 'https://www.example.com/',
        ),
        'https://www.example.com/',
      );
    });

    test('no label at all is nothing, not a bare address', () {
      // The anchor this is: a linked logo or a linked file-type icon, whose
      // target is the hundred-character address that opened every one of
      // these notifications with a line nobody could read.
      expect(canonicalLinkRun(label: '', target: 'https://example.com/x'), '');
      expect(
        canonicalLinkRun(label: '   ', target: 'https://example.com/x'),
        '',
      );
    });

    test('a target no click can follow leaves the label alone', () {
      expect(
        canonicalLinkRun(label: 'Click here', target: 'javascript:alert(1)'),
        'Click here',
      );
      expect(canonicalLinkRun(label: 'Top', target: '#top'), 'Top');
      expect(canonicalLinkRun(label: 'Share', target: 'smb://fs/share'), 'Share');
      expect(canonicalLinkRun(label: 'Open', target: ''), 'Open');
    });

    test('a mailto CTA keeps its whole query, which is the message', () {
      const target = 'mailto:rep@vendor.example.com'
          '?cc=assistant@vendor.example.com'
          '&subject=Yes%2C%20I%20will%20be%20there'
          '&body=Count%20me%20in.';

      expect(
        canonicalLinkRun(label: 'Yes, I will be there', target: target),
        'Yes, I will be there <$target>',
      );
    });

    test('a plain address linked to itself is the words, not the scheme', () {
      expect(
        canonicalLinkRun(
          label: 'dana@example.com',
          target: 'mailto:dana@example.com',
        ),
        'dana@example.com',
      );
    });

    test('a Safe Links wrapper with a human label keeps both', () {
      const wrapper = 'https://eu01.safelinks.protection.outlook.com/'
          '?url=https%3A%2F%2Fprocure.example.com%2Frequests%2Fdetail%2F7c9e'
          '&data=05%7C01%7C';

      final run = canonicalLinkRun(label: 'View comment', target: wrapper);

      expect(run, startsWith('View comment <https://eu01.safelinks'));
      // The click goes through Microsoft: the tenant bought click-time
      // scanning and a click that skips it is one the policy never saw.
      expect(run, contains('url=https%3A%2F%2Fprocure.example.com'));
    });

    test('a Safe Links wrapper with no label reads as where it goes', () {
      const wrapper = 'https://eu01.safelinks.protection.outlook.com/'
          '?url=https%3A%2F%2Fprocure.example.com%2Frequests%2Fdetail%2F7c9e'
          '%2Foverview&data=05%7C01%7C';

      expect(
        canonicalLinkRun(label: '', target: wrapper),
        'procure.example.com/requests <$wrapper>',
      );
      expect(
        canonicalLinkRun(label: wrapper, target: wrapper),
        'procure.example.com/requests <$wrapper>',
      );
    });

    test('an address over a different address yields to the real one', () {
      // The label reads as a destination and names the wrong one: the words
      // go, and where the click really lands is what the reader sees.
      expect(
        canonicalLinkRun(
          label: 'https://bank.example',
          target: 'https://evil.example',
        ),
        'https://evil.example',
      );
      expect(
        canonicalLinkRun(
          label: 'www.bank.example',
          target: 'https://login.evil.example/session',
        ),
        'https://login.evil.example/session',
      );
    });

    test('a label hiding its host behind userinfo yields to the target', () {
      // Dart and a browser both read this label's host as evil.example; a
      // reader reads bank.example. The label claims nothing checkable.
      expect(
        canonicalLinkRun(
          label: 'https://bank.example@evil.example',
          target: 'https://evil.example/',
        ),
        'https://evil.example/',
      );
    });

    test('an address over itself, give or take the scheme, is still it', () {
      expect(
        canonicalLinkRun(
          label: 'http://www.bank.example/',
          target: 'https://bank.example',
        ),
        'https://bank.example',
      );
    });

    test('the claim is about the host, so a same-host label keeps its words',
        () {
      // Leaving off a tracking query is not a false claim, and yielding to
      // the target would paint the query back into the text.
      expect(
        canonicalLinkRun(
          label: 'https://bank.example/a',
          target: 'https://bank.example/a?utm=1',
        ),
        'https://bank.example/a <https://bank.example/a?utm=1>',
      );
      expect(
        canonicalLinkRun(
          label: 'www.bank.example',
          target: 'https://bank.example/statements?id=7',
        ),
        'www.bank.example <https://bank.example/statements?id=7>',
      );
    });

    test('an address label over a composer for another address yields', () {
      expect(
        canonicalLinkRun(
          label: 'ceo@bank.example',
          target: 'mailto:attacker@evil.example',
        ),
        'mailto:attacker@evil.example',
      );
      // The same address, whatever its case, is still just the words.
      expect(
        canonicalLinkRun(
          label: 'Dana@Example.com',
          target: 'mailto:dana@example.com',
        ),
        'Dana@Example.com',
      );
    });

    test('a bare domain is not read as a claim', () {
      // `Report.xlsx` and `Node.js` have the same shape; the hover caption
      // shows the host for these.
      expect(
        canonicalLinkRun(
          label: 'bank.example',
          target: 'https://evil.example/login',
        ),
        'bank.example <https://evil.example/login>',
      );
    });

    test('words over an address are a label, not a claim', () {
      expect(
        canonicalLinkRun(
          label: 'Sign in to your bank',
          target: 'https://evil.example',
        ),
        'Sign in to your bank <https://evil.example>',
      );
    });

    test('a built label is capped rather than becoming the wall again', () {
      final long = 'https://eu01.safelinks.protection.outlook.com/?url='
          'https%3A%2F%2F${'segment-and-more.' * 4}example.com%2Fdeeply';

      final run = canonicalLinkRun(label: '', target: long);
      final label = run.substring(0, run.indexOf(' <'));

      expect(label.length, lessThanOrEqualTo(60));
      expect(label, endsWith('…'));
    });
  });

  group('an anchor\'s label in mail', () {
    test('a line break inside the label is a space, not nothing', () {
      expect(
        htmlToText(
          '<a href="https://shop.example.com/o/1">View<br>order</a>',
          profile: HtmlProfile.mail,
        ),
        'View order <https://shop.example.com/o/1>',
      );
      expect(
        htmlToText(
          '<a href="https://shop.example.com/o/1"><div>View</div>'
          '<div>order</div></a>',
          profile: HtmlProfile.mail,
        ),
        'View order <https://shop.example.com/o/1>',
      );
    });

    test('a label escaped twice is decoded once, as it is outside an anchor',
        () {
      expect(
        htmlToText(
          '<p>Use &amp;lt;b&amp;gt;</p>',
          profile: HtmlProfile.mail,
        ),
        'Use &lt;b&gt;',
      );
      expect(
        htmlToText(
          '<a href="https://x.example.com">Use &amp;lt;b&amp;gt;</a>',
          profile: HtmlProfile.mail,
        ),
        'Use &lt;b&gt; <https://x.example.com>',
      );
    });

    test('an escaped query separator in a target is decoded exactly once', () {
      expect(
        htmlToText(
          '<a href="https://x.example.com/r?a=1&amp;b=2&amp;amp;c=3">Report</a>',
          profile: HtmlProfile.mail,
        ),
        'Report <https://x.example.com/r?a=1&b=2&amp;c=3>',
      );
    });

    test('a line break inside an address is dropped, as a browser does', () {
      expect(
        htmlToText(
          '<a href="https://x.example.com/a\r\nb\tc">Doc</a>',
          profile: HtmlProfile.mail,
        ),
        'Doc <https://x.example.com/abc>',
      );
    });

    test('an unclosed anchor does not swallow the anchors after it', () {
      expect(
        htmlToText(
          '<p><a href="https://a.example.com">Broken</p>'
          '<p><a href="https://b.example.com">Second</a></p>',
          profile: HtmlProfile.mail,
        ),
        'Broken\n\nSecond <https://b.example.com>',
      );
    });
  });

  group('the whitespace fold in a document', () {
    test('a paragraph wrapped in the source is one line', () {
      expect(
        htmlToText(
          '<h2>Findings</h2><p>Retention held\r\nthrough the quarter.</p>',
          profile: HtmlProfile.document,
        ),
        '## Findings\n\nRetention held through the quarter.',
      );
    });
  });

  group('the cost of a hostile body', () {
    // Twenty thousand stray `<` with no `>` anywhere after them. A tag
    // pattern that could run across a `<` made every one of them scan to the
    // end of the text. The bound is generous on purpose: this is a test of
    // the SHAPE of the cost, and a busy machine must not fail it.
    final hostile = List.filled(20000, 'a < b ').join();

    for (final profile in HtmlProfile.values) {
      test('twenty thousand stray brackets convert quickly ($profile)', () {
        final clock = Stopwatch()..start();
        final text = htmlToText(hostile, profile: profile);
        clock.stop();

        expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
        expect(text, contains('a < b'));
      });
    }

    // Every tag shape with no `>` after it, twenty thousand times. Each one
    // scanned to the end of the text once per opener while its pattern could
    // run across a `<`, and the unclosed comment did the same across later
    // comments.
    for (final shape in [
      '<div ',
      '<img ',
      '<a ',
      '<script ',
      '<!--x',
      '<head>x',
    ]) {
      final shaped = List.filled(20000, shape).join();
      for (final profile in HtmlProfile.values) {
        test('twenty thousand unclosed "${shape.trim()}" convert quickly '
            '($profile)', () {
          final clock = Stopwatch()..start();
          htmlToText(shaped, profile: profile);
          clock.stop();

          expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
        });
      }
    }

    test('a mail with megabytes of base64 picture keeps its sentence', () {
      // A report mailed with its chart as a `data:` picture. A cut on the raw
      // markup landed inside the `<img>` and stored the base64 as the body.
      final html = '<div><img src="data:image/png;base64,'
          '${'A' * (3 * 1024 * 1024)}"></div>'
          '<div>Hi Dana, the numbers are below.</div>';

      expect(
        htmlToText(html, profile: HtmlProfile.mail),
        'Hi Dana, the numbers are below.',
      );
    });

    test('a mail with megabytes of style keeps its words', () {
      final html = '<style>${'.a{color:#123456}' * (2600 * 1024 ~/ 17)}'
          '</style><p>Body words</p>';
      expect(html.length, greaterThan(htmlInputCap));

      expect(htmlToText(html, profile: HtmlProfile.mail), 'Body words');
    });

    test('the cap backs off rather than cut a tag in half', () {
      final kept = 'a' * (htmlInputCap - 10);
      final html = '$kept<span class="${'x' * 40}">tail</span>';

      expect(capHtmlInput(html), kept);
    });

    test('a stray bracket in prose is not a tag the cap backs off to', () {
      // `x < y`, then two megabytes of words with no `>` anywhere: the only
      // `<` is prose, and backing off to it would keep two characters.
      final words = List.filled(htmlInputCap ~/ 5 + 1000, 'word ').join();
      final html = 'x < y $words';

      expect(capHtmlInput(html).length, htmlInputCap);
      expect(
        htmlToText('<p>$html</p>', profile: HtmlProfile.mail).length,
        greaterThan(htmlInputCap - 16),
      );
    });

    test('a mail body over the cap is cut to it', () {
      final html = '<p>${List.filled(htmlInputCap ~/ 5 + 1000, 'word ').join()}'
          '</p>';
      expect(html.length, greaterThan(htmlInputCap));

      final text = htmlToText(html, profile: HtmlProfile.mail);

      expect(text.length, lessThanOrEqualTo(htmlInputCap));
      expect(text, startsWith('word word'));
    });

    test('a capped document is cut after its script, not before it', () {
      // The Plotly shape: megabytes of script, then the page. A cap on the
      // raw markup would keep the script and lose the findings.
      final script = 'var d = [1, 2, 3];\n' * (3 * 1024 * 1024 ~/ 19 + 1);
      final html = '<script>$script</script><p>Findings here</p>';
      expect(html.length, greaterThan(htmlInputCap));

      final text = htmlToText(
        html,
        profile: HtmlProfile.document,
        capProse: true,
      );

      expect(text, 'Findings here');
    });

    test('a capped document with more prose than the cap is cut to it', () {
      final html = '<p>${List.filled(htmlInputCap ~/ 5 + 1000, 'word ').join()}'
          '</p>';

      final text = htmlToText(
        html,
        profile: HtmlProfile.document,
        capProse: true,
      );

      expect(text.length, lessThanOrEqualTo(htmlInputCap));
      expect(text, startsWith('word word'));
    });

    test('the cap never splits a surrogate pair', () {
      // An emoji whose high half is the last character under the cap.
      final html = '${'a' * (htmlInputCap - 1)}\u{1F600}tail';

      final capped = capHtmlInput(html);

      expect(capped.length, htmlInputCap - 1);
      expect(capHtmlInput('short'), 'short');
    });
  });

  group('safeLinksTargetOf', () {
    test('a wrapper answers the address it carries', () {
      expect(
        safeLinksTargetOf(
          'https://nam02.safelinks.protection.outlook.com/'
          '?url=https%3A%2F%2Fdocs.example.com%2Fa%3Fb%3Dc&data=05%7C01',
        ),
        'https://docs.example.com/a?b=c',
      );
    });

    test('the host suffix is tested with its dot', () {
      // Somebody else's domain, and a link to one of them is not Microsoft's.
      expect(
        safeLinksTargetOf(
          'https://safelinks.protection.outlook.com.evil.example/'
          '?url=https%3A%2F%2Fdocs.example.com%2Fa',
        ),
        isNull,
      );
    });

    test('a wrapper carrying nothing openable answers null', () {
      const host = 'https://nam02.safelinks.protection.outlook.com/';
      expect(safeLinksTargetOf(host), isNull);
      expect(safeLinksTargetOf('$host?url=javascript%3Aalert(1)'), isNull);
      expect(safeLinksTargetOf('https://docs.example.com/a'), isNull);
    });

    test('a malformed escape in the tracking blob does not cost the address',
        () {
      expect(
        safeLinksTargetOf(
          'https://nam02.safelinks.protection.outlook.com/'
          '?url=https%3A%2F%2Fdocs.example.com&data=%zz',
        ),
        'https://docs.example.com',
      );
    });

    test('a wrapped target that is not a web address answers null', () {
      // A reader trusts the domain in front of them, and the domain here is
      // Microsoft's. Whatever the `url=` carries is put through the same gate
      // as any other target.
      expect(
        safeLinksTargetOf(
          'https://nam02.safelinks.protection.outlook.com/?url=%zz',
        ),
        isNull,
      );
      expect(
        safeLinksTargetOf(
          'https://nam02.safelinks.protection.outlook.com/'
          '?url=file%3A%2F%2F%2FUsers%2Fdana%2F.ssh%2Fconfig',
        ),
        isNull,
      );
    });
  });

  group('webTargetOf', () {
    test('agrees with the rule the launcher button states', () {
      const cases = [
        'https://example.com/a',
        'http://example.com',
        'file:///Users/dana/.ssh/config',
        'smb://fs/share',
        'javascript:alert(1)',
        'mailto:dana@example.com',
        'https://',
        '',
        '   ',
      ];

      for (final url in cases) {
        expect(
          webTargetOf(url)?.toString(),
          webUriOf(url)?.toString(),
          reason: url,
        );
      }
    });
  });

  group('stripLinkTargets', () {
    test('a run keeps its label and loses its target', () {
      expect(
        stripLinkTargets('Findings.docx <https://t.example.com/a/Findings.docx>'),
        'Findings.docx',
      );
    });

    test('a run with no label becomes the address in plain text', () {
      expect(
        stripLinkTargets('<https://t.example.com/a>'),
        'https://t.example.com/a',
      );
      expect(
        stripLinkTargets('Findings.docx\n<https://t.example.com/a>'),
        'Findings.docx\nhttps://t.example.com/a',
      );
    });

    test('a bare address that was never in a run is left alone', () {
      const text = 'Read https://example.com/x today, and mail dana@example.com';

      expect(stripLinkTargets(text), same(text));
    });

    test('two runs in a sentence', () {
      expect(
        stripLinkTargets(
          'Go to comment <https://a.example.com/c> or reply '
          '<mailto:x@example.com?subject=Hi>',
        ),
        'Go to comment or reply',
      );
    });
  });

  group('entities', () {
    test('a double-escaped entity decodes once, not twice', () {
      expect(decodeHtmlEntities('a &amp;lt; b &amp;amp; c'), 'a &lt; b &amp; c');
    });

    test('half a surrogate pair is left as it was typed', () {
      final out = decodeHtmlEntities('Q4 &#xD800; revenue &#x2014; done');

      expect(out, 'Q4 &#xD800; revenue — done');
      expect(
        out.codeUnits.any((unit) => unit >= 0xd800 && unit <= 0xdfff),
        isFalse,
      );
    });

    test('a body converted through mail never emits a lone surrogate', () {
      final text = htmlToText(
        '<p>Fees &amp; charges &#xDC00; &#0; &#x110000; done</p>',
        profile: HtmlProfile.mail,
      );

      expect(text, 'Fees & charges &#xDC00; &#0; &#x110000; done');
      expect(
        text.codeUnits.any((unit) => unit >= 0xd800 && unit <= 0xdfff),
        isFalse,
      );
    });
  });

  group('the zero-width delimiters', () {
    test('an attach-as-link run survives the conversion intact', () {
      const url = 'https://contoso.sharepoint.com/:x:/s/deals/EqRsTuVwXyZ';
      final text = htmlToText(
        '<p>$zwsp<a href="$url">'
        '<img src="https://res.cdn.example.com/x.png" alt="Excel Icon">'
        'Budget.xlsx</a>$zwsp</p>',
        profile: HtmlProfile.mail,
      );

      expect(text, '${zwsp}Budget.xlsx <$url>$zwsp');
      expect(text, isNot(contains('Excel Icon')));
    });

    test('a delimiter entity is decoded and not collapsed away', () {
      final text = htmlToText(
        '<p>&#8203;before after&#8203;</p>',
        profile: HtmlProfile.mail,
      );

      expect(text, '${zwsp}before after$zwsp');
      expect(zwsp.allMatches(text).length, 2);
    });
  });

  group('a forged marker', () {
    test('control characters in a body cannot buy a quote level or a bracket',
        () {
      final text = htmlToText(
        '<p>\u0001forged\u0002 \u0003https://evil.example\u0004</p>',
        profile: HtmlProfile.mail,
      );

      expect(text, 'forged https://evil.example');
      expect(text, isNot(contains('>')));
      expect(text, isNot(contains('<')));
    });
  });
}
