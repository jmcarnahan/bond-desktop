import 'dart:io';

import 'package:bond_inbox/services/context/context_walk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// What the app is allowed to read out of a folder somebody registered.
///
/// This is the only part of the feature that touches a real disk, so the
/// tests build real trees rather than mocking a walk: the rules being pinned
/// here are about names, dots and separators, and every one of them has a
/// spelling that only shows up against a real `Directory.list`.
///
/// The stakes are asymmetric. A file wrongly SKIPPED is a question the app
/// answers with a shrug; a file wrongly READ can be a private key in a
/// database on a public machine. The denylist tests are the second kind.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('bond_ctx_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Creates a file at [rel] (always `/`-separated), making its parents.
  void write(String rel, [String content = 'words']) {
    final file = File(p.join(root.path, p.joinAll(rel.split('/'))));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  Future<WalkResult> walk({
    bool honorGitignore = false,
    int maxFiles = defaultMaxFiles,
    int maxTextBytes = defaultMaxTextBytes,
  }) =>
      walkDirectory(
        root.path,
        honorGitignore: honorGitignore,
        maxFiles: maxFiles,
        maxTextBytes: maxTextBytes,
      );

  Future<List<String>> paths({
    bool honorGitignore = false,
    int maxFiles = defaultMaxFiles,
    int maxTextBytes = defaultMaxTextBytes,
  }) async =>
      [
        for (final file in (await walk(
          honorGitignore: honorGitignore,
          maxFiles: maxFiles,
          maxTextBytes: maxTextBytes,
        ))
            .files)
          file.relPath,
      ];

  group('what the walk refuses to look at', () {
    test('machinery directories are skipped wherever they sit', () async {
      write('.git/config', 'core stuff');
      write('node_modules/left-pad/index.js', 'module.exports = 1;');
      write('build/app.js', 'bundled');
      write('.venv/lib/site.py', 'import sys');
      write('nested/__pycache__/model.py', 'cached');
      write('nested/model.py', 'def rate(): return 41');

      // A dependency tree indexed alongside the project buries the project's
      // own words under a hundred thousand passages of somebody else's.
      expect(await paths(), ['nested/model.py']);
    });

    test('dot-directories are skipped, except .claude', () async {
      write('.cache/x.md', '# cached');
      write('.claude/skills/vendor-notes/SKILL.md', '# Vendor notes');

      final found = await paths();

      // `.claude` is the one dot-directory that is CONTENT: it holds the
      // skills and rules this whole feature exists to read.
      expect(found, contains('.claude/skills/vendor-notes/SKILL.md'));
      expect(found, isNot(contains('.cache/x.md')));
    });

    test('a denied tree is pruned, not listed and then thrown away',
        () async {
      write('node_modules/left-pad/index.js', 'module.exports = 1;');
      write('node_modules/left-pad/readme.md', '# left-pad');
      write('node_modules/rxjs/operators.js', 'export const map = 1;');
      write('app.js', 'const app = 1;');

      final result = await walk();

      expect([for (final file in result.files) file.relPath], ['app.js']);
      // One, not three. `skipped` counts a pruned DIRECTORY once, because the
      // files under it were never listed — which is the point: a dependency
      // tree of fifty thousand files must not be stat-walked once a minute
      // only to be filtered out afterwards.
      expect(result.skipped, 1);
    });

    test('the file denylist matches by name at any depth', () async {
      write('pnpm.lock', 'lockfile noise');
      write('.env', 'API_TOKEN=nope');
      write('deep/.env.local', 'API_TOKEN=also-nope');
      write('certs/server.pem', '-----BEGIN CERTIFICATE-----');
      write('certs/id.key', '-----BEGIN PRIVATE KEY-----');
      write('notes.md', '# Notes');

      // Depth must not launder a secret: an app that reads a person's folders
      // must never be the thing that copies their private key into a table.
      expect(await paths(), ['notes.md']);
    });

    test('.bondignore at the root is honoured, comments and all', () async {
      write('.bondignore', '# generated, not written\n\nreports/**\n');
      write('reports/q3.md', '# Generated');
      write('docs/q3.md', '# Written by hand');

      final found = await paths();

      expect(found, contains('docs/q3.md'));
      expect(found, isNot(contains('reports/q3.md')));
    });

    test('.gitignore is ignored by default and honoured when asked', () async {
      write('.gitignore', 'output/**\n');
      write('output/run.md', '# Analysis run');

      // The default is off on purpose: Claude Code drops its analyses into
      // gitignored `output/` folders, which are exactly the files worth
      // reading. The flag exists for a person who disagrees.
      expect(await paths(), contains('output/run.md'));
      expect(
        await paths(honorGitignore: true),
        isNot(contains('output/run.md')),
      );
    });
  });

  group('whether there are words in it', () {
    test('a NUL in the header demotes a file with a text extension', () async {
      final file = File(p.join(root.path, 'data', 'blob.json'));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync([...'{"rows":'.codeUnits, 0, ...'}'.codeUnits]);

      final found = (await walk()).files.single;

      // Listed, not dropped — the row is how the app says "this is here and
      // there is nothing to read in it" instead of rediscovering it as new on
      // every sync.
      expect(found.relPath, 'data/blob.json');
      expect(found.isText, isFalse);
      expect(found.reason, 'binary');
    });

    test('a shape with no extractor is listed as not_text', () async {
      write('art/logo.png', 'not really a png');

      final found = (await walk()).files.single;

      expect(found.isText, isFalse);
      expect(found.reason, 'not_text');
    });

    test('a file over four megabytes is listed and not read', () async {
      final file = File(p.join(root.path, 'huge.log'));
      file.writeAsBytesSync(List.filled(maxContextFileBytes + 1, 65));

      final found = (await walk()).files.single;

      // Four megabytes of one file is a log or a dump, and it would be most
      // of the whole-directory budget on its own.
      expect(found.isText, isFalse);
      expect(found.reason, 'too_large');
      expect(found.size, maxContextFileBytes + 1);
    });

    test('a readable file carries its size and a UTC mtime', () async {
      write('notes.md', '# Notes');

      final found = (await walk()).files.single;

      expect(found.isText, isTrue);
      expect(found.reason, isNull);
      expect(found.size, 7);
      // Stored as text because that is what the column holds; a comparison
      // across two representations is a bug waiting for a timezone.
      expect(found.mtime, endsWith('Z'));
      expect(DateTime.parse(found.mtime).isUtc, isTrue);
    });
  });

  group('caps', () {
    test('the file cap keeps what says what the project IS', () async {
      write('.claude/rules/pricing.md', '# Pricing rule');
      write('CLAUDE.md', '# Standing notes');
      write('README.md', '# Halcyon Freight tools');
      write('docs/a.md', '# Architecture');
      write('zzz1.md', 'a');
      write('zzz2.md', 'b');
      write('zzz3.md', 'c');
      write('zzz4.md', 'd');

      final result = await walk(maxFiles: 5);

      // Precedence, not luck: a directory too large to index whole should
      // still index the part that introduces it.
      expect(result.truncated, isTrue);
      expect(result.files.map((f) => f.relPath), [
        '.claude/rules/pricing.md',
        'CLAUDE.md',
        'README.md',
        'docs/a.md',
        'zzz1.md',
      ]);
    });

    test('the list comes back sorted by path', () async {
      write('zebra.md', 'z');
      write('CLAUDE.md', 'c');
      write('docs/api.md', 'a');
      write('alpha.md', 'a');

      final found = await paths();

      // The caps needed precedence order to choose; every reader after this
      // wants the order a person would list a folder in.
      final sorted = [...found]..sort();
      expect(found, sorted);
      expect(found, hasLength(4));
    });

    test('the byte cap demotes rather than drops', () async {
      write('docs/a.md', '# Small');
      write('zzz.md', 'x' * 500);

      final result = await walk(maxTextBytes: 100);
      final big = result.files.firstWhere((f) => f.relPath == 'zzz.md');

      // Still listed, so the next sync does not rediscover it as new — but
      // with no words asked of it.
      expect(result.truncated, isTrue);
      expect(big.isText, isFalse);
      expect(big.reason, 'too_large');
      expect(
        result.files.firstWhere((f) => f.relPath == 'docs/a.md').isText,
        isTrue,
      );
    });

    test('an untruncated walk says so', () async {
      write('notes.md', '# Notes');

      expect((await walk()).truncated, isFalse);
    });
  });

  test('a missing root is an empty walk, not a throw', () async {
    final gone = Directory(p.join(root.path, 'never-registered'));

    final result = await walkDirectory(gone.path);

    // A folder the user moved or unmounted must not fail the sync that also
    // covers four other folders.
    expect(result.files, isEmpty);
    expect(result.truncated, isFalse);
  });

  test(
    'a subdirectory that will not open costs itself and nothing else',
    () async {
      write('notes.md', '# Notes');
      write('locked/secret.md', '# Not readable');
      write('docs/plan.md', '# Plan');
      final locked = Directory(p.join(root.path, 'locked'));
      Process.runSync('chmod', ['000', locked.path]);
      // Before the recursive tearDown, or the folder cannot be deleted
      // either.
      addTearDown(() => Process.runSync('chmod', ['755', locked.path]));

      final result = await walk();

      // A `Directory.list(recursive: true)` reports this by putting a
      // `FileSystemException` into the stream, which ends the walk and
      // leaves the whole project unindexed over one folder's permissions.
      expect(
        [for (final file in result.files) file.relPath],
        ['docs/plan.md', 'notes.md'],
      );
      expect(result.skipped, greaterThanOrEqualTo(1));
    },
    skip: Platform.environment['USER'] == 'root'
        ? 'root reads a 000 directory anyway'
        : null,
  );

  test('symlinks are not followed', () async {
    write('notes.md', '# Notes');
    Link(p.join(root.path, 'loop')).createSync(root.path);

    final result = await walk();

    // A project with a link to its own parent is a walk that never ends, and
    // a link out of the folder is a path the user never granted.
    expect([for (final file in result.files) file.relPath], ['notes.md']);
    // Counted, like every other thing the walk stepped over: a path the app
    // declined to read is a diagnostic, not a silence.
    expect(result.skipped, 1);
  });

  group('contextKindFor', () {
    test('the two Claude Code conventions come first', () {
      expect(contextKindFor('CLAUDE.md'), 'claude_md');
      expect(contextKindFor('docs/CLAUDE.md'), 'claude_md');
      expect(
        contextKindFor('.claude/skills/vendor-notes/SKILL.md'),
        'skill',
      );
      expect(contextKindFor('.claude/rules/pricing.md'), 'rule');
    });

    test('a file beside a SKILL.md is not itself a skill', () {
      // Only the `SKILL.md` at `<name>/` is the skill; the notes a skill
      // keeps next to it are documents, and treating them as guidance would
      // put a scratch file into a reply's instructions.
      expect(
        contextKindFor('.claude/skills/vendor-notes/extra.md'),
        isNot('skill'),
      );
      expect(contextKindFor('.claude/skills/vendor-notes/extra.md'), 'doc');
    });

    test('everything else falls out of the extension', () {
      expect(contextKindFor('src/main.dart'), 'code');
      expect(contextKindFor('run.py'), 'code');
      expect(contextKindFor('data/rows.csv'), 'data');
      expect(contextKindFor('conf.json'), 'data');
      expect(contextKindFor('docs/plan.md'), 'doc');
      expect(contextKindFor('art/logo.png'), 'other');
      expect(contextKindFor('Makefile'), 'other');
    });
  });

  group('claudeChainFor', () {
    const claudeMds = {'CLAUDE.md', 'analysis/CLAUDE.md'};

    test('every governing CLAUDE.md, root first', () {
      // Root first because the nested file is the amendment: a reader that
      // applies them in order ends on the most specific statement.
      expect(
        claudeChainFor('analysis/pricing/model.py', claudeMds),
        ['CLAUDE.md', 'analysis/CLAUDE.md'],
      );
      expect(claudeChainFor('notes.md', claudeMds), ['CLAUDE.md']);
    });

    test('a file never governs itself', () {
      // Without this the root notes would arrive attached to the root notes,
      // which is the same passage twice in one prompt.
      expect(claudeChainFor('CLAUDE.md', claudeMds), isEmpty);
      expect(claudeChainFor('analysis/CLAUDE.md', claudeMds), ['CLAUDE.md']);
    });

    test('a directory with no notes contributes nothing', () {
      expect(claudeChainFor('analysis/pricing/model.py', const {}), isEmpty);
    });
  });
}
