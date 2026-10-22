import 'package:flutter/widgets.dart';

import 'package:scheduling/core/validators/password_requirements.dart';
import 'package:scheduling/l10n/l10n.dart';

abstract final class AuthValidators {
  static final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  static bool isValidEmailFormat(String email) => _emailPattern.hasMatch(email);

  static String? email(BuildContext context, String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return context.l10n.validation_pleaseEnterYourEmail;
    }
    if (!isValidEmailFormat(trimmed)) {
      return context.l10n.validation_pleaseEnterAValidEmailAddress;
    }
    return null;
  }

  /// Sign-in: non-empty only — legacy credentials predate the 8-char policy.
  static String? password(BuildContext context, String value) {
    if (value.trim().isEmpty) {
      return context.l10n.validation_pleaseEnterYourPassword;
    }
    return null;
  }

  /// Strict variant for new passwords (setup, change password).
  static String? newPassword(BuildContext context, String value) {
    if (value.trim().isEmpty) {
      return context.l10n.validation_pleaseEnterYourPassword;
    }
    if (!PasswordRequirement.allMetBy(value)) {
      return context.l10n.validation_passwordDoesNotMeetAllRequirements;
    }
    return null;
  }
}
