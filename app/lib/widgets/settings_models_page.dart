import 'dart:async';

import 'package:flutter/material.dart';

import '../providers/app_providers.dart' show ParkedFact;
import '../providers/prefs_provider.dart' show AppPrefs;
import '../services/llm/model_probe.dart' show ModelProbeResult;
import '../services/llm/model_slots.dart'
    show
        LlmTargetSpec,
        ModelPlacement,
        StageRole,
        builtInFastId,
        builtInProseId,
        handServersBuild,
        hostPort,
        isLoopbackHost,
        pipelineStages;
import '../services/models/managed_model_status.dart' show ManagedModelStatus;
import '../services/server/server_state.dart';
import '../theme/tokens.dart';
import 'attachment_format.dart' show formatBytes;
import 'model_servers_form.dart' show ModelServersForm;
import 'probe_status.dart' show ProbeStatus, guardedProbe;
import 'settings_segments.dart';

/// One role's row on the Models page.
///
/// Three of these are the whole read-only half of the page: what the role is
/// called, one phrase naming the model and the machine that answers for it,
/// what it costs on disk and whether it is loaded, and where **Check** should
/// look. Built from the preferences by [fromPrefs] and dressed with the live
/// facts by [withStatus], both of which the host calls, so this widget stays
/// prop-only like every other body in Settings and both resolutions are pure
/// functions a test can call.
@immutable
class RoleLine {
  /// `big`, `small` or `embed` — the slug the row's Check key is built on, and
  /// the reason this is a field rather than a position in a list: a test taps
  /// one named row, never the second one.
  final String id;

  /// The role's own word, as the page says it.
  final String title;

  /// One phrase: the model and the machine it runs on, or the Custom sentence
  /// when the role's steps do not all agree. See [SettingsModelsPage
  /// .roleDetail], which is where both spellings are built.
  final String detail;

  /// What **Check** asks. Null takes the button off that row, the discipline
  /// every optional control in Settings follows.
  final String? checkUrl;

  /// Which target's stored token rides that one request, or null for a target
  /// with none. An ID, never the token: the lookup happens at the press.
  final String? bearerId;

  /// What this checkpoint costs on disk, already formatted, for a model this
  /// Mac runs. Null on a row about somebody else's server, which has no local
  /// file to report.
  final String? size;

  /// `not downloaded`, `on disk` or `on disk · loaded`, from the ledger and
  /// the router. Null for the same reason [size] is.
  final String? state;

  const RoleLine({
    required this.id,
    required this.title,
    required this.detail,
    this.checkUrl,
    this.bearerId,
    this.size,
    this.state,
  });

  RoleLine copyWith({
    String? detail,
    String? size,
    String? state,
  }) =>
      RoleLine(
        id: id,
        title: title,
        detail: detail ?? this.detail,
        checkUrl: checkUrl,
        bearerId: bearerId,
        size: size ?? this.size,
        state: state ?? this.state,
      );

  /// The row's second line, as one string: the phrase, then whatever local
  /// facts there are, in the order a person asks for them.
  String get line => [
        detail,
        if (size != null && size!.isNotEmpty) size!,
        if (state != null && state!.isNotEmpty) state!,
      ].join(' · ');

