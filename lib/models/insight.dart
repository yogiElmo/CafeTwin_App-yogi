import 'package:flutter/material.dart';

/// The two families of business-intelligence insights.
enum InsightKind { optimization, prediction }

/// One computed insight (cost-optimization recommendation or predictive
/// forecast) derived from the live state of the station twins.
///
/// Insights are produced by `InsightsEngine` on every engine tick; the
/// optimization / predictive screens render them directly, and [CafeState]
/// upserts them into the persistent session record. [stationId] is null for
/// organization-wide insights; [icon] and [color] carry the display hint so
/// the screens keep their exact previous visuals.
class Insight {
  const Insight({
    required this.kind,
    required this.title,
    required this.detail,
    required this.icon,
    required this.color,
    this.stationId,
    this.stationName,
    this.category,
    this.impact = '',
    this.urgent = false,
  });

  /// Which engine family produced this insight.
  final InsightKind kind;

  /// Station the insight belongs to, e.g. `ST-03`; null = organization-wide.
  final String? stationId;

  /// Human-friendly station name, e.g. `Station 3`; null when org-wide.
  final String? stationName;

  /// Station category (Gaming, Marketing, …); also set for per-category
  /// organization insights such as an empty-area warning.
  final String? category;

  /// Headline, e.g. "ST-03 will reach 85°C in ~19 min".
  final String title;

  /// Longer explanation / recommended action.
  final String detail;

  /// Quantified impact, e.g. "$1.30/day", or '' when not applicable.
  final String impact;

  /// True for time-critical predictions (rendered red).
  final bool urgent;

  /// Display hint used by the insight cards.
  final IconData icon;

  /// Accent color used by the insight cards.
  final Color color;
}
