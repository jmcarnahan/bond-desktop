import 'dart:convert';

import 'package:bond_inbox/services/context/context_extract.dart';
import 'package:flutter_test/flutter_test.dart';

/// Turning one local file's bytes into the words a search can answer with.
///
/// The shapes here are the ones a mail attachment almost never is and a
/// person's own project folder almost always has: a rendered HTML analysis, a
/// notebook, a CSV of results. Each has a way of going wrong that costs a
/// whole index — a Plotly export whose megabyte of JavaScript embeds as
/// English, a notebook whose base64 chart embeds as nothing — so the tests
/// below assert what is ABSENT as hard as what survives.
void main() {
  ExtractedText extract(String relPath, String source, {int? maxChars}) {
    final result = maxChars == null
        ? extractContextText(relPath, utf8.encode(source))
        : extractContextText(relPath, utf8.encode(source), maxChars: maxChars);
    return result!;
  }

  group('a rendered HTML analysis', () {
    // The case the HTML path exists for: a chart export where the script is
    // most of the file and the findings are one page inside it.
    final blob = List.filled(4000, '{"x":1,"y":2}').join(',');
    final page = '''
<html>
<head>
<title>Marrowfield internal — do not index</title>
</head>
<body>
<style>.chart { color: #123456; background: url(sprite.png); }</style>
<!-- regenerated nightly from the warehouse -->
<h1>Cohort churn, Q4</h1>
<p>Churn &amp; retention &lt;strong&gt; and &#39;quotes&#39; &#x2014; done.</p>
<h2>Method</h2>
<p>Cohorts&nbsp;are bucketed by signup month.</p>
<table>
<tr><th>Cohort</th><th>Churn</th></tr>
<tr><td>Jan 2031</td><td>4.1%</td></tr>
<tr><td>Feb 2031</td><td>3.8%</td></tr>
</table>
<img alt="Churn by cohort" src="chart.png">
<script>Plotly.newPlot("chart", [$blob]);</script>
</body>
</html>
''';

    test('the script, the style and the head go before anything else', () {
      final text = extract('reports/churn.html', page).text;

      // Strip tags first and the index fills with minified JS that happens to
      // contain English words. Strip the script FIRST and what is left is the
      // page a person read.
      expect(text, isNot(contains('Plotly')));
      expect(text, isNot(contains('newPlot')));
      expect(text, isNot(contains('123456')));
      expect(text, isNot(contains('do not index')));
      expect(text, isNot(contains('regenerated nightly')));
    });

    test('the structure a reader used survives', () {
      final text = extract('reports/churn.html', page).text;

      // The `#` prefixes are not decoration: the chunker cuts markdown on
      // them, so an HTML analysis chunks by its own headings.
      expect(text, contains('# Cohort churn, Q4'));
      expect(text, contains('## Method'));
      expect(text, contains('Cohorts are bucketed by signup month.'));
      // A chart's `alt` is the one sentence saying what it shows, and it is
      // routinely the most retrievable line on the page.
      expect(text, contains('Churn by cohort'));
    });

    test('a table row stays one row, tab separated', () {
      final text = extract('reports/churn.html', page).text;

      // Cells run together are a row nobody can search and a number with no
      // column name attached.
      expect(text, contains('Cohort\tChurn'));
      expect(text, contains('Jan 2031\t4.1%'));
      expect(text, contains('Feb 2031\t3.8%'));
    });

    test('entities are decoded', () {
      final text = extract('reports/churn.html', page).text;

      expect(text, contains("Churn & retention <strong> and 'quotes' — done."));
    });

    test('the page is a fraction of the file', () {
      final result = extract('reports/churn.html', page);

      // The whole point. If this ratio ever creeps up, the script sweep has
      // stopped matching and every export is being indexed as JavaScript.
      expect(result.text.length, lessThan(page.length ~/ 10));
      expect(result.truncated, isFalse);
    });

    test('a double-escaped entity decodes once, not twice', () {
      final text = extract('n.html', '<p>a &amp;lt; b &amp;amp; c</p>').text;

      // `&amp;` is decoded LAST for exactly this: text that was escaped twice
      // is text that meant to show the escape.
      expect(text, contains('a &lt; b'));
      expect(text, isNot(contains('a < b')));
      expect(text, contains('b &amp; c'));
    });

    test('a truncated file loses the script it never closed', () {
      // The walk reads whatever is on disk, and a page still being written —
      // or a download that died — ends inside its `<script>`. The matched-pair
      // sweep cannot see that one, and without the unclosed-tail sweep the
      // tag alone is stripped and the whole body is indexed as English.
      final text = extract(
        'reports/half.html',
        '<h1>Churn</h1><p>Retention held.</p>'
        '<script>var plotConfig = {"displaylogo": false}; '
        'Plotly.newPlot("chart", data);',
      ).text;

      expect(text, contains('# Churn'));
      expect(text, contains('Retention held.'));
      expect(text, isNot(contains('Plotly')));
      expect(text, isNot(contains('displaylogo')));
    });

    test('half a surrogate pair is left as it was typed', () {
      final text = extract('n.html', '<p>Q4 &#xD800; revenue</p>').text;

      // Dart will hold a lone surrogate and UTF-8 cannot encode one, so
      // decoding this would produce a string that travels as far as the
      // database write or the embedding POST and throws there.
      expect(text, contains('&#xD800;'));
      expect(
        text.codeUnits.any((unit) => unit >= 0xd800 && unit <= 0xdfff),
        isFalse,
      );
    });

    test('a self-closing chart does not eat the page after it', () {
      // Every matplotlib and Plotly export writes its inline `<svg …/>`
      // closed in the tag. Treated as an unclosed block, the sweep runs to
      // the end of the file and the findings BELOW the chart — which is
      // where findings sit — are the whole of what is lost.
      final text = extract(
        'reports/q4.html',
        '<h1>Q4 revenue</h1><svg aria-label="Revenue by month"/>'
        '<p>Revenue was 4.2M.</p>',
      ).text;

      expect(text, contains('# Q4 revenue'));
      expect(text, contains('Revenue was 4.2M.'));
      // The picture's label is the one sentence saying what it shows, and a
      // self-closing tag still has one.
      expect(text, contains('Revenue by month'));
    });

    test('a head with no closing tag costs the head and not the body', () {
      // `</head>` is optional in HTML and plenty of generators omit it. The
      // head still must not be indexed — it is the title, the meta and the
      // stylesheet links — but it ends where the body starts, not at EOF.
      final text = extract(
        'reports/open.html',
        '<html><head><title>Internal — do not index</title>'
        '<meta name="generator" content="pandoc">'
        '<body><h1>Churn</h1><p>Retention held.</p></body></html>',
      ).text;

      expect(text, contains('# Churn'));
      expect(text, contains('Retention held.'));
      expect(text, isNot(contains('do not index')));
      expect(text, isNot(contains('pandoc')));
    });
  });

  group('a notebook', () {
    final notebook = jsonEncode({
      'cells': [
        {
          'cell_type': 'markdown',
          'source': '# Cohort churn\n\nPulled from the Marrowfield warehouse.',
        },
        {
          'cell_type': 'code',
          'source': [
            'import polars as pl\n',
            'frame = pl.read_parquet("cohorts.parquet")\n',
          ],
          'outputs': [
            {
              'output_type': 'stream',
              'text': ['shape: (4, 3)\n'],
            },
            {
              'output_type': 'execute_result',
              'data': {'text/plain': 'cohort  churn\nJan 2031  4.1'},
            },
            {
              'output_type': 'display_data',
              'data': {'image/png': 'iVBORw0KGgoAAAANSUhEUg0000FAKE'},
            },
          ],
        },
      ],
      'nbformat': 4,
    });

    test('is read as the document a person wrote', () {
      final text = extract('analysis/churn.ipynb', notebook).text;

      expect(text, contains('# Cohort churn'));
      expect(text, contains('Pulled from the Marrowfield warehouse.'));
      // Fenced so the chunker and the reader can both see where code starts.
      expect(
        text,
        contains(
          '```\nimport polars as pl\n'
          'frame = pl.read_parquet("cohorts.parquet")\n```',
        ),
      );
    });

    test('text outputs are kept and the picture is not', () {
      final text = extract('analysis/churn.ipynb', notebook).text;

      expect(text, contains('shape: (4, 3)'));
      expect(text, contains('cohort  churn'));
      // A base64 PNG is a megabyte that embeds as nothing, and the
      // `text/plain` beside it is the table the chart drew.
      expect(text, isNot(contains('iVBORw0KGgo')));
    });

    test('a notebook that is not JSON falls back to its raw text', () {
      const half = 'half-written by a tool, {"cells": ';

      // The honest answer for a `.ipynb` a crash left behind: index what is
      // there rather than the empty string.
      expect(extract('analysis/broken.ipynb', half).text, half);
    });
  });

  group('a table', () {
    String csv(int rows) => [
          'cohort,signups,churn',
          for (var i = 1; i <= rows; i++) 'row$i,${100 + i},${i / 10}',
        ].join('\n');

    test('a long CSV keeps its header and forty rows, and says so', () {
      final result = extract('data/cohorts.csv', csv(100));

      // The header is the only part that names the columns; a hundred
      // thousand rows of numbers embed as noise.
      expect(result.text, contains('cohort,signups,churn'));
      expect(result.text, contains('row40,'));
      expect(result.text, isNot(contains('row41,')));
      // The trailer is what stops a passage quoting this from reading as the
      // whole file.
      expect(result.text, endsWith('[… 60 more rows]'));
      expect(result.truncated, isTrue);
    });

    test('a short CSV comes back whole', () {
      final result = extract('data/small.csv', csv(5));

      expect(result.text, csv(5));
      expect(result.truncated, isFalse);
    });

    test('a TSV gets the same treatment', () {
      final tsv = [
        'cohort\tsignups\tchurn',
        for (var i = 1; i <= 100; i++) 'row$i\t${100 + i}\t${i / 10}',
      ].join('\n');

      final result = extract('data/cohorts.tsv', tsv);

      expect(result.text, contains('row40\t'));
      expect(result.text, isNot(contains('row41\t')));
      expect(result.truncated, isTrue);
    });
  });

  group('everything else', () {
    test('comes back as it was written', () {
      const md = '# Notes\n\nHalcyon Freight moved the pickup to Thursday.\n';
      const py = 'def rate(pallets):\n    return pallets * 41\n';
      const json = '{"desk": "Marrowfield", "rate": 41}';
      const txt = 'Devi Okonkwo owns the sheet.\n';

      // No cleverness: a `.md` is already the shape the chunker wants, and
      // rewriting it would only lose something.
      expect(extract('notes.md', md).text, md);
      expect(extract('src/rate.py', py).text, py);
      expect(extract('conf.json', json).text, json);
      expect(extract('notes.txt', txt).text, txt);
    });

    test('the character cap takes the head and admits it', () {
      final long = '# Notes\n${'pallet ' * 400}';

      final result = extract('notes.md', long, maxChars: 100);

      expect(result.text, long.substring(0, 100));
      expect(result.text, hasLength(100));
      // Carried so the caller can say so rather than quietly presenting a
      // fragment as the whole file.
      expect(result.truncated, isTrue);
    });
  });
}
