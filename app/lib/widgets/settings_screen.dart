import 'dart:async';

import 'package:flutter/material.dart';

import '../providers/context_provider.dart' show ContextDirRow;
import '../providers/prefs_provider.dart'
    show NotifyStyle, backendModeMcp, defaultMcpServerUrl, mcpDeployedUrl;
import '../services/llm/model_probe.dart' show ModelProbeResult;
import '../services/llm/model_slots.dart';
import '../theme/tokens.dart';
import 'attachment_format.dart' show formatBytes;
import 'inline_alert.dart';
import 'needs_you_rules_editor.dart';
import 'pane_surface.dart';
import 'settings_connection_section.dart';
import 'settings_context_section.dart';
import 'settings_lookback_field.dart';
import 'settings_models_body.dart';
import 'settings_section.dart';
import 'time_format.dart' show relativeTime;

/// How much of Settings a host is asking for.
///
/// [SettingsScope.all] is the screen the avatar menu opens. [SettingsScope.ai]
/// is the same screen narrowed to the sections that are about the model — the
/// pane behind the icon rail's AI stop — and titled for it.
///
/// A scope rather than a second screen: every section here is wired through
/// forty callbacks the host already assembles, and a second screen would be a
/// second copy of that wiring drifting out of step with this one.
enum SettingsScope { all, ai }

/// What the user gets to say about how the inbox behaves, plus what Microsoft
/// has actually let this app do.
///
/// A full pane rather than the popup this replaced: the house rule is screens
/// with a back button, and the old dialog had outgrown a popup anyway — a
/// threshold, two free texts, a backend picker, a session block and a
/// permissions table in one undifferentiated column.
///
/// The shape is a list of [SettingsSection]s, every one of them collapsed on
/// arrival. Collapsed, a section is a title and a one-line answer about the
/// state it holds, so the screen opens as a report rather than as a wall of
/// controls; expanded, it is the controls that change that answer. Several may
/// be open at once and none of it is persisted — where the disclosures were
/// left is a scroll position, not a preference.
///
/// It stays a plain [StatefulWidget] over values and closures, reaching for no
/// providers itself, so the host owns every wire and a test can drive the whole
/// screen with nothing but closures.
class SettingsScreen extends StatefulWidget {
  /// Where the Needs You cut sits now, 0..1.
  final double threshold;

  final String aboutMe;

  /// Fired when the user lets go of the slider, not on every pixel of the
  /// drag: each call writes a preference and reloads the list, and doing that
  /// sixty times a second would make the slider feel like it was fighting back.
  final void Function(double value) onThresholdChanged;

  /// Fired by the About me section's Save and by nothing else — never on
  /// dispose. Cancel means cancel, and leaving means leaving.
  final void Function(String value) onAboutMeChanged;

  /// Whether the rail is currently offering the activity log.
  final bool showActivityLog;

  /// Fired the instant the switch moves, not on the way out like the texts
  /// above: the thing it changes is a rail icon sitting behind this pane, and
  /// a toggle whose effect only appears on Back reads as broken. Null hides
  /// the whole section — the same discipline [hasScope] follows.
  final void Function(bool value)? onShowActivityLogChanged;

  /// How a settled message currently announces itself.
  final NotifyStyle notifyStyle;

  /// Fired the instant the selection moves, for the same reason
  /// [onShowActivityLogChanged] is. Null hides the whole section.
  final void Function(NotifyStyle value)? onNotifyStyleChanged;

  /// See [MicrosoftConnectionSection.hasScope].
  final Future<bool> Function(String bareScope)? hasScope;

  /// See [MicrosoftConnectionSection.onSignInAgain].
  final VoidCallback? onSignInAgain;

  /// See [MicrosoftConnectionSection.backendMode].
  final String backendMode;

  /// See [MicrosoftConnectionSection.mcpServerUrl].
  final String mcpServerUrl;

  /// The deployed platform's URL, when this build knows one. Empty hides the
  /// Deployed preset — a build with no `BOND_MCP_SERVER_URL` define has no
  /// deployed endpoint to offer. A parameter rather than a direct read of the
  /// compiled constant so tests can exercise the preset without a dart-define.
  final String deployedUrl;

  /// See [MicrosoftConnectionSection.onBackendModeChanged].
  final void Function(String mode)? onBackendModeChanged;

  /// See [MicrosoftConnectionSection.onMcpServerUrlChanged].
  final void Function(String url)? onMcpServerUrlChanged;

  /// See [MicrosoftConnectionSection.connectionStatus].
  final Future<Map<String, Object?>?> Function()? connectionStatus;

  /// See [MicrosoftConnectionSection.onConnectMicrosoft].
  final VoidCallback? onConnectMicrosoft;

  /// See [MicrosoftConnectionSection.isTargetSignedIn].
  final Future<bool> Function()? isTargetSignedIn;

  /// See [MicrosoftConnectionSection.targetAccountLabel].
  final Future<String?> Function()? targetAccountLabel;

  /// See [MicrosoftConnectionSection.onSignIn].
  final Future<void> Function()? onSignIn;

  /// See [MicrosoftConnectionSection.onSignOutOfServer].
  final Future<void> Function()? onSignOutOfServer;

  /// Leaves Settings, back to whatever section was showing.
  final VoidCallback onBack;

  /// Goes to Home. Null renders no home affordance — a host with no Home to go
  /// to must not offer one.
  final VoidCallback? onHome;

  /// The stored needs-you rules, verbatim. Empty means the app's own
  /// [needsYouDefaultRules] are in force.
  final String needsYouRules;

  /// How many needs-you judgements are queued right now — the whole queue,
  /// not only what the last Save put there.
  ///
  /// The section's summary says so while the re-judge a Save started is still
  /// running, which is the only feedback the owner gets that editing the rules
  /// did anything at all: the verdicts move minutes later, on a queue this
  /// screen does not show. The wording is "judging", not "re-judging", because
  /// the count cannot tell a Save's rows from a sync's, and a summary that
  /// called a fresh backlog a re-judge would be claiming an edit that never
  /// happened.
  final int needsYouRejudging;