  /// The three rows, resolved from the preferences the way the page reports
  /// them. The host calls this and hands the result down; a test calls it on
  /// an [AppPrefs] it built.
  ///
  /// A role's steps are every stage the placement's rule sends to the same
  /// default target as the role's LEAD stage, `draft_reply` for the big model
  /// and `triage` for the small. Membership is read off
  /// `defaultTargetIdForStage` rather than off `roleOfStage`, and the two
  /// disagree on purpose: storyline membership is the big model's work on a
  /// user-defined server and the small model's on this Mac, so grouping by the
  /// enum would read every Managed install as Custom. `draft_improve` is one
  /// of the big model's steps like the reply it improves on; nothing is
  /// optional any more.
  ///
  /// The row describes the target MOST of the role's steps resolve to, and the
  /// count is how many do not, so one odd step reads as one wherever it sits,
  /// the lead stage included, and **Check** asks the target the row is
  /// actually describing. Steps are compared by the spec `specForStage`
  /// answers rather than by the stored id, because that is what a request
  /// would reach: a third-party pick with consent withheld falls back there,
  /// and the row says so by not saying Custom.
  ///
  /// Embeddings is not routed at all, so its row is the one fixed answer and
  /// its Check asks the embedding server the app would actually send to.
  static List<RoleLine> fromPrefs(AppPrefs prefs) {
    RoleLine routed(String id, String title, StageRole role, String lead) {
      final byDefault = prefs.defaultTargetIdForStage(lead);
      final members = [
        for (final stage in pipelineStages)
          if (prefs.defaultTargetIdForStage(stage.id) == byDefault) stage.id,
      ];
      final specs = {for (final m in members) m: prefs.specForStage(m)};
      final counts = <String?, int>{};
      for (final spec in specs.values) {
        counts[spec?.id] = (counts[spec?.id] ?? 0) + 1;
      }
      // The lead stage's own answer wins a tie, so a role split down the
      // middle still describes the step a person recognises.
      var modal = specs[lead]?.id;
      var best = counts[modal] ?? 0;
      for (final m in members) {
        final id = specs[m]?.id;
        if ((counts[id] ?? 0) > best) {
          modal = id;
          best = counts[id]!;
        }
      }
      LlmTargetSpec? spec;
      for (final m in members) {
        if (specs[m]?.id == modal) {
          spec = specs[m];
          break;
        }
      }
      return RoleLine(
        id: id,
        title: title,
        detail: SettingsModelsPage.roleDetail(
          role: role,
          spec: spec,
          overrides: members.length - best,
        ),
        checkUrl: spec?.url,
        // An ID, never the token: the lookup happens at the press, through
        // the same `storedBearer` closure every other Check here uses.
        bearerId: spec != null && spec.hasBearer ? spec.id : null,
      );
    }

    return [
      routed('big', 'Big model', StageRole.big, 'draft_reply'),
      routed('small', 'Small model', StageRole.small, 'triage'),
      RoleLine(
        id: 'embed',
        title: 'Embeddings',
        detail: SettingsModelsPage.roleDetail(
          role: StageRole.embed,
          spec: null,
        ),
        checkUrl: prefs.embedRequestTarget.baseUrl,
      ),
    ];
  }

  /// The same three rows with this Mac's own facts joined on: what the model
  /// is called in the manifest, what it cost to fetch, whether the bytes are
  /// there and whether the router has them loaded.
  ///
  /// A pure function beside the widget, so the join is pinned by a test that
  /// never pumps a screen. [statuses] is null while the provider is still
  /// reading, or when it failed, and a row then keeps exactly what
  /// [fromPrefs] said: a page that blanked its own answers while a future
  /// settled would flicker on every rebuild.
  ///
  /// Under the user-defined placement the two chat models run on somebody's
  /// server, so only the embedding row has local facts to add. The resolved
  /// manifest holds one file there and the statuses say so already, but the
  /// [placement] is checked as well rather than trusted to: a list resolved a
  /// frame before the mode moved would otherwise put a size and a disk state
  /// on a row about a machine this app cannot see.
  static List<RoleLine> withStatus(
    List<RoleLine> lines, {
    required List<ManagedModelStatus>? statuses,
    required ServerState serverState,
    required ModelPlacement placement,
  }) {
    if (statuses == null) return lines;
    final byRole = {for (final row in statuses) row.roleId: row};
    return [
      for (final line in lines)
        if (placement == ModelPlacement.box && line.id != 'embed')
          line
        else
          switch (byRole[line.id]) {
            null => line,
            final status => line.copyWith(
                detail: '${status.displayName} on this Mac',
                size: formatBytes(status.bytes),
                state: _diskState(status, serverState),
              ),
          },
    ];
  }

  /// Whether the bytes are there, and whether the router is holding them.
  ///
  /// `loaded` is keyed by ROUTER id rather than by role, which is why the
  /// status carries one: on a small Mac the big row's file IS the bulk file,
  /// and a row that looked itself up by `bond-prose` would read as never
  /// loaded there.
  static String _diskState(ManagedModelStatus status, ServerState state) {
    if (!status.onDisk) return 'not downloaded';
    final loaded = switch (state) {
      ServerReady() => true,
      ServerLoading(loaded: final map) => map[status.routerId] == true,
      _ => false,
    };
    return loaded ? 'on disk · loaded' : 'on disk';
  }
}

