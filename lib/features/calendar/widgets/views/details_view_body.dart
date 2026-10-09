import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/adaptive/adaptive_action_sheet.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/launchers/phone_call_launcher.dart';
import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/auth/application/active_user_identity_provider.dart';
import 'package:scheduling/features/auth/application/is_active_admin_provider.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/event_details_controller.dart';
import 'package:scheduling/features/calendar/application/event_series_helpers.dart';
import 'package:scheduling/features/calendar/domain/day_off_reason.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_prefill.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/policies/appointment_form_validator.dart';
import 'package:scheduling/features/calendar/domain/policies/push_back_options.dart';
import 'package:scheduling/features/calendar/widgets/dialogs/busy_conflict_dialog.dart';
import 'package:scheduling/features/calendar/widgets/dialogs/cancel_appointment_dialog.dart';
import 'package:scheduling/features/calendar/widgets/dialogs/series_scope_dialog.dart';
import 'package:scheduling/features/calendar/widgets/views/details_action_bar.dart';
import 'package:scheduling/features/calendar/widgets/views/details_field_notes_view.dart';
import 'package:scheduling/features/calendar/widgets/views/details_field_record_view.dart';
import 'package:scheduling/features/calendar/widgets/views/details_view_leaf_widgets.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/widgets/cards/client_contacts_cards.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';
import 'package:scheduling/features/maps/address_map_launcher.dart';
import 'package:scheduling/features/maps/domain/address_parser.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/cards/key_value_panel.dart';
import 'package:scheduling/shared/widgets/feedback/status_chip.dart';
import 'package:scheduling/shared/widgets/primitives/quick_action_button.dart';

class DetailsViewBody extends ConsumerWidget {
  const DetailsViewBody({
    required this.appointment,
    required this.showActions,
    required this.onClose,
    super.key,
    this.onBookAgain,
    this.tourWrap,
  });

  final AppointmentRecord appointment;
  final bool showActions;
  final VoidCallback onClose;

  /// Hands a "book again" draft to the host, which closes this view and opens
  /// the add sheet with it.
  final ValueChanged<AppointmentPrefill>? onBookAgain;

  /// Tour wraps, null off-tour so the view stays usable untoured. They live
  /// here rather than in a State because this is a ConsumerWidget — the
  /// TourSteps that builds them belongs to EventDetailsView.
  /// Wraps a step's target as that step's showcase when injected — the same
  /// one-parameter shape as `AppointmentFormFields.tourWrap`, so a new step
  /// costs a call rather than a parameter threaded through three widgets.
  final Widget Function(TourStepId, Widget)? tourWrap;

  Widget _tour(TourStepId id, Widget child) =>
      tourWrap?.call(id, child) ?? child;

  Widget _buildClientSection(
    BuildContext context,
    WidgetRef ref,
    _DetailsViewData data,
    EventDetailsController notifier,
  ) {
    final pushBackOptions = pushBackOptionsFor(appointment.startTime);
    final onPushBack =
        offersPushBack(
          appointment,
          showActions: showActions,
          isClosed: data.isClosed,
          hasOptions: pushBackOptions.isNotEmpty,
        )
        ? () => _onPushBack(context, ref, notifier, pushBackOptions)
        : null;
    return _ClientSection(
      isPersonal: appointment.isPersonal,
      clientName: data.clientName,
      phone: data.phone,
      displayAddress: data.displayAddress,
      notes: data.notes,
      onCall: data.phone.isNotEmpty
          ? () => launchPhoneCall(context, ref, data.phone)
          : null,
      onDirections: appointment.address.isNotEmpty
          ? () => AddressMapLauncher.showMapChoices(
              context,
              ref,
              address: appointment.address,
            )
          : null,
      onPushBack: onPushBack,
      tourWrap: tourWrap,
    );
  }