  final String needsYouDefaultRules;
  final String needsYouFixedTail;
  final int needsYouRulesMaxLength;

  /// Fired by the rules editor's Save and by nothing else. Null hides the
  /// editor and leaves the Needs You section as the threshold alone.
  final void Function(String value)? onNeedsYouRulesSaved;

  final bool storylineNewestFirst;
  final void Function(bool value)? onStorylineNewestFirstChanged;

  /// Opens the activity log pane. Null hides the link; the switch beside it
  /// still renders if [onShowActivityLogChanged] is wired.
  final VoidCallback? onOpenActivityLog;

  /// Where each slot points NOW, with "follow the build" already resolved by
  /// the host into the build's own values.
  final Map<ModelSlot, LlmTarget> slotTargets;

  /// Whether each slot is still on those build values — what the editors
  /// render as `Default` rather than as `Custom`.
  final Map<ModelSlot, bool> slotIsDefault;

  /// What this build was compiled with, per slot. Deliberately NOT named
  /// `slotDefaults`: a field of that name would shadow the const map of the
  /// same name in the constructor's own default expression below.
  final Map<ModelSlot, LlmTarget> compiledDefaults;

  /// The authored stage → slot table the section displays. A parameter so a
  /// test can hand it a short one; the app always passes [pipelineStages].
  final List<PipelineStageInfo> stages;

  /// Asks a server what it serves, for the editors' 'Check server'. Null takes
  /// the button off every editor and the embeddings card — the editors still
  /// work, with the model as a typed name — on the same discipline as every
  /// other optional control here: a host that cannot ask does not offer to.
  final Future<ModelProbeResult> Function(String url)? probeServer;

  /// Fired by a slot editor's Save. **Null hides the whole Models section**,
  /// the same discipline every other optional section follows: a host that
  /// cannot store a change must not offer the controls that make one.
  final void Function(ModelSlot slot, {required String url, required String model})?
      onSlotTargetChanged;

  /// Fired by 'Use build defaults'. Null leaves the button inert rather than
  /// hiding the section — the section's premise is [onSlotTargetChanged].
  final void Function(ModelSlot slot)? onSlotReset;

  /// When mail, Teams and the storyline sweep last ran. Null means never, and
  /// reads as 'never' rather than as a blank.
  final String? lastMailSyncIso;
  final String? lastTeamsSyncIso;
  final String? lastSweepIso;

  /// When the mail reconcile — the re-enumeration that catches what the delta
  /// feed skipped — last finished. Its own row because it runs on its own
  /// cadence: a mail sync minutes fresher than this one is the normal state,
  /// and a reader asking whether the safety net is alive cannot tell from the
  /// sync stamp above.
  final String? lastReconcileIso;

  /// The clock the relative times are measured against. Passed rather than
  /// read from [DateTime.now] so a test can pin it and assert an exact string.
  final DateTime Function() now;

  /// Pulls mail, chats and acks now. Null hides the whole Sync & data section.
  ///
  /// A future, not a callback, because the button has to know when the pull
  /// is over: it reads 'Refreshing…' and goes inert until then, the same way
  /// the Storylines pane's Sync does. A pull that gave no sign it was running
  /// was the one thing on this section a user could not tell had worked.
  final Future<void> Function()? onRefreshNow;

  /// How far back each connector's next sync reaches, in days. Two of them
  /// because the two mailboxes are different sizes — a quarter of email is a
  /// reasonable ask where a quarter of chat is rarely the same one.
  final int mailLookbackDays;
  final int teamsLookbackDays;

  /// Fired by a preset pick, and by a custom date that parsed. Null hides that
  /// one control and leaves the section otherwise whole — the Sync & data
  /// section's premise is [onRefreshNow], not this.
  ///
  /// What the user reads back is the resolved line under the control, which
  /// names the calendar day the window reaches rather than repeating the
  /// number they just chose. Nothing syncs on the strength of the change: the
  /// next sync is what applies it, and a wider window re-drains history then.
  final void Function(int days)? onMailLookbackChanged;
  final void Function(int days)? onTeamsLookbackChanged;

  /// Signs out AND wipes this device's copy of the mailbox — the rail's Sign
  /// out, in other words, and deliberately not [onSignOutOfServer], which
  /// leaves one server's session and keeps the mail. Null hides the block.
  final Future<void> Function()? onSignOutAndClear;

  /// How much of this disk the fetched attachments occupy. Null hides nothing
  /// on its own — the line simply says less until the future answers, and a
  /// host with no cache to measure wires neither this nor
  /// [onClearAttachmentCache].
  final Future<int> Function()? attachmentCacheBytes;

  /// Deletes every cached attachment file. Null hides the whole block: a build
  /// with no cache behind it must not offer to empty one.
  final Future<void> Function()? onClearAttachmentCache;

  /// Already composed by the host as `1.0.0 (1)`. Null when the platform did
  /// not answer, which is the ordinary case in a widget test.
  final String? appVersion;

  final String? databasePath;

  /// The registered context directories, with their link and passage counts.
  /// **Null hides the whole section** — the same "absent wiring, absent
  /// section" discipline every optional row here follows. An empty list is
  /// not null: it renders the section saying there are none yet, which is
  /// what a host with the wiring but no directories wants.
  final List<ContextDirRow>? contextDirectories;

  /// Whether the first read of that list is still out. The rows keep
  /// rendering while it is.
  final bool contextDirectoriesLoading;

  /// A sentence about a library that could not be read at all.
  final String? contextDirectoriesError;

  /// Opens the folder panel and registers what comes back. A future, because
  /// the button holds `Adding…` until the panel is closed and the row is
  /// written. Null leaves the section otherwise whole and offers no Add.
  final Future<void> Function()? onAddContextDirectory;

