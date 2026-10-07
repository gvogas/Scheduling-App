import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/button_styles.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/employees/application/employee_form_controller.dart';
import 'package:scheduling/features/employees/domain/employees_failure.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/models/new_account_credentials.dart';
import 'package:scheduling/features/employees/widgets/fields/credential_line.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/dialogs/confirm_dialog.dart';
import 'package:scheduling/shared/widgets/feedback/user_status_chip.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';
import 'package:scheduling/shared/widgets/primitives/mono_section_label.dart';
import 'package:scheduling/shared/widgets/primitives/name_initials.dart';

/// The roster row for someone whose account exists but who has never signed
/// in. Tapping expands it in place — they have no detail page worth opening
/// (no jobs, no availability that matters yet).
///
/// Expanding is NOT a reveal here: it makes no server round-trip and rotates
/// nothing. The starting password is random per account and never persisted,
/// so a row holding no server echo masks it. Only Reset password
/// re-provisions, and only that rotates what they were given.
class PendingInviteTile extends ConsumerStatefulWidget {
  const PendingInviteTile({required this.employee, super.key});

  final EmployeeRecord employee;

  @override
  ConsumerState<PendingInviteTile> createState() => _PendingInviteTileState();
}

class _PendingInviteTileState extends ConsumerState<PendingInviteTile> {
  bool _expanded = false;
  bool _copied = false;

  /// The re-issued credentials, held only after a Reset password. Null means
  /// the row is showing the account as created. A credential either way: it
  /// lives here and nowhere else — never logged, never in a provider, never
  /// persisted, never in a notice.
  NewAccountCredentials? _credentials;

  /// Which account [_credentials] belongs to, so a recycled State can't show
  /// one person's password on another person's row.
  String? _credentialsFor;

  NewAccountCredentials? get _cached =>
      _credentialsFor == widget.employee.id ? _credentials : null;

  /// Expanding costs nothing: unlike the retired code flow, there is no
  /// server round-trip, and nothing is re-issued.
  void _toggleExpanded() => setState(() => _expanded = !_expanded);

  /// Re-provisions the account through the idempotent `createEmployeeAccount`
  /// path, which issues a fresh random password and echoes it back once.
  ///
  /// Every argument comes from the stored record: the callable's re-provision
  /// branch *updates* name/phone/colour/job title with whatever it is handed,
  /// so passing blanks would silently wipe the person's details.
  Future<void> _resetPassword() async {
    final l10n = context.l10n;
    final notices = ref.read(noticeServiceProvider);
    if (guardedOffline(
      context,
      ref,
      intro: context.l10n.error_introSaveEmployee,
    )) {
      return;
    }

    final employee = widget.employee;
    // The stored record, whole — the re-issue branch refreshes every editable
    // field it is handed, so anything dropped here would be blanked server-side.
    final outcome = await ref
        .read(employeeFormControllerProvider.notifier)
        .createAccount(employee);
    if (!mounted) return;

    switch (outcome) {
      // A skipped duplicate submit committed nothing and failed nothing — the
      // save already running owns the outcome, so say nothing.
      case EmployeeSaveBusy():
        break;
      case EmployeeAccountCreated(:final credentials):
        setState(() {
          _credentials = credentials;
          _credentialsFor = employee.id;
          _copied = false;
        });
      case EmployeeSaveFailed(:final error):
        notices.error(
          composeErrorNotice(
            context,
            intro: l10n.error_introSaveEmployee,
            error: error,
          ),
        );
      case EmployeeEmailInUse():
      case EmployeeUpdated():
        // Unreachable from a re-provision; the sealed family forces the branch.
        break;
    }
  }

  Future<void> _remove() async {
    final l10n = context.l10n;
    final notices = ref.read(noticeServiceProvider);
    if (guardedOffline(
      context,
      ref,
      intro: context.l10n.error_introRemoveAccount,
    )) {
      return;
    }

    final confirmed = await showConfirmDialog(
      context,
      title: l10n.employees_removeAccount,
      message: l10n.employees_removeAccountConfirmBody,
      confirmLabel: l10n.employees_removeAccount,
    );
    if (!confirmed || !mounted) return;

    final outcome = await ref
        .read(employeeFormControllerProvider.notifier)
        .deleteAccount(widget.employee.id);
    if (!mounted) return;

    switch (outcome) {
      case AccountDeleted():
        // No notice: the live stream drops the row, and that IS the
        // confirmation.
        break;
      case AccountDeleteBusy():
        break;
      case AccountDeleteFailed(:final error):
        notices.error(
          error is EmployeesFailureAccountNoLongerPending
              ? error.toLocalizedMessage(context)
              : composeErrorNotice(
                  context,
                  intro: l10n.error_introRemoveAccount,
                  error: error,
                ),
        );
    }
  }

