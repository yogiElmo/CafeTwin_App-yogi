/// One row of an admin's own organization list, as returned by
/// `GET /organizations`. Carries just enough to render the list screen --
/// the full station roster is only fetched (via `GET /organizations/:id`)
/// once the admin actually taps an organization to open it.
class OrganizationSummary {
  OrganizationSummary({
    required this.id,
    required this.name,
    required this.configuredAt,
    required this.stationCount,
  });

  factory OrganizationSummary.fromJson(Map<String, dynamic> json) {
    return OrganizationSummary(
      id: json['id'] as String,
      name: json['name'] as String,
      configuredAt:
          DateTime.tryParse(json['configured_at'] as String? ?? '') ??
              DateTime.now(),
      stationCount: _asInt(json['station_count']),
    );
  }

  /// Postgres COUNT(...)::int usually arrives as a number via pg, but some
  /// drivers/paths surface bigint-derived counts as a string -- handle both
  /// rather than assuming.
  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  /// Backend organization id (UUID).
  final String id;

  /// Organization / company name entered on setup.
  final String name;

  /// When the organization was first configured.
  final DateTime configuredAt;

  /// Number of stations on this organization's floor.
  final int stationCount;
}