  /// Forces a read of one directory now.
  final void Function(String id)? onRereadContextDirectory;

  /// Forgets one directory: its index and its links, never the folder.
  final void Function(String id)? onRemoveContextDirectory;

  /// Whether each changed file in that directory earns a digest.
  final void Function(String id, bool on)? onContextDigestsChanged;

  /// The stored `honor_gitignore` value — the section has already inverted
  /// the switch a person reads as **Read ignored files**.
  final void Function(String id, bool on)? onContextHonorGitignoreChanged;

  /// Which half of the screen to render — see [SettingsScope].
  final SettingsScope scope;

  const SettingsScreen({
    super.key,
    this.scope = SettingsScope.all,
    required this.threshold,
    required this.aboutMe,
    required this.onThresholdChanged,
    required this.onAboutMeChanged,
    required this.onBack,
    this.onHome,
    this.showActivityLog = false,
    this.onShowActivityLogChanged,
    this.onOpenActivityLog,
    this.notifyStyle = NotifyStyle.native,
    this.onNotifyStyleChanged,
    this.hasScope,
    this.onSignInAgain,
    this.backendMode = backendModeMcp,
    this.mcpServerUrl = defaultMcpServerUrl,
    this.deployedUrl = mcpDeployedUrl,
    this.onBackendModeChanged,
    this.onMcpServerUrlChanged,
    this.connectionStatus,
    this.onConnectMicrosoft,
    this.isTargetSignedIn,
    this.targetAccountLabel,
    this.onSignIn,
    this.onSignOutOfServer,
    this.needsYouRules = '',
    this.needsYouRejudging = 0,
    this.needsYouDefaultRules = '',
    this.needsYouFixedTail = '',
    this.needsYouRulesMaxLength = 4000,
    this.onNeedsYouRulesSaved,
    this.storylineNewestFirst = false,
    this.onStorylineNewestFirstChanged,
    this.slotTargets = slotDefaults,
    this.slotIsDefault = const {
      ModelSlot.fast: true,
      ModelSlot.prose: true,
      ModelSlot.embed: true,
    },
    this.compiledDefaults = slotDefaults,
    this.stages = pipelineStages,
    this.probeServer,
    this.onSlotTargetChanged,
    this.onSlotReset,
    this.lastMailSyncIso,
    this.lastTeamsSyncIso,
    this.lastSweepIso,
    this.lastReconcileIso,
    this.now = DateTime.now,
    this.onRefreshNow,
    this.mailLookbackDays = 14,
    this.teamsLookbackDays = 14,
    this.onMailLookbackChanged,
    this.onTeamsLookbackChanged,
    this.attachmentCacheBytes,
    this.onClearAttachmentCache,
    this.onSignOutAndClear,
    this.appVersion,
    this.databasePath,
    this.contextDirectories,
    this.contextDirectoriesLoading = false,
    this.contextDirectoriesError,
    this.onAddContextDirectory,
    this.onRereadContextDirectory,
    this.onRemoveContextDirectory,
    this.onContextDigestsChanged,
    this.onContextHonorGitignoreChanged,
  });

  /// Keyed because their labels are ordinary words a test would otherwise have
  /// to find among the section bodies around them.
  static const Key refreshNowKey = ValueKey('settings-refresh-now');
  static const Key signOutClearKey = ValueKey('settings-sign-out-clear');
  static const Key signOutConfirmKey = ValueKey('settings-sign-out-confirm');
  static const Key signOutKeepKey = ValueKey('settings-sign-out-keep');
  static const Key clearCacheKey = ValueKey('settings-clear-attachment-cache');
  static const Key clearCacheConfirmKey =
      ValueKey('settings-clear-attachment-cache-confirm');
  static const Key clearCacheKeepKey =
      ValueKey('settings-clear-attachment-cache-keep');

  /// The three extended permissions, which are [microsoftPermissions] — the
  /// table itself moved to the section that renders the rows. Kept here
  /// because `settings_connection_test.dart` reads its length off
  /// `SettingsScreen.permissions`.
  static const List<(String, String, bool)> permissions = microsoftPermissions;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late double _threshold = widget.threshold.clamp(0.0, 1.0);
  late bool _showActivityLog = widget.showActivityLog;
  late NotifyStyle _notifyStyle = widget.notifyStyle;
  late bool _storylineNewestFirst = widget.storylineNewestFirst;

  /// Ten stops. Enough that the slider feels like it has an opinion, few enough
  /// that the same drag lands on the same value twice.
  static const int _divisions = 10;

  /// The one handle the screen keeps on the connection section's own state.
  ///
  /// Back and Home have to commit a half-typed custom server URL before they
  /// take the field off the screen, and only the section knows whether that
  /// field is showing and what is in it — see
  /// [MicrosoftConnectionSectionState].
  final GlobalKey<MicrosoftConnectionSectionState> _connectionKey = GlobalKey();

  /// The same handle again, for the two lookback fields.
  ///
  /// Their custom date is the other text on this screen with no Save of its
  /// own, so Back, Home and collapsing Sync & data have to commit it before
  /// they take the field off the screen — and only the field knows whether it
  /// is showing and what has been typed into it. See [LookbackFieldState].
  final GlobalKey<LookbackFieldState> _mailLookbackKey = GlobalKey();
  final GlobalKey<LookbackFieldState> _teamsLookbackKey = GlobalKey();

  /// Which sections are open, by title. Several may be; none is by default.
  /// Deliberately not persisted — see the [SettingsSection] doc.
  final Set<String> _open = <String>{};

  /// Whether the wipe button has been armed — see [_signOutBlock]. Reset by
  /// 'Keep' and by the wipe completing, never by a rebuild: an armed button is
  /// a state the user put it in.
  bool _confirmingClear = false;

  /// True while the wipe is running. Both buttons go inert: it takes a
  /// keychain round trip and a database delete, and a second click on either
  /// of them while that is out would be a race over the same rows.
  bool _clearing = false;

