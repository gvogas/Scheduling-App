import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';

/// Keeps the `user_role` user property in step with the LIVE account doc.
class AnalyticsIdentityListener {
  const AnalyticsIdentityListener(this.ref);

  final WidgetRef ref;

  void registerAll() => _userRole();

  void _userRole() {
    ref.listen<AsyncValue<String>>(userRoleProvider, (previous, next) {
      // An unsettled read holds the last role rather than blanking it.
      if (next.isLoading || next.hasError) return;
      final role = next.value ?? '';
      if (previous?.value == role) return;
      ref
          .read(analyticsServiceProvider)
          .setUserRole(role.isEmpty ? null : role);
    });
  }
}
