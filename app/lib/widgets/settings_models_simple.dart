import 'dart:async';

import 'package:flutter/material.dart';

import '../providers/app_providers.dart' show ParkedFact;
import '../providers/prefs_provider.dart' show AppPrefs;
import '../screens/setup/setup_where_body.dart' show SetupWhereBody;
import '../services/llm/model_probe.dart' show ModelProbeResult;
import '../services/llm/model_slots.dart'
    show
        LlmTargetSpec,
        ModelPlacement,
        StageRole,
        boxBulkId,
        boxProseId,
        builtInFastId,
        builtInProseId,
        isBoxOrigin,
        normalizeBoxBaseUrl,
        pipelineStages;
import '../theme/tokens.dart';
import 'probe_status.dart' show ProbeStatus;
import 'settings_models_body.dart' show SettingsModelsBody;
import 'settings_section.dart';
import 'settings_segments.dart';

/// One role's row on the simple Models page.
///
/// Three of these are the whole read-only half of the page: what the role is
/// called, one phrase naming the model and the machine that answers for it,
/// and where **Check** should look. Built from the preferences by [fromPrefs],
/// which the host calls and hands down, so this widget stays prop-only like
/// every other body in Settings and the resolution is one pure function a test
/// can call.
@immutable
class RoleLine {
  /// `big`, `small` or `embed` — the slug the row's Check key is built on, and
  /// the reason this is a field rather than a position in a list: a test taps
  /// one named row, never the second one.
  final String id;

  /// The role's own word, as the page says it.
  final String title;

  /// One phrase: the model and the machine it runs on, or the Custom sentence
  /// when the role's steps do not all agree. See [SettingsModelsSimple
  /// .roleDetail], which is where both spellings are built.
  final String detail;

  /// What **Check** asks. Null takes the button off that row, the discipline
  /// every optional control in Settings follows.
  final String? checkUrl;

  /// Which target's stored token rides that one request, or null for a target
  /// with none. An ID, never the token: the lookup happens at the press.
  final String? bearerId;

  const RoleLine({
    required this.id,
    required this.title,
    required this.detail,
    this.checkUrl,
    this.bearerId,
  });

  /// The three rows, resolved from the preferences the way the page reports
  /// them. The host calls this and hands the result down; a test calls it on
  /// an [AppPrefs] it built.
  ///
  /// A role's steps are every stage the placement's rule sends to the same
  /// default target as the role's LEAD stage, `draft_reply` for the big model
  /// and `triage` for the small. Membership is read off
  /// `defaultTargetIdForStage` rather than off `roleOfStage`, and the two
  /// disagree on purpose: storyline membership is the big model's work on the
  /// box and the small model's on this Mac, so grouping by the enum would read
  /// every local install as Custom. `draft_improve` is one of the big model's
  /// steps like the reply it improves on; nothing is optional any more.
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
        detail: SettingsModelsSimple.roleDetail(
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
        detail: SettingsModelsSimple.roleDetail(
          role: StageRole.embed,
          spec: null,
        ),
        checkUrl: prefs.embedRequestTarget.baseUrl,
      ),
    ];
  }
}

/// The Models section as a tester reads it: one question, one form, one status
/// line, three answers, and everything else folded away.
///
/// The section this replaced asked sixteen questions and hid the one a person
/// could answer. The question is **where the models run**; the answer is a
/// segment and, on the GPU server, an address and a key pasted once. The three
/// role lines are a report rather than a control, and every per-step pick and
/// extra server that used to be on top level is behind the **Advanced** fold,
/// unchanged. The port and the models folder are on the Local server card,
/// which the page draws under This Mac.
///
/// PROP-ONLY, like every other body here: nothing reaches for a provider, the
/// host resolves every fact and takes every write back as a closure, and the
/// whole page is drivable from a test with a handful of values. The one piece
/// of state it owns is which segment is showing, because a segment has to move
/// under the finger rather than after a round trip through the store, and the
/// probe results of this session, which belong to no preference.
///
/// The ACCESS KEY is never held here. It lives in [SetupWhereBody]'s own
/// controller, arrives as the argument of one call, and reaches the keychain
/// through the host.
class SettingsModelsSimple extends StatefulWidget {
  /// Where this install's model work runs today. The segment opens on it.
  final ModelPlacement modelPlacement;