  /// Whatever the last wipe attempt said went wrong, shown under the pair and
  /// cleared by the next attempt.
  String? _clearError;

  /// The cache's size in bytes, once the host has said. Null means "not
  /// answered yet" and renders as nothing rather than as a zero — a line
  /// claiming an empty cache before anyone has looked would be a lie a
  /// fraction of a second long.
  int? _cacheBytes;

  /// The same three-state pair the wipe below keeps, for the same two-step
  /// reason.
  bool _confirmingCacheClear = false;
  bool _clearingCache = false;
  String? _cacheClearError;

  late final TextEditingController _aboutMe = TextEditingController(
    text: widget.aboutMe,
  );

  /// The last about-me text actually handed to the host. Cancel restores it,
  /// Save replaces it, and it is what "dirty" is measured against — the same
  /// contract [NeedsYouRulesEditor] keeps for the rules beside it.
  late String _aboutMeSaved = widget.aboutMe;

  /// What the about-me prompt clamps to, enforced on the field. A cap the
  /// screen did not show would silently drop the end of what somebody typed.
  static const int _aboutMeCap = 600;

  static const String _aboutMeBlurb =
      'Two steps of the pipeline read this: the one that decides whether a '
      'message is actually waiting on a reply from you, and the one that '
      'writes the draft. Nothing else does — the Needs You rules below are a '
      'separate text, and this one is not in that prompt. The first 600 '
      'characters are what reaches the model.';

  @override
  void initState() {
    super.initState();
    // Save and Cancel are both enabled by what is in the field, so the buttons
    // have to hear every keystroke.
    _aboutMe.addListener(_onAboutMeChanged);
    // Started once, here, rather than in build: the section rebuilds on every
    // keystroke in the fields above it, and a future created in build would
    // walk the cache tree each time.
    unawaited(_readCacheBytes());
  }

  /// Asks the host how big the cache is and forgets a failure.
  ///
  /// A size nobody could measure renders as nothing, which is exactly what an
  /// unanswered one renders as — there is no state between them worth a user's
  /// attention, and the button below works either way.
  Future<void> _readCacheBytes() async {
    final measure = widget.attachmentCacheBytes;
    if (measure == null) return;
    try {
      final bytes = await measure();
      if (!mounted) return;
      setState(() => _cacheBytes = bytes);
    } on Object catch (e) {
      debugPrint('attachment cache size unavailable: $e');
    }
  }

  void _onAboutMeChanged() => setState(() {});

  @override
  void didUpdateWidget(SettingsScreen old) {
    super.didUpdateWidget(old);
    // A wipe underneath us, not an edit of ours: a sign-in from inside this
    // screen that changes the identity clears the previous person's about-me.
    // An unsaved edit is the user's and is never overwritten; a clean field
    // adopts what the host now says.
    if (old.aboutMe != widget.aboutMe && _aboutMe.text == _aboutMeSaved) {
      _aboutMeSaved = widget.aboutMe;
      _aboutMe.text = widget.aboutMe;
    }
  }