  void _copy(String email, String? password) {
    copyCredentialsToClipboard(email: email, password: password);
    setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context),
        // AnimatedSize, not AnimatedCrossFade: the collapsed body must leave
        // the tree entirely, and a cross-fade keeps both children built — the
        // code would stay findable (and readable by a screen reader) on a
        // collapsed row.
        AnimatedSize(
          alignment: Alignment.topCenter,
          curve: Curves.easeOutCubic,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : AppDuration.normal,
          // Only the expanded body watches, and it watches THIS row's keys via
          // select — so a save elsewhere rebuilds nothing here, and a collapsed
          // row (whose header carries a CustomPaint avatar) rebuilds never.
          child: _expanded
              ? Consumer(
                  builder: (context, ref, _) {
                    final id = widget.employee.id;
                    return _buildBody(
                      context,
                      isResetting: ref.watch(
                        employeeFormControllerProvider.select(
                          (a) => a.isSavingId(id),
                        ),
                      ),
                      isRemoving: ref.watch(
                        employeeFormControllerProvider.select(
                          (a) => a.isDeletingAccountId(id),
                        ),
                      ),
                    );
                  },
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compact = context.isCompact;
    final displayName = widget.employee.displayName;
    const chip = UserStatusChip(status: UserStatus.invited);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _toggleExpanded,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sp16,
            vertical: AppSpacing.sp12,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DashedAvatar(name: displayName),
              const SizedBox(width: AppSpacing.sp12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayName,
                      maxLines: compact ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (widget.employee.email.isNotEmpty &&
                        displayName != widget.employee.email) ...[
                      const SizedBox(height: AppSpacing.sp4),
                      Text(
                        widget.employee.email,
                        maxLines: compact ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (compact) ...[
                      const SizedBox(height: AppSpacing.sp8),
                      const Align(alignment: Alignment.centerLeft, child: chip),
                    ],
                  ],
                ),
              ),
              if (!compact) ...[const SizedBox(width: AppSpacing.sp8), chip],
              const SizedBox(width: AppSpacing.sp8),
              AnimatedRotation(
                turns: _expanded ? 0.5 : 0,
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : AppDuration.fast,
                child: Icon(
                  Icons.expand_more,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required bool isResetting,
    required bool isRemoving,
  }) {
    final l10n = context.l10n;
    final reissued = _cached;
    // Before any reset the row shows the stored email; the starting password
    // is random per account and is never persisted, so there is nothing to
    // show until a reset issues a new one.
    final email = reissued?.email ?? widget.employee.email;
    final password = reissued?.password;
    final actionsBusy = isResetting || isRemoving;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sp16,
        0,
        AppSpacing.sp16,
        AppSpacing.sp16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MonoSectionLabel(l10n.employees_signInDetails),
          const SizedBox(height: AppSpacing.sp8),
          _CredentialsBlock(
            email: email,
            password: password,
            isBusy: isResetting,
            copied: _copied,
            onCopy: () => _copy(email, password),
          ),
          if (reissued != null) ...[
            const SizedBox(height: AppSpacing.sp8),
            // Only shown after an actual reset: unlike the retired code flow,
            // merely opening the row rotates nothing.
            Text(
              l10n.employees_newPasswordIssued,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).palette.textMuted,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sp16),
          _ActionRow(
            // Derived from the cached credentials, not a separate latch: a
            // recycled State showing a different employee has no cached
            // credentials, and must not claim their password was just reset.
            resetLabel: reissued != null
                ? l10n.employees_passwordReset
                : l10n.employees_resetPassword,
            onReset: actionsBusy ? null : _resetPassword,
            onRemove: actionsBusy ? null : _remove,
            isRemoving: isRemoving,
          ),
        ],
      ),
    );
  }
}

