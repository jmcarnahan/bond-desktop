import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;

/// The inventory of what one draft was written from, as stored in
/// `drafts.context_json`.
///
/// The `drafts` table used to store no such inventory, and the composer's
/// provenance caption was a CONSTANT because of it: a line naming what the
/// model read would have been assembled at render time out of guesses. Now
/// the handler that built the prompt writes down what went into it, and the
/// caption is a fact rather than a description of the pipeline.
///
/// Every field is a list of the owner's own words — file names a sender
/// chose, folder names the owner chose — so nothing here is trusted as
/// markup anywhere it is rendered. [decode] is tolerant for the reason every
/// decoder in this app is: a column read on the draft path must cost a
/// caption when it is malformed, never the composer around it.
@immutable
class DraftProvenance {
  /// The attached documents the excerpts came out of, distinct, in the order
  /// they were ranked. `a file` stands in for a document the connector never
  /// named.
  final List<String> documents;

  /// The display names of the directories in scope, whether or not a passage
  /// came out of one. A room that has a project linked and nothing indexed in
  /// it yet still read the project's brief.
  final List<String> directories;

  /// The distinct `(directory, path, locator)` of the passages that reached
  /// the prompt, in the order they were ranked.
  final List<({String dir, String path, String locator})> files;

  /// The skills that matched — the owner's own instructions this reply was
  /// written under.
  final List<String> skills;

  const DraftProvenance({
    required this.documents,
    required this.directories,
    required this.files,
    required this.skills,
  });

  static const DraftProvenance none = DraftProvenance(
    documents: [],
    directories: [],
    files: [],
    skills: [],
  );

  /// What the composer's caption says when nothing beyond the thread was
  /// read, and the fallback the screen keeps for a draft written before any
  /// of this existed.
  static const String base = '$_from and your past mail';

  /// The half of the sentence that is true of every suggestion. [base] and
  /// [caption] are built from it rather than from each other, so the two
  /// cannot drift into saying different things about the same draft.
  static const String _from = '✨ Suggested reply — drafted from this thread';

  bool get isEmpty =>
      documents.isEmpty &&
      directories.isEmpty &&
      files.isEmpty &&
      skills.isEmpty;

  /// Snake_case keys and all four of them, always — including the empty ones,
  /// on `ContextFileDigest.toJson`'s reasoning: a reader that has to ask
  /// whether a key is there is a reader that will one day forget.
  String encode() => jsonEncode({
        'documents': documents,
        'directories': directories,
        'files': [
          for (final file in files)
            {'dir': file.dir, 'path': file.path, 'locator': file.locator},
        ],
        'skills': skills,
      });

  /// A `context_json` column as a [DraftProvenance], or null.
  ///
  /// Null for absent, empty, unparseable and anything that does not decode to
  /// a map — every one of those means "this draft recorded nothing" to every
  /// caller, and one branch is enough for all of them. Missing keys read as
  /// empty lists and entries of the wrong type are dropped, because a row
  /// written by an earlier build is a row that met a different validator.
  static DraftProvenance? decode(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return null;
      return DraftProvenance(
        documents: _strings(decoded['documents']),
        directories: _strings(decoded['directories']),
        files: _files(decoded['files']),
        skills: _strings(decoded['skills']),
      );
    } on FormatException {
      return null;
    }
  }

  /// The caption above an untouched suggestion, or null when there is nothing
  /// to add to [base].
  ///
  /// The shape is one sentence that grows: the thread and the past mail are
  /// always true, then the documents by name, then the directories in
  /// «guillemets» with what was actually read from them in brackets. Three
  /// files at most and then `+N more`, because this is a two-line caption
  /// above a reply box and not a manifest.
  String? caption() {
    if (isEmpty) return null;
    // The past mail is the first item of the list rather than part of the
    // stem, so one extra source reads "your past mail and «acme»" and three
    // read as a list — instead of an "and" for every one of them.
    final sources = <String>[
      'your past mail',
      ...documents,
      for (final directory in directories) '«$directory»',
    ];
    if (sources.length == 1) return null;

    final detail = <String>[
      for (final file in files.take(_maxFiles))
        file.locator.isEmpty
            ? file.path
            : '${file.path} § ${_locator(file.locator)}',
      if (files.length > _maxFiles) '+${files.length - _maxFiles} more',
      for (final skill in skills) 'SKILL $skill',
    ];

    final tail = detail.isEmpty ? '' : ' (${detail.join(' · ')})';
    return '$_from, ${_list(sources)}$tail';
  }

  /// How many files a caption names before it starts counting them.
  static const int _maxFiles = 3;

  /// `digest` is what the column, the work kind and the code call a per-file
  /// summary. `summary` is what a person reading a caption above their reply
  /// box understands — the same word the Settings switch uses.
  ///
  /// The chunker writes a heading path as `Pricing > Q4 rates`, which is a
  /// comparison operator sitting in the middle of a sentence a person is
  /// reading. The caption draws it as a breadcrumb instead. Only the caption:
  /// the stored JSON keeps the chunker's own spelling, so the locator in the
  /// row still matches the locator in the index.
  static String _locator(String locator) => locator == 'digest'
      ? 'summary'
      : locator.replaceAll(' > ', ' › ');

  /// `a`, `a and b`, `a, b and c`. An Oxford-comma-free list, because it is
  /// running prose in a caption rather than an enumeration.
  static String _list(List<String> items) {
    if (items.length == 1) return items.single;
    return '${items.sublist(0, items.length - 1).join(', ')} '
        'and ${items.last}';
  }

  static List<String> _strings(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is String) entry,
    ];
  }

  /// A file needs a path to be worth naming; a directory and a locator are
  /// both allowed to be missing, because a passage from a whole one-page file
  /// has no section to cite.
  static List<({String dir, String path, String locator})> _files(Object? raw) {
    if (raw is! List) return const [];
    final files = <({String dir, String path, String locator})>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final path = entry['path'];
      if (path is! String || path.isEmpty) continue;
      files.add((
        dir: entry['dir'] is String ? entry['dir']! as String : '',
        path: path,
        locator: entry['locator'] is String ? entry['locator']! as String : '',
      ));
    }
    return files;
  }
}
