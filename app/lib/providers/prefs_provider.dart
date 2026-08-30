import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../services/attention.dart';
import 'app_providers.dart';

/// The two settings the LO controls, held in memory so the widgets that read
/// them rebuild the moment one changes.
///
/// They live in `app_prefs` as TEXT, which is the only shape that table has.
/// Parsing back is this file's job and nobody else's — a threshold is a double
/// everywhere above here.
@immutable
class AppPrefs {
  /// The score a thread must reach to appear in Needs You. Below it, a thread
  /// is still in Conversations — the slider changes what gets promoted, never
  /// what exists.
  final double attentionThreshold;

  /// What the LO says about themselves and their role. Written here, read by
  /// the next phase's prompts.
  final String aboutMe;

  const AppPrefs({
    this.attentionThreshold = AttentionTuning.defaultThreshold,
    this.aboutMe = '',
  });

  AppPrefs copyWith({double? attentionThreshold, String? aboutMe}) => AppPrefs(
        attentionThreshold: attentionThreshold ?? this.attentionThreshold,
        aboutMe: aboutMe ?? this.aboutMe,
      );
}

/// Keys in `app_prefs`. Constants because they are typed in two places — the
/// read below and the tests that assert what landed in the table.
const String attentionThresholdKey = 'attention_threshold';
const String aboutMeKey = 'about_me';

class AppPrefsNotifier extends StateNotifier<AppPrefs> {
  final MessageStore _store;

  AppPrefsNotifier(this._store) : super(_read(_store));

  /// Reads both settings once, at construction. A stored threshold that does
  /// not parse — hand-edited, or written by a build that meant something else
  /// by the key — falls back to the default rather than throwing: a bad
  /// preference must not be able to stop the app from starting.
  static AppPrefs _read(MessageStore store) {
    final raw = store.getPref(attentionThresholdKey);
    return AppPrefs(
      attentionThreshold: (raw == null ? null : double.tryParse(raw)) ??
          AttentionTuning.defaultThreshold,
      aboutMe: store.getPref(aboutMeKey) ?? '',
    );
  }

  /// Clamped to the slider's own range, so a value that somehow arrived from
  /// outside it cannot make Needs You permanently empty.
  void setAttentionThreshold(double value) {
    final clamped = value.clamp(0.0, 1.0);
    _store.setPref(attentionThresholdKey, clamped.toString());
    state = state.copyWith(attentionThreshold: clamped);
  }

  void setAboutMe(String value) {
    _store.setPref(aboutMeKey, value);
    state = state.copyWith(aboutMe: value);
  }
}

final appPrefsProvider = StateNotifierProvider<AppPrefsNotifier, AppPrefs>(
  (ref) => AppPrefsNotifier(ref.watch(messageStoreProvider)),
);