  VoidCallback? _bookAgainCallback(ClientRecord? client) =>
      offersBookAgain(
        appointment,
        showActions: showActions,
        hasHandler: onBookAgain != null,
      )
      ? () => onBookAgain!(
          AppointmentPrefill.bookAgain(
            appointment,
            client: client ?? placeholderClient(appointment),
          ),
        )
      : null;

  List<Widget> _buildHeaderBlock(
    BuildContext context,
    _DetailsViewData data,
    EventDetailsController notifier,
  ) {
    final compactHeader = context.isCompact;
    return [
      // Cancelled visits still show the edit affordance — `showActions` is
      // the only thing that gates it.
      if (showActions && !data.isDone)
        Align(
          alignment: compactHeader
              ? Alignment.centerLeft
              : Alignment.centerRight,
          child: DetailsEditChip(onTap: notifier.enterEditing),
        ),
      DetailsHeader(
        appointment: appointment,
        status: data.displayStatus,
        compact: compactHeader,
      ),
      // The time record outlives the job; a cancelled one has no work to
      // time.
      if (data.hasTimeRecord && !data.isCancelled)
        DetailsTimeRecordRow(
          startedAt: appointment.startedAt,
          completedAt: appointment.completedAt,
        ),
      const SizedBox(height: AppSpacing.sp16),
      const Divider(height: 1),
      const SizedBox(height: AppSpacing.sp16),
    ];
  }

  Widget _buildActionBar(
    BuildContext context,
    WidgetRef ref,
    _DetailsViewData data,
    EventDetailsController notifier, {
    required bool isSaving,
    required bool canRecordFieldWork,
    required ClientRecord? client,
  }) {
    return DetailsActionBar(
      isDone: data.isDone,
      isCancelled: data.isCancelled,
      isInProgress: data.isInProgress,
      isSaving: isSaving,
      showCancel: showActions,
      onEdit: showActions ? notifier.enterEditing : null,
      // Anyone who may close the job may start it; a personal block has no
      // arrival to record.
      onStart: (showActions || canRecordFieldWork) && !appointment.isPersonal
          ? () => _onStart(context, ref, notifier)
          : null,
      onMarkDone: () => _onMarkDone(context, ref, notifier),
      onCancel: () => _onCancel(context, ref, notifier),
      onBookAgain: _bookAgainCallback(client),
      tourWrap: tourWrap,
    );
  }

