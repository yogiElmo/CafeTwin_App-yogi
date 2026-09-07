import 'insight.dart';

/// One persistent record of an insight detected while the organization runs.
///
/// Records are upserted by [CafeState] on every engine tick: the first time
/// an insight (matched by kind + stationId + title) appears, a new entry is
/// created; while it keeps being detected, [lastSeen] is refreshed and
/// [occurrences] is incremented, so the record shows how persistent each
/// issue/opportunity was over the whole session.
class ReportEntry {
  ReportEntry({
    required this.id,
    required this.firstSeen,
    required this.lastSeen,
    required this.kind,
    required this.title,
    required this.detail,
    required this.impact,
    this.stationId,
    this.stationName,
    this.category,
    this.occurrences = 1,
  });

  /// Unique record id, e.g. `REC-0007`.
  final String id;

  /// Wall-clock time the insight was first detected.
  final DateTime firstSeen;

  /// Wall-clock time the insight was most recently detected.
  DateTime lastSeen;

  /// Optimization (cost saving) or prediction (forecast).
  final InsightKind kind;

  /// Station the insight belongs to; null = organization-wide.
  final String? stationId;

  /// Human-friendly station name; null when org-wide.
  final String? stationName;

  /// Station/area category; may be null for purely org-wide insights.
  final String? category;

  /// Headline text of the insight (part of the upsert match key).
  final String title;

  /// Latest explanation text (refreshed when it changes).
  String detail;

  /// Latest impact text (refreshed when it changes).
  String impact;

  /// How many engine ticks this insight was detected on.
  int occurrences;
}
