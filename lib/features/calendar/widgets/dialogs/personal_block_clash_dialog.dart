import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/assignee_resolver.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/utils/sheet_helpers.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/dialogs/app_dialog_frame.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';

/// Offers crew swaps on the client jobs a just-saved personal block hit.
Future<void> showPersonalBlockClashesIfAny(
  BuildContext context,
  WidgetRef ref, {
  required AppointmentRecord block,
}) async {
  if (!block.isPersonal || block.employeeIds.isEmpty) return;

  // Resolved before the await: Riverpod 3 throws on `ref` once unmounted.
  final repository = ref.read(appointmentsRepositoryProvider);
  final logger = ref.read(loggerProvider);

  final List<AppointmentRecord> clashes;
  try {
    clashes = await repository.findClashingAppointments(
      employeeIds: block.employeeIds,
      start: block.startTime,
      end: block.endTime,
      excludeAppointmentId: block.id,
      clientJobsOnly: true,
    );
  } on Object catch (e, st) {
    logger.warn('APPT-BUSY personal-block clash lookup failed', e, st);
    return;
  }
  if (clashes.isEmpty || !context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (_) => _PersonalBlockClashDialog(block: block, clashes: clashes),
  );
}

/// One person on the block, and the client jobs their time off ran into.
class _ClashGroup {
  const _ClashGroup({
    required this.employeeId,
    required this.name,
    required this.jobs,
  });

  final String employeeId;
  final String name;
  final List<AppointmentRecord> jobs;
}

/// What a row is showing; sealed so every builder branch must handle it.
sealed class _RowState {
  const _RowState();
}

class _RowIdle extends _RowState {
  const _RowIdle();
}

class _RowBusy extends _RowState {
  const _RowBusy();
}

class _RowOpen extends _RowState {
  const _RowOpen(this.free);
  final List<EmployeeRecord> free;
}

class _RowStuck extends _RowState {
  const _RowStuck();
}

class _RowDone extends _RowState {
  const _RowDone({required this.took});

  /// Who took the job; Undo inverts the swap off this, never a snapshot.
  final EmployeeRecord took;
}

class _PersonalBlockClashDialog extends ConsumerStatefulWidget {
  const _PersonalBlockClashDialog({required this.block, required this.clashes});

  final AppointmentRecord block;
  final List<AppointmentRecord> clashes;

  @override
  ConsumerState<_PersonalBlockClashDialog> createState() =>
      _PersonalBlockClashDialogState();
}

