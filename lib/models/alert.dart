/// Category of a rule-based alert.
enum AlertCategory { hardware, network, utilization }

/// Severity of a rule-based alert.
enum AlertSeverity { warning, critical }

/// A single alert fired by the rules engine.
///
/// Alerts are mutable only in their lifecycle flags ([acknowledged],
/// [resolved]); the descriptive fields are immutable once fired.
class Alert {
  Alert({
    required this.id,
    required this.stationId,
    required this.ruleCode,
    required this.category,
    required this.severity,
    required this.message,
    required this.suggestion,
    required this.timestamp,
    this.acknowledged = false,
    this.resolved = false,
  });

  /// Globally unique alert instance id.
  final String id;

  /// Station the alert belongs to, e.g. `ST-03`.
  final String stationId;

  /// Rule that fired, e.g. `HW-CRIT`, `NET-LAT`.
  final String ruleCode;

  final AlertCategory category;
  final AlertSeverity severity;

  /// Human-readable description including the measured values.
  final String message;

  /// Practical, staff-friendly recommended action for this alert —
  /// tells café staff what to do about it.
  final String suggestion;

  /// Wall-clock time the alert fired.
  final DateTime timestamp;

  /// Operator tapped the alert to acknowledge it.
  bool acknowledged;

  /// Condition cleared on its own; the alert is no longer active.
  bool resolved;

  /// An alert that is still firing (its rule condition currently holds).
  bool get isActive => !resolved;
}