/// The Models section as a tester reads it: one question, two answers, and
/// nothing else on the page.
///
/// The question is **where the models run**. *Managed* means this app runs the
/// models on this Mac and there is nothing to configure, so the page is a
/// status block: one server line, a bar while the weights load, and the three
/// role rows saying what each model is, what it cost and whether it is loaded.
/// *User defined* means the person names a big model address and a small model
/// address and pastes an access key, and **Connect** asks each server what it
/// serves. Everything that used to be folded away under Advanced — the stage
/// table, the slot editors, the targets list, the Local server card — is gone
/// rather than hidden.
///
/// PROP-ONLY, like every other body here: nothing reaches for a provider, the
/// host resolves every fact and takes every write back as a closure, and the
/// whole page is drivable from a test with a handful of values. The state it
/// owns is which mode is being edited before anything is written, and the
/// probe results of this session, which belong to no preference.
///
/// The ACCESS KEY is never held here. It lives in [ModelServersForm]'s own
/// controllers, arrives as the argument of one call, and reaches the keychain
/// through the host.
class SettingsModelsPage extends StatefulWidget {
  /// Where this install's model work runs today. The segments open on it.
  final ModelPlacement modelPlacement;

  /// Whether the session's processing switch is on. Off, the status line says
  /// so instead of repeating a park sentence, because a park says work is
  /// retrying and nothing retries while the switch is off: the last parked
  /// fact stays in its provider after the drains stop, and the rail guards
  /// the same way.
  final bool processingOn;

  /// Where the app's own llama-server stands, for the Managed status line and
  /// the loaded half of each row.
  ///
  /// What this Mac's own MODELS are does not arrive here: the host joins them
  /// onto [roleLines] through [RoleLine.withStatus] before it hands them
  /// down, so the page draws rows rather than resolving them.
  final ServerState serverState;

  /// The four user-defined values to prefill the form with, already resolved
  /// by the host: the stored ones where there are stored ones, the build's
  /// otherwise. Never a key.
  final String boxBigUrl;
  final String boxSmallUrl;
  final String boxBigModel;
  final String boxSmallModel;

  /// Whether a key is in the keychain, for either server and for each.
  /// Presence flags, never the token.
  final bool boxKeyStored;
  final bool boxBigKeyStored;
  final bool boxSmallKeyStored;

  /// Asks a server what it serves. Null takes every **Check** on this page
  /// off, the form's Connect and the three rows' alike.
  final Future<ModelProbeResult> Function(String url, {String? bearer})? probe;

  /// Looks up one target's stored token for a probe's `Authorization` header.
  /// A LOOKUP, never the value.
  final String? Function(String targetId)? storedBearer;

  /// **Connect**: the two addresses, the two discovered names and a key per
  /// server where one was typed. **Null takes the form off the page**, this
  /// screen's usual discipline.
  final Future<void> Function({
    required String bigUrl,
    required String smallUrl,
    required String bigModel,
    required String smallModel,
    String? bigKey,
    String? smallKey,
  })? onUseBox;

  /// **Managed**: puts the install back on this Mac's own models. Null leaves
  /// that segment inert.
  final Future<void> Function()? onUseManaged;

  /// Forgets both stored keys. Null takes **Remove key** off the form.
  final Future<void> Function()? onRemoveKey;

  /// Raised by the form when the big address is somebody else's service. Null
  /// makes the form refuse such an address instead.
  final Future<void> Function(
    LlmTargetSpec big,
    Future<void> Function() resume,
  )? onThirdParty;

  /// Reruns the wizard, which is how the models folder changes and a download
  /// is retried. Null takes the link off.
  final VoidCallback? onSetUpAgain;

  /// Opens the server's log in the operating system's own viewer. Null takes
  /// **Show log** off the failure line.
  final VoidCallback? onShowLog;

  /// The three rows, in the order they are drawn. Empty draws none, which is
  /// what a host that resolved no targets has.
  final List<RoleLine> roleLines;

  /// Why the pipeline is parked and how much is waiting, for the status line.
  /// Null is the ordinary state and reads as nothing parked.
  final ParkedFact? parked;

