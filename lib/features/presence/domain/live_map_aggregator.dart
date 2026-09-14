import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/presence/domain/models/presence_fix.dart';

/// Staleness window for a presence fix on the admin live map; keep in sync
/// with PRESENCE_STALE_MINUTES in functions/travel_utils.js.
const presenceStaleAfter = Duration(minutes: 25);

/// A pin older than this leaves the map; Dart-only, unlike [presenceStaleAfter].
const presenceHiddenAfter = Duration(hours: 2);

/// Pure reducers that join raw presence fixes with the active staff roster
/// for the admin live-location map. Every function takes `now` explicitly so
/// the whole feature can be tested with a fixed clock.
class LiveMapAggregator {
  LiveMapAggregator._();

  /// Joins [fixes] with [users] by users-doc id, dropping any fix with no
  /// matching, inactive or test user, and sorts the result by name.
  static List<StaffMapPoint> join({
    required List<PresenceFix> fixes,
    required List<EmployeeRecord> users,
  }) {
    final byId = {for (final u in users) u.id: u};
    final points = <StaffMapPoint>[];
    for (final fix in fixes) {
      final user = byId[fix.userDocId];
      if (user == null || !_isTeammate(user)) continue;
      points.add(
        StaffMapPoint(
          userDocId: fix.userDocId,
          name: user.name,
          color: user.color,
          lat: fix.lat,
          lng: fix.lng,
          updatedAt: fix.updatedAt,
        ),
      );
    }
    points.sort((a, b) => a.name.compareTo(b.name));
    return points;
  }

  /// On the map, not seen (old fix, or sharing on with none yet), or sharing off.
  static LiveMapTeam groupTeam({
    required List<PresenceFix> fixes,
    required List<EmployeeRecord> users,
    required DateTime now,
  }) {
    final onMap = [
      for (final p in join(fixes: fixes, users: users))
        if (!isHidden(p.updatedAt, now)) p,
    ];
    final onMapIds = {for (final p in onMap) p.userDocId};
    final fixById = {for (final f in fixes) f.userDocId: f};
    final notSeen = <StaffAbsence>[];
    final sharingOff = <StaffAbsence>[];
    for (final user in users) {
      if (!_isTeammate(user) || onMapIds.contains(user.id)) continue;
      final fix = fixById[user.id];
      final absence = StaffAbsence(
        userDocId: user.id,
        name: user.displayName,
        color: user.color,
        lastSeenAt: fix?.updatedAt,
      );
      if (fix != null || user.locationSharingEnabled) {
        notSeen.add(absence);
      } else {
        sharingOff.add(absence);
      }
    }
    int byName(StaffAbsence a, StaffAbsence b) => a.name.compareTo(b.name);
    return LiveMapTeam(
      onMap: onMap,
      notSeen: notSeen..sort(byName),
      sharingOff: sharingOff..sort(byName),
    );
  }

  static bool _isTeammate(EmployeeRecord user) =>
      user.isActive && !user.isTestAccount;

  /// True only once [updatedAt] is older than [presenceStaleAfter]. A null
  /// value — a pending own-write's server timestamp — reads as fresh.
  static bool isStale(DateTime? updatedAt, DateTime now) {
    if (updatedAt == null) return false;
    return now.difference(updatedAt) > presenceStaleAfter;
  }

  /// True only once [updatedAt] is older than [presenceHiddenAfter].
  static bool isHidden(DateTime? updatedAt, DateTime now) {
    if (updatedAt == null) return false;
    return now.difference(updatedAt) > presenceHiddenAfter;
  }

  /// Widget-facing freshness bucket so call sites only map to l10n strings.
  static FreshnessBucket freshnessOf(DateTime? updatedAt, DateTime now) {
    if (updatedAt == null) return const FreshnessJustNow();
    final elapsed = now.difference(updatedAt);
    if (elapsed < const Duration(minutes: 1)) return const FreshnessJustNow();
    if (elapsed < const Duration(minutes: 60)) {
      return FreshnessMinutesAgo(elapsed.inMinutes);
    }
    return FreshnessHoursAgo(elapsed.inHours);
  }

