import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/auth/application/active_user_identity_provider.dart';
import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/features/employees/application/employee_schedule_providers.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/models/emergency_contact.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/policies/work_schedule_policy.dart';
import 'package:scheduling/features/navigation/widgets/app_nav_drawer.dart';
import 'package:scheduling/features/settings/application/my_details_providers.dart';
import 'package:scheduling/features/settings/services/self_email_service.dart';
import 'package:scheduling/features/settings/widgets/dialogs/change_email_dialog.dart';
import 'package:scheduling/features/settings/widgets/sections/my_availability_section.dart';
import 'package:scheduling/features/settings/widgets/sections/my_identity_section.dart';
import 'package:scheduling/features/settings/widgets/sections/my_scheduling_section.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/app_bars/app_header_pair.dart';
import 'package:scheduling/shared/widgets/app_bars/app_top_bar.dart';
import 'package:scheduling/shared/widgets/feedback/centered_error_text.dart';
import 'package:scheduling/shared/widgets/feedback/offline_form_notice.dart';

/// The one surface where a person edits their OWN record.
class MyDetailsScreen extends ConsumerStatefulWidget {
  const MyDetailsScreen({super.key});

  @override
  ConsumerState<MyDetailsScreen> createState() => _MyDetailsScreenState();
}

class _MyDetailsScreenState extends ConsumerState<MyDetailsScreen> {
  bool _seeded = false;
  bool _isSaving = false;
  bool _isEmailSheetOpen = false;
  int _availabilityMutationId = 0;

  List<bool> _workingDays = kDefaultWorkingDays;
  int _workStartMinutes = kDefaultWorkStartMinutes;
  int _workEndMinutes = kDefaultWorkEndMinutes;
  bool _onCall = false;

  /// The phone as STORED, not as typed.
  String _storedPhone = '';
  String _storedEmergencyContact = '';
  String _storedEmergencyPhone = '';

  /// Seeds once, from the first record that arrives — a later snapshot must not
  /// overwrite what the person is part-way through changing.
  void _seed(EmployeeRecord record) {
    if (_seeded) return;
    _seeded = true;
    _workingDays = normalizeWorkingDays(record.workingDays);
    _workStartMinutes = record.workStartMinutes;
    _workEndMinutes = record.workEndMinutes;
    _onCall = record.onCall;
    _storedPhone = record.phone;
  }

  void _seedEmergencyContact(EmergencyContact contact) {
    if (_storedEmergencyContact.isNotEmpty ||
        _storedEmergencyPhone.isNotEmpty) {
      return;
    }
    _storedEmergencyContact = contact.contact;
    _storedEmergencyPhone = contact.phone;
  }