  const SettingsModelsPage({
    super.key,
    required this.modelPlacement,
    this.processingOn = true,
    this.serverState = const ServerStopped(),
    this.boxBigUrl = '',
    this.boxSmallUrl = '',
    this.boxBigModel = '',
    this.boxSmallModel = '',
    this.boxKeyStored = false,
    this.boxBigKeyStored = false,
    this.boxSmallKeyStored = false,
    this.probe,
    this.storedBearer,
    this.onUseBox,
    this.onUseManaged,
    this.onRemoveKey,
    this.onThirdParty,
    this.onSetUpAgain,
    this.onShowLog,
    this.roleLines = const [],
    this.parked,
  });

  /// The one question, and the heading over the segments.
  static const String whereHeading = 'Where the models run';

  /// The controls, keyed for the reason every control in Settings is: the
  /// words on them are ordinary words that also appear in the sentences
  /// beside them.
  static const Key modeKey = ValueKey('settings-mode');
  static const Key statusKey = ValueKey('settings-models-status');
  static const Key progressKey = ValueKey('settings-models-progress');
  static const Key showLogKey = ValueKey('settings-show-log');
  static const Key setUpAgainKey = ValueKey('settings-set-up-again');

  /// One role row's **Check**. Three buttons carry the same word, so a test
  /// that tapped by label would tap whichever came first.
  static Key roleCheckKey(String roleId) =>
      ValueKey('settings-role-check-$roleId');

  /// The two modes, in the owner's own words.
  static const String managedLabel = 'Managed';
  static const String userDefinedLabel = 'User defined';

  /// What choosing one does, which is the whole of the page in one sentence.
  static const String modeCaption =
      'Managed runs the models on this Mac. User defined sends the work to '
      'servers you name.';

  /// The status line while the processing switch is off, ahead of any park.
  static const String processingOffText =
      'Processing is off. Turn it on under Processing, or in the sidebar, and '
      'the work starts.';

  /// The status line while the form is open on an install that has not
  /// connected yet. Nothing moves until Connect, and this is what says so.
  static const String untilConnectText =
      'Running on this Mac until you connect.';

  /// The parks this page can answer for, in its own words. The same facts the
  /// inbox rail reads, from the drains' own progress streams; nothing polls a
  /// server to produce them.
  static const String serverParkedText =
      'Your server is not answering. Work is waiting and will retry each '
      'minute.';

  /// The same line when the server ANSWERED and refused the key. A different
  /// sentence because it is a different job: waiting fixes the first and
  /// nothing but a new key fixes this one, and the field that takes one is
  /// standing open directly above it.
  static const String serverUnauthorizedText =
      'Your server refused the access key. Change it here.';

  /// And the third. The embedding model is on this Mac under EITHER mode, so
  /// this sentence names this Mac in both — the same reason
  /// `railProgressLine` keeps one wording for it across both.
  static const String embedUnavailableText =
      'The embedding model on this Mac is not answering. Work is waiting and '
      'will retry each minute.';

  /// The user-defined status line before a key has been pasted, and after one
  /// has. A server on this machine needs no key, so the first is asked for
  /// only when at least one address is somewhere else.
  static const String keyNeededText =
      'Access key needed. Paste it and press Connect.';
  static const String connectedText = 'Connected to your servers.';

  /// The Managed status line, one sentence per state of the app's own server.
  static const String startingText = 'Starting…';
  static String loadingText(int loaded, int total) =>
      'Loading models · $loaded of $total';
  static const String runningText = 'Running';
  static const String notRunningText = 'Not running';
  static String failedText(String reason) => 'Not running: $reason';
  static String portInUseText(int port, String? holder) => holder == null
      ? 'Port $port is in use'
      : 'Port $port is in use by $holder';

  /// A build that leaves the servers to the developer, which is a define
  /// rather than a preference since Round H.
  static const String handServersText =
      'Servers are started by hand for this build.';

  static const String showLogLabel = 'Show log';
  static const String setUpAgainLabel = 'Set up again';

  /// The two chat models this build runs on this Mac, in the words a person
  /// recognises, BY TARGET rather than by role: a small Mac runs its seven
  /// prose steps on the 4B, and the big model's row has to say so rather than
  /// name the 27B it is not using.
  ///
  /// A const map rather than a read of the manifest. [RoleLine.withStatus]
  /// replaces these with the manifest's own `displayName` the moment the
  /// host has read it; this is what a row says in the frame before that, and
  /// on a row the statuses do not cover.
  static const Map<String, String> localModelNames = {
    builtInProseId: 'Qwen3.8 27B',
    builtInFastId: 'Qwen3 4B',
  };

