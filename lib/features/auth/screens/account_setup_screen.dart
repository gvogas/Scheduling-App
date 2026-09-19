import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/animations/animated_loading_button.dart';
import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/constants/app_urls.dart';
import 'package:scheduling/core/launchers/web_url_launcher.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/validators/auth_validators.dart';
import 'package:scheduling/core/validators/phone_format.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/features/auth/application/sign_in_controller.dart';
import 'package:scheduling/features/auth/data/auth_error_mapper.dart';
import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/features/auth/services/auth_service.dart';
import 'package:scheduling/features/auth/widgets/account_setup/consent_row.dart';
import 'package:scheduling/features/auth/widgets/account_setup/locked_email_panel.dart';
import 'package:scheduling/features/auth/widgets/account_setup/setup_banner.dart';
import 'package:scheduling/features/auth/widgets/auth_banner.dart';
import 'package:scheduling/features/auth/widgets/auth_fields.dart';
import 'package:scheduling/features/auth/widgets/auth_scaffold.dart';
import 'package:scheduling/features/auth/widgets/password_requirements_checklist.dart';
import 'package:scheduling/features/auth/widgets/password_strength_meter.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/routes/app_routes.dart';
import 'package:scheduling/shared/widgets/fields/labeled_text_field.dart';

/// First-run setup for an employee whose account an admin created.
class AccountSetupScreen extends ConsumerStatefulWidget {
  const AccountSetupScreen({
    this.firstName = '',
    this.lastName = '',
    this.authService,
    super.key,
  });

  /// Admin-typed values, so the person confirms rather than retypes.
  final String firstName;
  final String lastName;
  final AuthService? authService;

  @override
  ConsumerState<AccountSetupScreen> createState() => _AccountSetupScreenState();
}

class _AccountSetupScreenState extends ConsumerState<AccountSetupScreen> {
  late final AuthService _authService =
      widget.authService ?? ref.read(authServiceProvider);

  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();

  final FocusNode _lastNameFocus = FocusNode();
  final FocusNode _phoneFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();
  final FocusNode _confirmFocus = FocusNode();

  bool _isObscured = true;
  bool _isConfirmObscured = true;
  bool _consented = false;
  bool _isLoading = false;
  bool _submitted = false;
  bool _isSigningOut = false;

  String? _firstNameError;
  String? _lastNameError;
  String? _passwordError;
  String? _confirmError;
  String? _bannerError;

  @override
  void initState() {
    super.initState();
    _firstNameController = TextEditingController(text: widget.firstName);
    _lastNameController = TextEditingController(text: widget.lastName);
  }

  @override
  void dispose() {
    for (final controller in [
      _firstNameController,
      _lastNameController,
      _phoneController,
      _passwordController,
      _confirmController,
    ]) {
      controller.dispose();
    }
    for (final node in [
      _lastNameFocus,
      _phoneFocus,
      _passwordFocus,
      _confirmFocus,
    ]) {
      node.dispose();
    }
    super.dispose();
  }

  bool _validate() {
    final l10n = context.l10n;
    final required = l10n.validation_nameIsRequired;
    final firstErr = _firstNameController.text.trim().isEmpty ? required : null;
    final lastErr = _lastNameController.text.trim().isEmpty ? required : null;
    // Strict validator on the TRIMMED value — what setup actually stores.
    final password = _passwordController.text.trim();
    final passwordErr = AuthValidators.newPassword(context, password);

    String? confirmErr;
    if (_confirmController.text.trim().isEmpty) {
      confirmErr = l10n.validation_pleaseConfirmYourPassword;
    } else if (_confirmController.text.trim() !=
        _passwordController.text.trim()) {
      confirmErr = l10n.validation_passwordsDoNotMatch;
    }

    // Only rebuild when a message changed; this runs on every keystroke.
    if (firstErr != _firstNameError ||
        lastErr != _lastNameError ||
        passwordErr != _passwordError ||
        confirmErr != _confirmError) {
      setState(() {
        _firstNameError = firstErr;
        _lastNameError = lastErr;
        _passwordError = passwordErr;
        _confirmError = confirmErr;
      });
    }

    return firstErr == null &&
        lastErr == null &&
        passwordErr == null &&
        confirmErr == null;
  }

  void _onFieldChanged() {
    if (_submitted) _validate();
    if (_bannerError != null) setState(() => _bannerError = null);
  }

  bool get _isTransitionBusy => _isLoading || _isSigningOut;

