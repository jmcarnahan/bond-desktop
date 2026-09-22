import 'dart:async';

import 'package:flutter/material.dart';

import '../services/llm/model_probe.dart' show ModelProbeResult;
import '../services/llm/model_slots.dart'
    show
        LlmTarget,
        LlmTargetSpec,
        MachineTier,
        ModelPlacement,
        ModelSlot,
        PipelineStageInfo,
        boxProseId,
        builtInProseId,
        builtInProseName,
        draftStageIds,
        slotDefaults;
import '../services/system/system_info.dart' show HardwareInfo;
import '../theme/tokens.dart';
import 'attachment_format.dart' show formatBytes;
import 'chips.dart';
import 'model_slot_editor.dart';
import 'settings_segments.dart';
import 'settings_targets_body.dart';
import 'stage_golden_notes.dart';

/// The Models section's body: which model each step of the pipeline uses, and
/// the two slots the user is allowed to move.
///
/// Its own file rather than another private method on the settings screen,
/// which is already thirteen hundred lines. Nothing here reaches for a
/// provider — the host resolves every target and takes the writes back, so
/// this whole section is drivable from a test with three closures.
class SettingsModelsBody extends StatefulWidget {
  /// The EFFECTIVE target per slot, defaults already resolved by the host.
  ///
  /// Named for the slot rather than `targets` since Round E, because [targets]
  /// is now the list of servers a stage may be pointed AT and the two are
  /// different questions: this map is what the two slot editors open on.
  final Map<ModelSlot, LlmTarget> slotTargets;

  /// Whether each slot is still on the build's own values. The host's answer,
  /// read back from the stored prefs, never a guess made here.
  final Map<ModelSlot, bool> isDefault;

  /// What this build was compiled with, per slot. Save normalises against it —
  /// see [ModelSlotEditor].
  final Map<ModelSlot, LlmTarget> compiledDefaults;

  /// The stage → slot table, as authored in `model_slots.dart`.
  final List<PipelineStageInfo> stages;

  /// Null takes every 'Check server' off the section — the editors' and the
  /// embeddings card's alike. See [ModelSlotEditor.probe].
  final Future<ModelProbeResult> Function(String url, {String? bearer})? probe;

  /// Looks up one target's stored token for the probe's `Authorization`
  /// header. A LOOKUP, never the value.
  final String? Function(String targetId)? storedBearer;
  final void Function(ModelSlot slot, {required String url, required String model})
      onSave;
  final void Function(ModelSlot slot) onReset;

  /// How many drafts may be at the prose server at once — `AppPrefs
  /// .proseParallel`. Rendered under the prose editor as **Drafts in flight**.
  final int proseParallel;

  /// Null takes the width control off the section altogether, on the same
  /// discipline every other optional control here follows: a host that cannot
  /// store the change must not offer the control that makes one.
  final void Function(int width)? onProseParallelChanged;

  /// Rendered ABOVE the stage table, before anything else in the section — the
  /// Local server card, when the host has one to give. Injected rather than
  /// built here so this file keeps knowing nothing about a supervisor: the
  /// section is about where model calls go, and what is running is the host's
  /// answer to hand over.
  final Widget? header;

  /// Every server a stage may be pointed at, built-ins first —
  /// `AppPrefs.allTargets`. Empty renders the section exactly as it rendered
  /// before routing was data: a chip per stage and no list.
  final List<LlmTargetSpec> targets;

  /// Which target id each stage resolves to now, by stage id. Null for
  /// `embeddings`, which is not routed at all, and for an optional stage
  /// nobody has turned on.
  final Map<String, String?> stageTargetIds;

  /// Whether the owner has already read what a third-party draft target
  /// receives. False sends the first such pick to [onConsentNeeded] instead of
  /// writing it.
  final bool cloudDraftsConsent;

  /// Fired by a stage's picker. **Null keeps today's rendering** — a chip and
  /// a model name per stage, no pickers — on the same discipline every other
  /// optional control here follows: a host that cannot store a change must not
  /// offer the control that makes one.
  final void Function(String stageId, String? targetId)? onStageTargetChanged;

