import 'package:flutter/material.dart';
import 'package:scheduling/l10n/l10n.dart';

/// One photo's accessible position, state and enabled viewer action.
/// Removal controls stay outside this node so they remain independently usable.
class AppointmentPhotoSemantics extends StatelessWidget {
  const AppointmentPhotoSemantics({
    required this.index,
    required this.count,
    required this.child,
    super.key,
    this.onTap,
    this.loading = false,
    this.unavailable = false,
  });

  /// One-based position in the displayed gallery, including unresolved photos.
  final int index;
  final int count;
  final Widget child;
  final VoidCallback? onTap;
  final bool loading;
  final bool unavailable;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Semantics(
      container: true,
      image: true,
      button: onTap != null,
      label: l.calendar_photoPosition(index, count),
      value: loading
          ? l.calendar_photoLoading
          : unavailable
          ? l.calendar_photoUnavailable
          : null,
      hint: onTap == null ? null : l.calendar_openPhoto,
      onTap: onTap,
      excludeSemantics: true,
      child: child,
    );
  }
}
