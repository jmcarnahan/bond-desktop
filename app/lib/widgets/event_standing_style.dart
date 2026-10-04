import 'package:flutter/material.dart';

import '../services/calendar/event_standing.dart';
import '../theme/tokens.dart';

/// The ONE standing → colour mapping for every calendar face: the agenda
/// row, the grid tile, the panel line and the Today row all colour a meeting
/// here, so "maybe" is the same copper everywhere. Lives with the widgets
/// because `theme/` never imports `services/`.

/// The standing's tone: the owner's meetings (organised, accepted, or asked
/// for no answer) in primary, a Maybe in attention, the rest neutral.
BondTone toneOfStanding(EventStanding s) => switch (s) {
      EventStanding.organizer ||
      EventStanding.accepted ||
      EventStanding.noAnswerNeeded =>
        BondTone.primary,
      EventStanding.tentative => BondTone.attention,
      EventStanding.unanswered ||
      EventStanding.declined ||
      EventStanding.cancelled =>
        BondTone.neutral,
    };

/// A face's 3-px standing bar colour: the tone's foreground, except an
/// unanswered meeting's, which stays muted — the answer buttons under its
/// row do the talking — and a cancelled one's.
Color standingBarColor(EventStanding s) => switch (s) {
      EventStanding.unanswered || EventStanding.cancelled => BondColors.inkMuted,
      _ => bondToneColors[toneOfStanding(s)]!.foreground,
    };

/// A tile's fill: primary at the grid's long-standing 18 % for the owner's
/// meetings, the attention tint (a touch lighter) for a Maybe, and a faint
/// wash for the rest — an unanswered tile's thin border carries it.
Color standingFillColor(EventStanding s) => switch (toneOfStanding(s)) {
      BondTone.primary => BondColors.primary.withValues(alpha: 0.18),
      BondTone.attention => BondColors.attention.withValues(alpha: 0.14),
      _ => BondColors.primary.withValues(alpha: 0.05),
    };