  @override
  void dispose() {
    // NOTHING is saved here. Both texts on this screen — about me and the
    // Needs You rules — commit on their own Save and on nothing else, so
    // Cancel means cancel and leaving means leaving. The dialog this replaced
    // saved about-me on the way out, which needed a scheduleMicrotask to
    // survive being unmounted by its own backend-switch callback; with no
    // write here, that whole hazard is gone.
    _aboutMe.removeListener(_onAboutMeChanged);
    _aboutMe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onHome = widget.onHome;
    return PaneSurface(
      title: widget.scope == SettingsScope.ai ? 'AI' : 'Settings',
      // Both ways out commit a half-typed server URL and a typed lookback date
      // first: they are the two clicks that take those fields off the screen,
      // and [Focus] does not see them (see _commitPendingServerUrl).
      onBack: () {
        _commitPendingServerUrl();
        _commitPendingLookbacks();
        widget.onBack();
      },
      onHome: onHome == null
          ? null
          : () {
              _commitPendingServerUrl();
              _commitPendingLookbacks();
              onHome();
            },
      // A Column in a SingleChildScrollView, never a ListView: two sections
      // hold a TextField, and a lazy list may dispose an off-screen child —
      // which would drop an unsaved edit the moment the user scrolled past it.
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(BondSpacing.s24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final section in _sections()) section],
        ),
      ),
    );
  }

  /// The sections, in order. A section whose wiring is absent is absent — the
  /// same discipline every optional row in the dialog followed.
  ///
  /// Adding a section is inserting one entry here and one builder below.
  /// Nothing else knows the order.
  List<Widget> _sections() {
    // Once per build, so every relative time on the screen is measured against
    // the same instant: two rows a millisecond apart on the boundary of a
    // minute would otherwise disagree with each other.
    final now = widget.now();
    // The AI scope keeps the sections that describe how the model reads this
    // mailbox — who the user is, which server answers, what counts as needing
    // them, how storylines are ordered, and the log of what it did. Everything
    // else on this screen is about the app or the account, and belongs to the
    // avatar menu's Settings.
    final ai = widget.scope == SettingsScope.ai;
    return [
      _section('About me', _aboutMeSummary(), _aboutMeBody()),
      if (!ai && _connectionWired)
        MicrosoftConnectionSection(
          key: _connectionKey,
          expanded: _open.contains(MicrosoftConnectionSection.title),
          onToggle: () => _toggle(MicrosoftConnectionSection.title),
          backendMode: widget.backendMode,
          mcpServerUrl: widget.mcpServerUrl,
          deployedUrl: widget.deployedUrl,
          hasScope: widget.hasScope,
          onSignInAgain: widget.onSignInAgain,
          onBackendModeChanged: widget.onBackendModeChanged,
          onMcpServerUrlChanged: widget.onMcpServerUrlChanged,
          connectionStatus: widget.connectionStatus,
          onConnectMicrosoft: widget.onConnectMicrosoft,
          isTargetSignedIn: widget.isTargetSignedIn,
          targetAccountLabel: widget.targetAccountLabel,
          onSignIn: widget.onSignIn,
          onSignOutOfServer: widget.onSignOutOfServer,
        ),
      if (widget.onSlotTargetChanged != null)
        _section(
          'Models',
          SettingsModelsBody.summary(widget.slotTargets),
          _modelsBody(),
        ),
      _section('Needs You', _needsYouSummary(), _needsYouBody()),
      if (!ai && widget.onNotifyStyleChanged != null)
        _section('Notifications', _notifySummary(), _notifyBody()),
      if (widget.onShowActivityLogChanged != null)
        _section('Activity log', _activityLogSummary(), _activityLogBody()),
      if (widget.onStorylineNewestFirstChanged != null)
        _section('Storylines', _storylinesSummary(), _storylinesBody()),
      // After Storylines and before Sync & data, in BOTH scopes: what the
      // model is allowed to read is a question about the model, so it belongs
      // on the AI stop as much as on the avatar menu's Settings.
      if (widget.contextDirectories != null)
        ContextDirectoriesSection(
          expanded: _open.contains(ContextDirectoriesSection.title),
          onToggle: () => _toggle(ContextDirectoriesSection.title),
          rows: widget.contextDirectories!,
          loading: widget.contextDirectoriesLoading,
          error: widget.contextDirectoriesError,
          onAdd: widget.onAddContextDirectory,
          onReread: widget.onRereadContextDirectory ?? _ignoreId,
          onRemove: widget.onRemoveContextDirectory ?? _ignoreId,
          onDigestsChanged: widget.onContextDigestsChanged ?? _ignoreIdFlag,
          onHonorGitignoreChanged:
              widget.onContextHonorGitignoreChanged ?? _ignoreIdFlag,
          now: widget.now,
        ),
      if (!ai && widget.onRefreshNow != null)
        _section('Sync & data', _syncSummary(now), _syncBody(now)),
      if (!ai && (widget.appVersion != null || widget.databasePath != null))
        _section('About', _aboutSummary(), _aboutBody()),
    ];
  }

  /// The four per-row callbacks are required on the section — every row
  /// renders all four controls — so a host that wired only some of them gets
  /// a control that does nothing rather than a section that is missing. The
  /// section's own premise is [contextDirectories]; these are not it.
  static void _ignoreId(String id) {}

  static void _ignoreIdFlag(String id, bool on) {}

  Widget _section(String title, String summary, Widget body) => SettingsSection(
    title: title,
    summary: summary,
    expanded: _open.contains(title),
    onToggle: () => _toggle(title),
    body: body,
  );

  void _toggle(String title) {
    // Collapsing Sync & data takes a typed lookback date off the screen
    // without ever moving focus — the third of the same three clicks the
    // custom server URL handles, and the only one the screen owns for a
    // section it builds itself.
    if (title == 'Sync & data' && _open.contains(title)) {
      _commitPendingLookbacks();
    }
    setState(
      () => _open.contains(title) ? _open.remove(title) : _open.add(title),
    );
  }

  /// Back and Home's half of the custom-server-URL commit, forwarded to the
  /// state that actually holds the field — see
  /// [MicrosoftConnectionSectionState.commitPendingServerUrl] for why the two
  /// clicks that leave this pane have to commit for themselves.
  void _commitPendingServerUrl() =>
      _connectionKey.currentState?.commitPendingServerUrl();

  /// The same errand for the two lookback fields. Either may be absent — an
  /// unwired side renders no field and the key holds no state — and a field
  /// that is not on Custom… has nothing pending, which it decides for itself.
  void _commitPendingLookbacks() {
    _mailLookbackKey.currentState?.commitPending();
    _teamsLookbackKey.currentState?.commitPending();
  }

  /// Whether the connection section has enough wiring to exist —
  /// [MicrosoftConnectionSection.isWired] holds the rule.
  bool get _connectionWired => MicrosoftConnectionSection.isWired(
    onBackendModeChanged: widget.onBackendModeChanged,
    connectionStatus: widget.connectionStatus,
    hasScope: widget.hasScope,
    onSignIn: widget.onSignIn,
  );

  // ── About me ──────────────────────────────────────────────────────────────

  String _aboutMeSummary() {
    final text = _aboutMeSaved.trim();
    if (text.isEmpty) return 'Not written yet';
    final oneLine = text.replaceAll(RegExp(r'\s+'), ' ');
    // Cut on grapheme clusters, not code units: a substring can land in the
    // middle of an emoji and hand the renderer half a surrogate pair.
    final chars = oneLine.characters;
    return chars.length <= 80 ? oneLine : '${chars.take(80)}…';
  }

  Widget _aboutMeBody() {
    final dirty = _aboutMe.text != _aboutMeSaved;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_aboutMeBlurb, style: BondType.small),
        const SizedBox(height: BondSpacing.s12),
        TextField(
          controller: _aboutMe,
          minLines: 3,
          maxLines: 5,
          // The same 600 the two prompts clamp to. Shown rather than silently
          // applied downstream, so nobody writes a page and loses half of it.
          maxLength: _aboutMeCap,
          decoration: const InputDecoration(
            hintText: 'e.g. I run marketing at a small company; I own the '
                'website redesign and event planning.',
          ),
        ),
        const SizedBox(height: BondSpacing.s8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: dirty ? _cancelAboutMe : null,
              child: const Text('Cancel'),
            ),
            const SizedBox(width: BondSpacing.s8),
            FilledButton(
              onPressed: dirty ? _saveAboutMe : null,
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }

  void _saveAboutMe() {
    final text = _aboutMe.text;
    setState(() => _aboutMeSaved = text);
    widget.onAboutMeChanged(text);
  }

  void _cancelAboutMe() => setState(() => _aboutMe.text = _aboutMeSaved);

  // ── Models ────────────────────────────────────────────────────────────────

  Widget _modelsBody() => SettingsModelsBody(
    targets: widget.slotTargets,
    isDefault: widget.slotIsDefault,
    compiledDefaults: widget.compiledDefaults,
    stages: widget.stages,
    probe: widget.probeServer,
    onSave: widget.onSlotTargetChanged!,
    onReset: widget.onSlotReset ?? (_) {},
  );

  // ── Sync & data ───────────────────────────────────────────────────────────

  /// Where the two pulls stand, in one line.
  ///
  /// A side that has never run says 'not synced yet' in words rather than
  /// 'never' after a verb it does not fit: "Mail synced never" is the sentence
  /// the obvious formatter writes, and nobody would say it. When both have run
  /// the verb is said once — 'Mail synced 4m ago · Teams 2h ago' — because the
  /// second half is read against the first.
  String _syncSummary(DateTime now) {
    final mail = relativeTime(widget.lastMailSyncIso, now);
    final teams = relativeTime(widget.lastTeamsSyncIso, now);
    if (mail == null && teams == null) return 'Not synced yet';
    final mailPart = mail == null ? 'Mail not synced yet' : 'Mail synced $mail';
    final teamsPart = teams == null
        ? 'Teams not synced yet'
        : mail == null
        ? 'Teams synced $teams'
        : 'Teams $teams';
    return '$mailPart · $teamsPart';
  }

  /// True while a pull started from this section is running. The button is
  /// the only thing that can start one, so it is the only thing that has to
  /// go inert — and the host's own Sync label, on the Storylines pane, is not
  /// visible from here.
  bool _refreshing = false;

  /// Runs the host's pull and holds the button until it is over.
  ///
  /// Nothing escapes: every leg of the pull already turns its own failure
  /// into the banner the inbox shows, so a throw arriving here is a bug worth
  /// a trace and never worth leaving the button saying 'Refreshing…' for the
  /// rest of the session — the same contract the Storylines pane's Sync keeps.
  Future<void> _refreshNow() async {
    final refresh = widget.onRefreshNow;
    if (refresh == null) return;
    setState(() => _refreshing = true);
    try {
      await refresh();
    } on Object catch (e) {
      debugPrint('refresh from settings failed: $e');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// The width the three stamp labels share. A column, not a padding: the
  /// three relative times have to line up or the block reads as three
  /// unrelated sentences.
  static const double _stampLabelWidth = 140;

  /// When each source last ran, one button to run them all now, and the one
  /// destructive action in the app that is not the rail's own.
  Widget _syncBody(DateTime now) {
    final onMail = widget.onMailLookbackChanged;
    final onTeams = widget.onTeamsLookbackChanged;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Above the stamps because it is the question they raise: a person
        // reading when the last pull ran is asking how much of their mail is
        // in here, and this is the answer to the second half of that.
        if (onMail != null || onTeams != null) ...[
          Text(
            'How far back to sync',
            style: BondType.small.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: BondSpacing.s8),
          if (onMail != null)
            LookbackField(
              key: _mailLookbackKey,
              label: 'Mail',
              days: widget.mailLookbackDays,
              now: now,
              onChanged: onMail,
              fieldKey: 'settings-mail-lookback',
            ),
          if (onMail != null && onTeams != null)
            const SizedBox(height: BondSpacing.s8),
          if (onTeams != null)
            LookbackField(
              key: _teamsLookbackKey,
              label: 'Teams',
              days: widget.teamsLookbackDays,
              now: now,
              onChanged: onTeams,
              fieldKey: 'settings-teams-lookback',
            ),
          const SizedBox(height: BondSpacing.s12),
        ],
        _stampRow('Mail', widget.lastMailSyncIso, now),
        // Directly under the mail stamp, because it is a fact about that pull
        // and reads as a qualification of it.
        _stampRow('Mail reconcile', widget.lastReconcileIso, now),
        _stampRow('Teams', widget.lastTeamsSyncIso, now),
        _stampRow('Storyline sweep', widget.lastSweepIso, now),
        const SizedBox(height: BondSpacing.s12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonal(
            key: SettingsScreen.refreshNowKey,
            onPressed: _refreshing ? null : () => unawaited(_refreshNow()),
            child: Text(_refreshing ? 'Refreshing…' : 'Refresh now'),
          ),
        ),
        if (widget.onClearAttachmentCache != null) ..._clearCacheBlock(),
        if (widget.onSignOutAndClear != null) ..._signOutBlock(),
      ],
    );
  }

  Widget _stampRow(String label, String? iso, DateTime now) {
    return Row(
      children: [
        SizedBox(
          width: _stampLabelWidth,
          child: Text(
            label,
            style: BondType.small.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: Text(relativeTime(iso, now) ?? 'never', style: BondType.small),
        ),
      ],
    );
  }

  /// Emptying the attachment cache, in the same two clicks the wipe below
  /// takes.
  ///
  /// A gentler action than that one and deliberately shaped identically: it
  /// costs nothing but a re-download, but it is still a delete of files the
  /// user can see the size of, and two destructive buttons on one section that
  /// behaved differently would teach nobody anything.
  List<Widget> _clearCacheBlock() {
    return [
      const SizedBox(height: BondSpacing.s24),
      const Divider(height: 1, color: BondColors.border),
      const SizedBox(height: BondSpacing.s12),
      Text(
        'Attachment cache',
        style: BondType.small.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: BondSpacing.s4),
      Text(
        'Files opened from mail and chats are kept on this device so they '
        'open again without a download.$_cacheSizeSuffix',
        style: BondType.caption,
      ),
      const SizedBox(height: BondSpacing.s8),
      if (!_confirmingCacheClear)
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: SettingsScreen.clearCacheKey,
            onPressed: () => setState(() => _confirmingCacheClear = true),
            child: const Text('Clear attachment cache'),
          ),
        )
      else
        OverflowBar(
          alignment: MainAxisAlignment.start,
          spacing: BondSpacing.s8,
          children: [
            FilledButton(
              key: SettingsScreen.clearCacheConfirmKey,
              style: FilledButton.styleFrom(
                backgroundColor: BondColors.error,
                foregroundColor: BondColors.surface,
              ),
              onPressed:
                  _clearingCache ? null : () => unawaited(_clearCache()),
              child: const Text('Yes, clear the cache'),
            ),
            TextButton(
              key: SettingsScreen.clearCacheKeepKey,
              // Standing down drops the last failure with it, for the reason
              // the wipe's Keep gives.
              onPressed: _clearingCache
                  ? null
                  : () => setState(() {
                      _confirmingCacheClear = false;
                      _cacheClearError = null;
                    }),
              child: const Text('Keep'),
            ),
          ],
        ),
      if (_cacheClearError case final error?) ...[
        const SizedBox(height: BondSpacing.s8),
        InlineAlert(severity: InlineAlertSeverity.error, text: error),
      ],
    ];
  }

  /// What the cache line says about its size, including saying nothing.
  ///
  /// `formatBytes` renders zero as the empty string — it is written for a chip
  /// where an unknown size must draw no characters — so an empty cache says so
  /// in a word instead of reporting `0 B`.
  String get _cacheSizeSuffix {
    final bytes = _cacheBytes;
    if (bytes == null) return '';
    return bytes <= 0 ? ' Empty.' : ' Using ${formatBytes(bytes)}.';
  }

  /// Runs the host's clear, then re-reads the size so the line agrees with
  /// what just happened.
  Future<void> _clearCache() async {
    setState(() {
      _clearingCache = true;
      _cacheClearError = null;
    });
    try {
      await widget.onClearAttachmentCache!();
      if (!mounted) return;
      setState(() {
        _clearingCache = false;
        _confirmingCacheClear = false;
        _cacheBytes = 0;
      });
      await _readCacheBytes();
    } on Object {
      if (!mounted) return;
      setState(() {
        _clearingCache = false;
        _cacheClearError = 'The cache could not be cleared.';
      });
    }
  }

  /// Wiping this device, in two clicks that are not the same click twice.
  ///
  /// The house rule forbids a confirmation dialog, so the confirmation is the
  /// button changing shape in place: the first tap REPLACES 'Sign out and
  /// clear local data' with a red 'Yes, clear and sign out' beside a 'Keep'.
  /// The second click therefore lands on a different button, in a different
  /// place, that did not exist a moment ago — which is the whole of the
  /// protection a modal would have given, without the popup.
  List<Widget> _signOutBlock() {
    return [
      const SizedBox(height: BondSpacing.s24),
      const Divider(height: 1, color: BondColors.border),
      const SizedBox(height: BondSpacing.s12),
      Text(
        'This device',
        style: BondType.small.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: BondSpacing.s4),
      Text(
        "Removes this account's mail, chats, storylines and drafts from this "
        'device and returns to the sign-in screen. Nothing on the server '
        'changes.',
        style: BondType.caption,
      ),
      const SizedBox(height: BondSpacing.s8),
      if (!_confirmingClear)
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: SettingsScreen.signOutClearKey,
            onPressed: () => setState(() => _confirmingClear = true),
            child: const Text('Sign out and clear local data'),
          ),
        )
      else
        OverflowBar(
          alignment: MainAxisAlignment.start,
          spacing: BondSpacing.s8,
          children: [
            FilledButton(
              key: SettingsScreen.signOutConfirmKey,
              style: FilledButton.styleFrom(
                backgroundColor: BondColors.error,
                foregroundColor: BondColors.surface,
              ),
              onPressed: _clearing ? null : () => unawaited(_signOutAndClear()),
              child: const Text('Yes, clear and sign out'),
            ),
            TextButton(
              key: SettingsScreen.signOutKeepKey,
              // Keep also drops a failure from the last attempt: the user has
              // stood down, and a stale "failed" under a single disarmed
              // button would read as a live problem.
              onPressed: _clearing
                  ? null
                  : () => setState(() {
                      _confirmingClear = false;
                      _clearError = null;
                    }),
              child: const Text('Keep'),
            ),
          ],
        ),
      if (_clearError case final error?) ...[
        const SizedBox(height: BondSpacing.s8),
        InlineAlert(severity: InlineAlertSeverity.error, text: error),
      ],
    ];
  }

  /// Nothing here may escape as an unhandled async error, for the same reason
  /// [_signIn] catches everything: it runs off a button press nobody awaits,
  /// and the host may unmount this pane in the middle of it — signing out
  /// takes the whole screen back to the gate.
  Future<void> _signOutAndClear() async {
    setState(() {
      _clearing = true;
      _clearError = null;
    });
    try {
      await widget.onSignOutAndClear!();
      if (!mounted) return;
      setState(() {
        _clearing = false;
        _confirmingClear = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _clearing = false;
        _clearError = 'Sign-out failed.';
      });
    }
  }

  // ── About ─────────────────────────────────────────────────────────────────

  String _aboutSummary() => widget.appVersion == null
      ? 'Version unknown'
      : 'Bond ${widget.appVersion}';

  /// What this build is and where it keeps the mailbox — the two things a bug
  /// report needs and nothing else on this screen answers.
  Widget _aboutBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Version ${widget.appVersion ?? 'unknown'}', style: BondType.small),
        if (widget.databasePath case final path?) ...[
          const SizedBox(height: BondSpacing.s12),
          Text(
            'Database',
            style: BondType.small.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: BondSpacing.s4),
          // Selectable because the only useful thing to do with a path is
          // paste it somewhere else.
          SelectableText(path, style: BondType.mono),
        ],
        const SizedBox(height: BondSpacing.s12),
        Text(
          'Local model servers are configured in the Models section above.',
          style: BondType.caption,
        ),
        Text(
          'The pipeline is documented in docs/pipeline in the repository.',
          style: BondType.caption,
        ),
      ],
    );
  }

  // ── Needs You ─────────────────────────────────────────────────────────────

  /// Five words for ten stops. The slider is a feel, not a number, and a
  /// summary that said "0.7" would be reporting an implementation detail at
  /// somebody who moved a slider.
  String _thresholdWording() {
    if (_threshold >= 0.8) return 'Only the critical';
    if (_threshold >= 0.6) return 'Close to critical';
    if (_threshold >= 0.4) return 'A middle cut';
    if (_threshold >= 0.2) return 'Leaning generous';
    return 'Anything plausible';
  }

  /// Whether the owner has replaced the app's own rules. It reads the WIDGET
  /// prop rather than editor-local state, so a Save inside the editor only
  /// moves this line because the host rebuilds — which is why `_settings()` in
  /// `inbox_screen.dart` watches the prefs rather than reading them.
  bool get _rulesAreCustom => widget.needsYouRules.trim().isNotEmpty;

  String _needsYouSummary() {
    final rules = widget.onNeedsYouRulesSaved == null
        ? ''
        : _rulesAreCustom
        ? ' · custom rules'
        : ' · default rules';
    // Last, after what the rules ARE, because it is the transient half: the
    // rules are the state, this is a queue draining behind them.
    final count = widget.needsYouRejudging;
    final rejudging = count == 0
        ? ''
        : ' · judging $count ${count == 1 ? 'message' : 'messages'}';
    return '${_thresholdWording()}$rules$rejudging';
  }

  Widget _needsYouBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'How much lands in Needs You',
          style: BondType.body.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: BondSpacing.s4),
        // The direction is the thing worth stating: the slider raises a score
        // threshold, so RIGHT means more mail, and a label-less slider would
        // leave that a coin flip.
        Slider(
          value: 1 - _threshold,
          divisions: _divisions,
          onChanged: (value) => setState(() => _threshold = 1 - value),
          onChangeEnd: (value) => widget.onThresholdChanged(1 - value),
        ),
        // Both halves flex: the labels are long enough relative to the pane
        // that a fixed Row overflows at a large text scale.
        Row(
          children: [
            Expanded(
              child: Text('Only the critical', style: BondType.caption),
            ),
            Expanded(
              child: Text(
                'Anything plausible',
                style: BondType.caption,
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
        // Under the slider because it refines the same question the slider
        // tunes: the slider says how much gets through, this says what "needs
        // you" means in the first place.
        if (widget.onNeedsYouRulesSaved case final onSave?) ...[
          const SizedBox(height: BondSpacing.s24),
          NeedsYouRulesEditor(
            value: widget.needsYouRules,
            defaultRules: widget.needsYouDefaultRules,
            fixedTail: widget.needsYouFixedTail,
            maxLength: widget.needsYouRulesMaxLength,
            onSave: onSave,
          ),
        ],
      ],
    );
  }

  // ── Notifications ─────────────────────────────────────────────────────────

  String _notifySummary() => switch (_notifyStyle) {
    NotifyStyle.off => 'Off',
    NotifyStyle.inApp => 'In-app ribbon',
    NotifyStyle.native => 'System notifications when in background',
  };

  /// How loudly the app speaks up when it finishes deciding a message needs the
  /// user — and whether it does at all.
  ///
  /// Reported to the host the instant the selection changes, for the same
  /// reason the switches are: the next settle is what the choice governs, and
  /// one could arrive while this section is still open.
  Widget _notifyBody() {
    final onChanged = widget.onNotifyStyleChanged!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<NotifyStyle>(
            // No tick on the selected segment, matching the backend picker.
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: NotifyStyle.off, label: Text('Off')),
              ButtonSegment(value: NotifyStyle.inApp, label: Text('In-app')),
              ButtonSegment(value: NotifyStyle.native, label: Text('Native')),
            ],
            selected: {_notifyStyle},
            onSelectionChanged: (selection) {
              setState(() => _notifyStyle = selection.first);
              onChanged(selection.first);
            },
          ),
        ),
        const SizedBox(height: BondSpacing.s4),
        // The one thing about Native that is not obvious from its name, and
        // that a user would otherwise report as a bug: it is silent while they
        // are looking at the app, on purpose.
        Text(
          'Native uses system notifications when the app is in the background '
          'and falls back to the in-app ribbon when it is frontmost.',
          style: BondType.caption,
        ),
      ],
    );
  }

  // ── Activity log ──────────────────────────────────────────────────────────

  String _activityLogSummary() =>
      _showActivityLog ? 'Shown in the sidebar' : 'Hidden';

  /// Whether the rail carries the door to the machine room — and a way through
  /// it from here.
  ///
  /// Reported to the host on the spot rather than on the way out: the icon this
  /// controls is on the rail behind this pane, and a switch that only takes
  /// effect once Settings is closed cannot be checked by the person who
  /// flipped it.
  Widget _activityLogBody() {
    final onChanged = widget.onShowActivityLogChanged!;
    final open = widget.onOpenActivityLog;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _showActivityLog,
          title: Text(
            'Show activity log',
            style: BondType.body.copyWith(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            'Adds a link in the sidebar to what has synced and what the AI did.',
            style: BondType.caption,
          ),
          onChanged: (value) {
            setState(() => _showActivityLog = value);
            onChanged(value);
          },
        ),
        if (open != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: open,
              child: const Text('Open the activity log'),
            ),
          ),
      ],
    );
  }

  // ── Storylines ────────────────────────────────────────────────────────────

  String _storylinesSummary() =>
      _storylineNewestFirst ? 'Newest first' : 'Oldest first';

  Widget _storylinesBody() {
    final onChanged = widget.onStorylineNewestFirstChanged!;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      value: _storylineNewestFirst,
      title: Text(
        'Newest episode first',
        style: BondType.body.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        'Storyline timelines open at the newest episode instead of the oldest.',
        style: BondType.caption,
      ),
      onChanged: (value) {
        setState(() => _storylineNewestFirst = value);
        onChanged(value);
      },
    );
  }
}
