import 'package:flutter/material.dart';

import '../models/alert.dart';
import '../models/insight.dart';
import '../state/cafe_state.dart';
import 'digital_twin.dart';

/// Shared business-intelligence engine.
///
/// Holds the exact computations that used to live inline in
/// `OptimizationScreen` and `PredictiveScreen`, so the same insights can be
/// rendered live AND recorded persistently by [CafeState] on every tick.
/// Every per-station insight carries stationId / stationName / category.
class InsightsEngine {
  InsightsEngine._();

  static const Color amber = Color(0xFFD9A441);
  static const Color green = Color(0xFF58A16C);
  static const Color red = Color(0xFFCC5148);

  /// Assumed average draw of a powered-on but idle station, in kW.
  static const double idlePowerKw = 0.15;

  /// Assumed electricity price in $/kWh.
  static const double pricePerKwh = 0.12;

  /// CPU temperature considered the danger threshold.
  static const double tempLimitC = 85.0;

  /// Daily saving per idle station that gets powered down:
  /// 0.15 kW × $0.12/kWh × 24 h = $0.432/day.
  static double savingsPerDay(int idleStations) =>
      idleStations * idlePowerKw * pricePerKwh * 24;

  /// Live cost-optimization recommendations (same math as the original
  /// optimization screen). Org-wide insights have a null stationId; the
  /// empty-area insight carries its [Insight.category].
  static List<Insight> optimizationsFor(CafeState state) {
    final List<StationTwin> twins = state.stationList;
    final int total = twins.length;
    final int occupied =
        twins.where((StationTwin t) => t.session.occupied).length;
    final int idle = total - occupied;
    final double occupancyRatio = total > 0 ? occupied / total : 0.0;

    // Distinct stations with an active ghost-session alert.
    final Set<String> ghostStationIds = state.alerts
        .where((Alert a) => a.ruleCode == 'UTIL-GHOST' && a.isActive)
        .map((Alert a) => a.stationId)
        .toSet();
    final int ghostStations = ghostStationIds.length;

    // Categories in which no station is currently occupied.
    final Map<String, int> idlePerCategory = <String, int>{};
    final Set<String> occupiedCategories = <String>{};
    for (final StationTwin twin in twins) {
      if (twin.session.occupied) {
        occupiedCategories.add(twin.station.category);
      } else {
        idlePerCategory.update(
          twin.station.category,
          (int count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    }
    final List<String> emptyCategories = idlePerCategory.keys
        .where((String c) => !occupiedCategories.contains(c))
        .toList();

    final double dailySavings = savingsPerDay(idle);

    final List<Insight> insights = <Insight>[];

    // 1. Power down idle stations.
    if (idle > 0) {
      insights.add(Insight(
        kind: InsightKind.optimization,
        icon: Icons.power_settings_new,
        color: amber,
        title: 'Power down $idle idle station${idle == 1 ? '' : 's'}',
        detail: 'Each idle station still draws ~$idlePowerKw kW. '
            'Switching them off cuts the power bill without affecting '
            'a single customer.',
        impact: '\$${dailySavings.toStringAsFixed(2)}/day',
      ));
    }

    // 2. Free ghost stations (lists the affected stations explicitly).
    if (ghostStations > 0) {
      final String stationList = ghostStationIds.join(', ');
      insights.add(Insight(
        kind: InsightKind.optimization,
        icon: Icons.event_seat_outlined,
        color: amber,
        title: 'Free $ghostStations ghost '
            'station${ghostStations == 1 ? '' : 's'}',
        detail: 'These stations show an active session but no GPU activity '
            '— a customer likely left without logging out, so the seat '
            'is blocked while earning nothing. Affected: $stationList.',
        impact: '~\$5/hour each',
      ));
    }

    // 3. Low utilization.
    if (total > 0 && occupancyRatio < 0.4) {
      insights.add(Insight(
        kind: InsightKind.optimization,
        icon: Icons.compress,
        color: amber,
        title: 'Low utilization',
        detail: 'Only $occupied of $total stations are in use — consider '
            'consolidating customers to fewer stations and switching '
            'off the rest.',
        impact: idle > 0
            ? 'Up to \$${dailySavings.toStringAsFixed(2)}/day'
            : 'Fewer stations to run',
      ));
    }

    // 4. Category imbalance.
    for (final String category in emptyCategories) {
      final int count = idlePerCategory[category]!;
      insights.add(Insight(
        kind: InsightKind.optimization,
        icon: Icons.meeting_room_outlined,
        color: amber,
        category: category,
        title: "The '$category' area is empty",
        detail: 'No customer is using any $category station — repurpose '
            'the area or power-save those '
            '$count station${count == 1 ? '' : 's'}.',
        impact: '$count station${count == 1 ? '' : 's'} idle',
      ));
    }

    // 5. Standing tip (always present).
    insights.add(const Insight(
      kind: InsightKind.optimization,
      icon: Icons.nightlight_outlined,
      color: amber,
      title: 'Schedule auto-shutdown after closing hours',
      detail: 'Automatically power down all stations at closing time and '
          'boot them just before opening to eliminate overnight draw.',
      impact: 'Overnight savings',
    ));

    return insights;
  }

  /// Live predictive forecasts (same math as the original predictive
  /// screen). Thermal / network / maintenance forecasts are per-station and
  /// carry stationId / stationName / category.
  static List<Insight> predictionsFor(CafeState state) {
    final List<StationTwin> twins = state.stationList;
    final int total = twins.length;
    final int occupied =
        twins.where((StationTwin t) => t.session.occupied).length;
    final double occupancyRatio = total > 0 ? occupied / total : 0.0;

    final List<Insight> insights = <Insight>[];

    // 1 + 2 + 4. Per-station forecasts from twin history.
    for (final StationTwin twin in twins) {
      // 1. Thermal forecast.
      final double trend = twin.cpuTempTrend();
      if (trend > 0.5) {
        final double current = twin.hardware.cpuTemp;
        if (current >= tempLimitC) {
          insights.add(Insight(
            kind: InsightKind.prediction,
            icon: Icons.thermostat,
            color: red,
            urgent: true,
            stationId: twin.id,
            stationName: twin.name,
            category: twin.station.category,
            title: '${twin.id} is already at '
                '${current.toStringAsFixed(0)}°C',
            detail: 'The CPU is above the ${tempLimitC.toStringAsFixed(0)}°C '
                'threshold and still warming at '
                '+${trend.toStringAsFixed(1)} °C/min. Improve airflow '
                'or reduce load immediately.',
          ));
        } else {
          // Guard against division by ~0 even though trend > 0.5 here.
          final double safeTrend = trend > 0.1 ? trend : 0.1;
          final int minutes = ((tempLimitC - current) / safeTrend).round();
          insights.add(Insight(
            kind: InsightKind.prediction,
            icon: Icons.thermostat,
            color: minutes < 5 ? red : amber,
            urgent: minutes < 5,
            stationId: twin.id,
            stationName: twin.name,
            category: twin.station.category,
            title: '${twin.id} will reach '
                '${tempLimitC.toStringAsFixed(0)}°C in ~$minutes min',
            detail: 'CPU is warming at +${trend.toStringAsFixed(1)} °C/min '
                '(current: ${current.toStringAsFixed(0)}°C). Improve '
                'airflow or reduce load.',
          ));
        }
      }

      // 2. Network forecast.
      if (twin.latencySustainedAbove(100, count: 5)) {
        insights.add(Insight(
          kind: InsightKind.prediction,
          icon: Icons.wifi_tethering,
          color: amber,
          stationId: twin.id,
          stationName: twin.name,
          category: twin.station.category,
          title: '${twin.id} latency trending high — congestion likely '
              'within 10 min',
          detail: 'Latency has stayed above 100 ms for the last 5 readings '
              '(now ${twin.network.latencyMs.toStringAsFixed(0)} ms). '
              'Check the network uplink or throttle background traffic.',
        ));
      }

      // 4. Maintenance forecast: average CPU temp over history > 70°C.
      if (twin.history.isNotEmpty) {
        double sum = 0;
        for (final snapshot in twin.history) {
          sum += snapshot.hardware.cpuTemp;
        }
        final double average = sum / twin.history.length;
        if (average > 70) {
          insights.add(Insight(
            kind: InsightKind.prediction,
            icon: Icons.cleaning_services_outlined,
            color: amber,
            stationId: twin.id,
            stationName: twin.name,
            category: twin.station.category,
            title: '${twin.id} runs hot on average — schedule fan '
                'cleaning within 3 days',
            detail: 'Mean CPU temperature over the last '
                '${twin.history.length} readings is '
                '${average.toStringAsFixed(0)}°C — dust buildup is the '
                'likely cause.',
          ));
        }
      }
    }

    // 3. Occupancy forecast.
    if (total > 0) {
      if (occupancyRatio > 0.7) {
        insights.add(const Insight(
          kind: InsightKind.prediction,
          icon: Icons.groups_outlined,
          color: amber,
          title: 'Approaching full capacity — prepare spare stations',
          detail: 'More than 70% of stations are occupied. Get spare '
              'stations ready and brief staff on seating walk-ins.',
        ));
      } else if (occupancyRatio < 0.2) {
        insights.add(const Insight(
          kind: InsightKind.prediction,
          icon: Icons.build_outlined,
          color: green,
          title: 'Quiet period — good time for maintenance windows',
          detail: 'Less than 20% of stations are occupied. A safe window '
              'for updates, fan cleaning and cable checks.',
        ));
      }
    }

    return insights;
  }
}
