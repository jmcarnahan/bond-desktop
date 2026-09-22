import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/message_store.dart' show MessageStore;
import '../providers/activity_provider.dart';
import '../providers/app_providers.dart';
import '../providers/context_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/draft_provider.dart';
import '../providers/home_provider.dart';
import '../providers/prefs_provider.dart';
import '../providers/recipient_search_provider.dart';
import '../providers/setup_provider.dart';
import '../providers/storylines_provider.dart';
import '../services/attachments/file_dialogs.dart';
import '../services/llm/model_probe.dart';
// [ModelSlot] and [LlmTargetSpec] arrive with `prefs_provider.dart`, which
// re-exports them; `pipelineStages` is not re-exported, and the settings host
// needs it to ask where every stage currently points.
import '../services/llm/model_slots.dart'
    show ModelPlacement, boxBaseFromProseUrl, pipelineStages;
import '../services/llm/needs_you_task.dart'
    show needsYouDefaultRules, needsYouOutputContract, needsYouRulesCap;
import '../widgets/settings_local_server_card.dart';
import '../widgets/settings_models_body.dart' show SettingsModelsBody;
import '../widgets/settings_models_simple.dart' show RoleLine;
import '../widgets/settings_screen.dart';

/// The settings surface, and every mutator only settings calls.
///
/// A widget rather than a method on the inbox, for the message history host's
/// reason: two rungs seat the same pane — the avatar menu's Settings and the
/// rail's AI stop — and behind it sit forty wired parameters and a dozen
/// writers that nothing outside settings reaches for. Keeping them here is
/// what lets the inbox screen be about the inbox.
///
/// What is left to the host's own host is what only the inbox can answer:
/// where Back and Home go, the sidebar switch's setter (that switch is the
/// same preference, and one switch is one writer), the two pull flags a reset
/// waits out, and the toasts. Those arrive as callbacks and nothing else does.
///
/// It OWNS the probe: one HTTP client for every server check the pane makes,
/// built on first use and closed with the pane.
class SettingsHost extends ConsumerStatefulWidget {
  /// Which rungs the pane shows — see [SettingsScreen.scope]. The avatar
  /// menu's Settings opens all of it, the AI stop the model half.
  final SettingsScope scope;

  final VoidCallback onBack;
  final VoidCallback onHome;

  /// Leaves the Settings pane without moving the section, for the SDK
  /// permissions table's **Sign in again**, which closes the pane and then
  /// signs out. Deliberately NOT [onBack]: on the AI rung Back goes home, and
  /// this one must not.
  final VoidCallback onCloseSettings;

  /// The open panel every folder in this app is chosen with.
  final FileDialogs fileDialogs;

  /// Turns model work on or off for the session. It stays on the inbox
  /// because the sidebar's own switch calls it too.
  final Future<void> Function(bool on) onSetProcessing;

  /// Waits until neither connector has a pull out. It stays on the inbox
  /// because it reads the two pull flags that screen's own syncs raise, and
  /// [_SettingsHostState._resetPipeline] awaits it before it deletes anything.
  final Future<void> Function() waitForPullsToSettle;

  /// The list AND whatever thread is open, handed over as the future it is so
  /// the Sync section's button can hold 'Refreshing…' until both pulls land.
  final Future<void> Function() onRefreshNow;

  /// The rail's Sign out, the whole wipe.
  final Future<void> Function() onSignOut;

  final VoidCallback onOpenActivityLog;

  /// Drops the inbox's thumbnail cache, whose pictures were drawn for rows a
  /// reset or a cache clear has just taken away.
  final VoidCallback onForgetThumbnails;

  final void Function(String message) onToast;

  /// The probe this pane checks servers with; null builds a real one. A test
  /// hands a fake so a widget test opens no socket, and the host closes
  /// whichever it ends up with.
  final ModelServerProbe? probe;

  const SettingsHost({
    super.key,
    required this.scope,
    required this.onBack,
    required this.onHome,
    required this.onCloseSettings,
    required this.fileDialogs,
    required this.onSetProcessing,
    required this.waitForPullsToSettle,
    required this.onRefreshNow,
    required this.onSignOut,
    required this.onOpenActivityLog,
    required this.onForgetThumbnails,
    required this.onToast,
    this.probe,
  });

  @override
  ConsumerState<SettingsHost> createState() => _SettingsHostState();
}

class _SettingsHostState extends ConsumerState<SettingsHost> {
  /// One HTTP client for every server check the settings screen makes, closed
  /// with the screen. Held here rather than built per check because a client
  /// per button press leaks a connection pool per press, and the probe is
  /// diagnostics that a user can hammer.
  ///
  /// Built on first use rather than in `initState`, so the one a test
  /// handed in through [SettingsHost.probe] is the one that is used and the
  /// one that is closed.
  late final ModelServerProbe _probe = widget.probe ?? ModelServerProbe();

  @override
  void dispose() {
    _probe.close();
    super.dispose();
  }