  /// Opens the editor pane on a new target. **Null takes the Targets list off
  /// the section**, which is its premise the way [onSave] is the section's.
  final VoidCallback? onAddTarget;
  final void Function(LlmTargetSpec spec)? onEditTarget;
  final Future<void> Function(String id)? onRemoveTarget;

  /// A third-party target was picked for a draft stage and consent has not
  /// been given. The host opens the consent pane; NOTHING is written here, and
  /// the write happens on the other side of Continue.
  final void Function(String stageId, LlmTargetSpec target)? onConsentNeeded;

  /// Whose width **Drafts in flight** is about: the name of the target the
  /// `draft_reply` stage resolves to.
  final String proseParallelTargetName;

  /// What this Mac is, for the fact line above the Targets list. Null while
  /// the host is still asking, which is one frame on a real machine and
  /// forever in a test that does not wire it.
  final HardwareInfo? hardware;

  /// Which tier this Mac is in. Null means the same "still asking", and it is
  /// what disables the button: the defaults it would write are the tier's, so
  /// there is nothing to press until the tier is known.
  final MachineTier? machineTier;

  /// Writes the tier's stage picks and its draft policy. **Null takes the
  /// fact line and the button off the section altogether**, the discipline
  /// every optional control here follows: a host that cannot store the change
  /// must not offer the control that makes one.
  final Future<void> Function()? onApplyTierDefaults;

  /// Where this install's model work runs today, for the line and the button
  /// above **Use this Mac's defaults**.
  final ModelPlacement modelPlacement;

  /// Opens the pane that takes the box address and the access key. Null takes
  /// the adopt button off, this section's usual discipline.
  final VoidCallback? onOpenBoxPane;

  /// Puts the install back on this Mac's own models. What the same button
  /// does when the placement is already the box.
  final Future<void> Function()? onAdoptLocal;

  /// Why the pipeline is parked, when the reason is one the BOX placement can
  /// answer for: `model_unavailable` or `unauthorized`, and null for neither.
  /// One sentence under the placement line, on the same fact the rail reads.
  ///
  /// The reason rather than a bool, because the two park differently and the
  /// sentences send a person to two different places: one waits for a machine
  /// to come back, the other needs a key typed again right here.
  final String? boxParkedReason;

  /// Opens the box pane with the address prefilled and the key field empty,
  /// for a key that was rotated. Null takes the button off, this section's
  /// usual discipline.
  final VoidCallback? onChangeBoxKey;

  const SettingsModelsBody({
    super.key,
    this.header,
    required this.slotTargets,
    required this.isDefault,
    required this.compiledDefaults,
    required this.stages,
    this.probe,
    this.storedBearer,
    required this.onSave,
    required this.onReset,
    this.proseParallel = 1,
    this.onProseParallelChanged,
    this.targets = const [],
    this.stageTargetIds = const {},
    this.cloudDraftsConsent = false,
    this.onStageTargetChanged,
    this.onAddTarget,
    this.onEditTarget,
    this.onRemoveTarget,
    this.onConsentNeeded,
    this.proseParallelTargetName = builtInProseName,
    this.hardware,
    this.machineTier,
    this.onApplyTierDefaults,
    this.modelPlacement = ModelPlacement.local,
    this.onOpenBoxPane,
    this.onAdoptLocal,
    this.boxParkedReason,
    this.onChangeBoxKey,
  });

  /// The collapsed summary — where the three slots point, in one line.
  ///
  /// Static so the screen can build it without this widget existing: a
  /// collapsed section renders its summary and nothing else, and a summary
  /// that needed the body would defeat the whole shape.
  /// [server] is the local server's own one-liner, prefixed when there is one.
  /// Null leaves the summary byte-identical to what it has always said, which
  /// is what a host that wires no server card gets.
  ///
  /// [userTargets] is how many servers the user has ADDED, and it is appended
  /// only when there are some. A machine with the two built-ins and nothing
  /// else reads exactly as it did before routing was data, which is what
  /// `settings_models_test.dart` pins.
  static String summary(
    Map<ModelSlot, LlmTarget> slotTargets, {
    String? server,
    int userTargets = 0,
  }) {
    final fast = _resolve(slotTargets, ModelSlot.fast);
    final prose = _resolve(slotTargets, ModelSlot.prose);
    final embed = _resolve(slotTargets, ModelSlot.embed);
    final slots = 'Fast ${fast.model} @ ${hostPort(fast.baseUrl)} · '
        'Prose ${prose.model} @ ${hostPort(prose.baseUrl)} · '
        'Embeddings ${hostPort(embed.baseUrl)}';
    final line = server == null ? slots : '$server · $slots';
    if (userTargets <= 0) return line;
    return userTargets == 1
        ? '$line · 1 more target'
        : '$line · $userTargets more targets';
  }