/// The `SIGN-IN DETAILS` block: the email and starting password side by side
/// with one Copy pill, or a spinner while a reset is in flight. With no
/// password held the pill copies the email alone.
class _CredentialsBlock extends StatelessWidget {
  const _CredentialsBlock({
    required this.email,
    required this.password,
    required this.isBusy,
    required this.copied,
    required this.onCopy,
  });

  final String email;

  /// Null when the app holds no server echo — the row masks it and points at
  /// Reset password instead.
  final String? password;
  final bool isBusy;
  final bool copied;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    if (isBusy) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.sp12),
        decoration: credentialPanelDecoration(theme),
        child: const Center(child: AdaptiveProgressIndicator()),
      );
    }

    final copyButton = CopyCredentialsButton(
      copied: copied,
      password: password,
      onCopy: onCopy,
    );

    final values = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        CredentialLine(label: l10n.common_email, value: email),
        const SizedBox(height: AppSpacing.sp8),
        CredentialLine(
          label: l10n.employees_temporaryPassword,
          value: password ?? kMaskedCredential,
        ),
        if (password == null) ...[
          const SizedBox(height: AppSpacing.sp4),
          Text(
            l10n.employees_passwordHiddenUntilReset,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.palette.textMuted,
            ),
          ),
        ],
      ],
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sp12,
        vertical: AppSpacing.sp8,
      ),
      decoration: credentialPanelDecoration(theme),
      child: context.isCompact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                values,
                const SizedBox(height: AppSpacing.sp8),
                copyButton,
              ],
            )
          : Row(
              children: [
                Expanded(child: values),
                const SizedBox(width: AppSpacing.sp8),
                copyButton,
              ],
            ),
    );
  }
}

/// Reset and Remove as two equal-width bordered actions, stacking when the
/// row is too narrow or the text too large to hold them side by side.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.resetLabel,
    required this.onReset,
    required this.onRemove,
    required this.isRemoving,
  });

  final String resetLabel;
  final VoidCallback? onReset;
  final VoidCallback? onRemove;
  final bool isRemoving;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    const minimumSize = Size.fromHeight(48);

    final reset = OutlinedButton(
      onPressed: onReset,
      style: OutlinedButton.styleFrom(minimumSize: minimumSize),
      child: Text(
        resetLabel,
        maxLines: 2,
        textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis,
      ),
    );
    final remove = OutlinedButton(
      onPressed: onRemove,
      style: destructiveOutlinedButtonStyle(context, minimumSize: minimumSize),
      child: isRemoving
          ? const AdaptiveProgressIndicator(size: 18)
          : Text(
              l10n.employees_removeAccount,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
            ),
    );

    if (context.isCompact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          reset,
          const SizedBox(height: AppSpacing.sp8),
          remove,
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: reset),
        const SizedBox(width: AppSpacing.sp8),
        Expanded(child: remove),
      ],
    );
  }
}

/// Dashed-ring avatar — the visual cue that this person hasn't signed in yet. No
/// crew colour is rendered even though the invite HAS reserved one: the
/// dashing is visual only, and `usedColors` still counts the invite.
class _DashedAvatar extends StatelessWidget {
  const _DashedAvatar({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.palette;
    final initials = nameInitials(name);
    final diameter = AvatarSize.md.diameter;
    return SizedBox(
      width: diameter,
      height: diameter,
      child: CustomPaint(
        painter: _DashedCirclePainter(color: palette.decorFaint),
        child: Center(
          child: initials == '?'
              ? Icon(Icons.person_outline, size: 17, color: palette.textMuted)
              : Text(
                  initials,
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
        ),
      ),
    );
  }
}

class _DashedCirclePainter extends CustomPainter {
  const _DashedCirclePainter({required this.color});

  final Color color;

  static const int _dashCount = 12;
  static const double _strokeWidth = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = color;
    final rect = Rect.fromLTWH(
      _strokeWidth / 2,
      _strokeWidth / 2,
      size.width - _strokeWidth,
      size.height - _strokeWidth,
    );
    const sweep = 2 * math.pi / _dashCount;
    for (var i = 0; i < _dashCount; i++) {
      canvas.drawArc(rect, i * sweep, sweep * 0.55, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DashedCirclePainter oldDelegate) =>
      oldDelegate.color != color;
}
