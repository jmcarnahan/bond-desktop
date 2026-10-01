/// The sample sandbox switch.
///
/// A build pointed at a directory of recorded traffic (`BOND_SAMPLE_DIR` in
/// `local.mk`, passed as a `--dart-define` by the Makefile) serves that
/// recording through the five backend interfaces instead of Microsoft, so the
/// whole production pipeline — ingest, gates, triage, the decision model,
/// storylines, every screen — can be reviewed by hand over a real-sized
/// mailbox without anything reaching the network.
///
/// READ-ONLY by construction: every write on the seam refuses with a sentence
/// that says "sandbox" (see `sample_backends.dart`), so nothing composed here
/// can go anywhere. It also gets its own database file (`appDatabasePath`),
/// because the identity guard only runs on a sign-in and this path never signs
/// in — without its own file the sample's rows would land beside the real
/// account's. Removing the define is the whole way back.
///
/// A compile-time constant rather than a preference for the reason
/// `BOND_DEV_HAND_SERVERS` is one: it chooses what the app IS for a whole run,
/// and a setting that could flip mid-session would mix two mailboxes in one
/// graph of providers. Absent, `String.fromEnvironment` answers `''`.
library;

/// The sample directory the build was pointed at, or `''` for a normal build.
const String sampleDirDefine = String.fromEnvironment('BOND_SAMPLE_DIR');

/// Whether this build serves the sample sandbox. Trimmed, so a `local.mk` line
/// written as `BOND_SAMPLE_DIR = ` with trailing space reads as off.
bool get sampleModeOn => sampleDirDefine.trim().isNotEmpty;
