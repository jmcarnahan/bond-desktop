import 'package:bond_inbox/services/models/model_ensurer.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;

/// The model ensurer as its callers see it: counts the kicks and starts no
/// download. A widget test overrides `modelEnsurerProvider` with one, because
/// the real ensurer would start a download over real sockets inside a
/// fake-async body.
///
/// [flag], when set, is read at each kick into [blockedAtCall], so a case
/// can say whether the wizard flag was up when it was asked. [next] is the
/// state a kick publishes, for a case that wants the page to show one.
/// [reverified] records each kick's `reverify` set; [standDowns] counts the
/// hand-overs to the wizard.
class RecordingEnsurer implements ModelEnsurer {
  int calls = 0;
  int standDowns = 0;
  final List<bool> blockedAtCall = [];
  final List<Set<String>> reverified = [];
  bool Function()? flag;
  EnsureState? next;
  final ValueNotifier<EnsureState> _state = ValueNotifier(const EnsureState());

  @override
  ValueListenable<EnsureState> get state => _state;

  /// Publishes [value] as the ensurer's state, as a run would.
  void publish(EnsureState value) => _state.value = value;

  @override
  Future<EnsureState> ensure({Set<String> reverify = const {}}) async {
    calls++;
    reverified.add(reverify);
    blockedAtCall.add(flag?.call() ?? false);
    final value = next;
    if (value != null) _state.value = value;
    return _state.value;
  }

  @override
  Future<void> standDown() async => standDowns++;

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