  List<Widget> _buildSections(
    _DetailsViewData data,
    EventDetailsController notifier, {
    required bool canRecordFieldWork,
  }) {
    return [
      if (data.materials.isNotEmpty) ...[
        const SizedBox(height: AppSpacing.sp16),
        DetailsMaterialsRow(items: data.materials),
      ],
      DetailsEmployeesView(appointment: appointment),
      DetailsPhotosView(
        appointment: appointment,
        isCancelled: data.isCancelled,
        // Only the editor can act on a retry. The crew re-add through the
        // field record's own picker below, and a Retry that merely cleared
        // the failure record destroyed their one trace of the loss.
        onRetry: showActions ? notifier.enterEditing : null,
      ),
      // Anyone who may READ the job may read its crew notes — the same set
      // the rules admit. The compose box below stays crew-only.
      DetailsFieldNotesView(appointment: appointment),
      // Offered to a NON-ADMIN ASSIGNEE only — exactly the set the crew
      // branches of `firestore.rules` admit, so the surface and the rule
      // cannot disagree about who may write.
      if (canRecordFieldWork)
        _tour(
          TourStepId.jobFieldRecord,
          DetailsFieldRecordView(appointment: appointment),
        ),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = eventDetailsControllerProvider(
      EventDetailsKey(appointment),
    );
    final client = ref.watch(provider.select((s) => s.client));
    final isSaving = ref.watch(provider.select((s) => s.isSaving));
    final notifier = ref.read(provider.notifier);

    final data = _DetailsViewData.from(appointment, client);
    // Resolved once: it gates the field record below AND the Start button.
    final canRecordFieldWork = _canRecordFieldWork(ref, appointment);

    // TIME OFF is its own body: it has no client, no address, no materials and
    // no photos, and no lifecycle to act on — so it renders who it is for,
    // which days, and the note, and nothing else.
    if (appointment.isTimeOff) {
      return _DayOffBody(
        appointment: appointment,
        notes: data.notes,
        showActions: showActions,
        onEdit: notifier.enterEditing,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ..._buildHeaderBlock(context, data, notifier),
        _buildClientSection(context, ref, data, notifier),
        ClientContactsCards(contacts: data.extraContacts, collapsible: true),
        ..._buildSections(
          data,
          notifier,
          canRecordFieldWork: canRecordFieldWork,
        ),
        _buildActionBar(
          context,
          ref,
          data,
          notifier,
          isSaving: isSaving,
          canRecordFieldWork: canRecordFieldWork,
          client: client,
        ),
      ],
    );
  }

  /// Whether Push back is offered.
  ///
  /// The admin's, on a job that still has a time to move: an all-day block has
  /// no clock to shift and a closed one nothing to delay.
  @visibleForTesting
  static bool offersPushBack(
    AppointmentRecord appointment, {
    required bool showActions,
    required bool isClosed,
    required bool hasOptions,
  }) => showActions && !isClosed && !appointment.isAllDay && hasOptions;

  /// Whether Book again is offered.
  ///
  /// The admin's, on any client job — a repeat callback most often follows a
  /// FINISHED visit, so a closed job offers it too.
  @visibleForTesting
  static bool offersBookAgain(
    AppointmentRecord appointment, {
    required bool showActions,
    required bool hasHandler,
  }) =>
      hasHandler &&
      showActions &&
      !appointment.isPersonal &&
      appointment.clientId.trim().isNotEmpty;

  /// Whether the viewer is a non-admin assignee of [appointment].
  static bool _canRecordFieldWork(
    WidgetRef ref,
    AppointmentRecord appointment,
  ) {
    if (ref.watch(isActiveAdminProvider)) return false;
    final identity = ref.watch(activeUserIdentityProvider).value;
    if (identity == null) return false;
    return appointment.employeeIds.contains(identity.docId);
  }

  Future<void> _onMarkDone(
    BuildContext context,
    WidgetRef ref,
    EventDetailsController notifier,
  ) async {
    final previousStatus = AppointmentStatus.storedRaw(appointment.status);
    // Everything the Undo needs, resolved BEFORE the sheet closes. The action
    // runs after `onClose()` has dropped the last listener on the autoDispose
    // controller, so touching `notifier`, `ref` or `context` in there is a
    // use-after-dispose — and it runs from a timer callback with no caller
    // left to catch the StateError.
    final l10n = context.l10n;
    final id = appointment.id;
    final notices = ref.read(noticeServiceProvider);
    final repository = ref.read(appointmentsRepositoryProvider);
    final logger = ref.read(loggerProvider);
    // Hoisted with the rest: the Undo runs from a timer callback after this
    // sheet is gone, where `ref.read` throws.
    final analytics = ref.read(analyticsServiceProvider);
    final outcome = await notifier.markAsDone(appointment);
    if (!context.mounted) return;
    switch (outcome) {
      case EventDetailsActionBusy():
        return;
      case EventDetailsActionFailed(:final error):
        ref
            .read(noticeServiceProvider)
            .error(
              composeErrorNotice(
                context,
                intro: context.l10n.error_introUpdateAppointmentStatus,
                error: error,
              ),
            );
      case EventDetailsActionOk():
        analytics.logJobCompleted(hasPhotos: appointment.pictureCount > 0);
        notices.successWithAction(
          l10n.common_appointmentMarkedAsDone,
          actionLabel: l10n.common_undo,
          onAction: () async {
            if (id == null) return;
            try {
              await repository.restoreAppointmentStatus(
                id: id,
                previousStatus: previousStatus,
              );
              analytics.logAppointmentRestored();
              notices.success(l10n.common_changesSaved);
            } catch (e, st) {
              logger.warn('APPT-STATUS undo mark-complete failed', e, st);
              notices.error(
                composeErrorNoticeFor(
                  l10n,
                  intro: l10n.error_introUpdateAppointmentStatus,
                  error: e,
                ),
              );
            }
          },
        );
        onClose();
    }
  }

  Future<void> _onStart(
    BuildContext context,
    WidgetRef ref,
    EventDetailsController notifier,
  ) async {
    final outcome = await notifier.startJob(appointment);
    if (!context.mounted) return;
    _onStatusOutcome(
      context,
      ref,
      outcome,
      successMessage: context.l10n.calendar_jobStarted,
      // Mark-done and cancel close because the job is FINISHED.
      closeOnSuccess: false,
      onSuccess: ref.read(analyticsServiceProvider).logJobStarted,
    );
  }

  /// Push back: pick an offset, shift the job, and — like the edit form — let
  /// the admin push through a clash the shift creates.
  Future<void> _onPushBack(
    BuildContext context,
    WidgetRef ref,
    EventDetailsController notifier,
    List<int> options,
  ) async {
    final l10n = context.l10n;
    // Resolved before the awaits: this sheet can be dismissed mid-flight.
    final notices = ref.read(noticeServiceProvider);
    final minutes = await showAdaptiveActionSheet<int>(
      context,
      title: l10n.calendar_pushBackTitle,
      actions: [
        for (final m in options)
          AdaptiveSheetAction(value: m, label: l10n.calendar_pushBackBy(m)),
      ],
    );
    if (minutes == null || !context.mounted) return;

    final outcome = await retryPastBusyConflict(
      context,
      attempt: ({forceBusy = false}) => notifier.delayAppointment(
        appointment,
        minutes: minutes,
        forceBusy: forceBusy,
      ),
      busyOf: (o) => o is EventDetailsBusyEmployees
          ? (busyEmployees: o.busyEmployees, start: o.start, end: o.end)
          : null,
    );
    // The helper already returned null if unmounted; repeated so the
    // analyzer can still see the guard across the await.
    if (outcome == null || !context.mounted) return;
    switch (outcome) {
      case EventDetailsSaved():
        ref
            .read(analyticsServiceProvider)
            .logAppointmentDelayed(minutes: minutes);
        notices.success(l10n.calendar_pushedBack(minutes));
        onClose();
      case EventDetailsFailed(:final error):
        notices.error(
          composeErrorNotice(
            context,
            intro: l10n.error_introSaveAppointment,
            error: error,
          ),
        );
      // Busy skipped the write; a clash the admin declined stays as it was.
      case EventDetailsSaveBusy() ||
          EventDetailsInvalid() ||
          EventDetailsBusyEmployees():
        break;
    }
  }

  Future<void> _onCancel(
    BuildContext context,
    WidgetRef ref,
    EventDetailsController notifier,
  ) async {
    final choice = await showCancelAppointmentDialog(
      context,
      // One day of a run offers the tail; anything else is a plain confirm.
      isRun: appointment.isRunMember,
    );
    if (choice == null || !context.mounted) return;
    final outcome = await notifier.cancelAppointment(
      appointment,
      includeFuture: choice == SeriesScopeChoice.thisAndFuture,
    );
    if (!context.mounted) return;
    _onStatusOutcome(
      context,
      ref,
      outcome,
      successMessage: context.l10n.common_appointmentCancelled,
      onSuccess: ref.read(analyticsServiceProvider).logAppointmentCancelled,
    );
  }

  /// Surfaces the result of a status write.
  void _onStatusOutcome(
    BuildContext context,
    WidgetRef ref,
    EventDetailsActionOutcome outcome, {
    required String successMessage,
    bool closeOnSuccess = true,
    // Runs on the Ok branch only — never for the reentrancy-guard no-op, which
    // wrote nothing.
    void Function()? onSuccess,
  }) {
    switch (outcome) {
      case EventDetailsActionBusy():
        return;
      case EventDetailsActionFailed(:final error):
        ref
            .read(noticeServiceProvider)
            .error(
              composeErrorNotice(
                context,
                intro: context.l10n.error_introUpdateAppointmentStatus,
                error: error,
              ),
            );
      case EventDetailsActionOk():
        onSuccess?.call();
        ref.read(noticeServiceProvider).success(successMessage);
        if (closeOnSuccess) onClose();
    }
  }
}

/// Pure-data derivations for [DetailsViewBody].
class _DayOffBody extends StatelessWidget {
  const _DayOffBody({
    required this.appointment,
    required this.notes,
    required this.showActions,
    required this.onEdit,
  });