  /// The embedding model, which is on this Mac under either mode and is never
  /// routed, so it is one name rather than a lookup.
  static const String embedModelName = 'Qwen3 Embedding 0.6B';

  /// One role's phrase: the model and the machine, or the Custom sentence.
  ///
  /// Here rather than in the host because it is user-facing prose, and prose
  /// that lives in a 5,800-line screen is prose nothing can pin. [overrides]
  /// is how many of the role's other steps resolve somewhere else than its
  /// representative one; any at all and the role has no single answer to give.
  ///
  /// Embeddings never route, so the role answers the same phrase under either
  /// mode: that model is on this Mac whatever the rest of the pipeline is
  /// doing.
  static String roleDetail({
    required StageRole role,
    required LlmTargetSpec? spec,
    int overrides = 0,
  }) {
    if (overrides > 0) return customDetail(overrides);
    if (role == StageRole.embed) return '$embedModelName on this Mac';
    if (spec == null) return 'Not pointed at a server';
    if (spec.isBuiltIn) return '${localModelNames[spec.id]} on this Mac';
    // A user-defined server and somebody's own target read the same way, and
    // they are the same fact: the page cannot claim which machine either one
    // is, so it says the model and where it dials.
    return '${spec.model} at ${hostPort(spec.url)}';
  }

  /// A role whose steps disagree. It names the count, and nothing more: the
  /// screen that could have shown which ones is gone.
  static String customDetail(int steps) => steps == 1
      ? 'Custom · 1 step points elsewhere'
      : 'Custom · $steps steps point elsewhere';

  /// The collapsed Models summary: which mode, and the one fact about it.
  ///
  /// Static so the screen can build it without this widget existing — a
  /// collapsed section renders its summary and nothing else. [serverLine] is
  /// the same sentence the page would show under Managed, resolved by the
  /// screen from the same state.
  static String summary({
    required ModelPlacement placement,
    required String serverLine,
    required String bigUrl,
    required String smallUrl,
  }) {
    if (placement == ModelPlacement.local) {
      return 'Managed · $serverLine';
    }
    final big = hostPort(bigUrl);
    final small = hostPort(smallUrl);
    final hosts = <String>[
      if (big.isNotEmpty) big,
      if (small.isNotEmpty && small != big) small,
    ];
    return hosts.isEmpty
        ? 'User defined · no address yet'
        : 'User defined · ${hosts.join(' · ')}';
  }

  /// The Managed server line, from the state alone. Static for [summary]'s
  /// reason: the collapsed section says the same thing the open one does, and
  /// two copies of these sentences would drift.
  static String serverLine(ServerState state) {
    if (handServersBuild || state is ServerDisabled) return handServersText;
    return switch (state) {
      ServerStopped() => notRunningText,
      ServerStarting() => startingText,
      ServerLoading(loaded: final loaded) => loadingText(
          loaded.values.where((v) => v).length,
          loaded.length,
        ),
      ServerReady() => runningText,
      ServerFailed(reason: final reason) => failedText(reason),
      ServerPortInUse(port: final port, holder: final holder) =>
        portInUseText(port, holder),
      // Answered above, and unreachable: a sealed switch needs the arm.
      ServerDisabled() => handServersText,
    };
  }

  @override
  State<SettingsModelsPage> createState() => _SettingsModelsPageState();
}

class _SettingsModelsPageState extends State<SettingsModelsPage> {
  /// Whether the form is open on an install that is still Managed. Choosing
  /// **User defined** opens it and writes nothing; **Connect** is what moves
  /// the install, and the placement prop coming back as `box` is what closes
  /// this again.
  bool _editing = false;

  /// And the same per role row, keyed by [RoleLine.id].
  final Map<String, bool> _roleProbing = {};
  final Map<String, ModelProbeResult> _roleProbe = {};

  @override
  void didUpdateWidget(SettingsModelsPage old) {
    super.didUpdateWidget(old);
    // The Connect landed: the placement is what the form was asking for, and
    // the form is now showing because of the placement rather than because of
    // a press.
    if (widget.modelPlacement == ModelPlacement.box && _editing) {
      _editing = false;
    }
    // A row that now asks a different server drops the answer it had, and the
    // busy line with it: a green Checked line from a user-defined server would
    // otherwise survive a switch to Managed and read as a report about the
    // wrong machine. A check still in flight is dropped where it lands, by
    // the URL it was pressed on.
    final before = {for (final line in old.roleLines) line.id: line.checkUrl};
    for (final line in widget.roleLines) {
      if (before.containsKey(line.id) && before[line.id] != line.checkUrl) {
        _roleProbe.remove(line.id);
        _roleProbing.remove(line.id);
      }
    }
  }

