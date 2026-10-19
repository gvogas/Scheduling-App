import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/photo_upload_notifier.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/features/calendar/utils/sheet_helpers.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/error_snack_bar.dart';

/// Surfaces a background photo-upload failure, wherever the user happens to be.
///
/// Photos upload AFTER the appointment save returns, so the sheet that started
/// the upload is long gone by the time one fails — which is why this is not the
/// edit sheet's job, and why it lived on the calendar screen. It is not a
/// calendar concern either: it belongs to the session, so it sits here beside
/// `AppSyncListeners` and wraps whichever screen hosts it.
///
/// **This is one of the three sanctioned `SnackBar` sites** (see
/// `.claude/rules/frontend.md`), not a notice: the message carries an action
/// that reopens the appointment, and the notice surface has no action slot.
/// It builds that bar through `errorSnackBar` rather than hand-rolling the
/// `errorContainer` row.
class PhotoUploadFailureListener extends ConsumerStatefulWidget {
  const PhotoUploadFailureListener({
    required this.child,
    super.key,
    this.showActions = false,
  });

  final Widget child;

  /// The host's resolved role, passed to `showEventDetails` when the Open
  /// action reopens the job. Defaults CLOSED, like every appointment surface.
  final bool showActions;

  @override
  ConsumerState<PhotoUploadFailureListener> createState() =>
      _PhotoUploadFailureListenerState();
}

class _PhotoUploadFailureListenerState
    extends ConsumerState<PhotoUploadFailureListener> {
  late final PhotoUploadNotifier _notifier;
  final _shownExpiryIds = <String>{};

  @override
  void initState() {
    super.initState();
    _notifier = ref.read(photoUploadNotifierProvider)
      ..latestFailure.addListener(_onFailure)
      ..expired.addListener(_onExpiry);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onExpiry());
  }

  @override
  void dispose() {
    _notifier.latestFailure.removeListener(_onFailure);
    _notifier.expired.removeListener(_onExpiry);
    super.dispose();
  }

  void _onExpiry() {
    if (!mounted) return;
    final unseen = _notifier.expired.value
        .where((entry) => !_shownExpiryIds.contains(entry.id))
        .toList();
    if (unseen.isEmpty) return;
    final ids = unseen.map((entry) => entry.id).toSet();
    _shownExpiryIds.addAll(ids);
    final count = unseen.fold<int>(0, (sum, entry) => sum + entry.count);
    ref
        .read(noticeServiceProvider)
        .info(context.l10n.calendar_photoUploadsExpired(count));
    final uploader = ref.read(appointmentImageUploadProvider);
    final logger = ref.read(loggerProvider);
    unawaited(
      uploader.acknowledgeExpiry(ids).catchError((
        Object error,
        StackTrace stack,
      ) {
        logger.warn('IMG-UPLOAD expiry acknowledgment failed', error, stack);
      }),
    );
  }

  void _onFailure() {
    final failure = _notifier.latestFailure.value;
    if (failure == null || !mounted) return;
    final appointmentId = failure.appointmentId;
    final scheme = Theme.of(context).colorScheme;
    // Everything the Open action needs is resolved HERE, not inside it. The
    // bar is hosted by ScaffoldMessenger and can outlive this State, so a
    // `ref.read` in the callback throws once the host is gone.
    final repository = ref.read(appointmentsRepositoryProvider);
    final logger = ref.read(loggerProvider);
    final notices = ref.read(noticeServiceProvider);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      errorSnackBar(
        context,
        context.l10n.calendar_photoUploadFailedSnackbar,
        action: SnackBarAction(
          label: context.l10n.calendar_open,
          textColor: scheme.onErrorContainer,
          onPressed: () async {
            // Guarded: `getAppointmentById` rethrows, and this is an unawaited
            // async callback — offline or a rules rejection would otherwise
            // escape to the zone handler as a FATAL, with no feedback at all.
            try {
              final appointment = await repository.getAppointmentById(
                appointmentId,
              );
              if (!mounted || appointment == null) return;
              await showEventDetails(
                context,
                appointment,
                showActions: widget.showActions,
                analyticsSource: AnalyticsSources.notice,
              );
            } catch (error, stackTrace) {
              logger.warn('APPT-OPEN photo failure reopen', error, stackTrace);
              if (!mounted) return;
              notices.error(
                composeErrorNotice(
                  context,
                  intro: context.l10n.error_introOpenAppointment,
                  error: error,
                ),
              );
            }
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