  Future<void> _finishSetup() async {
    // Reentrancy guard first: the button only disables after the rebuild.
    if (_isTransitionBusy) return;
    FocusScope.of(context).unfocus();
    // Consent enforced here too: keyboard-submit bypasses the button.
    if (!_consented) return;

    setState(() {
      _submitted = true;
      _bannerError = null;
    });

    if (!_validate()) return;

    // Before the in-flight flag, per the offline write guard.
    if (ref.read(isOfflineProvider)) {
      setState(() {
        _bannerError = const AuthFailureNetwork().toLocalizedMessageInContext(
          context,
          AuthErrorContext.register,
        );
      });
      return;
    }

    setState(() => _isLoading = true);

    final logger = ref.read(loggerProvider);
    try {
      await _authService.completeAccountSetup(
        newPassword: _passwordController.text,
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim(),
        phone: _phoneController.text.trim(),
        termsAccepted: _consented,
        locationConsent: _consented,
      );
      // Success only — a failed attempt must never ask the OS to save it.
      TextInput.finishAutofillContext();
      if (!mounted) return;
      await _routeIntoApp();
    } catch (error, stackTrace) {
      final failure = AuthErrorMapper.map(error);
      logger.authFailure(
        'AUTH-SETUP completeAccountSetup failed',
        failure,
        error,
        stackTrace,
      );
      if (!mounted) return;
      // Already active: the password change landed, so walk them in.
      if (failure is AuthFailureSetupAlreadyComplete) {
        await _routeIntoApp();
        return;
      }
      // A reused starting password is a field error, not a banner.
      if (failure is AuthFailureStartingPasswordReused) {
        setState(() {
          _isLoading = false;
          _passwordError = failure.toLocalizedMessageInContext(
            context,
            AuthErrorContext.register,
          );
        });
        _passwordFocus.requestFocus();
        return;
      }
      setState(() {
        _isLoading = false;
        _bannerError = failure.toLocalizedMessageInContext(
          context,
          AuthErrorContext.register,
        );
      });
    }
  }

  /// Setup leaves us signed in and now active, so resolve the freshly
  /// activated profile and go straight into the app.
  Future<void> _routeIntoApp() async {
    final outcome = await ref
        .read(signInControllerProvider.notifier)
        .resumeAfterSignUp();
    if (!mounted) return;
    switch (outcome) {
      case SignInSuccess(:final employee):
        // Only on the branch that actually reaches the app.
        ref.read(analyticsServiceProvider).logAccountSetupCompleted();
        await Navigator.of(context).pushNamedAndRemoveUntil(
          AppRoutes.mainCalendar,
          (_) => false,
          arguments: MainCalendarArgs(
            isAdmin: employee.isAdmin,
            employeeId: employee.id,
          ),
        );
      // Active server-side but the doc isn't readable yet — back to sign-in.
      case SignInNoSession() || SignInProfilePending():
        await _recoverToLoginAfterSetup();
      // Only signIn() yields these; looping back here is not a recovery.
      case SignInInvalidCredentials() ||
          SignInNoProfile() ||
          SignInAccountDisabled() ||
          SignInNeedsAccountSetup() ||
          SignInError():
        setState(() {
          _isLoading = false;
          _bannerError = context.l10n.error_somethingWentWrongPleaseTryAgain;
        });
    }
  }

  Future<void> _recoverToLoginAfterSetup() async {
    final logger = ref.read(loggerProvider);
    try {
      await _authService.signOut();
    } catch (error, stackTrace) {
      logger.warn('AUTH-SETUP recovery signOut failed', error, stackTrace);
    }
    if (!mounted) return;
    await Navigator.of(
      context,
    ).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
  }

