import 'package:flutter/material.dart';

import '../../services/models/download_state.dart';
import '../../services/models/model_manifest.dart';
import '../../theme/tokens.dart';
import '../../widgets/attachment_format.dart' show formatBytes;
import 'setup_controls.dart';

/// Step five: the twenty-three gigabytes, arriving.
///
/// PROP-ONLY. [files] is the manifest in `bySize` order — the order the
/// downloader actually works in — so the bar that is moving is the one at the
/// top rather than somewhere in the middle.
///
/// Continue is enabled only when EVERY file is done, not at the "usable" pair
/// (embed + bulk). Two reasons, and the first is decisive:
/// `ModelServerSupervisor._launch` refuses to start while any file the preset
/// names is missing, so a partial set could not serve the inbox anyway; and
/// finishing early would leave a non-engineer looking at an idle inbox with
/// no progress bar left to explain it.
class SetupDownloadBody extends StatelessWidget {
  final List<ModelFile> files;

  /// The latest position of each file, by id. A file with no entry has not
  /// been reached yet and renders as `Waiting` at zero.
  final Map<String, DownloadProgress> progress;

  final bool running;
  final bool paused;
  final bool complete;

  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;
  final VoidCallback onContinue;

  const SetupDownloadBody({
    super.key,
    required this.files,
    required this.progress,
    required this.running,
    required this.paused,
    required this.complete,
    required this.onStart,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
    required this.onContinue,
  });

  static const Key startKey = ValueKey('setup-download-start');
  static const Key pauseKey = ValueKey('setup-download-pause');
  static const Key resumeKey = ValueKey('setup-download-resume');
  static const Key cancelKey = ValueKey('setup-download-cancel');

  /// How long is left, said the way a person would say it.
  ///
  /// Deliberately vague at every scale. The rate is measured over the last
  /// few seconds of a transfer that runs for an hour, so a figure to the
  /// second would be precise about a number that is not.
  static String describeRemaining(Duration d) {
    if (d.inSeconds < 60) return 'less than a minute left';
    final minutes = (d.inSeconds / 60).ceil();
    if (minutes < 60) return 'about $minutes min left';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0
        ? 'about $hours h left'
        : 'about $hours h $rest min left';
  }

  /// A word from [DownloadError] as a sentence with a next step in it.
  ///
  /// Every case says what the user can DO. An unknown word — a ledger written
  /// by a later build — falls through to the plain sentence rather than
  /// rendering a machine word at somebody.
  static String describeDownloadError(String? error) => switch (error) {
        DownloadError.diskFull =>
          'Not enough disk space. Free some space, then try again.',
        DownloadError.checksum =>
          'The file did not verify after two attempts. Check the connection '
              'and try again.',
        DownloadError.network =>
          'The connection dropped too many times. Check the network and try '
              'again.',
        DownloadError.gated =>
          'This model needs a Hugging Face login and cannot be downloaded '
              'automatically.',
        DownloadError.manifestMismatch =>
          'The file on the server no longer matches this version of Bond. '
              'Update Bond and try again.',
        DownloadError.missingFolder =>
          'The models folder could not be created. Go back and choose '
              'another folder.',
        _ => _httpOrGeneric(error),
      };

  /// Digits and nothing else — not `int.tryParse`, which would take a sign.
  static final RegExp _digits = RegExp(r'^[0-9]+$');

  /// The HTTP sentence only for a word that really carries a status code —
  /// `http_` followed by digits and nothing else. A later build's
  /// `http_timeout` would otherwise be read back at somebody as a status code
  /// that does not exist.
  static String _httpOrGeneric(String? error) {
    if (error != null && error.startsWith('http_')) {
      final code = error.substring('http_'.length);
      if (_digits.hasMatch(code)) {
        return 'The server answered HTTP $code.';
      }
    }
    return 'The download failed.';
  }

