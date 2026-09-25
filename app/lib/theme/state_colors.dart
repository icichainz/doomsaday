import 'package:flutter/material.dart';

import '../data/models.dart';
import '../widgets/primitives.dart';
import 'tokens.dart';

/// Green for running, amber for restarting, coral for stopped — the same three
/// colours the design uses for dots, pills and segment bars.
Color containerStateColor(AppTokens t, ContainerState state) => switch (state) {
  ContainerState.running => t.accent,
  ContainerState.restarting || ContainerState.paused => t.warning,
  ContainerState.created => t.mutedText,
  ContainerState.exited || ContainerState.dead => t.danger,
};

/// One segment of a stack's or a service's health bar.
///
/// Up is mint, restarting or converging is warning amber, and only something
/// that is actually down is danger coral — a stack with one service flapping
/// is not the same picture as a stack that has stopped.
Color segmentColor(AppTokens t, ContainerState state) =>
    containerStateColor(t, state);

PillTone containerStateTone(ContainerState state) => switch (state) {
  ContainerState.running => PillTone.accent,
  ContainerState.restarting || ContainerState.paused => PillTone.warning,
  ContainerState.created => PillTone.neutral,
  ContainerState.exited || ContainerState.dead => PillTone.danger,
};