  /// The tuning controls, the two owner texts, and what Microsoft granted. The
  /// threshold reloads the list as it changes — the whole point of the slider
  /// is watching Needs You grow and shrink under it — while about me and the
  /// Needs You rules are each saved by their own Save.
  ///
  /// It is also where SESSIONS are managed. The screen shows whether the
  /// backend it is currently pointing at is signed in, and signs in and out of
  /// it in place — the gate above never swaps the screen for a settings change,
  /// so this is the only place that work can happen.
  ///
  /// "Sign in again" is kept wired for the SDK permissions table, where it
  /// signs OUT and lets the gate take over. It is not rendered while the
  /// session block is on screen — that block's Sign in… is the same action,
  /// beside the state it fixes.
  ///
  /// `ref.watch` rather than the `ref.read` the dialog used: this is a build
  /// method now, and the Needs You summary reads the STORED rules to say
  /// whether they are custom — a Save from inside the screen only moves that
  /// line because this host rebuilds. Do not "optimise" it to `ref.read`.
  ///
  /// [scope] is what tells the two rungs apart: the avatar menu's Settings
  /// opens all of it, the AI stop opens the model half under the title 'AI'.
  /// ONE builder for both, so a callback added to one is added to the other —
  /// two copies of forty wired parameters is two copies that drift.
  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(appPrefsProvider);
    final notifier = ref.read(appPrefsProvider.notifier);
    // `watch` is legal here because this runs inside `build`, and it is what
    // keeps the three sync stamps live while the pane is open: the stamps
    // re-read on every recorded event, so a sync that lands behind Settings
    // moves the numbers in it. The stamps alone, not the activity snapshot —
    // that one re-reads the whole pane's table per event, and this pane wants
    // three preferences. The two below answer null in a widget test, where
    // there is no platform on the other end of the channel — the About
    // section then says 'Version unknown' rather than throwing.
    final stamps = ref.watch(syncStampsProvider).valueOrNull;
    // Watched for the same reason the stamps are: the library re-reads on
    // every recorded activity event, so a reconcile that finishes behind an
    // open Settings pane moves `reading…` to `12 files · read just now`
    // without the user touching anything.
    final contextDirs = ref.watch(contextDirectoriesProvider);
    final appInfo = ref.watch(appInfoProvider).valueOrNull;
    final databasePath = ref.watch(databasePathProvider).valueOrNull;
    // Null until the channel answers, and null forever in a widget test —
    // which is why every update prop below is a ternary rather than a `!`.
    final updates = ref.watch(updaterStatusProvider).valueOrNull;
    // Watched so the card follows a load through to ready without anybody
    // touching the pane; the supervisor's own field is the fallback for the
    // frame before the stream's first value lands, so the card never renders
    // a blank where a state belongs.
    final serverState = ref.watch(serverStateProvider).valueOrNull ??
        ref.read(modelServerSupervisorProvider).state;
    final supervisor = ref.read(modelServerSupervisorProvider);
    final paths = ref.read(appPathsProvider);
    // Both watched, both null only until the channel answers. Neither stays
    // null: `ChannelSystemInfo.hardware()` catches a missing plugin and a
    // platform error alike and answers `HardwareInfo.unknown`, so in a widget
    // test these resolve to zero bytes rather than never resolving. One future
    // behind both, so they cannot settle a frame apart. The tier is derived
    // from this Mac's memory on every read and stored nowhere, so a models
    // folder carried to another Mac gets that Mac's answer.
    final hardware = ref.watch(hardwareInfoProvider).valueOrNull;
    final machineTier = ref.watch(machineTierProvider).valueOrNull;
    // Read once: the width, its caption's name and whether the control is
    // offered at all are three questions about the same resolved target.
    final draftSpec = prefs.specForStage('draft_reply');
    return SettingsScreen(
      scope: widget.scope,
      onBack: widget.onBack,
      onHome: widget.onHome,
      threshold: prefs.attentionThreshold,
      aboutMe: prefs.aboutMe,
      // The prefs setters update state first and persist behind the caller's
      // back on purpose (see AppPrefsNotifier) — `unawaited` says the discard
      // is that contract, not an oversight.
      onThresholdChanged: (value) {
        unawaited(notifier.setAttentionThreshold(value));
        if (!mounted) return;
        ref.read(conversationsProvider.notifier).load(syncFirst: false);
      },
      onAboutMeChanged: (text) => unawaited(notifier.setAboutMe(text)),
      needsYouRules: prefs.needsYouRules,
      needsYouDefaultRules: needsYouDefaultRules,
      needsYouFixedTail: needsYouOutputContract,
      needsYouRulesMaxLength: needsYouRulesCap,
      onNeedsYouRulesSaved: (text) => unawaited(_saveNeedsYouRules(text)),
      needsYouRejudging: ref.watch(needsYouPendingProvider).valueOrNull ?? 0,
      showActivityLog: prefs.showActivityLog,
      onShowActivityLogChanged: (on) =>
          unawaited(notifier.setShowActivityLog(on)),
      contextSelectExpand: prefs.contextSelectExpand,
      onContextSelectExpandChanged: (on) =>
          unawaited(notifier.setContextSelectExpand(on)),
      onOpenActivityLog: widget.onOpenActivityLog,
      notifyStyle: prefs.notifyStyle,
      onNotifyStyleChanged: (style) => unawaited(notifier.setNotifyStyle(style)),
      draftPolicy: prefs.draftPolicy,
      onDraftPolicyChanged: (value) =>
          unawaited(notifier.setDraftPolicy(value)),
      storylineNewestFirst: prefs.storylineNewestFirst,
      onStorylineNewestFirstChanged: (on) =>
          unawaited(notifier.setStorylineNewestFirst(on)),
      // BOTH sources are wired, and deliberately not bound to the mode the
      // screen OPENED in: the toggle switches backends in place, so which one
      // answers is the screen's live choice. Each closure reads the providers
      // at CALL time — after a switch, the re-ask lands on the session the
      // switch just built.
      //
      // Every closure that touches `ref` starts with a mounted check. The work
      // behind them outlives the pane — a sign-in still out in the browser, a
      // sign-out from the rail — and a dead host must answer with nothing,
      // never with "ref after dispose".
      hasScope: (scope) async {
        if (!mounted) return false;
        return ref.read(authSessionProvider).hasScope(scope);
      },
      connectionStatus: _connectionStatus,
      onConnectMicrosoft: () => unawaited(_connectMicrosoft()),
      backendMode: prefs.backendMode,
      mcpServerUrl: prefs.mcpServerUrl,
      onBackendModeChanged: (mode) {
        unawaited(notifier.setBackendMode(mode));
        _reloadAfterBackendChange();
      },
      onMcpServerUrlChanged: (url) {
        unawaited(notifier.setMcpServerUrl(url));
        _reloadAfterBackendChange();
      },
      onSignInAgain: () {
        widget.onCloseSettings();
        widget.onSignOut();
      },
      isTargetSignedIn: () async {
        if (!mounted) return false;
        return ref.read(authSessionProvider).isSignedIn;
      },
      targetAccountLabel: () async {
        if (!mounted) return null;
        final account = await ref.read(authSessionProvider).storedAccount;
        return account?.mail ?? account?.displayName;
      },
      onSignIn: () async {
        if (!mounted) return;
        final account = await ref.read(authSessionProvider).signIn();
        if (!mounted) return;
        // Before anything syncs: if the rows in this file belong to a
        // different person, the sign-in that just succeeded is the moment
        // they stop being reachable. Two mailboxes must never be in the
        // database at once, and after the first sync is too late.
        final wiped = await ref.read(identityGuardProvider).adopt(account);
        if (!mounted) return;
        if (wiped) {
          // The same list `SignInScreen._invalidateAfterWipe` drops, and
          // duplicated for the same reason it is duplicated there: it is
          // "everything holding mail rows in memory", and a shared helper
          // would hide that from whichever screen gains a provider next.
          // Keep them in step.
          ref.invalidate(conversationsProvider);
          ref.invalidate(storylinesProvider);
          ref.invalidate(threadProvider);
          ref.invalidate(draftProvider);
          ref.invalidate(storylineTimelineProvider);
          // And the previous person's about-me text and needs-you rules,
          // which the notifier still holds in memory — same reason
          // SignInScreen clears them. Both editors adopt the wipe only if
          // their own field is clean, so an unsaved edit survives it.
          unawaited(ref.read(appPrefsProvider.notifier).setAboutMe(''));
          unawaited(ref.read(appPrefsProvider.notifier).setNeedsYouRules(''));
        }
        _reloadAfterBackendChange();
      },
      onSignOutOfServer: () async {
        if (!mounted) return;
        await ref.read(authSessionProvider).signOut();
        if (!mounted) return;
        // NO database wipe here, deliberately. Leaving one server is not
        // "remove this account from this machine" — the rail's Sign out is,
        // and it keeps its explicit wipe. If a different identity signs in
        // next, the IdentityGuard wipes then, which is the moment the rows
        // actually stop being this user's.
        _reloadAfterBackendChange();
      },
      // The effective targets, defaults already resolved: the editors open on
      // real values rather than on the empty strings that mean "follow the
      // build" in the database.
      slotTargets: {
        for (final slot in ModelSlot.values) slot: prefs.targetFor(slot),
      },
      slotIsDefault: {
        for (final slot in ModelSlot.values) slot: prefs.isSlotDefault(slot),
      },
      // What each editor treats as "Default", which is the ROUTER target while
      // the app runs its own server: handing it the compiled default instead
      // would turn a Save on an untouched editor into an override equal to
      // today's router URL, detaching the slot from the router for good.
      compiledDefaults: {
        for (final slot in ModelSlot.values) slot: prefs.slotBaseline(slot),
      },
      probeServer: _probe.probe,
      // A LOOKUP by id, never the token: the closure reads one bearer out of
      // the notifier's cache at the moment Check server is pressed, hands it
      // to the probe and drops it. Nothing holds it.
      storedBearer: (id) => ref.read(appPrefsProvider.notifier).bearerFor(id),
      onSlotTargetChanged: (slot, {required url, required model}) =>
          unawaited(switch (slot) {
            ModelSlot.fast => notifier.setFastLlmTarget(url: url, model: model),
            ModelSlot.prose => notifier.setProseLlmTarget(
              url: url,
              model: model,
            ),
            // Display only — the screen offers no editor for it, and a write
            // that arrived here anyway must not invent one.
            ModelSlot.embed => Future<void>.value(),
          }),
      onSlotReset: (slot) => unawaited(notifier.clearSlotTarget(slot)),
      // Every server a stage may be pointed at, and where each stage points
      // now. Built by the prefs so the picker's items and its selection come
      // from one resolver rather than from two guesses.
      targets: prefs.allTargets,
      stageTargetIds: {
        for (final stage in pipelineStages)
          stage.id: prefs.targetIdForStage(stage.id),
      },
      cloudDraftsConsent: prefs.cloudDraftsConsent,
      // The spec first and the presets after it, in that order: `applyPreset`
      // refuses a target id it cannot find, and until the upsert lands this
      // one is not in the list.
      onTargetSaved: (
        spec, {
        String? bearer,
        bool prose = false,
        bool confirm = false,
        bool bulk = false,
      }) async {
        await notifier.upsertTarget(spec, bearer: bearer);
        if (!prose && !confirm && !bulk) return;
        await notifier.applyPreset(
          targetId: spec.id,
          prose: prose,
          confirm: confirm,
          bulk: bulk,
        );
      },
      onTargetRemoved: notifier.removeTarget,
      // Both watched, both null only until the channel answers. Neither stays
      // null: `ChannelSystemInfo.hardware()` catches a missing plugin and a
      // platform error alike and answers `HardwareInfo.unknown`, so in a
      // widget test these resolve to zero bytes rather than never resolving —
      // which is the case the section renders as "memory could not be read",
      // with nothing to press. One future behind both, so they cannot settle a
      // frame apart. The tier is derived from this Mac's memory on every read
      // and stored nowhere, so a models folder carried to another Mac gets
      // that Mac's answer.
      hardware: hardware,
      machineTier: machineTier,
      // Always wired, and disabled on the section while the tier is unknown
      // rather than taken off it: the button is a fact about this machine and
      // it should not appear a frame late. The tier is READ at the press, not
      // closed over, so a press cannot write last frame's answer. The section
      // re-renders off `prefs` above, so the pickers show the new picks the
      // moment this returns — the same confirmation a slot Save gets, and the
      // section has no snackbar for either.
      onApplyTierDefaults: () async {
        if (!mounted) return;
        final tier = await ref.read(machineTierProvider.future);
        if (!mounted) return;
        // Through the PLACEMENT, read at the press, rather than the tier
        // alone: on the GPU server the picks go back to the box's defaults,
        // and `applyTierDefaults` with this Mac's tier would move the six
        // prose steps onto the local 4B on a small Mac. On this Mac
        // `usePlacement(local)` ends in the same `applyTierDefaults` call
        // this used to make, after dropping the entries the app itself wrote.
        await notifier.usePlacement(
          ref.read(appPrefsProvider).modelPlacement,
          hardwareTier: tier,
        );
      },
      modelPlacement: prefs.modelPlacement,
      // The stored address when there is one and the compiled one otherwise,
      // already resolved — the form prefills from it and never asks twice.
      // The ORIGIN behind the big model's address, which is what the form
      // still asks for: the page's one address field is a `/prose` and
      // `/bulk` pair until Phase 6 gives it two.
      boxUrl: boxBaseFromProseUrl(prefs.effectiveBoxBigUrl),
      boxKeyStored: prefs.boxKeyStored,
      // The whole fact, not just the two words the old block could answer
      // for: the page decides which reasons it can speak to, and it can speak
      // to the embedding server's as well now.
      parked: ref.watch(parkedProvider).valueOrNull,
      // Resolved by one pure function beside the widget, so the grouping rule
      // is pinned by a test that never pumps this screen.
      roleLines: RoleLine.fromPrefs(prefs),
      hardwareLine: SettingsModelsBody.hardwareLine(hardware, machineTier),
      // On the GPU server the managed process runs the embedding model alone,
      // and its state is the one thing the box's own status line cannot say.
      embedServerLine: 'Embedding model: ${SettingsLocalServerBody.summary(
        serverState,
        managed: prefs.managedServer,
      )}',
      // This Mac's HARDWARE tier, not the effective one: the tier is read at
      // the press rather than closed over, so a press cannot write last
      // frame's answer.
      onUseBox: (baseUrl, key) async {
        if (!mounted) return;
        final tier = await ref.read(machineTierProvider.future);
        if (!mounted) return;
        await notifier.useBoxOrigin(
          baseUrl: baseUrl,
          key: key,
          hardwareTier: tier,
        );
      },
      onUseLocal: () async {
        if (!mounted) return;
        final tier = await ref.read(machineTierProvider.future);
        if (!mounted) return;
        await notifier.usePlacement(ModelPlacement.local, hardwareTier: tier);
      },
      onStageTargetChanged: (stageId, targetId) => unawaited(
        targetId == null
            ? notifier.clearStageTarget(stageId)
            : notifier.setStageTarget(stageId, targetId),
      ),
      onCloudDraftsConsent: () => notifier.setCloudDraftsConsent(true),
      // The grant's order reversed, and that order is the protection.
      // `AppPrefs.specForStage` sends a third-party draft target back to the
      // local one while the flag is false, so clearing the two stages first
      // and the flag last means the stages are already local by the moment
      // consent goes. Consent first would leave two stage entries pointing
      // off this machine with nothing but the resolver between them and a
      // draft. Awaited in turn rather than fired together: three writes to
      // one prefs row.
      onStopCloudDrafts: () async {
        await notifier.clearStageTarget('draft_reply');
        await notifier.clearStageTarget('draft_improve');
        await notifier.setCloudDraftsConsent(false);
      },
      cloudDraftsStanding: prefs.cloudDraftsStanding,
      onCloudDraftsStandingChanged: (on) =>
          unawaited(notifier.setCloudDraftsStanding(on)),
      improveTargetName: prefs.specForStage('draft_improve')?.name,
      // Watched for the reason the sync stamps are: the count re-reads on
      // every recorded event, so a draft that leaves behind an open Settings
      // moves the line without the reader touching anything.
      cloudDraftsToday: ref.watch(cloudDraftsTodayProvider).valueOrNull,
      cloudDraftsDailyCap: prefs.cloudDraftsDailyCap,
      onCloudDraftsDailyCapChanged: (value) =>
          unawaited(notifier.setCloudDraftsDailyCap(value)),
      // The width is the DRAFT TARGET's since Round E, not the prose slot's: a
      // GPU box has slots this Mac does not. The old pref is still what the
      // built-in prose target's width is stored in, which is why the write
      // below forks on `isFixed` rather than always writing the spec — and it
      // reads `isFixed` rather than `isBuiltIn` because a derived box spec has
      // no row either, so `upsertTarget` would throw on it.
      proseParallel: draftSpec?.parallel ?? prefs.proseParallel,
      proseParallelTargetName: draftSpec?.name,
      // Not offered at all on the box, by decision: a derived box spec is
      // fixed at four, the width is the SERVER's slot count rather than a
      // preference, and a control that wrote nowhere would be a lie about a
      // number this install does not own.
      onProseParallelChanged: draftSpec != null && draftSpec.isBox
          ? null
          : (width) {
              unawaited(
                draftSpec == null || draftSpec.isFixed
                    ? notifier.setProseParallel(width)
                    : notifier.upsertTarget(
                        draftSpec.copyWith(parallel: width),
                      ),
              );
            },
      localServerSummary: SettingsLocalServerBody.summary(
        serverState,
        managed: prefs.managedServer,
      ),
      modelsHeader: SettingsLocalServerBody(
        state: serverState,
        managed: prefs.managedServer,
        port: prefs.routerPort,
        // Resolved here rather than in the card: empty means "the app's own
        // folder", and only this side knows where that is.
        modelsFolder: prefs.effectiveModelsFolder(paths),
        // No switch: whether this build runs its own server is a define now.
        onManagedChanged: null,
        onPortSaved: (port) => unawaited(_setRouterPort(port)),
        onPickFreePort: supervisor.pickFreePort,
        onChooseFolder: () => unawaited(_chooseModelsFolder()),
        onStart: () => unawaited(supervisor.ensureRunning()),
        onStop: () => unawaited(supervisor.stop()),
        onRestart: () => unawaited(supervisor.restart()),
        // The log is a file, and the operating system's own viewer is the
        // right reader for it — this app has no log pane and does not want
        // one.
        onShowLog: () => unawaited(launchUrl(Uri.file(supervisor.logFile.path))),
        // Clears the wizard's own bookkeeping — everything in `setup_state`
        // but the migration record and the download ledger — and bumps the
        // counter `SetupGate` watches. The inbox unmounts and the wizard opens
        // at the top, with the models still on disk and the session still
        // signed in, so those two steps are a Continue each.
        onSetUpAgain: () => unawaited(restartSetup(ref)),
      ),
      lastMailSyncIso: stamps?.mailIso,
      lastTeamsSyncIso: stamps?.teamsIso,
      lastSweepIso: stamps?.sweepIso,
      lastReconcileIso: stamps?.reconcileIso,
      // Handed over as the future it is, so the section's button can hold
      // 'Refreshing…' until both pulls are back.
      onRefreshNow: widget.onRefreshNow,
      mailLookbackDays: prefs.mailLookbackDays,
      teamsLookbackDays: prefs.teamsLookbackDays,
      // No sync is kicked here: the next sync — the sixty-second poll at the
      // latest — is what applies the new window.
      onMailLookbackChanged: (days) =>
          unawaited(notifier.setMailLookbackDays(days)),
      onTeamsLookbackChanged: (days) =>
          unawaited(notifier.setTeamsLookbackDays(days)),
      // The sidebar switch, mirrored: `watch` because the two resets below
      // are inert while it is on, and a section that learned about the flip
      // on its next rebuild would offer a button that refuses itself.
      processingOn: ref.watch(processingProvider),
      onProcessingChanged: (on) => unawaited(widget.onSetProcessing(on)),
      onClearAiResults: _clearAiResults,
      onForgetAndResync: _forgetAndResync,
      // The rail's Sign out, the whole wipe — deliberately NOT
      // [onSignOutOfServer] above, which leaves one server's session and
      // keeps the mail on this device.
      onSignOutAndClear: widget.onSignOut,
      // Measured on the way in, so the section says how much is actually
      // there rather than what the store thinks it wrote.
      attachmentCacheBytes: () =>
          ref.read(attachmentCacheProvider).sizeBytes(),
      // Both halves, always: the files on disk AND the columns pointing at
      // them. A row left holding a `blob_path` to a file that no longer exists
      // is how a preview shows an empty pane instead of re-downloading.
      onClearAttachmentCache: () async {
        await ref.read(attachmentCacheProvider).clear();
        await ref.read(messageStoreProvider).clearAttachmentBlobs();
        if (!mounted) return;
        // The providers this screen handed the rows point at files that no
        // longer exist; forgetting them lets the next open ask again.
        widget.onForgetThumbnails();
        ref.invalidate(threadProvider);
      },
      appVersion: appInfo == null
          ? null
          : '${appInfo.version} (${appInfo.build})',
      databasePath: databasePath,
      // Every one of these is wired ONLY when the updater said it is
      // available: a build without the Sparkle keys gets the sentence and no
      // controls, and a control that could not do anything is worse than none.
      automaticUpdates: updates?.available == true ? updates!.automatic : null,
      lastUpdateCheckIso: updates?.lastCheck?.toIso8601String(),
      updatesUnavailableReason:
          (updates != null && !updates.available) ? updates.unavailableReason : null,
      onCheckForUpdates: updates?.available == true
          ? () => unawaited(ref.read(updaterProvider).checkForUpdates())
          : null,
      onAutomaticUpdatesChanged: updates?.available == true
          ? (on) async {
              await ref.read(updaterProvider).setAutomaticChecks(on);
              if (!mounted) return;
              // Re-read rather than assume: Sparkle owns the preference, so
              // the switch has to show ITS answer — including the case where
              // it declined to take the new value.
              ref.invalidate(updaterStatusProvider);
            }
          : null,
      // `valueOrNull ?? const []` rather than the AsyncValue's own empty
      // state: the section must render — with its Loading… line — while the
      // first read is out, and a null here would take the whole section off
      // the screen for that frame.
      contextDirectories: contextDirs.valueOrNull ?? const [],
      contextDirectoriesLoading: contextDirs.isLoading,
      contextDirectoriesError:
          contextDirs.hasError ? 'The directories could not be read.' : null,
      onAddContextDirectory: () async {
        final added =
            await ref.read(contextDirectoriesActionsProvider).addDirectory(
                  widget.fileDialogs,
                );
        if (!mounted || added == null) return;
        widget.onToast('Added ${added.displayName}');
      },
      onRereadContextDirectory: (id) {
        if (!mounted) return;
        unawaited(ref.read(contextDirectoriesActionsProvider).reread(id));
      },
      onRemoveContextDirectory: (id) {
        if (!mounted) return;
        unawaited(ref.read(contextDirectoriesActionsProvider).remove(id));
      },
      onContextDigestsChanged: (id, on) {
        if (!mounted) return;
        unawaited(
          ref.read(contextDirectoriesActionsProvider).setDigests(id, on),
        );
      },
      onContextHonorGitignoreChanged: (id, on) {
        if (!mounted) return;
        unawaited(
          ref
              .read(contextDirectoriesActionsProvider)
              .setHonorGitignore(id, on),
        );
      },
    );
  }

  /// Saves the Needs You rules and re-asks the recent window under them.
  ///
  /// The editor replaces the WHOLE prompt body, so a Save changes how every
  /// message is judged — and every verdict already on disk was written under
  /// the words the owner has just replaced. The last week is re-asked so the
  /// chip and the tile follow what the new rules say (the needs-you handler's
  /// tail rewrites the flag when a verdict moves); anything older is history
  /// rather than a mistake, because those rules were the rules at the time.
  ///
  /// It lives here rather than on [AppPrefsNotifier] because the notifier
  /// holds a store and nothing else: the activity log and the worker pump are
  /// this host's, and a pref writer that reached for them would be a pref
  /// writer that could not be tested without them.
  Future<void> _saveNeedsYouRules(String text) async {
    // The editor already stores default-equal text as the empty string, so the
    // two strings compared here are in the same normal form and an unchanged
    // Save re-judges nothing.
    final before = ref.read(appPrefsProvider).needsYouRules;
    final notifier = ref.read(appPrefsProvider.notifier);
    unawaited(notifier.setNeedsYouRules(text));
    if (text == before) return;

    // Everything the rest of this needs is read BEFORE the first await, so a
    // Settings pane closed while the requeue is on disk still gets its log
    // row and its wake — the work is queued by then, and a queue nobody
    // pumped would sit until the next sync. Nothing below touches `ref`.
    final store = ref.read(messageStoreProvider);
    final log = ref.read(activityLogProvider);
    final worker = ref.read(aiWorkerProvider);
    final since = DateTime.now()
        .toUtc()
        .subtract(const Duration(days: 7))
        .toIso8601String();
    final queued = await store.requeueNeedsYouRejudge(
      sinceIso: since,
      sources: inboxSources,
    );
    if (queued == 0) return;
    await log.record(
      'needs_you_rejudge',
      count: queued,
      detail: {'since': since},
    );
    // The same wake the attachment digest's requeue relies on: on a running
    // drain this only sets the re-pump flag, and the future it returns is that
    // drain's.
    unawaited(worker.pump());
  }

  /// Settings' **Clear AI results**: every verdict, summary, storyline, draft
  /// and vector goes, and the mail it was written about stays.
  Future<void> _clearAiResults() {
    // The message store owns five indexes and rebuilds them itself; the two
    // over `context_chunks` belong to the context store, and that one is
    // reachable from here and not from there — the same split the inbox's
    // sign-out works to when it unlinks directories beside the wipe. Read
    // before the first await, on [_resetPipeline]'s rule.
    final context = ref.read(contextStoreProvider);
    return _resetPipeline((store) async {
      await store.clearDerived();
      await context.rebuildIndexes();
    });
  }

  /// Settings' **Forget everything and re-sync**: the mailbox goes too, and
  /// the person stays.
  ///
  /// Deliberately NOT the inbox's sign-out with a wipe: the session, the two
  /// sender rules and every setting survive, and so do the registered
  /// directories and their links. A sign-out unlinks those because the next
  /// account's threads are different threads; here the same account re-syncs
  /// the same conversation keys, so a link the user made still names what
  /// they meant.
  Future<void> _forgetAndResync() async {
    final store = ref.read(messageStoreProvider);
    await _resetPipeline((s) => s.wipeAll(keepIdentity: true));
    // A second time, after the invalidates, and this is the call that matters
    // — see [MessageStore.clearSyncCursors]. A mail pass that was already at
    // Graph when the button went down writes its delta cursor back through
    // `setDeltaLink` when it lands, long after the wipe deleted the row, and
    // a resumed cursor over an empty mailbox is the re-sync quietly not
    // happening.
    await store.clearSyncCursors();
  }

  /// What both resets do around the one statement that differs.
  ///
  /// The order is the method, and every step of it is a race this would
  /// otherwise lose:
  ///
  /// - Refused outright while processing is on. The buttons are already inert
  ///   (`SettingsScreen.processingOn`), and this is the same rule read where
  ///   it can be enforced rather than merely drawn.
  /// - Every drain is QUIESCED, not stopped: `stop()` ends the loop and
  ///   leaves the item at the server holding a claim, and a claim outliving
  ///   the row it points at is a worker writing a result into a table that
  ///   was emptied under it. `quiesce` waits for that item and hands the
  ///   claim back.
  /// - `resetInterruptedWork` afterwards, for the claim that was taken in the
  ///   microsecond before the quiesce and released into a table that no
  ///   longer holds the row.
  /// - Then the invalidates, which are the only thing that drops what the
  ///   providers are still holding: the inbox sign-out's five are not enough
  ///   because nobody is leaving the screen — `StorylinesNotifier` alone
  ///   keeps an audit flag and live backstop timers that would fire against
  ///   deleted rows.
  ///
  /// Mail and Teams sync keep running throughout. A message that lands a
  /// millisecond after the delete is simply `pending`, which is where the
  /// next drain wants it anyway.
  ///
  /// Everything below the switch check is read BEFORE the first await, on
  /// [_saveNeedsYouRules]'s rule: this runs off a button press, a reset takes
  /// as long as the item at the server does, and a Settings pane closed in
  /// the middle of it must still get the delete it asked for. Only the
  /// invalidates need a live host, and they check for one.
  ///
  /// The three lanes are named rather than asked of `AiWorkers`, which offers
  /// `pumpAll` and `stopAll` but no `quiesceAll`; that file is another
  /// agent's this phase.
  ///
  /// The pulls are waited out rather than stopped, because nothing can stop
  /// them: a `sync_mail` request is at Graph and will land when it lands, and
  /// what it writes on the way back — messages, a delta cursor — is written
  /// against a mailbox this method may have deleted underneath it. The wait
  /// is the inbox's own two pull flags, which every pull that screen starts
  /// raises, polled a quarter-second at a time and given up on after the
  /// inbox's own settle timeout — see [SettingsHost.waitForPullsToSettle],
  /// which is the seam this awaits. **The window it does not close** is a
  /// pull started somewhere other than that screen, and a pull that outlasts
  /// the timeout: for the mail rows that is harmless, since a message landing
  /// a moment after the delete is simply `pending`, and for the cursor it is
  /// why [_forgetAndResync] clears the cursors a second time on the way out.
  ///
  /// Throws rather than returning quietly when processing is on. The buttons
  /// are already inert, so this is unreachable from the UI, and a caller that
  /// got here anyway must see the refusal in the section's alert rather than
  /// a silent success over a mailbox nothing touched.
  Future<void> _resetPipeline(
    Future<void> Function(MessageStore store) apply,
  ) async {
    if (ref.read(processingProvider)) {
      throw StateError('Turn processing off first');
    }
    final triage = ref.read(triageQueueProvider);
    final workers = ref.read(aiWorkersProvider);
    final store = ref.read(messageStoreProvider);
    final drafts = ref.read(draftHandlerProvider);

    await widget.waitForPullsToSettle();
    await triage.quiesce();
    for (final lane in [workers.fast, workers.storyline, workers.draft]) {
      await lane.quiesce();
    }
    // The fourth thing that writes: Improve is a button press and not queue
    // work, so the draft lane's quiesce above knows nothing about it. One
    // improve still at the server would write its row into the table the
    // next line empties.
    await drafts.quiesce();
    await apply(store);
    await store.resetInterruptedWork();
    if (!mounted) return;
    // The sign-out's drops, and the rest a reset needs because the screen
    // stays open over them. Counted by the list below rather than in a
    // sentence: the last two counts here were both wrong by one.
    for (final provider in <ProviderOrFamily>[
      conversationsProvider,
      storylinesProvider,
      threadProvider,
      draftProvider,
      storylineTimelineProvider,
      storylineMembersProvider,
      storylineThreadIdsProvider,
      storylineBlockedThreadsProvider,
      storylineBlocksProvider,
      activitySnapshotProvider,
      // Reads the same table `activitySnapshotProvider` does and re-reads on
      // the same tick, which a bare DELETE never fires: without this the
      // Settings line keeps the pre-clear count until the next recorded event.
      cloudDraftsTodayProvider,
      syncStampsProvider,
      needsYouPendingProvider,
      contextDirectoriesProvider,
      homeMetricsProvider,
      pipelinePulseProvider,
    ]) {
      ref.invalidate(provider);
    }
    // The thumbnails are a memory cache keyed by attachment, and a reset
    // takes the rows they were drawn for. Not the inbox's `_clearOverlays`, deliberately:
    // it would take the Settings pane the user is standing in off the screen
    // as their own reset landed, and the panes it closes re-read through the
    // providers above anyway.
    widget.onForgetThumbnails();
  }


  /// Moves the port, and restarts onto it. A running server cannot change the
  /// socket it is bound to, so the restart IS the setting taking effect;
  /// nothing restarts when there is nothing running.
  Future<void> _setRouterPort(int port) async {
    final supervisor = ref.read(modelServerSupervisorProvider);
    await ref.read(appPrefsProvider.notifier).setRouterPort(port);
    if (!mounted) return;
    if (ref.read(appPrefsProvider).managedServer) {
      await supervisor.restart();
    }
  }

  /// Points the server at another folder of model files, through the same open
  /// panel every other folder in this app is chosen with. Cancelling changes
  /// nothing, and the restart follows for [_setRouterPort]'s reason: the
  /// preset names absolute paths, and a running server has already read it.
  Future<void> _chooseModelsFolder() async {
    final path = await widget.fileDialogs.chooseDirectory();
    if (path == null || !mounted) return;
    final supervisor = ref.read(modelServerSupervisorProvider);
    await ref.read(appPrefsProvider.notifier).setModelsFolder(path);
    if (!mounted) return;
    if (ref.read(appPrefsProvider).managedServer) {
      await supervisor.restart();
    }
  }

  /// Repaints the list after the backend under it was replaced.
  ///
  /// Changing the mode or the server rebuilds every provider below it, the
  /// conversations notifier included — which comes back with an empty state.
  /// This reads what is already stored, with no sync: the rows are the same
  /// mailbox either way, and asking the brand-new session for mail before the
  /// user has signed in to it would put an error where a list belongs.
  ///
  /// A target with no session is NOT a reason to take anything off screen: the
  /// gate above decides at launch only, this screen stays where it is, and the
  /// settings screen reports "not signed in to this server" with a Sign in…
  /// beside it. The list underneath is simply empty until that happens, which
  /// is the truth about a server nobody has signed in to.
  void _reloadAfterBackendChange() {
    // Settings can be left, and the whole screen torn down, around an
    // in-flight change; a dead host must answer with nothing rather than with
    // "ref after dispose".
    if (!mounted) return;
    // The session just changed, so a "this account has no directory" verdict
    // about the old one is not evidence about the new one; take it back and
    // let the next search ask the server that is actually connected now.
    ref.read(recipientSearchProvider).resetScope();
    ref.read(conversationsProvider.notifier).load(syncFirst: false);
  }

  /// The platform's view of the workspace's Microsoft account.
  ///
  /// EVERY failure answers null rather than throwing: this is a report on a
  /// settings pane, and a server that cannot be reached is a row that says so,
  /// not an exception on its way to a banner. The catch-all covers the rest —
  /// an ask still in flight when this screen goes away must render "no answer"
  /// rather than crash on a ref whose element is gone.
  Future<Map<String, Object?>?> _connectionStatus() async {
    try {
      return await ref
          .read(mcpStackProvider)
          .client
          .callTool('connection_status', const {});
    } on Object {
      return null;
    }
  }

  Future<void> _connectMicrosoft() async {
    if (!mounted) return;
    // The user is on their way to fix exactly the thing the cached verdict is
    // about, so it stops being worth believing the moment they leave. The next
    // search asks once and re-remembers if the grant is still refused.
    ref.read(recipientSearchProvider).resetScope();
    final url = await ref.read(mcpStackProvider).auth.microsoftConnectUrl();
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
