import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/adaptive/adaptive_action_sheet.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/launchers/external_uri_launcher.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/maps/domain/address_parser.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/error_snack_bar.dart';
import 'package:url_launcher/url_launcher.dart';

class AddressMapLauncher {
  const AddressMapLauncher._();

  static final AppLogger _logger = AppLogger();

  /// Takes a [ref] purely to report the launch: this chooser is the app's main
  /// Directions path and it deliberately does NOT go through
  /// `launchExternalUri` (it surfaces failures via a SnackBar), so without this
  /// the one contact action a field crew uses most would be the one missing
  /// from the numbers.
  static Future<void> showMapChoices(
    BuildContext context,
    WidgetRef ref, {
    required String address,
  }) async {
    final cleanAddress = address.trim();
    if (cleanAddress.isEmpty) return;

    final navAddress =
        AddressParser.splitApt(cleanAddress)?.street ?? cleanAddress;
    final navEncoded = Uri.encodeComponent(navAddress);
    final displayAddress = AddressParser.canonicalToDisplay(cleanAddress);

    final options = <_MapOption>[
      if (Platform.isIOS)
        _MapOption(
          label: context.l10n.maps_appleMaps,
          icon: Icons.map_outlined,
          uri: Uri.parse('http://maps.apple.com/?q=$navEncoded'),
        ),
      _MapOption(
        label: context.l10n.maps_googleMaps,
        icon: Icons.map_outlined,
        uri: Uri.parse(
          'https://www.google.com/maps/search/?api=1&query=$navEncoded',
        ),
      ),
      _MapOption(
        label: context.l10n.maps_waze,
        icon: Icons.navigation_outlined,
        uri: Uri.parse('https://waze.com/ul?q=$navEncoded&navigate=yes'),
      ),
    ];

    if (!context.mounted) return;

  final Uri? chosen;
    chosen = await showAdaptiveActionSheet<Uri>(
      context,
      title: context.l10n.maps_openAddressWith,
      message: displayAddress,
      actions: [
        for (final option in options)
          AdaptiveSheetAction(
            value: option.uri,
            label: option.label,
            icon: option.icon,
          ),
      ],
    );


    if (chosen == null || !context.mounted) return;
    // launchUrl can throw and an unguarded throw here would be fatal, so log
    // it before we even check mounted.
    var opened = false;
    // Read before the await, like every other post-await provider use.
    final analytics = ref.read(analyticsServiceProvider);
    try {
      opened = await launchUrl(chosen, mode: LaunchMode.externalApplication);
      if (opened) {
        analytics.logContactAction(
          action: AnalyticsContactActions.directions,
        );
      }
    } catch (e, st) {
      // Same reason as `launchExternalUri`: the chosen URI is a Maps route
      // built from client addresses, and the exception message quotes it.
      _logger.warn(
        'LAUNCH-MAPS showMapChoices launchUrl failed '
        '(${chosen.scheme}): ${e.runtimeType}',
        launchFailureRecord(e),
        st,
      );
    }
    if (!opened) {
      // `launchUrl` returning false throws nothing, so without this a map that
      // silently refuses to open leaves no trace at all — the same branch
      // `launchExternalUri` logs for the schemes it owns.
      _logger.warn('LAUNCH-MAPS showMapChoices launchUrl returned false');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          errorSnackBar(context, context.l10n.error_couldNotOpenMapApp),
        );
      }
    }
  }
}

class _MapOption {
  const _MapOption({
    required this.label,
    required this.icon,
    required this.uri,
  });
  final String label;
  final IconData icon;
  final Uri uri;
}