  /// Abandons setup with a plain `signOut`; there is nothing to tear down.
  Future<void> _signOut() async {
    if (_isTransitionBusy) return;
    final logger = ref.read(loggerProvider);
    setState(() {
      _isSigningOut = true;
      _bannerError = null;
    });
    try {
      await _authService.signOut();
      if (!mounted) return;
      await Navigator.of(
        context,
      ).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
    } catch (error, stackTrace) {
      logger.warn('AUTH-SETUP signOut failed', error, stackTrace);
      if (!mounted) return;
      setState(() {
        _isSigningOut = false;
        _bannerError = context.l10n.error_somethingWentWrongPleaseTryAgain;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AuthScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.auth_setUpYourAccountTitle,
            style: theme.textTheme.headlineLarge,
          ),
          const SizedBox(height: AppSpacing.sp16),
          const SetupBanner(),
          ..._identityPanels(),
          const SizedBox(height: AppSpacing.sp16),
          ..._formFields(context.l10n),
          ..._submitBlock(context.l10n),
        ],
      ),
    );
  }

  /// The read-only address they signed in with.
  List<Widget> _identityPanels() {
    final email = _authService.currentUser?.email ?? '';
    if (email.isEmpty) return const [];
    return [
      const SizedBox(height: AppSpacing.sp16),
      LockedEmailPanel(email: email),
    ];
  }

  /// Name, phone and the two password fields, in tab order.
  List<Widget> _formFields(AppLocalizations l10n) => [
    LabeledTextField(
      key: const Key('firstName'),
      label: l10n.employees_firstName,
      controller: _firstNameController,
      required: true,
      textCapitalization: TextCapitalization.words,
      textInputAction: TextInputAction.next,
      autofillHints: const [AutofillHints.givenName],
      maxLength: TextLimits.employeeNameHalf,
      errorText: _firstNameError,
      onChanged: (_) => _onFieldChanged(),
      onSubmitted: (_) => _lastNameFocus.requestFocus(),
    ),
    const SizedBox(height: AppSpacing.sp16),
    LabeledTextField(
      key: const Key('lastName'),
      label: l10n.employees_lastName,
      controller: _lastNameController,
      focusNode: _lastNameFocus,
      required: true,
      textCapitalization: TextCapitalization.words,
      textInputAction: TextInputAction.next,
      autofillHints: const [AutofillHints.familyName],
      maxLength: TextLimits.employeeNameHalf,
      errorText: _lastNameError,
      onChanged: (_) => _onFieldChanged(),
      onSubmitted: (_) => _phoneFocus.requestFocus(),
    ),
    const SizedBox(height: AppSpacing.sp16),
    LabeledTextField(
      key: const Key('phone'),
      label: l10n.employees_phoneNumber,
      controller: _phoneController,
      focusNode: _phoneFocus,
      optional: true,
      keyboard: TextInputType.phone,
      textInputAction: TextInputAction.next,
      autofillHints: const [AutofillHints.telephoneNumber],
      inputFormatters: const [PhoneInputFormatter()],
      maxLength: TextLimits.phone,
      onSubmitted: (_) => _passwordFocus.requestFocus(),
    ),
    const SizedBox(height: AppSpacing.sp16),
    AuthPasswordField(
      label: l10n.auth_newPassword,
      showLabel: true,
      textInputAction: TextInputAction.next,
      autofillHints: const [AutofillHints.newPassword],
      controller: _passwordController,
      focusNode: _passwordFocus,
      enabled: !_isLoading,
      errorText: _passwordError,
      isObscured: _isObscured,
      onSubmitted: _confirmFocus.requestFocus,
      onChanged: _onFieldChanged,
      onToggleObscured: () => setState(() => _isObscured = !_isObscured),
    ),
    _passwordFeedback(),
    const SizedBox(height: AppSpacing.sp16),
    AuthPasswordField(
      label: l10n.auth_confirmPassword,
      showLabel: true,
      prefixIcon: Icons.lock_reset_outlined,
      autofillHints: const [AutofillHints.newPassword],
      controller: _confirmController,
      focusNode: _confirmFocus,
      enabled: !_isLoading,
      errorText: _confirmError,
      isObscured: _isConfirmObscured,
      onSubmitted: _finishSetup,
      onChanged: _onFieldChanged,
      onToggleObscured: () =>
          setState(() => _isConfirmObscured = !_isConfirmObscured),
    ),
  ];

  /// Consent, any banner, and the primary action.
  List<Widget> _submitBlock(AppLocalizations l10n) {
    return [
      const SizedBox(height: AppSpacing.sp24),
      ConsentRow(
        value: _consented,
        enabled: !_isLoading,
        onChanged: (value) => setState(() => _consented = value),
        onTapTerms: () => launchWebUrl(context, ref, AppUrls.termsOfService),
      ),
      AuthBanner(message: _bannerError),
      const SizedBox(height: AppSpacing.sp24),
      AnimatedLoadingButton(
        label: l10n.auth_finishSetup,
        isLoading: _isTransitionBusy,
        // The checkbox IS the gate, so the disabled button needs no error copy.
        onPressed: _consented ? _finishSetup : null,
      ),
      const SizedBox(height: AppSpacing.sp8),
      Center(
        child: TextButton(
          onPressed: _isTransitionBusy ? null : _signOut,
          child: Text(l10n.settings_logOut),
        ),
      ),
    ];
  }

  /// Meter and checklist; the only keystroke-driven rebuild on the form.
  Widget _passwordFeedback() => ValueListenableBuilder<TextEditingValue>(
    valueListenable: _passwordController,
    builder: (context, value, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.sp8),
        // Trimmed, matching what `_validate` gates on and setup stores.
        PasswordStrengthMeter(password: value.text.trim()),
        const SizedBox(height: AppSpacing.sp8),
        PasswordRequirementsChecklist(password: value.text.trim()),
      ],
    ),
  );
}
