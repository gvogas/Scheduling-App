import 'package:flutter/widgets.dart';

import 'package:scheduling/core/errors/failure.dart';
import 'package:scheduling/l10n/l10n.dart';

sealed class MapsFailure extends Failure {
  const MapsFailure({this.cause, this.stackTrace});

  final Object? cause;
  final StackTrace? stackTrace;
}

class MapsFailureNetwork extends MapsFailure {
  const MapsFailureNetwork({super.cause, super.stackTrace});

  @override
  String toLocalizedMessage(BuildContext context) =>
      context.l10n.error_addressLookupFailed;
}

class MapsFailureParse extends MapsFailure {
  const MapsFailureParse({super.cause, super.stackTrace});

  @override
  String toLocalizedMessage(BuildContext context) =>
      context.l10n.error_couldNotLoadAddressDetails;
}

class MapsFailureRateLimit extends MapsFailure {
  const MapsFailureRateLimit({super.cause, super.stackTrace});

  @override
  String toLocalizedMessage(BuildContext context) =>
      context.l10n.error_tooManyAttemptsPleaseTryAgainLater;
}

class MapsFailureUnauthorized extends MapsFailure {
  const MapsFailureUnauthorized({super.cause, super.stackTrace});

  @override
  String toLocalizedMessage(BuildContext context) =>
      context.l10n.error_somethingWentWrongPleaseTryAgain;
}

class MapsFailureInvalidInput extends MapsFailure {
  const MapsFailureInvalidInput({super.cause, super.stackTrace});

  @override
  String toLocalizedMessage(BuildContext context) =>
      context.l10n.error_somethingWentWrong;
}

/// The server refused because the address kill switch is off.
class MapsFailurePaused extends MapsFailure {
  const MapsFailurePaused({super.cause, super.stackTrace});

  @override
  String toLocalizedMessage(BuildContext context) =>
      context.l10n.common_featurePaused;
}
