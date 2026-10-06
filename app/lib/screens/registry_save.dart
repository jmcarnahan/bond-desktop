import '../providers/prefs_provider.dart' show AppPrefsNotifier;
import '../widgets/model_registry_form.dart' show ModelRegistryForm;
import '../widgets/model_servers_form.dart' show ModelServersForm;

/// The model registry's Save, shared by Settings and the setup wizard:
/// [AppPrefsNotifier.useRegistry], which validates before it writes and moves
/// the keychain before the address. A refused write comes back as its
/// sentence for the form to draw under the field, and null means the write
/// landed. What follows a landed write, a download of whatever the new
/// address can now supply, is each caller's own.
///
/// The token is never in the answer: the writer's sentence for a token no
/// header can carry does not quote it, and nothing here logs it.
Future<String?> saveRegistry(
  AppPrefsNotifier notifier, {
  required String url,
  String? token,
  required bool clearToken,
}) async {
  try {
    await notifier.useRegistry(
      url: url,
      token: token,
      clearToken: clearToken,
    );
  } on ArgumentError catch (e) {
    // The address's own sentence for a refused address; the writer's for a
    // token no header can carry, which never quotes it.
    if (e.name == 'url') return ModelRegistryForm.addressRefusalText;
    final message = e.message;
    return message is String ? message : ModelServersForm.saveFailedText;
  }
  return null;
}