  bool get _onBox => widget.modelPlacement == ModelPlacement.box;

  /// Whether the form is on screen: always under User defined, and under
  /// Managed only while somebody is filling it in.
  bool get _showForm => (_onBox || _editing) && widget.onUseBox != null;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          SettingsModelsPage.whereHeading,
          style: BondType.small.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: BondSpacing.s8),
        SettingsSegments<ModelPlacement>(
          key: SettingsModelsPage.modeKey,
          segments: const [
            (
              value: ModelPlacement.local,
              label: SettingsModelsPage.managedLabel,
            ),
            (
              value: ModelPlacement.box,
              label: SettingsModelsPage.userDefinedLabel,
            ),
          ],
          // The segment moves under the finger. Under Managed that is this
          // page's own state until Connect lands, which is what the status
          // line directly below says out loud.
          selected: _onBox || _editing
              ? ModelPlacement.box
              : ModelPlacement.local,
          onChanged: _chooseMode,
          caption: SettingsModelsPage.modeCaption,
        ),
        const SizedBox(height: BondSpacing.s16),
        if (_showForm) ...[
          ModelServersForm(
            bigUrl: widget.boxBigUrl,
            smallUrl: widget.boxSmallUrl,
            bigModel: widget.boxBigModel,
            smallModel: widget.boxSmallModel,
            keyStored: widget.boxKeyStored,
            bigKeyStored: widget.boxBigKeyStored,
            smallKeyStored: widget.boxSmallKeyStored,
            probe: widget.probe,
            storedBearer: widget.storedBearer,
            onConnect: widget.onUseBox!,
            onRemoveKey: widget.onRemoveKey,
            onThirdParty: widget.onThirdParty,
          ),
          const SizedBox(height: BondSpacing.s16),
        ],
        Text(
          key: SettingsModelsPage.statusKey,
          _statusLine(),
          style: BondType.small,
        ),
        if (!_onBox) ..._managedProgress(),
        if (widget.roleLines.isNotEmpty) ...[
          const SizedBox(height: BondSpacing.s24),
          for (final line in widget.roleLines) _roleRow(line),
        ],
        if (widget.onSetUpAgain case final again?) ...[
          const SizedBox(height: BondSpacing.s16),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: SettingsModelsPage.setUpAgainKey,
              onPressed: again,
              child: const Text(SettingsModelsPage.setUpAgainLabel),
            ),
          ),
        ],
      ],
    );
  }

  /// Which mode the person just pressed.
  ///
  /// Managed ACTS, because there is nothing else to fill in: from a
  /// user-defined install it moves the work back here at once. User defined
  /// opens the form and writes nothing — the addresses and the key are the
  /// rest of that answer, and Connect is where it is given.
  void _chooseMode(ModelPlacement mode) {
    if (mode == ModelPlacement.box) {
      if (!_onBox) setState(() => _editing = true);
      return;
    }
    if (_onBox) {
      final managed = widget.onUseManaged;
      if (managed != null) unawaited(managed());
      return;
    }
    if (_editing) setState(() => _editing = false);
  }

  /// The bar under the Managed status line, and the way to the log.
  ///
  /// A bar only while something is happening: an indeterminate one for a
  /// process that has not answered yet, and a real fraction once the router
  /// is reporting model by model. **Show log** only under a failure, because
  /// that is the only state where the last twelve lines the server printed
  /// are what tells two identical sentences apart.
  List<Widget> _managedProgress() {
    final state = widget.serverState;
    final onShowLog = widget.onShowLog;
    return [
      if (state is ServerStarting)
        const Padding(
          padding: EdgeInsets.only(top: BondSpacing.s8),
          child: LinearProgressIndicator(key: SettingsModelsPage.progressKey),
        )
      else if (state is ServerLoading)
        Padding(
          padding: const EdgeInsets.only(top: BondSpacing.s8),
          child: LinearProgressIndicator(
            key: SettingsModelsPage.progressKey,
            value: state.loaded.isEmpty
                ? null
                : state.loaded.values.where((v) => v).length /
                    state.loaded.length,
          ),
        ),
      if (state is ServerFailed && onShowLog != null)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: SettingsModelsPage.showLogKey,
            onPressed: onShowLog,
            child: const Text(SettingsModelsPage.showLogLabel),
          ),
        ),
    ];
  }

  /// One role: what answers for it, what it costs here, and a Check that asks.
  Widget _roleRow(RoleLine line) {
    final probing = _roleProbing[line.id] ?? false;
    final result = _roleProbe[line.id];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: BondSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      line.title,
                      style:
                          BondType.small.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(line.line, style: BondType.caption),
                  ],
                ),
              ),
              if (widget.probe != null && line.checkUrl != null) ...[
                const SizedBox(width: BondSpacing.s12),
                OutlinedButton(
                  key: SettingsModelsPage.roleCheckKey(line.id),
                  onPressed: probing ? null : () => unawaited(_checkRole(line)),
                  child: const Text('Check'),
                ),
              ],
            ],
          ),
          ProbeStatus(probing: probing, result: result),
        ],
      ),
    );
  }

  /// One line, always, and it is the first thing a stalled tester reads.
  ///
  /// The order is the order the jobs come in. The switch being off first,
  /// because a park sentence promises a retry nothing is going to make while
  /// it is; then the form standing open over an install that has not moved
  /// yet; then a park; and only then the ordinary report.
  ///
  /// Under Managed the page answers for the embedding park alone. The other
  /// two are about a server, and under Managed the server line directly here
  /// is already saying what that server is doing.
  ///
  /// A refused ADDRESS is not on this line. The form owns that rule and says
  /// so under the field it is about.
  String _statusLine() {
    if (!widget.processingOn) return SettingsModelsPage.processingOffText;
    if (_showForm && !_onBox) return SettingsModelsPage.untilConnectText;
    final parked = widget.parked;
    if (parked != null && parked.waiting > 0) {
      final sentence = switch (parked.reason) {
        'model_unavailable' when _onBox => SettingsModelsPage.serverParkedText,
        'unauthorized' when _onBox => SettingsModelsPage.serverUnauthorizedText,
        'embed_unavailable' => SettingsModelsPage.embedUnavailableText,
        // Every other park word is about something this page cannot answer
        // for — a sign-out — and it must not claim it.
        _ => null,
      };
      if (sentence != null) return sentence;
    }
    if (!_onBox) return SettingsModelsPage.serverLine(widget.serverState);
    // PER SERVER, not either: two different hosts with a key stored for the
    // small one only leaves the big one with no credential, and a line
    // reading Connected there would be describing an install that cannot
    // draft. A server on this machine needs no key at all, and telling
    // somebody to paste one would be an instruction with nothing to follow.
    final bigNeeds =
        !isLoopbackHost(widget.boxBigUrl) && !widget.boxBigKeyStored;
    final smallNeeds =
        !isLoopbackHost(widget.boxSmallUrl) && !widget.boxSmallKeyStored;
    return bigNeeds || smallNeeds
        ? SettingsModelsPage.keyNeededText
        : SettingsModelsPage.connectedText;
  }

  /// One role row's **Check**: the target the role resolves to, with its own
  /// stored token looked up at the press and dropped after it.
  ///
  /// The answer is dropped unless the row still asks the URL it was pressed
  /// on. A Check on a user-defined server, a switch to Managed, and then that
  /// server's answer landing would otherwise draw a green line under a row
  /// that now points at this Mac — the same rule `didUpdateWidget` enforces
  /// for an answer already on screen, for the one that is still out.
  Future<void> _checkRole(RoleLine line) async {
    final probe = widget.probe;
    final url = line.checkUrl;
    if (probe == null || url == null) return;
    setState(() {
      _roleProbing[line.id] = true;
      _roleProbe.remove(line.id);
    });
    final id = line.bearerId;
    final result = await guardedProbe(
      probe,
      url,
      id == null ? null : widget.storedBearer?.call(id),
    );
    if (!mounted) return;
    final asksStill = widget.roleLines
        .any((row) => row.id == line.id && row.checkUrl == url);
    if (!asksStill) {
      setState(() => _roleProbing.remove(line.id));
      return;
    }
    setState(() {
      _roleProbing[line.id] = false;
      _roleProbe[line.id] = result;
    });
  }
}
