import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/auth/application/active_user_identity_provider.dart';
import 'package:scheduling/features/calendar/application/appointment_form_concerns.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/event_details_controller.dart';
import 'package:scheduling/features/calendar/application/field_notes_provider.dart';
import 'package:scheduling/features/calendar/application/photo_upload_notifier.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/features/calendar/data/appointment_images_store.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/widgets/sheets/image_source_picker.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/labeled_text_field.dart';
import 'package:scheduling/shared/widgets/primitives/mono_section_label.dart';

/// What the CREW can record about a job they are on.
class DetailsFieldRecordView extends ConsumerStatefulWidget {
  const DetailsFieldRecordView({required this.appointment, super.key});

  final AppointmentRecord appointment;

  @override
  ConsumerState<DetailsFieldRecordView> createState() =>
      _DetailsFieldRecordViewState();
}

class _DetailsFieldRecordViewState
    extends ConsumerState<DetailsFieldRecordView> {
  final TextEditingController _notes = TextEditingController();

  bool _isSaving = false;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _post() async {
    final id = widget.appointment.id;
    if (id == null || _isSaving) return;
    // Set BEFORE the first await, like every other submit in this codebase:
    // awaiting first leaves the button live and a double tap posts twice.
    setState(() => _isSaving = true);

    // Resolved up front — `ref.read` on an unmounted consumer throws under
    // Riverpod 3, and this sheet can be dismissed mid-write.
    final logger = ref.read(loggerProvider);
    final notices = ref.read(noticeServiceProvider);
    final repository = ref.read(appointmentsRepositoryProvider);
    final analytics = ref.read(analyticsServiceProvider);
    final identity = ref.read(activeUserIdentityProvider).value;
    final authorName = ref.read(currentUserNameProvider);
    final text = _notes.text.trim();

    // Disabled while empty, so this is the double-tap race, not a failure.
    if (text.isEmpty) {
      setState(() => _isSaving = false);
      return;
    }

    if (identity == null) {
      final missing = StateError('no active user identity');
      logger.warn('APPT-FIELDNOTE no identity for note author', missing);
      setState(() => _isSaving = false);
      notices.error(
        composeErrorNotice(
          context,
          intro: context.l10n.error_introSaveFieldNotes,
          error: missing,
        ),
      );
      return;
    }

    if (guardedOffline(
      context,
      ref,
      intro: context.l10n.error_introSaveFieldNotes,
    )) {
      setState(() => _isSaving = false);
      return;
    }

    try {
      await repository.appendFieldNote(
        appointmentId: id,
        text: text,
        // The rules pin this to the caller's own doc id, so a note can never
        // be filed under a colleague's name.
        authorId: identity.docId,
        authorName: authorName,
      );
      if (!mounted) return;
      _notes.clear();
      setState(() => _isSaving = false);
      ref.invalidate(appointmentFieldNotesProvider(id));
      // The note's TEXT is never sent — only that the crew wrote one.
      analytics.logNoteAdded(surface: AnalyticsSurfaces.fieldRecord);
      notices.success(context.l10n.calendar_notePosted);
    } catch (e, st) {
      logger.warn('APPT-FIELDNOTE appendFieldNote failed', e, st);
      if (!mounted) return;
      setState(() => _isSaving = false);
      notices.error(
        composeErrorNotice(
          context,
          intro: context.l10n.error_introSaveFieldNotes,
          error: e,
        ),
      );
    }
  }

  Future<void> _addPhotos() async {
    final id = widget.appointment.id;
    if (id == null) return;

    // Deliberately NOT offline-guarded: photos go through the persistent upload
    // queue and drain on reconnect, which is the one asymmetry this codebase
    // draws between entity writes and photos.
    final logger = ref.read(loggerProvider);
    final notices = ref.read(noticeServiceProvider);
    final l10n = context.l10n;
    final uploader = ref.read(appointmentImageUploadProvider);
    final analytics = ref.read(analyticsServiceProvider);
    try {
      final files = await pickAppointmentImages(context, ref);
      if (files.isEmpty) return;
      // The pick is the longest await in the app, so the sheet can be gone by
      // the time it returns — and the cap below MUST read live state, so it
      // cannot be hoisted the way the services above were. Under Riverpod 3
      // `ref.read` on an unmounted consumer throws, which this method's own
      // `catch` would file as "photo pick failed" while the crew's photos went
      // unqueued.
      if (!mounted) return;
      // Measured AFTER the pick — that await is the longest in the app, and a
      // background upload landing inside it would otherwise go uncounted and
      // let the job overshoot.
      final allowed = _roomForPhotos(id);
      final accepted = files.take(allowed).toList();
      if (accepted.length < files.length) {
        notices.info(
          allowed == 0
              ? l10n.calendar_photosLimitFull
              : l10n.calendar_photosLimitReached(allowed),
        );
      }
      if (accepted.isEmpty) return;
      // Queued FIRST: nothing after this line may be what stops the crew's
      // photos reaching the job.
      uploader.uploadInBackground(appointmentId: id, newImages: accepted);
      // Counted at ACCEPT, not at upload: the queue drains on reconnect, so a
      // send-time event would report the crew's offline photos as never taken.
      analytics.logPhotoAdded(
        surface: AnalyticsSurfaces.fieldRecord,
        count: accepted.length,
      );
    } catch (e, st) {
      logger.warn('APPT-FIELDNOTE photo pick failed', e, st);
    }
  }

  /// How many more photos this job will take.
  ///
  /// Two bounds, both real: one pick may not exceed what the admin form allows,
  /// and a job may not accumulate more than one subcollection read returns —
  /// past that the sheet caps while the Storage bytes keep growing.
  int _roomForPhotos(String id) {
    final photos = ref.read(photoUploadNotifierProvider);
    final state = ref.read(
      eventDetailsControllerProvider(EventDetailsKey(widget.appointment)),
    );
    final onJob = state.existingImages.length + photos.pendingFor(id);
    final room = (AppointmentImagesStore.scanLimit - onJob).clamp(
      0,
      AppointmentImagesStore.scanLimit,
    );
    return room < AppointmentFormConcerns.maxImagesPerAppointment
        ? room
        : AppointmentFormConcerns.maxImagesPerAppointment;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final canPost = _notes.text.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.sp16),
        MonoSectionLabel(l10n.calendar_fieldRecordLabel),
        const SizedBox(height: AppSpacing.sp8),
        LabeledTextField(
          controller: _notes,
          label: l10n.calendar_fieldNotesLabel,
          hint: l10n.calendar_fieldNotesHint,
          maxLines: 4,
          maxLength: TextLimits.appointmentNotes,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: AppSpacing.sp8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _addPhotos,
                icon: const Icon(Icons.add_a_photo_outlined),
                label: Text(l10n.calendar_addPhotos),
              ),
            ),
            const SizedBox(width: AppSpacing.sp8),
            Expanded(
              child: FilledButton(
                // Disabled while empty, so the row cannot spend a write on
                // nothing — this is the one surface a technician taps with
                // gloves on, glancing away.
                onPressed: canPost && !_isSaving ? _post : null,
                child: Text(
                  _isSaving ? l10n.common_saving : l10n.calendar_addANote,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