  /// Identity save — the emergency contact (subcollection) AND the phone (users
  /// doc).
  Future<void> _saveIdentity(
    EmployeeRecord record,
    MyIdentityEdit edit,
  ) async {
    // Set synchronously before the first await, or a double-tap starts a second
    // concurrent write.
    if (_isSaving) return;
    FocusScope.of(context).unfocus();

    final l10n = context.l10n;
    final notices = ref.read(noticeServiceProvider);
    // Resolved before the first await: the catch below logs above its `mounted`
    // guard so the warn survives unmount, and `ref.read` on an unmounted
    // consumer throws under Riverpod 3.
    final logger = ref.read(loggerProvider);

    // An awaited Firestore write offline only resolves on server ack, so
    // without this Save would spin until the connection returns.
    if (guardedOffline(context, ref, intro: l10n.error_introSaveMyDetails)) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      final repository = ref.read(employeesRepositoryProvider);
      await repository.saveEmergencyContact(
        record.id,
        EmergencyContact(
          contact: edit.emergencyContact,
          phone: edit.emergencyPhone,
        ),
      );
      // Only the fields this form owns are named; everything else on the
      // allowlist rides along on the record, so Settings' travel-alerts toggle
      // can't be clobbered by an omission here.
      await repository.updateSelfDetails(
        record.copyWith(
          phone: edit.phone,
          workingDays: _workingDays,
          workStartMinutes: _workStartMinutes,
          workEndMinutes: _workEndMinutes,
          onCall: _onCall,
        ),
      );
      if (!mounted) return;
      setState(() {
        _storedPhone = edit.phone;
        _storedEmergencyContact = edit.emergencyContact;
        _storedEmergencyPhone = edit.emergencyPhone;
      });
      notices.success(l10n.common_changesSaved);
    } catch (error, stackTrace) {
      logger.warn('ME-SAVE identity save failed', error, stackTrace);
      if (!mounted) return;
      notices.error(
        composeErrorNotice(
          context,
          intro: l10n.error_introSaveMyDetails,
          error: error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Availability applies immediately (P5 spec).
  Future<void> _applyAvailability(
    EmployeeRecord record,
    List<bool> days,
    int start,
    int end, {
    required bool onCall,
  }) async {
    final l10n = context.l10n;
    final notices = ref.read(noticeServiceProvider);
    final logger = ref.read(loggerProvider);

    final previousDays = _workingDays;
    final previousStart = _workStartMinutes;
    final previousEnd = _workEndMinutes;
    final previousOnCall = _onCall;
    final mutationId = ++_availabilityMutationId;

    void rollBack() {
      if (!mounted || mutationId != _availabilityMutationId) return;
      setState(() {
        _workingDays = previousDays;
        _workStartMinutes = previousStart;
        _workEndMinutes = previousEnd;
        _onCall = previousOnCall;
      });
    }

    setState(() {
      _workingDays = days;
      _workStartMinutes = start;
      _workEndMinutes = end;
      _onCall = onCall;
    });

    if (guardedOffline(context, ref, intro: l10n.error_introSaveAvailability)) {
      rollBack();
      return;
    }

    try {
      await ref
          .read(employeesRepositoryProvider)
          .updateSelfDetails(
            // `phone` is named EXPLICITLY from the stored value, never left to
            // ride along on `record`: this fires on a switch tap while the
            // identity form may hold a half-typed number, and a just-saved
            // phone can still be newer than the record snapshot in flight.
            record.copyWith(
              phone: _storedPhone,
              workingDays: days,
              workStartMinutes: start,
              workEndMinutes: end,
              onCall: onCall,
            ),
          );
    } catch (error, stackTrace) {
      logger.warn('ME-SAVE availability failed', error, stackTrace);
      rollBack();
      if (!mounted || mutationId != _availabilityMutationId) return;
      notices.error(
        composeErrorNotice(
          context,
          intro: l10n.error_introSaveAvailability,
          error: error,
        ),
      );
    }
  }

  /// Collects the new address + a re-auth password, then moves BOTH stores
  /// through the callable.
  Future<void> _changeEmail(String docId, String currentEmail) async {
    if (_isSaving || _isEmailSheetOpen) return;
    // Own guard, set before the sheet opens: the barrier isn't up on the tap frame, so a double-tap stacks sheets.
    _isEmailSheetOpen = true;
    final ChangeEmailDraft? draft;
    try {
      draft = await showChangeEmailSheet(
        context,
        currentEmail: currentEmail,
      );
    } finally {
      _isEmailSheetOpen = false;
    }
    if (draft == null || !mounted) return;

    final l10n = context.l10n;
    final notices = ref.read(noticeServiceProvider);
    final logger = ref.read(loggerProvider);

    if (guardedOffline(context, ref, intro: l10n.error_introChangeEmail)) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      await ref
          .read(selfEmailServiceProvider)
          .changeOwnEmail(
            docId: docId,
            email: draft.email,
            password: draft.password,
          );
      if (!mounted) return;
      notices.success(l10n.common_changesSaved);
    } on AuthFailure catch (failure, stackTrace) {
      // Typed branch first: a wrong password here is an expected outcome, and
      // authFailure buckets it as a breadcrumb rather than an error record.
      logger.authFailure(
        'ME-EMAIL change failed',
        failure,
        failure,
        stackTrace,
      );
      if (!mounted) return;
      // `changeOwnEmail` re-authenticates before it calls, so every
      // context-sensitive AuthFailure reaching here is from that step — the
      // address in "no account found with this email" would be the CURRENT one,
      // not the new one the sheet just took.
      notices.error(
        failure.toLocalizedMessageInContext(
          context,
          AuthErrorContext.reauthentication,
        ),
      );
    } catch (error, stackTrace) {
      logger.warn('ME-EMAIL change failed', error, stackTrace);
      if (!mounted) return;
      notices.error(
        composeErrorNotice(
          context,
          intro: l10n.error_introChangeEmail,
          error: error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// `maxJobsPerDay` is admin-owned, so this goes through the ordinary
  /// whole-record admin save rather than `updateSelfDetails` — the self
  /// allowlist does not name it, and `hasOnly` would reject the write.
  Future<void> _saveMaxJobs(
    String docId,
    EmployeeRecord record,
    int value,
  ) async {
    if (_isSaving) return;
    final l10n = context.l10n;
    final notices = ref.read(noticeServiceProvider);
    final logger = ref.read(loggerProvider);

    if (guardedOffline(context, ref, intro: l10n.error_introSaveMyDetails)) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      await ref
          .read(employeesRepositoryProvider)
          .updateEmployee(
            docId: docId,
            employee: record.copyWith(maxJobsPerDay: value),
          );
      if (!mounted) return;
      notices.success(l10n.common_changesSaved);
    } catch (error, stackTrace) {
      logger.warn('ME-SAVE max jobs failed', error, stackTrace);
      if (!mounted) return;
      notices.error(
        composeErrorNotice(
          context,
          intro: l10n.error_introSaveMyDetails,
          error: error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Switch on the AsyncValue, never on `.value`: this provider awaits a
    // findUserByUid wrapped in retryAsync (500ms + 1500ms), so `.value` is null
    // for up to ~2s on a cold read.
    final identity = ref.watch(activeUserIdentityProvider);

    return Scaffold(
      appBar: AppTopBar(
        title: l10n.settings_myDetails,
        compact: context.isLandscape,
        onBack: () => Navigator.maybePop(context),
        actions: const [AppHeaderPair()],
      ),
      endDrawer: AppNavDrawer(
        isAdmin: identity.value?.role == 'admin',
        employeeId: identity.value?.docId ?? '',
      ),
      body: _body(identity),
    );
  }

  /// ONE loading gate over the three reads (identity, own record, emergency
  /// pair), so a cold open shows a single late spinner, never three in a row.
  Widget _body(AsyncValue<ActiveUserIdentity?> identity) {
    final l10n = context.l10n;
    final docId = identity.value?.docId;
    final record = ref.watch(myEmployeeRecordProvider);
    final roster = ref.watch(allUsersStreamProvider);
    final emergency = docId == null
        ? null
        : ref.watch(emergencyContactProvider(docId));

    // All three must land before the form is safe to show: the identity
    // section seeds its controllers ONCE, and a blank-by-default field over a
    // stored value invites the person to save the blank back.
    final loading =
        identity.isLoading ||
        (docId != null && record == null && roster.isLoading) ||
        (emergency?.isLoading ?? false);
    if (loading) return const _LateSpinner();

    // A settled null identity — signed out or inactive — is a real error.
    if (identity.hasError || docId == null) {
      return _retry(l10n, () => ref.invalidate(activeUserIdentityProvider));
    }
    if (record == null) {
      return _retry(l10n, () => ref.invalidate(allUsersStreamProvider));
    }
    // A failed emergency read is "we couldn't load it", never "you have none on
    // file" — the same distinction the edit-person sheet draws.
    if (emergency == null || emergency.hasError) {
      return _retry(
        l10n,
        () => ref.invalidate(emergencyContactProvider(docId)),
      );
    }

    _seed(record);
    _seedEmergencyContact(emergency.requireValue);
    final isAdmin = identity.value?.role == 'admin';

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.sp16),
      children: [
        const OfflineFormNotice(),
        MyIdentitySection(
          email: record.email,
          initialPhone: _storedPhone,
          initialEmergencyContact: _storedEmergencyContact,
          initialEmergencyPhone: _storedEmergencyPhone,
          isSaving: _isSaving,
          onSave: (edit) => _saveIdentity(record, edit),
          onChangeEmail: () => _changeEmail(docId, record.email),
        ),
        const SizedBox(height: AppSpacing.sp24),
        Text(
          l10n.settings_myDetailsEmergencyBlurb,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.sp24),
        MyAvailabilitySection(
          workingDays: _workingDays,
          workStartMinutes: _workStartMinutes,
          workEndMinutes: _workEndMinutes,
          onCall: _onCall,
          enabled: !_isSaving,
          conflictDays: ref.watch(
            myAvailabilityConflictProvider(
              AvailabilityChange(
                previousWorkingDays: normalizeWorkingDays(record.workingDays),
                nextWorkingDays: _workingDays,
              ),
            ),
          ),
          onChanged: (days, start, end, {required onCall}) =>
              _applyAvailability(record, days, start, end, onCall: onCall),
        ),
        const SizedBox(height: AppSpacing.sp24),
        MySchedulingSection(
          isAdmin: isAdmin,
          maxJobsPerDay: record.maxJobsPerDay,
          enabled: !_isSaving,
          onChanged: (value) => _saveMaxJobs(docId, record, value),
        ),
        const SizedBox(height: AppSpacing.sp32),
      ],
    );
  }

  Widget _retry(AppLocalizations l10n, VoidCallback onRetry) => Center(
    child: CenteredErrorText(
      message: l10n.error_somethingWentWrong,
      onRetry: onRetry,
    ),
  );
}

/// A spinner that waits [_delay] first — the usual cold read lands sooner, so
/// most opens never flash one.
class _LateSpinner extends StatefulWidget {
  const _LateSpinner();

  static const _delay = Duration(milliseconds: 300);

  @override
  State<_LateSpinner> createState() => _LateSpinnerState();
}

class _LateSpinnerState extends State<_LateSpinner> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(_LateSpinner._delay).then((_) {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  Widget build(BuildContext context) => _visible
      ? const Center(child: AdaptiveProgressIndicator(size: 32))
      : const SizedBox.expand();
}