  /// The box address to prefill, already resolved by the host: the stored one
  /// when there is one, the compiled one otherwise. Never a key.
  final String boxUrl;

  /// Whether a key for the box is in the keychain. True opens the key field
  /// empty with the hint `Stored. Type to replace` and lets Save through with
  /// it blank; it is a presence flag and never the token.
  final bool boxKeyStored;

  /// Whether the session's processing switch is on. Off, the status line says
  /// so instead of repeating a park sentence, because a park says work is
  /// retrying and nothing retries while the switch is off: the last parked
  /// fact stays in its provider after the drains stop, and the rail guards
  /// the same way.
  final bool processingOn;

  /// Asks a server what it serves. Null takes every **Check** on this page
  /// off, the form's and the three rows' alike.
  final Future<ModelProbeResult> Function(String url, {String? bearer})? probe;

  /// Looks up one target's stored token for a probe's `Authorization` header.
  /// A LOOKUP, never the value.
  final String? Function(String targetId)? storedBearer;

  /// Save, under the GPU server segment: the typed address and the typed key,
  /// or null for a key that is already stored and was not retyped. Null takes
  /// the form off.
  final Future<void> Function(String url, String? key)? onUseBox;

  /// **Use this Mac**. Null takes the button off.
  final Future<void> Function()? onUseLocal;

  /// The three rows, in the order they are drawn. Empty draws none, which is
  /// what a host that resolved no targets has.
  final List<RoleLine> roleLines;

  /// Why the pipeline is parked and how much is waiting, for the status line.
  /// Null is the ordinary state and reads as nothing parked.
  final ParkedFact? parked;

  /// The host's Local server card, drawn under **This Mac**. Injected rather
  /// than built here so this file keeps knowing nothing about a supervisor.
  final Widget? localServer;

  /// What this Mac is, in one sentence — see [SettingsModelsBody.hardwareLine],
  /// which is where it is spelled. Null while the host is still reading.
  final String? hardwareLine;

  /// The embedding server's own state, as one line under the status on the
  /// GPU server placement. Null leaves it off.
  final String? embedServerLine;

  /// The Advanced fold's body: the whole of [SettingsModelsBody].
  final Widget advanced;

  /// Whether that fold is open. Owned by the screen, beside its other
  /// sections, so Advanced collapses like one.
  final bool advancedOpen;
  final VoidCallback onToggleAdvanced;

  const SettingsModelsSimple({
    super.key,
    required this.modelPlacement,
    required this.advanced,
    required this.advancedOpen,
    required this.onToggleAdvanced,
    this.boxUrl = '',
    this.boxKeyStored = false,
    this.processingOn = true,
    this.probe,
    this.storedBearer,
    this.onUseBox,
    this.onUseLocal,
    this.roleLines = const [],
    this.parked,
    this.localServer,
    this.hardwareLine,
    this.embedServerLine,
  });

  /// The one question, and the heading over the segments.
  static const String whereHeading = 'Where the models run';

  /// The Advanced fold's title and its one-line summary. The title is also the
  /// key the screen's open-sections set uses, so the two must stay in step.
  static const String advancedTitle = 'Advanced';
  static const String advancedSummary = 'Per-step picks and extra servers';

  /// The segments, the fold and the local button, keyed for the reason every
  /// control in Settings is: the words on them are ordinary words that also
  /// appear in the captions beside them.
  static const Key placementKey = ValueKey('settings-placement');
  static const Key useLocalKey = ValueKey('settings-use-local');
  static const Key advancedKey = ValueKey('settings-models-advanced');
  static const Key statusKey = ValueKey('settings-models-status');

  /// One role row's **Check**. Three buttons carry the same word, so a test
  /// that tapped by label would tap whichever came first.
  static Key roleCheckKey(String roleId) =>
      ValueKey('settings-role-check-$roleId');

  /// The two segment labels. The recommendation rides a middle dot rather than
  /// a parenthesis: user-facing strings carry neither parentheticals nor
  /// em-dashes.
  static const String boxSegmentLabel = 'GPU server · recommended';
  static const String localSegmentLabel = 'This Mac';

