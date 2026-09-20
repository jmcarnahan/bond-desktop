import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../providers/context_provider.dart' show ContextDirRow;
import '../providers/prefs_provider.dart'
    show
        AppPrefs,
        DraftPolicy,
        DraftPolicyLabel,
        NotifyStyle,
        backendModeMcp,
        defaultMcpServerUrl,
        mcpDeployedUrl;
import '../screens/consent_screen.dart' show CloudDraftsConsentPane;
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
import 'settings_segments.dart';
import 'settings_target_editor.dart' show LlmTargetEditor;
import 'time_format.dart' show relativeTime;

/// Which sub-pane of Settings is on screen. Null is the sections themselves.
///
/// A sealed type rather than an enum and two nullable fields, so the pane's
/// title, its body and the values it needs cannot disagree: there is no way to
/// be on the consent pane without the target it is asking about.
sealed class _Subpane {
  const _Subpane();
}

/// Add when [initial] is null, edit otherwise.
class _TargetEditorPane extends _Subpane {
  final LlmTargetSpec? initial;
  const _TargetEditorPane(this.initial);
}

class _ConsentPane extends _Subpane {
  final String stageId;
  final LlmTargetSpec target;
  const _ConsentPane(this.stageId, this.target);
}

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

  /// When a suggested reply is written without anyone asking for it.
  final DraftPolicy draftPolicy;

  /// Fired the instant the selection moves, for [onNotifyStyleChanged]'s
  /// reason and one of its own: the next message to finish extracting is what
  /// the choice governs, and one can land while this section is open. Null
  /// hides the whole section.
  final void Function(DraftPolicy value)? onDraftPolicyChanged;

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

  /// How many drafts the prose server may be writing at once.
  final int proseParallel;

  /// Fired by the **Drafts in flight** segments. Null takes that one control
  /// off the Models section and leaves the rest of it exactly as it was.
  final void Function(int width)? onProseParallelChanged;

  /// Whose width **Drafts in flight** is about — the name of the target the
  /// `draft_reply` stage resolves to. Null names the built-in prose target,
  /// which is what a host with no stage map has.
  final String? proseParallelTargetName;

  /// Every server a stage may be pointed at, built-ins first —
  /// `AppPrefs.allTargets`. Empty leaves the Models section rendering exactly
  /// as it did before routing was data.
  final List<LlmTargetSpec> targets;

  /// Which target id each stage resolves to now, by stage id.
  final Map<String, String?> stageTargetIds;

  /// Whether the owner has read what a third-party draft target receives.
  final bool cloudDraftsConsent;

  /// Fired by the target editor's Save, with the typed bearer and the three
  /// presets. **Null hides Add and Edit** and leaves the Targets list a
  /// read-only report, the same discipline every optional control here
  /// follows.
  final Future<void> Function(
    LlmTargetSpec spec, {
    String? bearer,
    bool prose,
    bool confirm,
    bool bulk,
  })? onTargetSaved;

  /// Fired by a row's confirmed Remove. Null takes Remove off the rows.
  final Future<void> Function(String id)? onTargetRemoved;

  /// Fired by a stage's picker. Null keeps the stage table's chips and offers
  /// no pickers at all.
  final void Function(String stageId, String? targetId)? onStageTargetChanged;

  /// Fired by the consent pane's Continue, before the stage is written. Null
  /// leaves the pane's Continue writing the stage alone, which is the shape a
  /// host that stores no consent flag has.
  final Future<void> Function()? onCloudDraftsConsent;

  /// Whether a draft for an urgent message that needs the owner is improved
  /// on the `draft_improve` target without anybody pressing anything.
  final bool cloudDraftsStanding;

  /// Fired by that switch. Null leaves it off the Suggested replies section
  /// entirely, the same discipline every optional control here follows.
  final ValueChanged<bool>? onCloudDraftsStandingChanged;

  /// What the `draft_improve` stage's target is called, or null when the
  /// stage points nowhere. The standing switch cannot be turned on without
  /// one, and the caption says so.
  final String? improveTargetName;

  /// How many drafts have gone to a third-party target since local midnight.
  /// Null leaves the ledger line off Processing, which is what a host that
  /// has not read the count yet passes.
  final int? cloudDraftsToday;

  /// How many may go in a day. Shown beside the count and quoted by the
  /// consent pane, so the person reading the promise sees the number in force.
  final int cloudDraftsDailyCap;

  /// Fired by the Daily cap field on commit. Null leaves the field off and the
  /// line a read-only report.
  final ValueChanged<int>? onCloudDraftsDailyCapChanged;

  /// Drawn at the top of the Models section — the host's Local server card.
  /// Null leaves the section exactly as it was before there was one.
  final Widget? modelsHeader;

  /// That card's one-liner, prefixed onto the collapsed Models summary. Null
  /// keeps the summary the three slots alone.
  final String? localServerSummary;

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

  /// Whether this session is running model work right now — the sidebar
  /// switch, mirrored here.
  ///
  /// It is read twice by the Processing section: once by the switch it draws,
  /// and once by the two reset buttons, which are inert while it is true. A
  /// reset races every drain it does not stop, and the honest way to say so
  /// is a disabled button with the reason under it.
  final bool processingOn;

  /// Fired the instant the mirror switch moves, for
  /// [onShowActivityLogChanged]'s reason: what it changes is the sidebar
  /// behind this pane and the queues behind that.
  final ValueChanged<bool>? onProcessingChanged;

  /// Deletes every verdict, summary, storyline, draft and vector and keeps
  /// the mail. Null hides the block.
  final Future<void> Function()? onClearAiResults;

  /// Deletes the mailbox as well, and keeps the person: the sign-in, their
  /// texts, their sender rules and every setting. Null hides the block.
  final Future<void> Function()? onForgetAndResync;

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

  /// Whether Sparkle checks for updates on its own. **Null hides the switch**,
  /// the same "absent wiring, absent control" discipline every optional row
  /// here follows — a build with no updater must not offer to configure one.
  final bool? automaticUpdates;

  /// When the updater last looked, as an ISO stamp the host composed from
  /// Sparkle's own answer. Null reads as never having checked.
  final String? lastUpdateCheckIso;

  /// Why this build cannot update itself, when it cannot. A development build
  /// and a widget test both land here: the Sparkle keys are written into
  /// Info.plist by `dist/bundle.sh` and exist in no other build.
  final String? updatesUnavailableReason;

  /// Asks Sparkle to look now. Null hides the button — and Sparkle's own
  /// window is what the user sees next, which is why nothing here is a future.
  final VoidCallback? onCheckForUpdates;

  /// Turns the daily check on or off. Null hides the switch.
  final ValueChanged<bool>? onAutomaticUpdatesChanged;

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

  /// Whether a directory-fed draft may pick two sections to read in full
  /// first. One switch for the library, not one per directory: it is a
  /// question about how the app spends model calls, not about a folder.
  final bool contextSelectExpand;

  /// Null hides that switch, on the discipline every callback here follows.
  final void Function(bool on)? onContextSelectExpandChanged;

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
    this.draftPolicy = DraftPolicy.needsYou,
    this.onDraftPolicyChanged,
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
    this.proseParallel = 1,
    this.onProseParallelChanged,
    this.proseParallelTargetName,
    this.targets = const [],
    this.stageTargetIds = const {},
    this.cloudDraftsConsent = false,
    this.onTargetSaved,
    this.onTargetRemoved,
    this.onStageTargetChanged,
    this.onCloudDraftsConsent,
    this.cloudDraftsStanding = false,
    this.onCloudDraftsStandingChanged,
    this.improveTargetName,
    this.cloudDraftsToday,
    this.cloudDraftsDailyCap = AppPrefs.defaultCloudDraftsDailyCap,
    this.onCloudDraftsDailyCapChanged,
    this.modelsHeader,
    this.localServerSummary,
    this.lastMailSyncIso,
    this.lastTeamsSyncIso,
    this.lastSweepIso,
    this.lastReconcileIso,
    this.now = DateTime.now,
    this.onRefreshNow,
    this.mailLookbackDays = 1,
    this.teamsLookbackDays = 1,
    this.onMailLookbackChanged,
    this.onTeamsLookbackChanged,
    this.processingOn = false,
    this.onProcessingChanged,
    this.onClearAiResults,
    this.onForgetAndResync,
    this.attachmentCacheBytes,
    this.onClearAttachmentCache,
    this.onSignOutAndClear,
    this.appVersion,
    this.databasePath,
    this.automaticUpdates,
    this.lastUpdateCheckIso,
    this.updatesUnavailableReason,
    this.onCheckForUpdates,
    this.onAutomaticUpdatesChanged,
    this.contextDirectories,
    this.contextDirectoriesLoading = false,
    this.contextDirectoriesError,
    this.onAddContextDirectory,
    this.onRereadContextDirectory,
    this.onRemoveContextDirectory,
    this.onContextDigestsChanged,
    this.onContextHonorGitignoreChanged,
    this.contextSelectExpand = true,
    this.onContextSelectExpandChanged,
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

  /// The Processing section's controls, keyed for the reason the three above
  /// are: 'Clear AI results' is also most of the caption beside it, and both
  /// confirm buttons carry the same words on purpose.
  static const Key processingToggleKey = ValueKey('settings-processing-toggle');
  static const Key clearAiResultsKey = ValueKey('settings-clear-ai-results');
  static const Key clearAiResultsConfirmKey =
      ValueKey('settings-clear-ai-results-confirm');
  static const Key clearAiResultsKeepKey =
      ValueKey('settings-clear-ai-results-keep');
  static const Key forgetResyncKey = ValueKey('settings-forget-resync');
  static const Key forgetResyncConfirmKey =
      ValueKey('settings-forget-resync-confirm');
  static const Key forgetResyncKeepKey =
      ValueKey('settings-forget-resync-keep');

  /// The cloud-draft controls: the standing switch under Suggested replies,
  /// and the ledger line and cap field under Processing. Keyed for the reason
  /// the buttons above are — each one's label is also most of the caption
  /// beside it.
  static const Key cloudStandingKey = ValueKey('settings-cloud-standing');
  static const Key cloudLedgerKey = ValueKey('settings-cloud-ledger');
  static const Key cloudCapKey = ValueKey('settings-cloud-cap');

  /// Keyed for the same reason the buttons above are: 'Check for updates' is
  /// an ordinary phrase, and the caption beside it contains half of it.
  static const Key checkForUpdatesKey = ValueKey('settings-check-for-updates');

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
  late DraftPolicy _draftPolicy = widget.draftPolicy;
  late bool _cloudDraftsStanding = widget.cloudDraftsStanding;
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

  /// Which sub-pane of Settings is on screen, or null for the sections.
  ///
  /// State on THIS object rather than a route, for two reasons. The house rule
  /// is panes with a back arrow and no `Navigator` routes; and the sections'
  /// expansion state lives here, so swapping only the child is what brings a
  /// person back to the Models section still open at the row they left.
  _Subpane? _subpane;

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

  /// The same triple again, once per reset in the Processing section. Two
  /// copies rather than one shared set: both buttons can be on screen at
  /// once, and a failure under one of them must not arm or blame the other.
  bool _confirmingAiClear = false;
  bool _clearingAi = false;
  String? _aiClearError;

  bool _confirmingForget = false;
  bool _forgetting = false;
  String? _forgetError;

  late final TextEditingController _aboutMe = TextEditingController(
    text: widget.aboutMe,
  );

  /// The Daily cap field, and the node that tells it when the reader has
  /// looked away. Committed on Enter AND on losing focus, which is the
  /// [LookbackField] contract: a half-typed number is not a cap, and the two
  /// ways out of a field are submitting and leaving it.
  late final TextEditingController _cloudCap = TextEditingController(
    text: '${widget.cloudDraftsDailyCap}',
  );
  late final FocusNode _cloudCapFocus = FocusNode();

  /// The last cap actually handed to the host. Enter both submits and drops
  /// focus, so without this one keystroke would commit twice.
  late int _cloudCapCommitted = widget.cloudDraftsDailyCap;

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
    // The other way out of the cap field. A blur is not an event the field
    // itself reports, so the node is what carries it.
    _cloudCapFocus.addListener(_onCloudCapFocusChanged);
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

  void _onCloudCapFocusChanged() {
    if (!_cloudCapFocus.hasFocus) _commitCloudCap();
  }

  /// Hands the typed cap to the host, or leaves it alone.
  ///
  /// A number that does not parse is IGNORED rather than corrected: the field
  /// takes digits only, so the only way to get here with nothing readable is
  /// an empty box, and emptying a box is not a request to change anything.
  /// The notifier clamps, so a number outside the range is still a number
  /// this can report.
  void _commitCloudCap() {
    final value = int.tryParse(_cloudCap.text.trim());
    if (value == null || value == _cloudCapCommitted) return;
    _cloudCapCommitted = value;
    widget.onCloudDraftsDailyCapChanged?.call(value);
  }

  @override
  void didUpdateWidget(SettingsScreen old) {
    super.didUpdateWidget(old);
    // The host clamps: a typed 5000 comes back as 1000, and the field has to
    // say what the ledger line beside it says. Only while the field still
    // holds the number last handed over — a reader mid-way through typing a
    // new one is not overwritten.
    if (old.cloudDraftsDailyCap != widget.cloudDraftsDailyCap &&
        int.tryParse(_cloudCap.text.trim()) == _cloudCapCommitted) {
      _cloudCapCommitted = widget.cloudDraftsDailyCap;
      _cloudCap.text = '${widget.cloudDraftsDailyCap}';
    }
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
    _cloudCapFocus.removeListener(_onCloudCapFocusChanged);
    _cloudCapFocus.dispose();
    _cloudCap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onHome = widget.onHome;
    // A sub-pane REPLACES the sections rather than floating over them: the
    // house rule is one pane at a time with a way back, and the sections stay
    // in this State so closing the sub-pane restores them untouched.
    if (_subpane case final subpane?) {
      return PaneSurface(
        title: switch (subpane) {
          _TargetEditorPane(initial: null) => 'Add target',
          _TargetEditorPane() => 'Edit target',
          _ConsentPane() => 'Cloud drafts',
        },
        onBack: _closeSubpane,
        onHome: onHome,
        child: switch (subpane) {
          _TargetEditorPane(:final initial) => LlmTargetEditor(
              initial: initial,
              probe: widget.probeServer,
              onSave: _saveTarget,
              onCancel: _closeSubpane,
            ),
          _ConsentPane(:final stageId, :final target) => CloudDraftsConsentPane(
              targetName: target.name,
              stageLabel: _stageLabel(stageId),
              dailyCap: widget.cloudDraftsDailyCap,
              onContinue: () => unawaited(_acceptCloudDrafts(stageId, target)),
              // Back and Not now are the same answer, and neither writes.
              onNotNow: _closeSubpane,
            ),
        },
      );
    }
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
          SettingsModelsBody.summary(
            widget.slotTargets,
            server: widget.localServerSummary,
            userTargets: _userTargetCount,
          ),
          _modelsBody(),
        ),
      _section('Needs You', _needsYouSummary(), _needsYouBody()),
      // After Needs You because it is the next question that pile raises —
      // these are the messages a reply gets written for — and in BOTH scopes
      // with no `!ai` guard: how much of the big model's time goes on replies
      // nobody asked for is a fact about the model, so the AI stop is exactly
      // where someone would look for it.
      if (widget.onDraftPolicyChanged != null)
        _section(
          'Suggested replies',
          _suggestedRepliesSummary(),
          _suggestedRepliesBody(),
        ),
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
          selectExpand: widget.contextSelectExpand,
          onSelectExpandChanged: widget.onContextSelectExpandChanged,
          now: widget.now,
        ),
      // Before Sync & data and in BOTH scopes, with no `!ai` guard: whether
      // the models are running at all, and whether what they wrote is thrown
      // away, are questions about the model — so the AI stop is exactly where
      // someone would look for them. Its premise is any one of the three
      // wires: a host that offers only the switch gets only the switch.
      if (_processingWired)
        _section('Processing', _processingSummary(), _processingBody()),
      if (!ai && widget.onRefreshNow != null)
        _section('Sync & data', _syncSummary(now), _syncBody(now)),
      if (!ai && (widget.appVersion != null || widget.databasePath != null))
        _section('About', _aboutSummary(), _aboutBody(now)),
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
    header: widget.modelsHeader,
    slotTargets: widget.slotTargets,
    isDefault: widget.slotIsDefault,
    compiledDefaults: widget.compiledDefaults,
    stages: widget.stages,
    probe: widget.probeServer,
    onSave: widget.onSlotTargetChanged!,
    onReset: widget.onSlotReset ?? (_) {},
    proseParallel: widget.proseParallel,
    onProseParallelChanged: widget.onProseParallelChanged,
    proseParallelTargetName:
        widget.proseParallelTargetName ?? builtInProseName,
    targets: widget.targets,
    stageTargetIds: widget.stageTargetIds,
    cloudDraftsConsent: widget.cloudDraftsConsent,
    onStageTargetChanged: widget.onStageTargetChanged,
    onAddTarget: widget.onTargetSaved == null
        ? null
        : () => setState(() => _subpane = const _TargetEditorPane(null)),
    onEditTarget: widget.onTargetSaved == null
        ? null
        : (spec) => setState(() => _subpane = _TargetEditorPane(spec)),
    onRemoveTarget: widget.onTargetRemoved,
    onConsentNeeded: (stageId, target) =>
        setState(() => _subpane = _ConsentPane(stageId, target)),
  );

  /// How many servers the user ADDED. The collapsed summary counts those and
  /// not the two built-ins, so a machine with neither reads exactly as it did
  /// before routing was data.
  int get _userTargetCount =>
      widget.targets.where((spec) => !spec.isBuiltIn).length;

  void _closeSubpane() => setState(() => _subpane = null);

  /// The stage's own word, for the consent pane's first line. The id itself is
  /// a schema name and is not what a person calls the thing.
  String _stageLabel(String stageId) {
    for (final stage in widget.stages) {
      if (stage.id == stageId) return stage.label;
    }
    return stageId;
  }

  Future<void> _saveTarget(
    LlmTargetSpec spec, {
    String? bearer,
    bool prose = false,
    bool confirm = false,
    bool bulk = false,
  }) async {
    await widget.onTargetSaved?.call(
      spec,
      bearer: bearer,
      prose: prose,
      confirm: confirm,
      bulk: bulk,
    );
    if (!mounted) return;
    _closeSubpane();
  }

  /// Continue: the consent is recorded FIRST and the stage written after it.
  ///
  /// That order is the whole protection. `AppPrefs.specForStage` sends a
  /// third-party draft target back to the local one while the flag is false,
  /// so a stage written before the flag would resolve locally until something
  /// else happened to rebuild it.
  Future<void> _acceptCloudDrafts(String stageId, LlmTargetSpec target) async {
    await widget.onCloudDraftsConsent?.call();
    widget.onStageTargetChanged?.call(stageId, target.id);
    if (!mounted) return;
    _closeSubpane();
  }

  // ── Processing ────────────────────────────────────────────────────────────

  /// Whether the section has any wiring at all. Any ONE of the three is
  /// enough — the same "absent wiring, absent control" discipline the rest of
  /// the screen follows, read per control rather than per section.
  bool get _processingWired =>
      widget.onProcessingChanged != null ||
      widget.onClearAiResults != null ||
      widget.onForgetAndResync != null;

  /// The state the section is about, which is the switch's. The two resets
  /// have no state to report between presses.
  String _processingSummary() => widget.processingOn ? 'On' : 'Off';

  /// The mirror switch, then the two resets.
  ///
  /// The order is the argument: both resets are refused while processing is
  /// on, so the control that turns it off has to be the thing above them
  /// rather than a trip back to the sidebar.
  Widget _processingBody() {
    final onChanged = widget.onProcessingChanged;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (onChanged != null) ...[
          // One node, not three: a switch, its name and its state read as a
          // single control to a screen reader, and split across siblings they
          // arrive as an unlabelled toggle followed by two loose words. The
          // sidebar's copy of this switch says the same thing the same way.
          MergeSemantics(
            child: Row(
              children: [
                Switch(
                  key: SettingsScreen.processingToggleKey,
                  value: widget.processingOn,
                  onChanged: onChanged,
                ),
                const SizedBox(width: BondSpacing.s8),
                Expanded(
                  child: Text(
                    'AI processing',
                    style: BondType.small.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  widget.processingOn ? 'On' : 'Off',
                  style: BondType.small,
                ),
              ],
            ),
          ),
          const SizedBox(height: BondSpacing.s4),
          Text(
            'The same switch as the one at the top of the sidebar. Mail and '
            'Teams keep syncing while it is off; only the models stand down.',
            style: BondType.caption,
          ),
        ],
        if (widget.cloudDraftsToday != null) ..._cloudLedgerBlock(),
        if (widget.onClearAiResults != null) ..._clearAiResultsBlock(),
        if (widget.onForgetAndResync != null) ..._forgetResyncBlock(),
      ],
    );
  }

  /// What has gone to somebody else's machine today, and the ceiling on it.
  ///
  /// In Processing rather than in Models because it is about what the app is
  /// DOING, not about where a stage points — the same reason the switch above
  /// it is here.
  List<Widget> _cloudLedgerBlock() {
    final onCap = widget.onCloudDraftsDailyCapChanged;
    return [
      const SizedBox(height: BondSpacing.s16),
      Text(
        'Cloud drafts today: ${widget.cloudDraftsToday} of '
        '${widget.cloudDraftsDailyCap}',
        key: SettingsScreen.cloudLedgerKey,
        style: BondType.small,
      ),
      const SizedBox(height: BondSpacing.s4),
      Text(
        'Drafts sent to a third-party target, by the Improve button, the '
        'standing rule, or a draft stage pointed at one. Nothing more goes '
        'today once the cap is reached.',
        style: BondType.caption,
      ),
      if (onCap != null) ...[
        const SizedBox(height: BondSpacing.s8),
        SizedBox(
          width: 160,
          child: TextField(
            key: SettingsScreen.cloudCapKey,
            controller: _cloudCap,
            focusNode: _cloudCapFocus,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: BondType.mono,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Daily cap',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _commitCloudCap(),
          ),
        ),
      ],
    ];
  }

  /// What both resets say when they are refused.
  static const String _turnOffFirst = 'Turn processing off first';

  /// Whether either reset is out. Both arm buttons read it, not just their
  /// own: the two delete overlapping rows, and a second one armed while the
  /// first is mid-transaction is a race the database would have to settle.
  bool get _resetting => _clearingAi || _forgetting;

  /// What both captions say about how long it takes, because the button
  /// gives no other sign: the refold walks every conversation and five
  /// indexes are rebuilt after it, with nothing to stream in between.
  static const String _resetTakesTime =
      'On a large mailbox this can take a minute or two, and the buttons stay '
      'disabled until it finishes.';

  /// The second click's words, on both buttons.
  ///
  /// Deliberately the same sentence twice: the two-step is the protection
  /// here (the house rule forbids a dialog), and what the second button has
  /// to say is not which reset this is — the caption above it said that — but
  /// that there is no way back from it.
  static const String _confirmLabel = 'Confirm: this cannot be undone';

  /// Throwing away what the models wrote, in the two clicks
  /// [_clearCacheBlock] takes and for its reason.
  List<Widget> _clearAiResultsBlock() {
    return [
      const SizedBox(height: BondSpacing.s24),
      const Divider(height: 1, color: BondColors.border),
      const SizedBox(height: BondSpacing.s12),
      Text(
        'Clear AI results',
        style: BondType.small.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: BondSpacing.s4),
      Text(
        'Deletes every triage verdict, summary, storyline, draft and '
        'embedding. Mail, Teams messages, attachments, directories and your '
        'settings stay. The next syncs re-queue the mailbox a slice at a time '
        'and processing redoes it under the models now configured. '
        '$_resetTakesTime',
        style: BondType.caption,
      ),
      const SizedBox(height: BondSpacing.s8),
      if (!_confirmingAiClear)
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: SettingsScreen.clearAiResultsKey,
            onPressed: widget.processingOn || _resetting
                ? null
                : () => setState(() => _confirmingAiClear = true),
            child: const Text('Clear AI results'),
          ),
        )
      else
        OverflowBar(
          alignment: MainAxisAlignment.start,
          spacing: BondSpacing.s8,
          children: [
            FilledButton(
              key: SettingsScreen.clearAiResultsConfirmKey,
              style: FilledButton.styleFrom(
                backgroundColor: BondColors.error,
                foregroundColor: BondColors.surface,
              ),
              onPressed: _clearingAi ? null : () => unawaited(_clearAi()),
              child: const Text(_confirmLabel),
            ),
            TextButton(
              key: SettingsScreen.clearAiResultsKeepKey,
              // Standing down drops the last failure with it, for the reason
              // the wipe's Keep gives.
              onPressed: _clearingAi
                  ? null
                  : () => setState(() {
                      _confirmingAiClear = false;
                      _aiClearError = null;
                    }),
              child: const Text('Keep'),
            ),
          ],
        ),
      if (widget.processingOn && !_confirmingAiClear) ...[
        const SizedBox(height: BondSpacing.s4),
        Text(_turnOffFirst, style: BondType.caption),
      ],
      if (_aiClearError case final error?) ...[
        const SizedBox(height: BondSpacing.s8),
        InlineAlert(severity: InlineAlertSeverity.error, text: error),
      ],
    ];
  }

  /// The bigger of the two, and the same shape: the mailbox goes as well as
  /// what the models made of it, and the person stays.
  List<Widget> _forgetResyncBlock() {
    return [
      const SizedBox(height: BondSpacing.s24),
      const Divider(height: 1, color: BondColors.border),
      const SizedBox(height: BondSpacing.s12),
      Text(
        'Forget everything and re-sync',
        style: BondType.small.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: BondSpacing.s4),
      Text(
        'Deletes everything synced and everything the pipeline made. Your '
        'sign-in, your name, your rules and your settings stay. The next sync '
        'fetches the lookback window again. $_resetTakesTime',
        style: BondType.caption,
      ),
      const SizedBox(height: BondSpacing.s8),
      if (!_confirmingForget)
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: SettingsScreen.forgetResyncKey,
            onPressed: widget.processingOn || _resetting
                ? null
                : () => setState(() => _confirmingForget = true),
            child: const Text('Forget everything and re-sync'),
          ),
        )
      else
        OverflowBar(
          alignment: MainAxisAlignment.start,
          spacing: BondSpacing.s8,
          children: [
            FilledButton(
              key: SettingsScreen.forgetResyncConfirmKey,
              style: FilledButton.styleFrom(
                backgroundColor: BondColors.error,
                foregroundColor: BondColors.surface,
              ),
              onPressed: _forgetting ? null : () => unawaited(_forget()),
              child: const Text(_confirmLabel),
            ),
            TextButton(
              key: SettingsScreen.forgetResyncKeepKey,
              onPressed: _forgetting
                  ? null
                  : () => setState(() {
                      _confirmingForget = false;
                      _forgetError = null;
                    }),
              child: const Text('Keep'),
            ),
          ],
        ),
      if (widget.processingOn && !_confirmingForget) ...[
        const SizedBox(height: BondSpacing.s4),
        Text(_turnOffFirst, style: BondType.caption),
      ],
      if (_forgetError case final error?) ...[
        const SizedBox(height: BondSpacing.s8),
        InlineAlert(severity: InlineAlertSeverity.error, text: error),
      ],
    ];
  }

  /// Runs the host's clear and disarms on the way out.
  ///
  /// Nothing here may escape as an unhandled async error, for [_clearCache]'s
  /// reason: it runs off a button press nobody awaits. A failure leaves the
  /// pair ARMED and says what happened — the user is about to press it again.
  Future<void> _clearAi() async {
    setState(() {
      _clearingAi = true;
      _aiClearError = null;
    });
    try {
      await widget.onClearAiResults!();
      if (!mounted) return;
      setState(() {
        _clearingAi = false;
        _confirmingAiClear = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _clearingAi = false;
        _aiClearError = 'The AI results could not be cleared.';
      });
    }
  }

  /// [_clearAi]'s twin, and the same contract on failure.
  Future<void> _forget() async {
    setState(() {
      _forgetting = true;
      _forgetError = null;
    });
    try {
      await widget.onForgetAndResync!();
      if (!mounted) return;
      setState(() {
        _forgetting = false;
        _confirmingForget = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _forgetting = false;
        _forgetError = 'The mailbox could not be cleared.';
      });
    }
  }

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
  /// report needs and nothing else on this screen answers — and, between them,
  /// whether this copy can replace itself.
  ///
  /// The updates block sits directly under the version because it is the same
  /// subject read forwards: what this build is, and what the next one would be.
  /// It renders only as far as it is wired — the button, the switch and the
  /// not-configured sentence are three independent `if`s, because a
  /// development build has the sentence and neither control, and the section's
  /// own visibility rule is unchanged either way.
  Widget _aboutBody(DateTime now) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Version ${widget.appVersion ?? 'unknown'}', style: BondType.small),
        if (widget.onCheckForUpdates case final check?) ...[
          const SizedBox(height: BondSpacing.s12),
          Row(
            children: [
              OutlinedButton(
                key: SettingsScreen.checkForUpdatesKey,
                onPressed: check,
                child: const Text('Check for updates'),
              ),
              const SizedBox(width: BondSpacing.s12),
              // The caption answers the question the button raises — "is what
              // I am looking at current?" — which is exactly what
              // `relativeTime` is for. Never a clock time: a stamp would make
              // a reader subtract.
              Expanded(
                child: Text(
                  switch (relativeTime(widget.lastUpdateCheckIso, now)) {
                    final ago? => 'Last checked $ago',
                    _ => 'Never checked for updates',
                  },
                  style: BondType.caption,
                ),
              ),
            ],
          ),
        ],
        if (widget.onAutomaticUpdatesChanged case final onChanged?)
          if (widget.automaticUpdates case final on?)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: on,
              title: Text(
                'Check for updates automatically',
                style: BondType.body.copyWith(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                'Bond looks once a day and asks before it installs anything.',
                style: BondType.caption,
              ),
              // No local mirror of the value: Sparkle owns this preference,
              // the host re-reads it after the call, and a `setState` here
              // would show what was asked for rather than what is true.
              onChanged: onChanged,
            ),
        if (widget.updatesUnavailableReason case final reason?) ...[
          const SizedBox(height: BondSpacing.s12),
          Text(reason, style: BondType.caption),
        ],
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
    return SettingsSegments<NotifyStyle>(
      segments: const [
        (value: NotifyStyle.off, label: 'Off'),
        (value: NotifyStyle.inApp, label: 'In-app'),
        (value: NotifyStyle.native, label: 'Native'),
      ],
      selected: _notifyStyle,
      onChanged: (value) {
        setState(() => _notifyStyle = value);
        onChanged(value);
      },
      // The one thing about Native that is not obvious from its name, and
      // that a user would otherwise report as a bug: it is silent while they
      // are looking at the app, on purpose.
      caption:
          'Native uses system notifications when the app is in the background '
          'and falls back to the in-app ribbon when it is frontmost.',
    );
  }

  // ── Suggested replies ─────────────────────────────────────────────────────

  String _suggestedRepliesSummary() => _draftPolicy.label;

  /// Which messages get a reply written for them before anyone asks.
  ///
  /// Reported to the host the instant the selection changes, like every other
  /// control on this screen: the next message to finish extracting is what the
  /// choice governs, and one can land while this section is open.
  Widget _suggestedRepliesBody() {
    final onChanged = widget.onDraftPolicyChanged!;
    final onStanding = widget.onCloudDraftsStandingChanged;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _draftPolicySegments(onChanged),
        if (onStanding != null) ..._standingBlock(onStanding),
      ],
    );
  }

  /// Which messages get a reply before anyone asks.
  Widget _draftPolicySegments(void Function(DraftPolicy value) onChanged) {
    return SettingsSegments<DraftPolicy>(
      // Off the enum, in its own declaration order: the labels belong to
      // `DraftPolicyLabel` beside the modes they name, and a second list here
      // would be a mode this screen could silently stop offering.
      segments: [
        for (final policy in DraftPolicy.values)
          (value: policy, label: policy.short),
      ],
      selected: _draftPolicy,
      onChanged: (value) {
        setState(() => _draftPolicy = value);
        onChanged(value);
      },
      // What each one does, and the sentence that keeps the third from
      // reading as "turn drafts off": the button is always there.
      caption:
          'Needs you writes a reply ahead of time for messages judged to need '
          'you, at most ten at a time. All drafts every message that looks '
          'like it wants a reply. When asked writes nothing until you press '
          'Draft reply, which works in every mode.',
    );
  }

  /// The standing rule: after a local draft is written for an urgent message
  /// that needs the owner, the same prompt goes to the Improve target and its
  /// answer replaces the draft.
  ///
  /// Inert without a target, because there is nowhere for it to send. The
  /// caption is the whole explanation of which way it is inert.
  List<Widget> _standingBlock(ValueChanged<bool> onStanding) {
    final target = widget.improveTargetName;
    return [
      const SizedBox(height: BondSpacing.s16),
      // One node, not two: the switch and its sentence read as a single
      // control to a screen reader, exactly as the Processing mirror does.
      MergeSemantics(
        child: Row(
          children: [
            Switch(
              key: SettingsScreen.cloudStandingKey,
              value: _cloudDraftsStanding,
              onChanged: target == null
                  ? null
                  : (on) {
                      setState(() => _cloudDraftsStanding = on);
                      onStanding(on);
                    },
            ),
            const SizedBox(width: BondSpacing.s8),
            Expanded(
              child: Text(
                'Improve drafts for messages that need you and are urgent',
                style: BondType.small.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: BondSpacing.s4),
      Text(
        target == null
            ? 'Pick a target for Improve a draft under Models first.'
            : 'After the local draft is written, the same prompt goes to '
                '$target and its answer replaces the draft. Counts toward the '
                'daily cap under Processing.',
        style: BondType.caption,
      ),
    ];
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