  /// The key on **Use this Mac's defaults**. Keyed rather than found by label
  /// for the reason every control here is: the section carries several
  /// buttons and a test that tapped by words would tap whichever came first.
  static const Key tierDefaultsKey = ValueKey('settings-tier-defaults');

  /// The one button that moves the placement. It reads **Use the shared GPU
  /// box** on this Mac and **Use this Mac's models** on the box, because
  /// there are two placements and the press is always the other one.
  static const Key adoptBoxKey = ValueKey('settings-adopt-box');

  /// The heading above both buttons.
  static const String whereHeading = 'Where the models run';

  /// The sentence under the placement line when the box is not answering.
  static const String boxParkedText =
      'The box is not answering. Work is waiting and will retry each minute.';

  /// The same line when the box ANSWERED and refused the key. A different
  /// sentence because it is a different job: waiting fixes the first and
  /// nothing but a new key fixes this one, and the pane that takes one is the
  /// button directly under it.
  static const String boxUnauthorizedText =
      'The box refused the access key. Change it here.';

  /// The key on **Change the access key**, beside the placement button. Keyed
  /// like every other control in this section, because two outlined buttons
  /// sit side by side here and a test that tapped by words would tap
  /// whichever came first.
  static const Key changeBoxKeyKey = ValueKey('settings-change-box-key');

  /// The key on one stage's target picker. Every picker carries the same
  /// words, so a test that tapped by label would be tapping whichever came
  /// first — the reason the slot editors' controls are keyed too.
  static Key stagePickerKey(String stageId) =>
      ValueKey('stage-target-picker-$stageId');

  /// The key on the line under a picker that says the app is dialling
  /// somewhere else than the row names — see [_gatedNote].
  static Key stageGatedKey(String stageId) =>
      ValueKey('stage-target-gated-$stageId');

  /// The nearest width the 1 / 2 / 4 / 8 segments actually offer.
  ///
  /// A stored 3 — hand-typed into the database, or a default this app never
  /// wrote — has to select SOMETHING, and `SegmentedButton` throws on a
  /// selection that is not one of its values.
  ///
  /// DISPLAY ONLY: snapping 3 down to 2 draws the control, it does not write
  /// anything. The stored number stays 3 and the draft lane keeps running
  /// three wide until somebody taps a segment, and then what is written is the
  /// number they tapped. Public and shared because the target editor's width
  /// control is the same control asking the same question, and two copies of a
  /// snapping rule are two copies that drift.
  static int knownWidth(int value) {
    const offered = [1, 2, 4, 8];
    if (offered.contains(value)) return value;
    return offered.lastWhere((w) => w <= value, orElse: () => 1);
  }

  /// `localhost:8082` out of a full completions URL — the part a person reads
  /// to tell two servers apart, without the `/v1/chat/completions` every one
  /// of them ends in.
  ///
  /// A URL that does not parse is returned WHOLE. Something typed into the
  /// field is still the answer to "where does this point", and hiding it
  /// behind a blank would leave the summary lying about a slot that is
  /// genuinely misconfigured.
  static String hostPort(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  /// The compiled default is the last resort, not an empty target: a host that
  /// passed an incomplete map still gets a summary that names a real server.
  static LlmTarget _resolve(
    Map<ModelSlot, LlmTarget> slotTargets,
    ModelSlot slot,
  ) =>
      slotTargets[slot] ?? slotDefaults[slot]!;

  @override
  State<SettingsModelsBody> createState() => _SettingsModelsBodyState();
}

class _SettingsModelsBodyState extends State<SettingsModelsBody> {
  /// The embeddings card runs its own check, because it is the one slot with
  /// no editor to hold that state for it.
  bool _embedProbing = false;
  ModelProbeResult? _embedProbe;

