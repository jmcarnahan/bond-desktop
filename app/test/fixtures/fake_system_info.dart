import 'package:bond_inbox/services/system/system_info.dart';

/// One recorded call to the activity API.
///
/// Begins and ends land in the same list, in order, because the property
/// worth testing is that they PAIR: an activity begun for a start that failed
/// and never ended keeps the machine awake for the rest of the session.
class ActivityCall {
  final String? reason;
  final int? token;

  const ActivityCall.begin(this.reason) : token = null;
  const ActivityCall.end(this.token) : reason = null;

  bool get isBegin => reason != null;

  @override
  String toString() => isBegin ? 'begin($reason)' : 'end($token)';
}

/// The platform, answering whatever the test says.
class FakeSystemInfo implements SystemInfo {
  HardwareInfo hardwareInfo = HardwareInfo.unknown;
  int? free;
  String? digest;
  bool notificationSettingsOpened = false;
  bool openNotificationSettingsAnswer = true;

  /// Null makes [beginActivity] answer null, which is the "no activity could
  /// be started" case every caller has to survive.
  int? nextActivityToken = 1;

  final List<ActivityCall> activities = [];
  final List<String> freeBytesPaths = [];
  final List<String> sha256Paths = [];

  @override
  Future<HardwareInfo> hardware() async => hardwareInfo;

  @override
  Future<int?> freeBytes(String path) async {
    freeBytesPaths.add(path);
    return free;
  }

  @override
  Future<String?> sha256(String path) async {
    sha256Paths.add(path);
    return digest;
  }

  @override
  Future<int?> beginActivity(String reason) async {
    activities.add(ActivityCall.begin(reason));
    final token = nextActivityToken;
    if (token != null) nextActivityToken = token + 1;
    return token;
  }

  @override
  Future<void> endActivity(int token) async {
    activities.add(ActivityCall.end(token));
  }

  @override
  Future<bool> openNotificationSettings() async {
    notificationSettingsOpened = true;
    return openNotificationSettingsAnswer;
  }
}