  /// What choosing a segment does, which is nothing until something is
  /// pressed. Said out loud because a segmented control that wrote on touch is
  /// what every other one on this screen does.
  static const String segmentsCaption =
      'Choosing here changes nothing yet. Save, or Use this Mac, is what '
      'moves the work.';

  /// What travels, under the box form. The one sentence a tester needs before
  /// pasting a key.
  static const String boxCaption =
      'Message text and drafts travel to the project’s GPU server over an '
      'encrypted connection. The embedding model stays on this Mac.';

  /// The status line on the GPU server before a key has been pasted.
  static const String keyNeededText =
      'Access key needed. Paste it above and press Save.';

  /// The status line while the processing switch is off, ahead of any park.
  static const String processingOffText =
      'Processing is off. Turn it on under Processing, or in the sidebar, and '
      'the work starts.';

  /// The status line on the GPU server with a key stored and no check run in
  /// this session.
  static const String notCheckedText =
      'Not checked yet. Press Check server.';

  /// The status line after a check that both slots answered.
  static const String bothAnsweredText = 'Checked: both models answered';

  /// The status line on this Mac. The local server's own state sentence is in
  /// the card directly above, so this line does not repeat it.
  static const String localStatusText = 'Models run on this Mac.';

  /// The sentence under the status when the box is not answering. Moved here
  /// from `SettingsModelsBody` verbatim: it is the same fact the inbox rail
  /// reads, from the drains' own progress streams, and nothing polls the box
  /// to produce it.
  static const String boxParkedText =
      'The box is not answering. Work is waiting and will retry each minute.';

  /// The same line when the box ANSWERED and refused the key. A different
  /// sentence because it is a different job: waiting fixes the first and
  /// nothing but a new key fixes this one, and the field that takes one is
  /// standing open directly above it.
  static const String boxUnauthorizedText =
      'The box refused the access key. Change it here.';

  /// And the third park this page can answer for. The embedding model is on
  /// this Mac under EITHER placement, so this sentence names this Mac even on
  /// the GPU server — the same reason `railProgressLine` keeps one wording for
  /// it across both.
  static const String embedUnavailableText =
      'The embedding model on this Mac is not answering. Work is waiting and '
      'will retry each minute.';

  /// The two chat models this build runs on this Mac, in the words a person
  /// recognises, BY TARGET rather than by role: a small Mac runs its six prose
  /// steps on the 4B, and the big model's row has to say so rather than name
  /// the 27B it is not using.
  ///
  /// A const map rather than a read of `assets/models/manifest.json`. The
  /// manifest does carry a `displayName` per file, but `modelManifestProvider`
  /// throws unless a host overrides it and no inbox test overrides it, so
  /// reaching for it from the settings wiring would turn every one of those
  /// tests red for a label. The manifest spells the small one `Qwen3 4B
  /// Instruct`; this page says `Qwen3 4B`, which is the name that fits the
  /// line beside the other two.
  static const Map<String, String> localModelNames = {
    builtInProseId: 'Qwen3.8 27B',
    builtInFastId: 'Qwen3 4B',
  };

  /// The embedding model, which is on this Mac under either placement and is
  /// never routed, so it is one name rather than a lookup.
  static const String embedModelName = 'Qwen3 Embedding 0.6B';

  /// One role's phrase: the model and the machine, or the Custom sentence.
  ///
  /// Here rather than in the host because it is user-facing prose, and prose
  /// that lives in a 5,800-line screen is prose nothing can pin. [overrides]
  /// is how many of the role's other steps resolve somewhere else than its
  /// representative one; any at all and the role has no single answer to give.
  ///
  /// Embeddings never route, so the role answers the same phrase on either
  /// placement: that model is on this Mac whatever the rest of the pipeline
  /// is doing.
  static String roleDetail({
    required StageRole role,
    required LlmTargetSpec? spec,
    int overrides = 0,
  }) {
    if (overrides > 0) return customDetail(overrides);
    if (role == StageRole.embed) return '$embedModelName on this Mac';
    if (spec == null) return 'Not pointed at a server';
    if (spec.isBox) return '${spec.model} on the GPU server';
    if (spec.isBuiltIn) return '${localModelNames[spec.id]} on this Mac';
    // Somebody's own target: the page cannot claim which machine it is, so it
    // says the model and where it dials and leaves the rest to Advanced.
    return '${spec.model} at ${SettingsModelsBody.hostPort(spec.url)}';
  }