  /// The selection on screen. Held locally so the segments move under the
  /// finger rather than after a round trip through the store — the host is
  /// told on the spot either way. Seeded from the prop and re-seeded when the
  /// host hands over a different one.
  late int _width = SettingsModelsBody.knownWidth(widget.proseParallel);

  @override
  void didUpdateWidget(SettingsModelsBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.proseParallel != widget.proseParallel) {
      _width = SettingsModelsBody.knownWidth(widget.proseParallel);
    }
  }

  LlmTarget _target(ModelSlot slot) =>
      widget.slotTargets[slot] ??
      widget.compiledDefaults[slot] ??
      slotDefaults[slot]!;

  LlmTarget _compiled(ModelSlot slot) =>
      widget.compiledDefaults[slot] ?? slotDefaults[slot]!;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.header != null) ...[
          widget.header!,
          const SizedBox(height: BondSpacing.s24),
          const Divider(height: 1),
          const SizedBox(height: BondSpacing.s24),
        ],
        Text(
          'Which model each step uses',
          style: BondType.small.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: BondSpacing.s4),
        for (final stage in widget.stages) _stageRow(stage),
        const SizedBox(height: BondSpacing.s24),
        ModelSlotEditor(
          key: const ValueKey('model-slot-editor-fast'),
          slot: ModelSlot.fast,
          title: 'Fast · bulk work',
          blurb: 'Triage, extraction, the Needs You verdict and storyline '
              'membership. A small, quick model.',
          current: _target(ModelSlot.fast),
          compiledDefault: _compiled(ModelSlot.fast),
          isDefault: widget.isDefault[ModelSlot.fast] ?? true,
          probe: widget.probe,
          onSave: ({required url, required model}) =>
              widget.onSave(ModelSlot.fast, url: url, model: model),
          onReset: () => widget.onReset(ModelSlot.fast),
        ),
        const SizedBox(height: BondSpacing.s16),
        ModelSlotEditor(
          key: const ValueKey('model-slot-editor-prose'),
          slot: ModelSlot.prose,
          title: 'Prose · reads and writes',
          blurb: 'Storyline titles, recaps, the reply decision and drafts. '
              'The big model.',
          current: _target(ModelSlot.prose),
          compiledDefault: _compiled(ModelSlot.prose),
          isDefault: widget.isDefault[ModelSlot.prose] ?? true,
          probe: widget.probe,
          onSave: ({required url, required model}) =>
              widget.onSave(ModelSlot.prose, url: url, model: model),
          onReset: () => widget.onReset(ModelSlot.prose),
        ),
        if (widget.onProseParallelChanged case final onChanged?) ...[
          const SizedBox(height: BondSpacing.s16),
          ..._draftsInFlight(onChanged),
        ],
        // TWO wirings, read apart. The placement block and the tier-defaults
        // button are different controls writing different things, and a host
        // that can move one but not the other must get exactly the one it can
        // write rather than neither.
        if (_placementWired) ...[
          const SizedBox(height: BondSpacing.s24),
          ..._whereModelsRun(),
        ],
        if (widget.onApplyTierDefaults case final apply?) ...[
          SizedBox(height: _placementWired ? BondSpacing.s16 : BondSpacing.s24),
          ..._thisMac(apply),
        ],
        if (widget.onAddTarget != null) ...[
          const SizedBox(height: BondSpacing.s24),
          Text(
            'Targets',
            style: BondType.small.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: BondSpacing.s4),
          Text(
            'Every server a step above may be pointed at. The two built-in '
            'ones are the slots edited above.',
            style: BondType.caption,
          ),
          const SizedBox(height: BondSpacing.s8),
          SettingsTargetsBody(
            targets: widget.targets,
            probe: widget.probe,
            storedBearer: widget.storedBearer,
            onAdd: widget.onAddTarget,
            onEdit: widget.onEditTarget,
            onRemove: widget.onRemoveTarget,
          ),
        ],
        const SizedBox(height: BondSpacing.s8),
        Text(
          'Pointing both slots at one server makes them share its cache and '
          'its queue — slower than two servers, never broken.',
          style: BondType.caption,
        ),
        const SizedBox(height: BondSpacing.s24),
        ..._embeddingsCard(),
      ],
    );
  }

  /// How wide the draft lane runs, directly under the slot it is about.
  ///
  /// Here rather than in a section of its own because it is a fact about the
  /// prose SERVER — how many slots it was started with — and reading it
  /// anywhere but beside that server's address would be reading it without the
  /// thing it describes. Reported to the host the instant it changes, like
  /// every other control on this screen: the next draft is what it governs, and
  /// one can be queued while this section is open.
  List<Widget> _draftsInFlight(void Function(int) onChanged) {
    return [
      Text(
        'Drafts in flight',
        style: BondType.small.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: BondSpacing.s8),
      SettingsSegments<int>(
        segments: const [
          (value: 1, label: '1'),
          (value: 2, label: '2'),
          (value: 4, label: '4'),
          (value: 8, label: '8'),
        ],
        selected: _width,
        onChanged: (value) {
          setState(() => _width = value);
          onChanged(value);
        },
        // The target's NAME leads the caption, because the width is the
        // target's rather than the slot's since Round E: a draft stage pointed
        // at a GPU box reads that box's slot count, and a caption that still
        // said "the prose server" would be describing a machine this number no
        // longer governs.
        caption: 'For ${widget.proseParallelTargetName}. One per slot the '
            'server was started with (SLOTS in local.mk, --max-num-seqs on '
            'vLLM). Extra requests queue at the server rather than fail.',
      ),
    ];
  }

  /// Whether this host can move the placement at all. Either direction is
  /// enough: a host that can adopt the box but not go back still has a button
  /// worth drawing, and a host that can do neither gets no block.
  bool get _placementWired =>
      widget.onOpenBoxPane != null || widget.onAdoptLocal != null;

  /// Where the models run: the heading, the placement this install is on, the
  /// parked line when the box is not answering, and the one button that is
  /// always the other placement.
  ///
  /// Above **Use this Mac's defaults**, because it is the larger question:
  /// which models this Mac runs only matters once the answer here is this Mac.
  List<Widget> _whereModelsRun() {
    final onBox = widget.modelPlacement == ModelPlacement.box;
    final parkedText = switch (widget.boxParkedReason) {
      'model_unavailable' => SettingsModelsBody.boxParkedText,
      'unauthorized' => SettingsModelsBody.boxUnauthorizedText,
      // Every other park word is about something that is not the box — the
      // local embedding server, a sign-out — and this block must not claim it.
      _ => null,
    };
    return [
      Text(
        SettingsModelsBody.whereHeading,
        style: BondType.small.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: BondSpacing.s4),
      Text(
        onBox
            ? 'The inbox and writing steps run on the shared GPU box. The '
                'embedding model runs here.'
            : 'Everything runs on this Mac.',
        style: BondType.caption,
      ),
      if (onBox && parkedText != null) ...[
        const SizedBox(height: BondSpacing.s4),
        Text(
          parkedText,
          style: BondType.caption.copyWith(color: BondColors.error),
        ),
      ],
      // One button, and the press is always the OTHER placement. Adopting the
      // box needs an address and a key, so it opens a pane; going back to this
      // Mac needs nothing and writes at once. One of the two is wired or this
      // block does not render at all, so the button is never dead.
      const SizedBox(height: BondSpacing.s8),
      Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: BondSpacing.s8,
          runSpacing: BondSpacing.s8,
          children: [
            OutlinedButton(
              key: SettingsModelsBody.adoptBoxKey,
              onPressed: onBox
                  ? (widget.onAdoptLocal == null
                      ? null
                      : () => unawaited(widget.onAdoptLocal!()))
                  : widget.onOpenBoxPane,
              child: Text(
                onBox ? "Use this Mac's models" : 'Use the shared GPU box',
              ),
            ),
            // Only on the box, and not only when parked. A key is rotated on
            // the box's side and this install finds out by being refused, so
            // the door to type the new one has to be standing open before
            // anything parks — and once something has, the sentence above
            // points straight at it.
            if (onBox && widget.onChangeBoxKey != null)
              OutlinedButton(
                key: SettingsModelsBody.changeBoxKeyKey,
                onPressed: widget.onChangeBoxKey,
                child: const Text('Change the access key'),
              ),
          ],
        ),
      ),
      const SizedBox(height: BondSpacing.s4),
      Text(
        onBox
            ? 'Puts every step back on this Mac and starts the local models '
                'again.'
            : 'Points the inbox and writing steps at the box and stops the '
                'local inbox and writing models.',
        style: BondType.caption,
      ),
    ];
  }

  /// What this Mac is, and one press that points the pipeline at what it can
  /// actually run.
  ///
  /// Below the placement block and above the Targets list, because it is about
  /// the machine rather than about a server somebody added: the tier is read
  /// from this Mac's memory every time it is asked for and stored nowhere, so
  /// a models folder carried to another Mac gets that Mac's answer. The
  /// caption names the stages the press rewrites, and it is not a two-step:
  /// nothing is destroyed, and any stage can be re-picked in the table above.
  List<Widget> _thisMac(Future<void> Function() apply) {
    final hardware = widget.hardware;
    final tier = widget.machineTier;

    // Zero bytes is `HardwareInfo.unknown`'s memory, and the channel usually
    // ANSWERS with it rather than failing: a `MissingPluginException` and a
    // `PlatformException` both degrade to it. Anything else it throws rejects
    // the hardware future while the tier, read off the SAME future, still
    // resolves `full` by the never-refuse rule. So a resolved tier beside a
    // null hardware means the read failed or timed out, and it is the zero
    // case in every way that matters here: a machine whose memory could not be
    // read must not be offered a button that would write defaults chosen from
    // a number nobody has. Both get the fact and nothing to press. While BOTH
    // are null the machine is still being read, and that is the branch below.
    final unreadable =
        tier != null && (hardware == null || hardware.memoryBytes <= 0);
    if (unreadable) {
      return [
        Text(
          'This Mac: memory could not be read',
          style: BondType.small.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: BondSpacing.s4),
        Text(
          'Point each step at a target by hand in the table above.',
          style: BondType.caption,
        ),
      ];
    }

    return [
      if (hardware != null && tier != null)
        Text(
          'This Mac: ${hardware.chip}, ${formatBytes(hardware.memoryBytes)}, '
          '${_tierWord(tier)}',
          style: BondType.small.copyWith(fontWeight: FontWeight.w600),
        ),
      const SizedBox(height: BondSpacing.s8),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton(
          key: SettingsModelsBody.tierDefaultsKey,
          onPressed: tier == null ? null : () => unawaited(apply()),
          child: const Text("Use this Mac's defaults"),
        ),
      ),
      const SizedBox(height: BondSpacing.s4),
      Text(_tierCaption(tier), style: BondType.caption),
    ];
  }

  String _tierWord(MachineTier tier) => switch (tier) {
        MachineTier.full => 'runs all three models',
        MachineTier.inbox => 'runs the inbox models',
        MachineTier.remote => 'runs the embedding model',
      };

  /// What a press rewrites, in the words the controls it moves actually carry:
  /// the draft policy's own label from `DraftPolicyLabel`, and the built-in
  /// targets' own names. Each caption NAMES the six stages rather than
  /// pointing at them, because only one of the two is ever on screen and
  /// "those six" on a big Mac would refer to a sentence nobody can see.
  String _tierCaption(MachineTier? tier) => switch (tier) {
        null => 'Reading this Mac…',
        MachineTier.inbox =>
          'Points naming, refresh, recap, grouping, the reply decision and '
              'drafts at Local fast and sets drafts to Only when asked.',
        MachineTier.full =>
          'Clears the six prose stage picks back to Local prose and sets '
              'drafts to For messages that need you.',
        MachineTier.remote =>
          'The inbox and writing steps run on the shared GPU box.',
      };

  /// One authored row: what the stage is, what it does, and which target
  /// answers it.
  ///
  /// The table is AUTHORED — see `pipelineStages` — and since Round E the
  /// stage's `slot` is its DEFAULT rather than its wiring: the right cell is a
  /// picker over every target, and what it selects is data in `stage_targets`.
  /// A host that wires no [SettingsModelsBody.onStageTargetChanged] gets the
  /// chip the row has always shown instead.
  Widget _stageRow(PipelineStageInfo stage) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: BondSpacing.s4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  stage.label,
                  style: BondType.small.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(stage.description, style: BondType.caption),
              ],
            ),
          ),
          const SizedBox(width: BondSpacing.s12),
          Expanded(flex: 2, child: _stageCell(stage)),
        ],
      ),
    );
  }

  /// The right-hand cell: a picker where the stage is routable and a chip
  /// where it is not.
  ///
  /// `embeddings` keeps the chip whatever the host wired. Its vectors carry a
  /// corpus tag and a swapped model would compare two different spaces, so
  /// there is nothing here to pick between — the same reason it has no editor.
  Widget _stageCell(PipelineStageInfo stage) {
    final onChanged = widget.onStageTargetChanged;
    if (onChanged == null || stage.slot == ModelSlot.embed) {
      // A Wrap rather than a Row: the chip and a long model name do not fit
      // two fifths of the pane at a doubled text scale, and wrapping is the
      // right failure.
      return Wrap(
        spacing: BondSpacing.s8,
        runSpacing: BondSpacing.s4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          BondChip.metric(ModelSlotEditor.slotLabel(stage.slot)),
          Text(_target(stage.slot).model, style: BondType.small),
        ],
      );
    }

    final note = stageGoldenNotes[stage.id];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButton<String>(
          key: SettingsModelsBody.stagePickerKey(stage.id),
          isExpanded: true,
          value: _pickerValue(stage),
          hint: const Text('None'),
          items: [
            // An optional stage can be turned OFF, and off is a value rather
            // than an absence: `draft_improve` with no target is the Improve
            // button not being there.
            if (stage.optional)
              const DropdownMenuItem(value: '', child: Text('None')),
            for (final spec in widget.targets)
              DropdownMenuItem(value: spec.id, child: Text(spec.name)),
          ],
          onChanged: (picked) => _pick(stage, picked, onChanged),
        ),
        if (_gatedNote(stage)) ...[
          const SizedBox(height: BondSpacing.s4),
          Text(
            key: SettingsModelsBody.stageGatedKey(stage.id),
            'Sends to ${_gatedFallbackName()} until you allow cloud drafts',
            style: BondType.caption,
          ),
        ],
        if (note != null) ...[
          const SizedBox(height: BondSpacing.s4),
          Text(note, style: BondType.caption),
        ],
      ],
    );
  }

  /// What the app dials INSTEAD while a draft stage is gated.
  ///
  /// `AppPrefs.specForStage` follows the placement now, so a box install's
  /// gated draft lands on the box's writing target rather than on a local port
  /// with nothing behind it. Resolved out of the list the host handed us, so
  /// the sentence names what the picker names; the built-in's name is the last
  /// resort and the answer on every local install.
  String _gatedFallbackName() {
    final wanted = widget.modelPlacement == ModelPlacement.box
        ? boxProseId
        : builtInProseId;
    for (final spec in widget.targets) {
      if (spec.id == wanted) return spec.name;
    }
    return builtInProseName;
  }

  /// Whether this row NAMES one target and the app dials another.
  ///
  /// `AppPrefs.specForStage` sends a third-party target on `draft_reply` back
  /// to the built-in prose one while `cloud_drafts_consent` is false, and on
  /// `draft_improve` leaves the stage unrouted. That can be the state on
  /// arrival — a `stage_targets` restored from a backup, or a consent the owner
  /// never gave — and a picker showing the stored id with no line under it
  /// would be the screen quietly lying about where the work goes.
  bool _gatedNote(PipelineStageInfo stage) {
    if (widget.cloudDraftsConsent) return false;
    if (!draftStageIds.contains(stage.id)) return false;
    final picked = widget.stageTargetIds[stage.id];
    if (picked == null) return false;
    for (final spec in widget.targets) {
      if (spec.id == picked) return spec.isThirdParty;
    }
    return false;
  }

  /// Which item is selected, or null when none of them is.
  ///
  /// `DropdownButton` throws on a value that is not among its items, and the
  /// host's map can name a target that has since been removed or one this
  /// build has never heard of. The ladder is the id the host RESOLVED, then
  /// the optional stage's own None, then nothing at all — never an exception
  /// on a settings screen.
  ///
  /// It computes no default of its own any more. The host passes
  /// `AppPrefs.targetIdForStage`, which is the placement rule applied, and a
  /// second guess here would have shown `Local fast` under a stage the app
  /// sends to the box.
  String? _pickerValue(PipelineStageInfo stage) {
    final stored = widget.stageTargetIds[stage.id];
    if (stored != null && widget.targets.any((spec) => spec.id == stored)) {
      return stored;
    }
    return stage.optional ? '' : null;
  }

  /// What a pick means.
  ///
  /// A third-party target on a DRAFT stage without consent writes nothing: the
  /// host is told to open the consent pane and the write happens on the far
  /// side of Continue. Every other pick is reported the instant it moves, like
  /// the rest of this screen.
  void _pick(
    PipelineStageInfo stage,
    String? picked,
    void Function(String stageId, String? targetId) onChanged,
  ) {
    if (picked == null) return;
    if (picked.isEmpty) {
      onChanged(stage.id, null);
      return;
    }
    for (final spec in widget.targets) {
      if (spec.id != picked) continue;
      final drafting = draftStageIds.contains(stage.id);
      if (drafting && spec.isThirdParty && !widget.cloudDraftsConsent) {
        widget.onConsentNeeded?.call(stage.id, spec);
        return;
      }
      break;
    }
    onChanged(stage.id, picked);
  }

  /// The embeddings slot: where it points and whether it answers, and nothing
  /// else.
  ///
  /// Read-only on purpose, and the note says why in the place somebody would
  /// go looking for the missing control.
  List<Widget> _embeddingsCard() {
    return [
      Row(
        children: [
          Expanded(
            child: Text(
              'Embeddings',
              style: BondType.body.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: BondSpacing.s8),
          // Read from the same map as the editors' chips, not hard-coded:
          // the slot is not switchable today, and the chip must say what the
          // host says rather than what this file assumes.
          BondChip.semantic(
            (widget.isDefault[ModelSlot.embed] ?? true) ? 'Default' : 'Custom',
            (widget.isDefault[ModelSlot.embed] ?? true)
                ? BondTone.neutral
                : BondTone.primary,
          ),
        ],
      ),
      const SizedBox(height: BondSpacing.s4),
      Text(_target(ModelSlot.embed).baseUrl, style: BondType.mono),
      if (widget.probe != null) ...[
        const SizedBox(height: BondSpacing.s8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: ModelSlotEditor.checkKey(ModelSlot.embed),
            onPressed: _embedProbing ? null : () => unawaited(_checkEmbed()),
            child: const Text('Check server'),
          ),
        ),
        // A URL this one refuses renders here as an error alert rather than
        // beside a field, because there is no field: nothing on this card is
        // editable, so there is nowhere else for the message to go.
        ProbeStatus(probing: _embedProbing, result: _embedProbe),
      ],
      const SizedBox(height: BondSpacing.s4),
      Text(
        'Not switchable: every stored vector is tagged with this model, so '
        'changing it means re-embedding everything. Set EMBED_URL at build '
        'time.',
        style: BondType.caption,
      ),
    ];
  }

  /// Same mounted-guarded shape the editors use: the pane can be left while a
  /// check is out, and a settings screen must not crash on diagnostics.
  Future<void> _checkEmbed() async {
    final probe = widget.probe;
    if (probe == null) return;
    setState(() {
      _embedProbing = true;
      _embedProbe = null;
    });
    try {
      final result = await probe(_target(ModelSlot.embed).baseUrl);
      if (!mounted) return;
      setState(() {
        _embedProbing = false;
        _embedProbe = result;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _embedProbing = false;
        _embedProbe = const ModelProbeResult(
          reachable: false,
          error: 'Could not check the server',
        );
      });
    }
  }
}