  final AppointmentRecord appointment;
  final String notes;
  final bool showActions;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final names = [
      for (final name in appointment.employeeNames)
        if (name.trim().isNotEmpty) name.trim(),
    ];
    final subject = names.isNotEmpty ? names.join(', ') : appointment.title;
    final reason = dayOffReason(
      title: appointment.title,
      hasSubject: names.isNotEmpty,
      placeholders: personalTitlePlaceholders,
    );
    final days = runLengthDays(appointment.startTime, appointment.endTime);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showActions)
          Align(
            alignment: context.isCompact
                ? Alignment.centerLeft
                : Alignment.centerRight,
            child: DetailsEditChip(onTap: onEdit),
          ),
        _buildHeading(theme, l10n, subject: subject, reason: reason),
        const SizedBox(height: AppSpacing.sp16),
        const Divider(height: 1),
        const SizedBox(height: AppSpacing.sp16),
        _buildPanel(l10n, days),
      ],
    );
  }

  Widget _buildHeading(
    ThemeData theme,
    AppLocalizations l10n, {
    required String subject,
    required String? reason,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sp4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(reason ?? subject, style: theme.textTheme.headlineLarge),
          if (reason != null) ...[
            const SizedBox(height: AppSpacing.sp4),
            Text(
              subject,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.palette.textTertiary,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sp8),
          Text(
            DateUtilsHelper.formatWhenLine(
              appointment.startTime,
              appointment.endTime,
              allDayLabel: l10n.calendar_dayOff,
              lastDay: appointment.endTime,
            ),
            style: theme.monoType.data,
          ),
        ],
      ),
    );
  }

  Widget _buildPanel(AppLocalizations l10n, int days) {
    return KeyValuePanel(
      rows: [
        KeyValueRow(
          label: l10n.calendar_dayOff.toUpperCase(),
          value: l10n.calendar_dayOffLength(days),
        ),
        if (notes.trim().isNotEmpty)
          KeyValueRow(
            label: l10n.calendar_notes.toUpperCase(),
            value: notes.trim(),
          ),
      ],
    );
  }
}

