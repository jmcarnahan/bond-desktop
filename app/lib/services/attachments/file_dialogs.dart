import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// Asking the operating system where to put a file.
///
/// The gatekeeper for `package:file_selector`, and the only file in the app
/// allowed to import it — the same discipline `pdf_preview.dart` keeps over
/// pdfrx and `local_desktop_notifier.dart` over the notifications plugin. What
/// it buys: a save flow that is testable without a platform channel, since
/// everything above takes [FileDialogs] and a test hands it a fake.
///
/// It is also the reason all four entitlement files carry
/// `com.apple.security.files.user-selected.read-write`. The sandbox grants
/// write access to exactly the path the person picked in this panel and to
/// nothing else, which is why the app can save an attachment anywhere the user
/// says without asking for a Documents-folder entitlement it would then hold
/// forever.
abstract interface class FileDialogs {
  /// Where the user wants [suggestedName] written, or null if they cancelled.
  Future<String?> chooseSaveLocation({required String suggestedName});

  /// The folder the user picked, or null if they cancelled.
  ///
  /// The open panel is also the SANDBOX's grant: the app may read the folder
  /// the person chose here, for this launch, and a security-scoped bookmark
  /// taken straight afterwards is what keeps that grant across a relaunch.
  Future<String?> chooseDirectory();
}

class SystemFileDialogs implements FileDialogs {
  const SystemFileDialogs();

  /// Cancelling and failing are the same answer here, deliberately.
  ///
  /// The caller's next step is identical either way — write nothing, say
  /// nothing — and the only failures this call has are a panel that could not
  /// open at all, which is a platform problem no message to the user improves.
  /// A save that then fails on disk is a different matter and does get told.
  @override
  Future<String?> chooseSaveLocation({required String suggestedName}) async {
    try {
      final location = await getSaveLocation(suggestedName: suggestedName);
      return location?.path;
    } on Object catch (e) {
      debugPrint('save panel did not open: $e');
      return null;
    }
  }

  /// Cancelling and failing are the same answer here too, for the reason
  /// above: the caller registers nothing either way.
  @override
  Future<String?> chooseDirectory() async {
    try {
      return await getDirectoryPath();
    } on Object catch (e) {
      debugPrint('open panel did not open: $e');
      return null;
    }
  }
}
