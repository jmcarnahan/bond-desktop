import 'package:bond_inbox/services/notify/desktop_notifier.dart';

/// The operating system's notification centre, answering however the test set
/// it.
///
/// The counter is the point: what the wizard's notifications step is for is
/// asking EXACTLY ONCE, and the only way to prove that is to count.
class FakeDesktopNotifier implements DesktopNotifier {
  FakeDesktopNotifier({this.supported = true, this.authorized = true});

  @override
  bool supported;

  bool authorized;
  int authorizeCalls = 0;
  final List<DesktopNotification> shown = [];

  @override
  Future<bool> ensureAuthorized() async {
    authorizeCalls++;
    return authorized;
  }

  @override
  Future<void> show(DesktopNotification notification) async {
    shown.add(notification);
  }
}
