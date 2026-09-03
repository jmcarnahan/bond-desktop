import 'dart:io' show Platform;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'desktop_notifier.dart';

/// The real notification centre, on the two platforms this app ships to.
///
/// This is the ONLY file in the app that imports `flutter_local_notifications`
/// and the only one that branches on [Platform] — both facts are the point of
/// the [DesktopNotifier] seam above it. A plugin swap or an OS quirk is a
/// change to this file and nothing else.
class LocalDesktopNotifier implements DesktopNotifier {
  /// What a tapped toast does. A plain callback because this file knows nothing
  /// about navigation: the provider that builds this wires the app's intent
  /// mechanism into it, and the OS side stays ignorant of where a thread lives.
  final void Function(NotificationTarget target)? onTap;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// The one-time initialization, memoized so every entry point can await it
  /// without racing. Null until something actually needs the OS.
  Future<void>? _initialized;

  LocalDesktopNotifier({this.onTap});

  @override
  bool get supported => Platform.isMacOS || Platform.isWindows;

  /// Initialization is LAZY, and has to be: it talks over a method channel, and
  /// `Platform.isMacOS` is true under `flutter test` — so an eager init in the
  /// constructor would put a channel call behind every widget test in the suite
  /// merely for building the provider graph.
  Future<void> _init() => _initialized ??= _doInit();

  Future<void> _doInit() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        // The request* flags are all off so that initializing cannot raise a
        // permission prompt — the app asks exactly once, from
        // [ensureAuthorized], and only when it has something worth saying.
        //
        // The defaultPresent* flags are the focus gate. macOS consults them
        // when a notification arrives while the app is FRONTMOST, and all-false
        // means it presents nothing: the in-app ribbon is already saying the
        // same thing over the inbox, and a banner on top of it would be the app
        // telling the user twice. A backgrounded app is not affected by these
        // at all and gets the normal banner, which is the whole feature.
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
          defaultPresentAlert: false,
          defaultPresentBanner: false,
          defaultPresentSound: false,
          defaultPresentBadge: false,
        ),
        // The guid is a constant on purpose. Windows keys COM activation on it,
        // so a fresh one per launch would orphan every toast this app ever
        // posted — the tap would arrive at a registration that no longer
        // exists. There is no focus gate here: Windows shows the toast whether
        // or not the app is frontmost, which is the accepted best-effort
        // behaviour on that platform.
        windows: WindowsInitializationSettings(
          appName: 'Bond Inbox',
          appUserModelId: 'com.bondinbox.app',
          guid: '8f4a2d1e-9c3b-4f6a-8d5e-2b7c9e0f4a61',
        ),
      ),
      onDidReceiveNotificationResponse: _onResponse,
    );
  }

  /// A payload this app did not write is a tap it does nothing about — see
  /// [NotificationTarget.decode] for why silence is the only safe answer.
  void _onResponse(NotificationResponse response) {
    final target = NotificationTarget.decode(response.payload);
    if (target == null) return;
    onTap?.call(target);
  }

  @override
  Future<bool> ensureAuthorized() async {
    if (!supported) return false;
    await _init();
    if (!Platform.isMacOS) {
      // Windows has no per-app permission to request: whether a toast appears
      // is the OS notification setting, which this app cannot ask about and
      // must not pretend to.
      return true;
    }
    try {
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true);
      return granted ?? false;
    } on Object {
      // Every throw is a denial. This runs on the path where the app has just
      // decided it has something to say, and a platform that will not answer
      // must leave it quiet rather than take the whole flush down with it.
      return false;
    }
  }

  @override
  Future<void> show(DesktopNotification notification) async {
    if (!supported) return;
    await _init();
    await _plugin.show(
      // The id is what makes a toast REPLACE rather than stack. A thread that
      // settles twice reuses its own key's id and overwrites its earlier toast;
      // every coalesced batch shares id 0 and overwrites the last batch. Either
      // way the notification centre holds one line per thing that happened,
      // which is what the ribbon does on screen.
      id: notification.target.count > 1
          ? 0
          : notification.target.conversationKey.hashCode & 0x7fffffff,
      title: notification.title,
      body: notification.body,
      // Plain details on both platforms. On macOS that is deliberate: leaving
      // every presentation option null is what lets the all-false defaults from
      // initialization govern the frontmost case.
      notificationDetails: const NotificationDetails(
        macOS: DarwinNotificationDetails(),
        windows: WindowsNotificationDetails(),
      ),
      payload: notification.target.encode(),
    );
  }
}