  /// The right-hand word for a file's state.
  ///
  /// A file with no progress entry on a COMPLETE set is `Ready`, not
  /// `Waiting`: a relaunch after the download finished starts no run and
  /// therefore emits no events, and three bars reading "Waiting" over a
  /// folder that already holds every model would be the screen contradicting
  /// itself.
  static String _status(DownloadProgress? entry, {required bool complete}) =>
      switch (entry?.status) {
        null => complete ? 'Ready' : 'Waiting',
        DownloadStatus.pending => 'Waiting',
        DownloadStatus.downloading => 'Downloading',
        DownloadStatus.paused => 'Paused',
        DownloadStatus.verifying => 'Verifying',
        DownloadStatus.done => 'Ready',
        DownloadStatus.failed => describeDownloadError(entry?.error),
      };

  bool get _anyFailed =>
      progress.values.any((p) => p.status == DownloadStatus.failed);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'The two models the inbox needs come first; the writing model is '
          'the big one.',
          style: BondType.caption,
        ),
        const SizedBox(height: BondSpacing.s16),
        for (final file in files) ..._row(file),
        ..._buttons(),
        const SizedBox(height: BondSpacing.s8),
        // Always, whatever the state: it is the one thing about this screen
        // somebody needs to know BEFORE they decide to walk away from it.
        Text(
          'You can quit — the download resumes next launch.',
          style: BondType.caption,
        ),
        if (complete) ...[
          const SizedBox(height: BondSpacing.s12),
          Text('All models are on this Mac.', style: BondType.body),
        ],
        const SizedBox(height: BondSpacing.s24),
        SetupPrimaryButton(
          label: 'Continue',
          onPressed: complete ? onContinue : null,
        ),
      ],
    );
  }

  List<Widget> _row(ModelFile file) {
    final entry = progress[file.id];
    final total = entry?.totalBytes ?? file.sizeBytes;
    // See [_status]: an entry-less file on a complete set is a file that is
    // all here, and its bar and its byte count have to say the same thing the
    // word does.
    final received = entry?.receivedBytes ?? (complete ? total : 0);
    final detail = StringBuffer()
      ..write(formatBytes(received).isEmpty ? '0 B' : formatBytes(received))
      ..write(' of ')
      ..write(formatBytes(total));
    if (entry != null && entry.status == DownloadStatus.downloading) {
      if (entry.bytesPerSecond > 0) {
        detail.write(' · ${formatBytes(entry.bytesPerSecond.round())}/s');
      }
      final remaining = entry.remaining;
      if (remaining != null) {
        detail.write(' · ${describeRemaining(remaining)}');
      }
    }
    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Text(
              file.displayName,
              style: BondType.body.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: BondSpacing.s12),
          // The status column is Expanded rather than sized to its word,
          // because a FAILURE puts a whole sentence here — "The connection
          // dropped too many times…" — and a right-hand column that could
          // not wrap would run off the pane.
          Expanded(
            flex: 2,
            child: Text(
              _status(entry, complete: complete),
              style: BondType.caption,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
      const SizedBox(height: BondSpacing.s4),
      LinearProgressIndicator(value: entry?.fraction ?? (complete ? 1 : 0)),
      const SizedBox(height: BondSpacing.s4),
      Text('$detail', style: BondType.caption),
      const SizedBox(height: BondSpacing.s16),
    ];
  }

  /// Which controls this state has a use for. A paused run is still a run —
  /// it offers Resume and Cancel, never Start, because starting a second run
  /// over a paused one is not a thing the downloader allows.
  List<Widget> _buttons() {
    final buttons = <Widget>[
      if (running && !paused)
        OutlinedButton(
          key: pauseKey,
          onPressed: onPause,
          child: const Text('Pause'),
        ),
      if (running && paused)
        FilledButton(
          key: resumeKey,
          onPressed: onResume,
          child: const Text('Resume'),
        ),
      if (running)
        TextButton(
          key: cancelKey,
          onPressed: onCancel,
          child: const Text('Cancel'),
        ),
      if (!running && !complete)
        FilledButton(
          key: startKey,
          onPressed: onStart,
          // A file that failed makes this a retry, and saying so is the
          // difference between "press it again" and "press it for the first
          // time".
          child: Text(_anyFailed ? 'Try again' : 'Start download'),
        ),
    ];
    if (buttons.isEmpty) return const [];
    return [
      Wrap(
        spacing: BondSpacing.s8,
        runSpacing: BondSpacing.s8,
        children: buttons,
      ),
    ];
  }
}