class _PersonalBlockClashDialogState
    extends ConsumerState<_PersonalBlockClashDialog> {
  final Map<String, _RowState> _states = {};

  /// The live record for each clashing job, keyed by DOC ID — never per row.
  final Map<String, AppointmentRecord> _jobs = {};

  /// The one open row; opening another closes it.
  String? _openKey;

  static String _keyFor(String employeeId, AppointmentRecord job) =>
      '$employeeId|${job.id}';

  /// The job as it stands now, after any swap already written from this dialog.
  AppointmentRecord _live(AppointmentRecord job) => _jobs[job.id] ?? job;

  List<_ClashGroup> _groups() {
    final groups = <_ClashGroup>[];
    for (var i = 0; i < widget.block.employeeIds.length; i++) {
      final employeeId = widget.block.employeeIds[i];
      // Membership uses the dialog-open job, so a swapped row can still Undo.
      final jobs = [
        for (final job in widget.clashes)
          if (job.employeeIds.contains(employeeId)) _live(job),
      ]..sort((a, b) => a.startTime.compareTo(b.startTime));
      if (jobs.isEmpty) continue;
      groups.add(
        _ClashGroup(
          employeeId: employeeId,
          name:
              assigneeNameAt(widget.block.employeeNames, i) ??
              _rosterName(employeeId),
          jobs: jobs,
        ),
      );
    }
    return groups;
  }

  String _rosterName(String employeeId) {
    for (final e
        in ref.read(employeesStreamProvider).value ??
            const <EmployeeRecord>[]) {
      if (e.id == employeeId) return e.name;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Watched to hold the roster stream open while the dialog is.
    ref.watch(employeesStreamProvider);
    final groups = _groups();
    final jobCount = widget.clashes.length;

    return AppDialogFrame(
      children: [
        _header(context, groups: groups, jobCount: jobCount),
        const SizedBox(height: AppSpacing.sp16),
        // Scrolls between a pinned header and footer so long absences fit.
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final group in groups)
                  ..._groupRows(context, group, showName: groups.length > 1),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sp24),
        _actions(context, theme),
      ],
    );
  }

  Widget _header(
    BuildContext context, {
    required List<_ClashGroup> groups,
    required int jobCount,
  }) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final statusColors = theme.statusColors;
    final soleName = groups.length == 1
        ? shortAssigneeName(groups.first.name, among: const {})
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: statusColors.warningContainer,
            borderRadius: BorderRadius.circular(AppRadius.r12),
          ),
          child: Icon(
            Icons.warning_amber_rounded,
            color: statusColors.onWarningContainer,
            size: 22,
          ),
        ),
        const SizedBox(height: AppSpacing.sp16),
        Text(
          soleName != null
              ? l10n.calendar_timeOffClashTitle(soleName)
              : l10n.calendar_timeOffClashTitleMany(groups.length),
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppSpacing.sp4),
        Text(
          '${DateUtilsHelper.formatDayRange(widget.block.startTime, lastWorkDayOf(widget.block)).toUpperCase()}'
          ' · ${l10n.calendar_clashJobsCount(jobCount)}',
          style: theme.monoType.data,
        ),
        const SizedBox(height: AppSpacing.sp12),
        Text(
          soleName != null
              ? l10n.calendar_personalBlockClashBody(soleName)
              : l10n.calendar_personalBlockClashBodyMany,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  List<Widget> _groupRows(
    BuildContext context,
    _ClashGroup group, {
    required bool showName,
  }) {
    final theme = Theme.of(context);
    // Day headings only once the jobs span more than one day.
    final days = {for (final job in group.jobs) job.startTime.dateOnly};
    final rows = <Widget>[
      if (showName)
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.sp12),
          child: Text(group.name, style: theme.monoType.label),
        ),
    ];
    // Resolved here, not in a per-row Builder, so rebuild order can't skew it.
    DateTime? lastDay;
    for (final job in group.jobs) {
      final day = job.startTime.dateOnly;
      if (days.length > 1 && day != lastDay) {
        lastDay = day;
        rows.add(
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sp12),
            child: Text(
              DateUtilsHelper.formatDayHeader(job.startTime),
              style: theme.monoType.groupLabel,
            ),
          ),
        );
      }
      rows.add(
        _ClashRow(
          job: job,
          blockedName: group.name,
          state: _states[_keyFor(group.employeeId, job)] ?? const _RowIdle(),
          onSwap: () => _openRow(group.employeeId, job),
          onPick: (person) => _swap(group.employeeId, job, person),
          onUndo: () => _undo(group, job),
          onOpenJob: () => showEventDetails(
            context,
            job,
            analyticsSource: AnalyticsSources.calendar,
            showActions: true,
          ),
        ),
      );
    }
    return rows;
  }

  Widget _actions(BuildContext context, ThemeData theme) => Row(
    children: [
      Expanded(
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(double.infinity, 44),
          ),
          onPressed: () => Navigator.pop(context),
          // Never "Cancel": that would read as cancelling the time off.
          child: Text(context.l10n.calendar_leaveThem),
        ),
      ),
      const SizedBox(width: AppSpacing.sp12),
      Expanded(
        child: FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size(double.infinity, 44),
          ),
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.common_done),
        ),
      ),
    ],
  );

  /// Who else could take [job]; a failed scan fails CLOSED to the stuck row.
  Future<void> _openRow(String employeeId, AppointmentRecord job) async {
    final key = _keyFor(employeeId, job);
    final repository = ref.read(appointmentsRepositoryProvider);
    final logger = ref.read(loggerProvider);
    final roster = ref.read(employeesStreamProvider.future);
    setState(() {
      // A still-loading previous row resets too, or it spins forever.
      final previous = _openKey;
      if (previous != null &&
          previous != key &&
          (_states[previous] is _RowOpen || _states[previous] is _RowBusy)) {
        _states[previous] = const _RowIdle();
      }
      _openKey = key;
      _states[key] = const _RowBusy();
    });

    List<EmployeeRecord> free;
    try {
      final pool = [
        for (final e in await roster)
          // `assignableEmployeesProvider`'s crew test, on the AWAITED stream.
          if (e.isAssignable &&
              !job.employeeIds.contains(e.id) &&
              !widget.block.employeeIds.contains(e.id))
            e,
      ];
      final busy = await repository.findBusyEmployees(
        candidates: pool,
        start: job.startTime,
        end: job.endTime,
        excludeAppointmentId: job.id,
      );
      free = [
        for (final e in pool)
          if (!busy.any((b) => b.id == e.id)) e,
      ];
    } on Object catch (e, st) {
      logger.warn('APPT-BUSY swap candidate scan failed', e, st);
      free = const [];
    }
    if (!mounted || _openKey != key) return;

    setState(() {
      _states[key] = free.isEmpty ? const _RowStuck() : _RowOpen(free);
    });
  }

  /// Replaces one assignee on THAT OCCURRENCE only — never the series.
  Future<void> _swap(
    String employeeId,
    AppointmentRecord job,
    EmployeeRecord person,
  ) async {
    final key = _keyFor(employeeId, job);
    final previous = _states[key] ?? const _RowIdle();
    final updated = replaceAssignee(
      _live(job),
      removeId: employeeId,
      addId: person.id,
      addName: person.name,
    );
    if (await _write(key, updated, previous: previous)) {
      setState(() {
        _jobs[updated.id!] = updated;
        _states[key] = _RowDone(took: person);
        _openKey = null;
      });
    }
  }

  /// Puts the person who is off back, built on [_live] like [_swap].
  Future<void> _undo(_ClashGroup group, AppointmentRecord job) async {
    final key = _keyFor(group.employeeId, job);
    final state = _states[key];
    if (state is! _RowDone) return;
    final reverted = replaceAssignee(
      _live(job),
      removeId: state.took.id,
      addId: group.employeeId,
      addName: group.name,
    );
    if (await _write(key, reverted, previous: state)) {
      setState(() {
        _jobs[reverted.id!] = reverted;
        _states[key] = const _RowIdle();
      });
    }
  }

  /// One appointment write, with the row parked as busy for the round trip and
  /// put back exactly where it was on failure.
  Future<bool> _write(
    String key,
    AppointmentRecord record, {
    required _RowState previous,
  }) async {
    if (guardedOffline(
      context,
      ref,
      intro: context.l10n.error_introSaveAppointment,
    )) {
      return false;
    }
    final repository = ref.read(appointmentsRepositoryProvider);
    final logger = ref.read(loggerProvider);
    final notices = ref.read(noticeServiceProvider);
    setState(() => _states[key] = const _RowBusy());
    try {
      await repository.updateAppointment(record);
      // Re-checked: setState on a dismissed dialog is a release FATAL.
      if (!mounted) return false;
      return true;
    } on Object catch (e, st) {
      logger.warn('APPT-SAVE personal-block swap failed', e, st);
      if (!mounted) return false;
      notices.error(
        composeErrorNotice(
          context,
          intro: context.l10n.error_introSaveAppointment,
          error: e,
        ),
      );
      setState(() => _states[key] = previous);
      return false;
    }
  }
}