  /// A role whose steps disagree. It names the count and points at the one
  /// place that can show which ones.
  static String customDetail(int steps) => steps == 1
      ? 'Custom · 1 step points elsewhere · see Advanced'
      : 'Custom · $steps steps point elsewhere · see Advanced';

  /// The collapsed Models summary: where the work goes, in one line.
  ///
  /// Static so the screen can build it without this widget existing — a
  /// collapsed section renders its summary and nothing else. [server] is the
  /// local server's own one-liner and is appended only on this Mac, because
  /// on the GPU server that process is running the embedding model alone and
  /// the line already says so.
  static String summary({
    required ModelPlacement placement,
    required String boxUrl,
    String? server,
  }) {
    if (placement == ModelPlacement.box) {
      final host = SettingsModelsBody.hostPort(boxUrl);
      return host.isEmpty
          ? 'GPU server · no address yet'
          : 'GPU server · $host · embeddings on this Mac';
    }
    final line = server == null || server.isEmpty ? null : server;
    return line == null ? 'This Mac' : 'This Mac · $line';
  }

  @override
  State<SettingsModelsSimple> createState() => _SettingsModelsSimpleState();
}

class _SettingsModelsSimpleState extends State<SettingsModelsSimple> {
  /// Which segment is showing. Local state so it moves under the finger; the
  /// PLACEMENT is only what the host says it is, and choosing a segment writes
  /// nothing at all.
  late ModelPlacement _segment = widget.modelPlacement;

  /// The address in the field. Owned here while the form is open so a typed
  /// value survives a rebuild of the host; re-seeded when the host hands over
  /// a different one, which is a save or a placement switch rather than an
  /// echo of this frame's keystroke.
  late String _url = widget.boxUrl;

  /// This session's answers from the form's **Check server**. Two of them,
  /// because the box serves both roles from one host and a check that asked
  /// only the writing slot would miss an inbox slot that is down.
  bool _probing = false;
  ModelProbeResult? _proseProbe;
  ModelProbeResult? _bulkProbe;

  /// Which **Check server** press is the current one. An address edit bumps
  /// it and turns the busy flag off, and a check that comes back to a
  /// different number writes nothing: it was about a server nobody is asking
  /// about any more.
  int _checkSeq = 0;

  /// And the same per role row, keyed by [RoleLine.id].
  final Map<String, bool> _roleProbing = {};
  final Map<String, ModelProbeResult> _roleProbe = {};

  @override
  void didUpdateWidget(SettingsModelsSimple old) {
    super.didUpdateWidget(old);
    if (old.modelPlacement != widget.modelPlacement) {
      _segment = widget.modelPlacement;
    }
    if (old.boxUrl != widget.boxUrl && widget.boxUrl != _url) {
      _url = widget.boxUrl;
    }
    // A row that now asks a different server drops the answer it had: a green
    // Checked line from the box would otherwise survive a switch to this Mac
    // and read as a report about the wrong machine.
    final before = {for (final line in old.roleLines) line.id: line.checkUrl};
    for (final line in widget.roleLines) {
      if (before.containsKey(line.id) && before[line.id] != line.checkUrl) {
        _roleProbe.remove(line.id);
      }
    }
  }

