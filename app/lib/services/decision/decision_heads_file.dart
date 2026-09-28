/// The decision model's heads file on disk, loaded once and re-read when it
/// changes.
///
/// `DecisionClient` asks for its heads SYNCHRONOUSLY at the top of every
/// call, so this answers synchronously too: a `stat` per call (cheap), and a
/// parse only on the first call and whenever the file's path or modification
/// time moved — which is what `make decide-install` over an older export
/// looks like. The heads are needed even when a remote server embeds (the
/// plan's D12): the nine heads always run here.
library;

import 'dart:convert';
import 'dart:io' show File, FileSystemException;

import '../llm/llm_client.dart'
    show
        DecisionMisconfiguredException,
        DecisionNotInstalledException,
        LlmFormatException;
import 'decision_heads.dart';

class DecisionHeadsFile {
  /// Where the file is RIGHT NOW: the models folder is a preference and can
  /// move, so it is asked on every call rather than captured.
  final String Function() _path;

  DecisionHeadsFile(this._path);

  /// What a missing file says. It reaches the rail through the
  /// `decision_not_installed` park, so the fix is in the sentence.
  static const String notInstalledText =
      'The decision model is not installed. Run: make decide-install';

  /// What a file this build cannot use says, before the parser's own
  /// reason. It parks under `decision_unavailable`.
  static const String mismatchText =
      "The decision model's heads file does not match this build. Run: make "
      'decide-install';

  DecisionHeads? _heads;
  String? _loadedPath;
  DateTime? _loadedModified;

  /// A parse that FAILED, cached like a success: keyed on the same path and
  /// modification time, so a bad file is read once rather than once per
  /// claim, and a re-install (a newer mtime) is read again. A MISSING file is
  /// never cached: it is a `stat`, and it must be seen the moment it lands.
  DecisionMisconfiguredException? _failure;
  String? _failedPath;
  DateTime? _failedModified;

  /// The heads, loading or re-loading them when the file is new to this
  /// cache. Throws [DecisionNotInstalledException] when the file is not
  /// there and [DecisionMisconfiguredException] when it is not a heads file
  /// this build can use. Both park the decision pass: neither is about the
  /// message, so neither may spend its attempts.
  DecisionHeads current() {
    final path = _path();
    final file = File(path);
    final DateTime modified;
    try {
      if (!file.existsSync()) {
        throw const DecisionNotInstalledException(notInstalledText);
      }
      modified = file.lastModifiedSync();
    } on FileSystemException {
      throw const DecisionNotInstalledException(notInstalledText);
    }
    final cached = _heads;
    if (cached != null &&
        _loadedPath == path &&
        _loadedModified == modified) {
      return cached;
    }
    final failed = _failure;
    if (failed != null &&
        _failedPath == path &&
        _failedModified == modified) {
      throw failed;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FileSystemException {
      throw const DecisionNotInstalledException(notInstalledText);
    } on FormatException {
      throw _fail(path, modified, 'It is not JSON.');
    }
    if (decoded is! Map) {
      throw _fail(path, modified, 'It is not a JSON object.');
    }
    final DecisionHeads heads;
    try {
      heads = DecisionHeads.fromJson(decoded.cast<String, Object?>());
    } on LlmFormatException catch (e) {
      throw _fail(path, modified, e.message);
    } catch (_) {
      // A field of the wrong type deep in the file: the same refusal.
      throw _fail(path, modified, 'It could not be read.');
    }
    _heads = heads;
    _loadedPath = path;
    _loadedModified = modified;
    _failure = null;
    return heads;
  }

  DecisionMisconfiguredException _fail(
    String path,
    DateTime modified,
    String why,
  ) {
    final failure = DecisionMisconfiguredException('$mismatchText. $why');
    _failure = failure;
    _failedPath = path;
    _failedModified = modified;
    return failure;
  }
}