  /// Great-circle distance in metres between two lat/lng pairs (haversine
  /// formula). Pure math, so the roster ordering can be tested without the
  /// geolocator plugin.
  static double distanceMeters(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    const earthRadius = 6371000.0; // metres
    final dLat = _radians(lat2 - lat1);
    final dLng = _radians(lng2 - lng1);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_radians(lat1)) *
            math.cos(_radians(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return earthRadius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _radians(double degrees) => degrees * math.pi / 180.0;

  /// Orders roster rows nearest-first relative to [selfDocId]'s point — the
  /// self row always leads. If there's no self point in [points], the
  /// incoming name order is preserved.
  static List<StaffMapPoint> sortedByProximity(
    List<StaffMapPoint> points, {
    required String? selfDocId,
  }) {
    StaffMapPoint? self;
    if (selfDocId != null) {
      for (final p in points) {
        if (p.userDocId == selfDocId) {
          self = p;
          break;
        }
      }
    }
    if (self == null) return List.of(points);
    final origin = self;
    // Decorate each row with its distance once (haversine is several trig ops
    // + two sqrt), then sort — a bare comparator would recompute it O(n log n)
    // times per point.
    final rest =
        points
            .where((p) => p.userDocId != origin.userDocId)
            .map(
              (p) => (
                point: p,
                distance: distanceMeters(origin.lat, origin.lng, p.lat, p.lng),
              ),
            )
            .toList()
          ..sort((a, b) => a.distance.compareTo(b.distance));
    return [origin, ...rest.map((e) => e.point)];
  }

  /// Best-effort city/locality pulled from a Google-formatted address, e.g.
  /// `"123 Rue X, Montréal, QC H2X 1Y4, Canada"` → `"Montréal"`. Tuned for
  /// the Canadian `street, City, PROV Postal, Country` shape; returns null
  /// when nothing usable can be picked out.
  static String? cityFromAddress(String? formatted) {
    final raw = formatted?.trim() ?? '';
    if (raw.isEmpty) return null;
    var parts = raw
        .split(',')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.length > 1 && _looksLikeCountry(parts.last)) {
      parts = parts.sublist(0, parts.length - 1);
    }
    if (parts.length > 1 && _looksLikeProvince(parts.last)) {
      parts = parts.sublist(0, parts.length - 1);
    }
    final city = parts.isEmpty ? '' : parts.last;
    return city.isEmpty ? null : city;
  }

  static bool _looksLikeCountry(String s) {
    final t = s.toLowerCase();
    return t == 'canada' ||
        t == 'united states' ||
        t == 'usa' ||
        t == 'états-unis';
  }

  // "QC", "QC H2X 1Y4", "ON M5V 2T6" — a 2-letter province code, optionally
  // trailed by a postal code (not a false-positive risk for city names).
  static final RegExp _provincePattern = RegExp(r'^[A-Z]{2}(\s|$)');

  static bool _looksLikeProvince(String s) => _provincePattern.hasMatch(s);
}

/// One staff member's plotted position, ready for the map widget.
class StaffMapPoint {
  const StaffMapPoint({
    required this.userDocId,
    required this.name,
    required this.color,
    required this.lat,
    required this.lng,
    required this.updatedAt,
  });

  final String userDocId;
  final String name;
  final Color color;
  final double lat;
  final double lng;
  final DateTime? updatedAt;
}

/// A teammate with no pin on the map.
class StaffAbsence {
  const StaffAbsence({
    required this.userDocId,
    required this.name,
    required this.color,
    required this.lastSeenAt,
  });

  final String userDocId;
  final String name;
  final Color color;

  /// The age of the stored fix; null when the phone has never reported one.
  final DateTime? lastSeenAt;
}

/// The admin map's three team sections.
class LiveMapTeam {
  const LiveMapTeam({
    required this.onMap,
    required this.notSeen,
    required this.sharingOff,
  });

  static const empty = LiveMapTeam(onMap: [], notSeen: [], sharingOff: []);

  final List<StaffMapPoint> onMap;
  final List<StaffAbsence> notSeen;
  final List<StaffAbsence> sharingOff;

  int get offMapCount => notSeen.length + sharingOff.length;
}

/// How long ago a fix was reported, bucketed for display.
sealed class FreshnessBucket {
  const FreshnessBucket();
}

class FreshnessJustNow extends FreshnessBucket {
  const FreshnessJustNow();
}

class FreshnessMinutesAgo extends FreshnessBucket {
  const FreshnessMinutesAgo(this.minutes);
  final int minutes;
}

class FreshnessHoursAgo extends FreshnessBucket {
  const FreshnessHoursAgo(this.hours);
  final int hours;
}