class _ClashRow extends StatelessWidget {
  const _ClashRow({
    required this.job,
    required this.blockedName,
    required this.state,
    required this.onSwap,
    required this.onPick,
    required this.onUndo,
    required this.onOpenJob,
  });

  final AppointmentRecord job;
  final String blockedName;
  final _RowState state;
  final VoidCallback onSwap;
  final ValueChanged<EmployeeRecord> onPick;
  final VoidCallback onUndo;
  final VoidCallback onOpenJob;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final statusColors = theme.statusColors;
    final (border, fill) = switch (state) {
      _RowOpen() || _RowBusy() => (scheme.primary, scheme.surface),
      _RowDone() => (statusColors.success, statusColors.successContainer),
      _RowStuck() => (statusColors.warning, statusColors.warningContainer),
      _RowIdle() => (scheme.outlineVariant, scheme.surface),
    };

    // Hoisted out of the chip loop so the tally isn't rebuilt per chip.
    final freeFirstNames = switch (state) {
      _RowOpen(:final free) => firstNameTally([for (final p in free) p.name]),
      _ => const <String, int>{},
    };

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sp8),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sp12),
        decoration: BoxDecoration(
          color: fill,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(AppRadius.r12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _titleRow(context, theme),
            const SizedBox(height: AppSpacing.sp4),
            _statusLine(context, theme),
            if (state case _RowOpen(:final free)) ...[
              const SizedBox(height: AppSpacing.sp8),
              Text(
                context.l10n.calendar_swapPersonFor(blockedName),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.sp8),
              Wrap(
                spacing: AppSpacing.sp8,
                runSpacing: AppSpacing.sp8,
                children: [
                  for (final person in free)
                    _FreeCrewChip(
                      person: person,
                      // Disambiguates two people sharing a first name.
                      shortName: shortAssigneeName(
                        person.name,
                        among: freeFirstNames,
                      ),
                      onTap: () => onPick(person),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _titleRow(BuildContext context, ThemeData theme) => Row(
    children: [
      Expanded(
        child: Text(
          job.clientName.isNotEmpty ? job.clientName : job.title,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      const SizedBox(width: AppSpacing.sp8),
      Text(
        DateUtilsHelper.formatWhenLine(
          job.startTime,
          job.endTime,
          lastDay: lastWorkDayOf(job),
        ),
        style: theme.monoType.data,
      ),
    ],
  );

  Widget _statusLine(BuildContext context, ThemeData theme) {
    final l10n = context.l10n;
    final statusColors = theme.statusColors;
    return switch (state) {
      _RowBusy() => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.sp8),
        child: SizedBox(
          height: 16,
          width: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      _RowDone(:final took) => _line(
        context,
        theme,
        text: l10n.calendar_takesThisJob(took.name),
        color: statusColors.onSuccessContainer,
        actionLabel: l10n.common_undo,
        onAction: onUndo,
      ),
      _RowStuck() => _line(
        context,
        theme,
        text: l10n.calendar_everyoneElseBooked,
        color: statusColors.onWarningContainer,
        actionLabel: l10n.calendar_openJob,
        onAction: onOpenJob,
      ),
      _RowOpen() => _line(
        context,
        theme,
        text: blockedName,
        color: theme.colorScheme.onSurfaceVariant,
        struckThrough: true,
      ),
      _RowIdle() => _line(
        context,
        theme,
        text: blockedName,
        color: theme.colorScheme.onSurfaceVariant,
        struckThrough: true,
        actionLabel: l10n.calendar_swap,
        onAction: onSwap,
      ),
    };
  }

  Widget _line(
    BuildContext context,
    ThemeData theme, {
    required String text,
    required Color color,
    bool struckThrough = false,
    String? actionLabel,
    VoidCallback? onAction,
  }) => Row(
    children: [
      Expanded(
        child: Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: color,
            decoration: struckThrough ? TextDecoration.lineThrough : null,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      if (actionLabel != null)
        TextButton(
          onPressed: onAction,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sp8),
          ),
          child: Text(actionLabel),
        ),
    ],
  );
}

class _FreeCrewChip extends StatelessWidget {
  const _FreeCrewChip({
    required this.person,
    required this.shortName,
    required this.onTap,
  });

  final EmployeeRecord person;
  final String shortName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: person.name,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.sp8,
            AppSpacing.sp4,
            AppSpacing.sp12,
            AppSpacing.sp4,
          ),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            border: Border.all(color: scheme.outlineVariant, width: 1.5),
            borderRadius: BorderRadius.circular(AppRadius.rFull),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppAvatar(
                name: person.name,
                color: person.color,
                size: AvatarSize.xs,
              ),
              const SizedBox(width: AppSpacing.sp8),
              Text(
                shortName,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
