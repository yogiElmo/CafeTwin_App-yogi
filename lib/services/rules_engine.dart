import '../models/alert.dart';
import 'digital_twin.dart';

/// Layer 4: rule-based alert detection.
///
/// [evaluate] is pure: given a twin it returns the list of alerts whose
/// conditions currently hold. De-duplication (one active alert per
/// (stationId, ruleCode)) and auto-resolution are handled by CafeState.
class RulesEngine {
  RulesEngine._();

  /// Station network link capacity in Mbps (NET-BW threshold basis).
  static const double bandwidthCapacityMbps = 1000.0;

  /// Evaluates all rules against [twin] and returns an [Alert] for every
  /// rule whose condition is currently true (may be empty).
  static List<Alert> evaluate(StationTwin twin) {
    final List<Alert> alerts = <Alert>[];
    final DateTime now = DateTime.now();

    String idFor(String ruleCode) =>
        '${twin.id}-$ruleCode-${now.microsecondsSinceEpoch}';

    // HW-CRIT: cpuTemp > 85 OR gpuTemp > 83 -> critical, hardware.
    if (twin.hardware.cpuTemp > 85.0 || twin.hardware.gpuTemp > 83.0) {
      alerts.add(Alert(
        id: idFor('HW-CRIT'),
        stationId: twin.id,
        ruleCode: 'HW-CRIT',
        category: AlertCategory.hardware,
        severity: AlertSeverity.critical,
        message: 'CPU ${twin.hardware.cpuTemp.toStringAsFixed(1)}°C / '
            'GPU ${twin.hardware.gpuTemp.toStringAsFixed(1)}°C exceeds safe '
            'limits (85°C / 83°C).',
        suggestion: 'Shut down station and check cooling fans / dust '
            'buildup immediately.',
        timestamp: now,
      ));
    }

    // HW-RAMP: cpuTempTrend > 2.0 °C/min AND cpuTemp > 75 -> warning, hardware.
    final double trend = twin.cpuTempTrend();
    if (trend > 2.0 && twin.hardware.cpuTemp > 75.0) {
      alerts.add(Alert(
        id: idFor('HW-RAMP'),
        stationId: twin.id,
        ruleCode: 'HW-RAMP',
        category: AlertCategory.hardware,
        severity: AlertSeverity.warning,
        message: 'CPU heating at ${trend.toStringAsFixed(1)}°C/min and '
            'already at ${twin.hardware.cpuTemp.toStringAsFixed(1)}°C. '
            'Check cooling.',
        suggestion: 'Check airflow and clean fans soon — schedule '
            'maintenance before next peak hours.',
        timestamp: now,
      ));
    }

    // NET-LAT: latency > 150ms sustained (last 6 readings) -> critical, network.
    if (twin.latencySustainedAbove(150.0)) {
      alerts.add(Alert(
        id: idFor('NET-LAT'),
        stationId: twin.id,
        ruleCode: 'NET-LAT',
        category: AlertCategory.network,
        severity: AlertSeverity.critical,
        message: 'Latency above 150ms for the last 6 readings '
            '(now ${twin.network.latencyMs.toStringAsFixed(0)}ms, '
            'loss ${twin.network.packetLoss.toStringAsFixed(1)}%).',
        suggestion: 'Check for bandwidth-hogging apps or downloads on this '
            'station; consider restarting the router port.',
        timestamp: now,
      ));
    }

    // NET-BW: bandwidth utilization > 80% -> warning, network.
    if (twin.bandwidthUtilization > 0.80) {
      alerts.add(Alert(
        id: idFor('NET-BW'),
        stationId: twin.id,
        ruleCode: 'NET-BW',
        category: AlertCategory.network,
        severity: AlertSeverity.warning,
        message: 'Bandwidth at '
            '${(twin.bandwidthUtilization * 100.0).toStringAsFixed(0)}% of '
            '${bandwidthCapacityMbps.toStringAsFixed(0)} Mbps capacity.',
        suggestion: 'Limit background downloads/updates on this station '
            'during peak hours.',
        timestamp: now,
      ));
    }

    // UTIL-GHOST: occupied but gpuLoad < 5 for 10+ min -> warning, utilization.
    if (twin.session.occupied && twin.ghostMinutes >= 10) {
      alerts.add(Alert(
        id: idFor('UTIL-GHOST'),
        stationId: twin.id,
        ruleCode: 'UTIL-GHOST',
        category: AlertCategory.utilization,
        severity: AlertSeverity.warning,
        message: 'Occupied for ${twin.session.sessionMinutes} min but GPU '
            'load under 5% for ${twin.ghostMinutes} min — possible '
            'ghost session.',
        suggestion: 'Customer may have left — check the seat and end the '
            'session to free the station.',
        timestamp: now,
      ));
    }

    // UTIL-LONG: session > 360 min -> warning, utilization.
    if (twin.session.sessionMinutes > 360) {
      alerts.add(Alert(
        id: idFor('UTIL-LONG'),
        stationId: twin.id,
        ruleCode: 'UTIL-LONG',
        category: AlertCategory.utilization,
        severity: AlertSeverity.warning,
        message: 'Session running ${twin.session.sessionMinutes} min '
            '(> 360) — check in with the customer.',
        suggestion: 'Long session — check on customer wellbeing and confirm '
            'billing is running correctly.',
        timestamp: now,
      ));
    }

    return alerts;
  }
}