  bool get _onBox => widget.modelPlacement == ModelPlacement.box;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          SettingsModelsSimple.whereHeading,
          style: BondType.small.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: BondSpacing.s8),
        SettingsSegments<ModelPlacement>(
          key: SettingsModelsSimple.placementKey,
          segments: const [
            (
              value: ModelPlacement.box,
              label: SettingsModelsSimple.boxSegmentLabel,
            ),
            (
              value: ModelPlacement.local,
              label: SettingsModelsSimple.localSegmentLabel,
            ),
          ],
          selected: _segment,
          onChanged: (value) => setState(() => _segment = value),
          caption: SettingsModelsSimple.segmentsCaption,
        ),
        const SizedBox(height: BondSpacing.s16),
        if (_segment == ModelPlacement.box)
          ..._boxForm()
        else
          ..._thisMac(),
        const SizedBox(height: BondSpacing.s16),
        Text(
          key: SettingsModelsSimple.statusKey,
          _statusLine(),
          style: BondType.small,
        ),
        if (_onBox && widget.embedServerLine != null) ...[
          const SizedBox(height: BondSpacing.s4),
          Text(widget.embedServerLine!, style: BondType.caption),
        ],
        if (widget.roleLines.isNotEmpty) ...[
          const SizedBox(height: BondSpacing.s24),
          for (final line in widget.roleLines) _roleRow(line),
        ],
        const SizedBox(height: BondSpacing.s16),
        SettingsSection(
          key: SettingsModelsSimple.advancedKey,
          title: SettingsModelsSimple.advancedTitle,
          summary: SettingsModelsSimple.advancedSummary,
          expanded: widget.advancedOpen,
          onToggle: widget.onToggleAdvanced,
          body: widget.advanced,
        ),
      ],
    );
  }

  /// The one box form, and it is the wizard's own: the same three keys, the
  /// same field that takes a secret, and no second copy of either.
  List<Widget> _boxForm() {
    if (widget.onUseBox == null) {
      return [Text(SettingsModelsSimple.boxCaption, style: BondType.caption)];
    }
    return [
      SetupWhereBody(
        placement: ModelPlacement.box,
        boxUrl: _url,
        showChoices: false,
        continueLabel: 'Save',
        keyStored: widget.boxKeyStored,
        probing: _probing,
        probeResult: _proseProbe,
        bulkProbeResult: _bulkProbe,
        twoSlots: true,
        onUrlChanged: (value) => setState(() {
          _url = value;
          _checkSeq++;
          _probing = false;
          _proseProbe = null;
          _bulkProbe = null;
        }),
        onCheck: widget.probe == null ? null : (key) => unawaited(_check(key)),
        onContinue: (key) => unawaited(_save(key)),
      ),
      const SizedBox(height: BondSpacing.s8),
      Text(SettingsModelsSimple.boxCaption, style: BondType.caption),
    ];
  }

  /// This Mac: the press that moves the work back here, then the card that
  /// says what is running and the fact about the machine under it.
  ///
  /// The button is above the card deliberately. It is the answer to the
  /// question the segments asked, and the card is the detail underneath it.
  List<Widget> _thisMac() {
    final onUseLocal = widget.onUseLocal;
    return [
      if (onUseLocal != null) ...[
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: SettingsModelsSimple.useLocalKey,
            // Inert rather than absent when the install is already here: a
            // button that vanished once it had been pressed would read as a
            // dead end, and this one is the state as much as the action.
            onPressed: _onBox ? () => unawaited(onUseLocal()) : null,
            child: const Text('Use this Mac'),
          ),
        ),
        const SizedBox(height: BondSpacing.s12),
      ],
      if (widget.localServer case final card?) ...[
        card,
        const SizedBox(height: BondSpacing.s12),
      ],
      if (widget.hardwareLine case final line?)
        Text(line, style: BondType.small.copyWith(fontWeight: FontWeight.w600)),
    ];
  }

  /// One role: what answers for it, and a Check that asks.
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
                    Text(line.detail, style: BondType.caption),
                  ],
                ),
              ),
              if (widget.probe != null && line.checkUrl != null) ...[
                const SizedBox(width: BondSpacing.s12),
                OutlinedButton(
                  key: SettingsModelsSimple.roleCheckKey(line.id),
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
  /// The order is the order the jobs come in. A missing key first, then the
  /// switch being off, and only then a park: a park about a refused key is
  /// answered by pasting one, and a park sentence says work is retrying,
  /// which nothing does while the switch is off. On this Mac the card above
  /// already carries the server's own state sentence, so this line says only
  /// where the work runs rather than saying it twice.
  ///
  /// A refused ADDRESS is not on this line. The form owns that rule and says
  /// so under the field it is about.
  String _statusLine() {
    if (!_onBox) return SettingsModelsSimple.localStatusText;
    if (!widget.boxKeyStored) return SettingsModelsSimple.keyNeededText;
    if (!widget.processingOn) return SettingsModelsSimple.processingOffText;
    final parked = widget.parked;
    if (parked != null && parked.waiting > 0) {
      final sentence = switch (parked.reason) {
        'model_unavailable' => SettingsModelsSimple.boxParkedText,
        'unauthorized' => SettingsModelsSimple.boxUnauthorizedText,
        'embed_unavailable' => SettingsModelsSimple.embedUnavailableText,
        // Every other park word is about something this page cannot answer
        // for — a sign-out — and it must not claim it.
        _ => null,
      };
      if (sentence != null) return sentence;
    }
    final prose = _proseProbe;
    final bulk = _bulkProbe;
    if (prose == null || bulk == null) {
      return SettingsModelsSimple.notCheckedText;
    }
    if (prose.reachable && bulk.reachable) {
      return SettingsModelsSimple.bothAnsweredText;
    }
    final failed = prose.reachable ? bulk : prose;
    return 'Checked: ${failed.error ?? 'Not reachable'}';
  }

  /// **Check server**, on both slots, with the typed key or the stored one.
  ///
  /// The key goes onto two requests' `Authorization` headers and is held
  /// nowhere: not in this State, not in a result, not in a caption. A key just
  /// typed beats the stored one: that is what checking a rotated key before
  /// saving it means.
  Future<void> _check(String typedKey) async {
    final probe = widget.probe;
    if (probe == null) return;
    final base = normalizeBoxBaseUrl(_url);
    if (base.isEmpty) return;
    final typed = typedKey.trim();
    String? bearer(String targetId) => typed.isNotEmpty
        ? typed
        : (widget.boxKeyStored ? widget.storedBearer?.call(targetId) : null);
    final seq = ++_checkSeq;
    setState(() {
      _probing = true;
      _proseProbe = null;
      _bulkProbe = null;
    });
    final prose = await _ask(
      probe,
      '$base/prose/v1/chat/completions',
      bearer(boxProseId),
    );
    final bulk = await _ask(
      probe,
      '$base/bulk/v1/chat/completions',
      bearer(boxBulkId),
    );
    if (!mounted || seq != _checkSeq) return;
    setState(() {
      _probing = false;
      _proseProbe = prose;
      _bulkProbe = bulk;
    });
  }

  /// One request, guarded, for the form's check and the role rows' alike. The
  /// probe promises never to throw, and a diagnostics call must not be able to
  /// crash a settings screen anyway.
  Future<ModelProbeResult> _ask(
    Future<ModelProbeResult> Function(String url, {String? bearer}) probe,
    String url,
    String? bearer,
  ) async {
    try {
      return await probe(
        url,
        bearer: bearer == null || bearer.isEmpty ? null : bearer,
      );
    } on Object {
      return const ModelProbeResult(
        reachable: false,
        error: 'Could not check the server',
      );
    }
  }

  /// One role row's **Check**: the target the role resolves to, with its own
  /// stored token looked up at the press and dropped after it.
  Future<void> _checkRole(RoleLine line) async {
    final probe = widget.probe;
    final url = line.checkUrl;
    if (probe == null || url == null) return;
    setState(() {
      _roleProbing[line.id] = true;
      _roleProbe.remove(line.id);
    });
    final id = line.bearerId;
    final result = await _ask(
      probe,
      url,
      id == null ? null : widget.storedBearer?.call(id),
    );
    if (!mounted) return;
    setState(() {
      _roleProbing[line.id] = false;
      _roleProbe[line.id] = result;
    });
  }

  /// Save: the address, and the key only when one was typed.
  ///
  /// An empty field with a key already stored means "keep it", on the target
  /// editor's precedent — which is the only way a key that has reached the
  /// keychain can be left alone by a form that never reads it back.
  ///
  /// The address rule belongs to the FORM, which refuses a bad one under the
  /// field before this is reached. The check here is belt and braces and
  /// silent: `setBoxServers` throws on the same rule, and the press is
  /// fire-and-forget, so a throw past it would be an unhandled error and, to
  /// the person, a Save that did nothing.
  Future<void> _save(String key) async {
    final use = widget.onUseBox;
    if (use == null) return;
    final base = normalizeBoxBaseUrl(_url);
    if (base.isEmpty) return;
    if (!isBoxOrigin(base)) return;
    final typed = key.trim();
    if (typed.isEmpty && !widget.boxKeyStored) return;
    await use(base, typed.isEmpty ? null : typed);
    if (!mounted) return;
    setState(() {
      _probing = false;
      _proseProbe = null;
      _bulkProbe = null;
    });
  }
}
