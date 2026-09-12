import 'package:flutter/material.dart';

/// Width [text] would paint at, at the ambient text scale.
///
/// For a header that carries a long label and a short one and has to pick
/// between them — the calendar's month row and the agenda's day title. Both
/// measure before they lay out, so neither can fall back to an ellipsis.
double measureTextWidth(BuildContext context, String text, TextStyle? style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}