class _DetailsViewData {
  const _DetailsViewData({
    required this.displayStatus,
    required this.isCancelled,
    required this.isDone,
    required this.isInProgress,
    required this.hasTimeRecord,
    required this.clientName,
    required this.phone,
    required this.displayAddress,
    required this.notes,
    required this.materials,
    required this.extraContacts,
  });

  factory _DetailsViewData.from(
    AppointmentRecord appointment,
    ClientRecord? client,
  ) {
    final status = AppointmentStatus.fromRaw(appointment.status);
    // The actions (mark-done/cancel/edit) are gated on the real stored status,
    // while the header chip uses the time-derived one instead, so it matches
    // what the card shows.
    final displayStatus = AppointmentStatus.fromRaw(appointment.displayStatus);
    final phone = (client?.phone.isNotEmpty ?? false)
        ? client!.phone
        : appointment.clientPhone;
    final materials = appointment.materialsNeeded
        .split(',')
        .map((m) => m.trim())
        .where((m) => m.isNotEmpty)
        .toList();
    return _DetailsViewData(
      displayStatus: displayStatus,
      isCancelled: status.isCancelled,
      isDone: status.isDone,
      isInProgress: status == AppointmentStatus.inProgress,
      hasTimeRecord:
          appointment.startedAt != null || appointment.completedAt != null,
      clientName: client?.displayName ?? appointment.clientName,
      phone: phone,
      displayAddress: appointment.address.isNotEmpty
          ? AddressParser.canonicalToDisplay(appointment.address)
          : '',
      notes: appointment.notes,
      materials: materials,
      extraContacts: (client?.contacts ?? const <ClientContact>[]).toList(),
    );
  }

