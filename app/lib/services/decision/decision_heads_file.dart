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
    show DecisionUnavailableException, LlmFormatException;
import 'decision_heads.dart';

class DecisionHeadsFile {
  /// Where the file is RIGHT NOW: the models folder is a preference and can
  /// move, so it is asked on every call rather than captured.
  final String Function() _path;

  DecisionHeadsFile(this._path);

  /// What a missing file says. It reaches the rail through the
  /// `decision_unavailable` park, so the fix is in the sentence.
  static const String notInstalledText =
      'The decision model is not installed. Run: make decide-install';

  DecisionHeads? _heads;
  String? _loadedPath;
  DateTime? _loadedModified;

  /// The heads, loading or re-loading them when the file is new to this
  /// cache. Throws [DecisionUnavailableException] when the file is not there
  /// (the decision pass parks, like a server that is down) and
  /// [LlmFormatException] when it is not a heads file this build can use.
  DecisionHeads current() {
    final path = _path();
    final file = File(path);
    final DateTime modified;
    try {
      if (!file.existsSync()) {
        throw const DecisionUnavailableException(notInstalledText);
      }
      modified = file.lastModifiedSync();
    } on FileSystemException {
      throw const DecisionUnavailableException(notInstalledText);
    }
    final cached = _heads;
    if (cached != null &&
        _loadedPath == path &&
        _loadedModified == modified) {
      return cached;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FileSystemException {
      throw const DecisionUnavailableException(notInstalledText);
    } on FormatException {
      throw const LlmFormatException('The decision heads file is not JSON.');
    }
    if (decoded is! Map) {
      throw const LlmFormatException(
        'The decision heads file is not a JSON object.',
      );
    }
    final heads = DecisionHeads.fromJson(decoded.cast<String, Object?>());
    _heads = heads;
    _loadedPath = path;
    _loadedModified = modified;
    return heads;
  }
}
