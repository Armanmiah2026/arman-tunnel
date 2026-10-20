import 'dart:math' as math;

import 'package:flutter/material.dart';

/// One responsive scale factor for the whole home/dashboard surface.
///
/// The reference is a standard 360x760 logical-dp phone: any device at least
/// that large keeps the exact current design (factor 1.0 — nothing changes on
/// modern phones/tablets). Smaller or low-DPI screens shrink EVERYTHING —
/// connect dial, cards, typography, icons, spacing and the bottom navigation —
/// by the SAME factor, so the layout keeps identical visual proportions and
/// the connect button keeps its relative prominence. No component ever scales
/// independently.
double snapdarkScale(BuildContext context) {
  final s = MediaQuery.sizeOf(context);
  // Width and height both constrain the layout (the home column must fit its
  // cards AND leave the dial its share), so the tighter dimension wins.
  // Scale-up is capped at 1.15: the 1.6 clamp multiplied with the text
  // scaler's 1.25 (35sp effective) blew every button/card up on large
  // screens — the "buttons got big" report. 1.15 keeps a hint of growth on
  // tablets without inflating phones.
  return math.min(s.width / 360, s.height / 760).clamp(0.75, 1.15);
}