  final AppointmentStatus displayStatus;
  final bool isCancelled;
  final bool isDone;
  final bool isInProgress;
  final bool hasTimeRecord;

  bool get isClosed => isDone || isCancelled;
  final String clientName;
  final String phone;
  final String displayAddress;
  final String notes;
  final List<String> materials;
  final List<ClientContact> extraContacts;
}

/// Quick-actions row plus the client panel (name/phone/address/notes).
class _ClientSection extends StatelessWidget {
  const _ClientSection({
    required this.isPersonal,
    required this.clientName,
    required this.phone,
    required this.displayAddress,
    required this.notes,
    required this.onCall,
    required this.onDirections,
    required this.onPushBack,
    this.tourWrap,
  });

  /// A personal job has no client, so the client row names it as personal
  /// instead of rendering an empty value.
  final bool isPersonal;
  final String clientName;
  final String phone;
  final String displayAddress;
  final String notes;
  final VoidCallback? onCall;
  final VoidCallback? onDirections;

  /// Admin-only, on an open timed job — see the gate in the parent's build.
  final VoidCallback? onPushBack;

  final Widget Function(TourStepId, Widget)? tourWrap;

  Widget _tour(TourStepId id, Widget child) =>
      tourWrap?.call(id, child) ?? child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (onCall != null || onDirections != null || onPushBack != null) ...[
          _buildQuickActions(context),
          const SizedBox(height: AppSpacing.sp24),
        ],
        // The mono key column labels the content, so this panel needs no
        // SectionLabel above it.
        _buildPanel(context),
      ],
    );
  }

  Widget _buildQuickActions(BuildContext context) {
    return QuickActionsRow(
      buttons: [
        if (onCall != null)
          QuickActionButton(
            icon: Icons.phone_outlined,
            label: context.l10n.clients_call,
            onTap: onCall!,
          ),
        if (onDirections != null)
          QuickActionButton(
            icon: Icons.directions_outlined,
            label: context.l10n.clients_directions,
            onTap: onDirections!,
          ),
        if (onPushBack != null)
          _tour(
            TourStepId.jobPushBack,
            QuickActionButton(
              icon: Icons.update_rounded,
              label: context.l10n.calendar_pushBack,
              onTap: onPushBack!,
            ),
          ),
      ],
    );
  }

  Widget _buildPanel(BuildContext context) {
    return KeyValuePanel(
      rows: [
        KeyValueRow(
          label: context.l10n.calendar_client.toUpperCase(),
          value: isPersonal ? context.l10n.calendar_personal : clientName,
        ),
        if (phone.isNotEmpty)
          KeyValueRow(
            label: context.l10n.clients_phone.toUpperCase(),
            value: phone,
            emphasize: true,
            onTap: onCall,
          ),
        if (displayAddress.isNotEmpty)
          KeyValueRow(
            label: context.l10n.common_address.toUpperCase(),
            value: displayAddress,
            emphasize: true,
            onTap: onDirections,
            semanticLabel:
                '$displayAddress, ${context.l10n.maps_openAddressWith}',
          ),
        if (notes.isNotEmpty)
          KeyValueRow(
            label: context.l10n.calendar_notes.toUpperCase(),
            value: notes,
          ),
      ],
    );
  }
}
