import 'package:bond_inbox/services/server/server_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// The states are a contract with the settings screen, and their summaries
/// are the sentences it draws. Pinned here so a wording change is a decision
/// somebody made rather than a string somebody edited.
void main() {
  group('summary', () {
    test('every state says one thing', () {
      expect(
        const ServerDisabled().summary,
        'Off — servers are started by hand',
      );
      expect(const ServerStopped().summary, 'Stopped');
      expect(const ServerStarting().summary, 'Starting…');
      expect(const ServerStarting(port: 8080).summary, 'Starting… on port 8080');
      expect(
        const ServerLoading(
          port: 8080,
          pid: 42,
          loaded: {'bond-embed': true, 'bond-bulk': true, 'bond-prose': false},
        ).summary,
        'Loading models (2 of 3) on port 8080',
      );
      expect(
        const ServerReady(port: 8080, pid: 42).summary,
        'Ready on 127.0.0.1:8080',
      );
      expect(
        const ServerFailed('the weights are corrupt').summary,
        'Failed: the weights are corrupt',
      );
      expect(const ServerPortInUse(8080).summary, 'Port 8080 is in use');
      expect(
        const ServerPortInUse(8080, holder: 'llama-server (pid 991)').summary,
        'Port 8080 is in use by llama-server (pid 991)',
      );
    });
  });

  group('equality', () {
    test('the loading map is compared by contents', () {
      const a = ServerLoading(port: 1, pid: 2, loaded: {'x': true, 'y': false});
      final b = ServerLoading(
        port: 1,
        pid: 2,
        loaded: {'y': false, 'x': true},
      );
      // Progress that has not moved must not re-emit, or the status line
      // rebuilds on every poll.
      expect(a, b);
      expect(a.hashCode, b.hashCode);

      const moved =
          ServerLoading(port: 1, pid: 2, loaded: {'x': true, 'y': true});
      expect(a, isNot(moved));
    });

    test('the failure tail is part of the value', () {
      expect(
        const ServerFailed('gone', logTail: ['a', 'b']),
        const ServerFailed('gone', logTail: ['a', 'b']),
      );
      expect(
        const ServerFailed('gone', logTail: ['a', 'b']),
        isNot(const ServerFailed('gone', logTail: ['b', 'a'])),
      );
    });

    test('the two idle states are not each other', () {
      expect(const ServerStopped(), isNot(const ServerDisabled()));
      expect(const ServerStarting(), isNot(const ServerStarting(port: 1)));
      expect(
        const ServerPortInUse(1),
        isNot(const ServerPortInUse(1, holder: 'x')),
      );
      expect(
        const ServerReady(port: 1, pid: 2),
        isNot(const ServerReady(port: 1, pid: 3)),
      );
    });
  });
}
