import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/utils/firestore_parsing.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';

/// When this person stamped location consent in account setup, off the own
/// `users` doc (server-owned, so `EmployeeRecord` deliberately omits it).
final myLocationConsentAtProvider = Provider.autoDispose<DateTime?>(
  (ref) => firestoreDateTime(
    ref.watch(currentUserDocProvider).value?['locationConsentAt'],
  ),
);
