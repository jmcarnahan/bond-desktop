/// Handing a web-page attachment to the browser, on purpose and only here.
///
/// The generic Open stays withheld for a page — `openRefused` is unchanged, and
/// `.html` is still in its list — because "hand this to whatever the operating
/// system decides opening means" is not an offer worth making for a file a
/// stranger mailed. This is the narrower door the owner asked for instead: one
/// control, labelled with where it goes, with a caution under it, and reaching
/// only the browser.
///
/// A page from a `file:` origin can still ask for a password, and that is the
/// whole reason the caution on the control says so. What this function can do
/// about it is keep the file honest: the bytes come from the cache the preview
/// already read, and the name handed to the browser is sanitised here rather
/// than trusted from the wire.
///
/// **A temp directory and never the attachment cache.** That cache is
/// content-addressed — the path asserts what the bytes hash to — and writing a
/// human-named copy into it would put a file there whose name means nothing to
/// the sweep. The browser needs a readable title and a `.html` suffix, so the
/// copy lives where copies belong.
///
/// **One directory per attachment, under one parent.** A fresh
/// `createTemp` per press left a copy of every page ever opened lying in
/// `/var/folders` until the operating system got around to reaping it. The
/// folder name is derived from WHICH attachment this is, so pressing the same
/// page twice overwrites one file instead of writing a second, and the parent
/// is swept of directories nothing has touched in [_keepFor] on the way past.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:url_launcher/url_launcher.dart';

import '../../models/attachment_models.dart';
import 'attachment_bytes.dart';
import 'attachment_cache.dart';

/// Writes [ref]'s bytes somewhere readable and opens them in the default
/// browser. False on any failure, so a host can say so once.
///
/// [launch] is the seam a test drives; the default is the real launcher.
/// [tempRoot] is the other one, so a test sweeps its own directory rather than
/// the machine's.
Future<bool> openHtmlInBrowser(
  AttachmentRef ref, {
  required AttachmentBytes bytes,
  Future<bool> Function(Uri uri) launch = _launchExternally,
  Directory? tempRoot,
}) async {
  try {
    final data = await bytes.bytesFor(ref);
    final folder = await _folderFor(ref, tempRoot ?? Directory.systemTemp);
    final file = File('${folder.path}${Platform.pathSeparator}'
        '${htmlFileNameFor(ref.name)}');
    await file.writeAsBytes(data, flush: true);
    return await launch(Uri.file(file.path));
  } on Object catch (e) {
    // The exception is a path, a socket error or a plugin's own words, and none
    // of those tell the reader anything they can act on.
    debugPrint('open in browser failed for ${ref.attachmentId}: $e');
    return false;
  }
}

/// Where copies of opened pages live, under the system temp directory.
const String pagesFolderName = 'bond-pages';

/// How long an untouched page directory is kept. A day, because the reason to
/// keep one at all is that the browser tab holding it may outlive the app: a
/// reload of a page opened this morning should still find its file.
const Duration _keepFor = Duration(days: 1);

/// This attachment's own directory, created, with the stale siblings gone.
Future<Directory> _folderFor(AttachmentRef ref, Directory temp) async {
  final parent = Directory('${temp.path}${Platform.pathSeparator}'
      '$pagesFolderName');
  final mine = Directory('${parent.path}${Platform.pathSeparator}'
      '${pageFolderNameFor(ref)}');
  await mine.create(recursive: true);
  await _sweep(parent, keeping: mine.path);
  return mine;
}

/// The directory name for [ref] — the same one every time, which is the whole
/// point: one page, one copy, however many times it is opened.
///
/// Hashed rather than spelled out, and not only for the path's sake: a temp
/// directory listing is readable by anything running as this user, and a
/// message id in a path name says who is talking to whom.
String pageFolderNameFor(AttachmentRef ref) {
  final identity = [ref.source, ref.messageId, ref.attachmentId].join('|');
  final hash = AttachmentCache.hashOf(
    Uint8List.fromList(utf8.encode(identity)),
  );
  return hash.substring(0, 16);
}

/// Drops the page directories nothing has touched lately.
///
/// Best effort in every direction, and a failure is never allowed near the
/// press: a page a browser still has open can be unremovable, a listing can
/// race another window doing the same sweep, and a copy left behind is a far
/// smaller problem than an Open that failed because of one.
Future<void> _sweep(Directory parent, {required String keeping}) async {
  try {
    final entries = await parent.list(followLinks: false).toList();
    for (final entry in entries) {
      if (entry is! Directory || entry.path == keeping) continue;
      if (await _touchedSince(entry, DateTime.now().subtract(_keepFor))) {
        continue;
      }
      try {
        await entry.delete(recursive: true);
      } on Object catch (e) {
        debugPrint('temp page kept, could not remove ${entry.path}: $e');
      }
    }
  } on Object catch (e) {
    debugPrint('temp page sweep skipped: $e');
  }
}

/// Whether anything in [folder] is newer than [cutoff]. True when it cannot be
/// read at all: a directory this cannot see into is one to leave alone.
Future<bool> _touchedSince(Directory folder, DateTime cutoff) async {
  try {
    for (final entry in await folder.list(followLinks: false).toList()) {
      if ((await entry.stat()).modified.isAfter(cutoff)) return true;
    }
  } on Object catch (e) {
    debugPrint('temp page age unreadable ${folder.path}: $e');
    return true;
  }
  return false;
}

/// The longest stem handed to the browser. A page's own `<title>` is what the
/// tab shows; this only has to be recognisable in a download list.
const int _nameCap = 64;

/// [name] as a file name that is a name and not a path, always ending `.html`.
///
/// Stricter than the save panel's `safeSuggestedName`, and for a different
/// reason: nobody is about to read this in a field and correct it. Separators
/// and control characters are dropped rather than replaced, a leading dot goes
/// (a hidden file is not what the browser should open), and the suffix is
/// FORCED — a page the browser is handed without one renders as source.
String htmlFileNameFor(String? name) {
  final cleaned = (name ?? '')
      .replaceAll(RegExp(r'[/\\:\x00-\x1f\x7f]'), '')
      .trim();
  // The suffix comes off BEFORE the leading dots, so that a file called
  // `.html` and nothing else ends up as the fallback rather than as
  // `html.html`.
  final stem = cleaned
      .replaceAll(RegExp(r'\.(html?|xhtml)$', caseSensitive: false), '')
      .replaceAll(RegExp(r'^[.\s]+'), '');
  // By code point, never by index: `substring` splits a surrogate pair and
  // leaves half a character in a path.
  final capped = String.fromCharCodes(stem.runes.take(_nameCap)).trim();
  return capped.isEmpty ? 'page.html' : '$capped.html';
}

Future<bool> _launchExternally(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);
