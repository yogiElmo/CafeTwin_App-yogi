import 'package:flutter/material.dart';

import '../models/alert.dart';
import '../services/digital_twin.dart';
import '../state/cafe_state.dart';
import '../widgets/alert_tile.dart';
import '../widgets/monitor_illustration.dart';
import '../widgets/sparkline_chart.dart';
import '../widgets/status_badge.dart';
import '../widgets/temp_gauge.dart';

/// Screen 2: live detail view of one station — header + status, four radial
/// gauges, latency/bandwidth sparkline, session card with "End Session",
/// and recent alerts. Rebuilds on every engine tick via [AnimatedBuilder].
class StationDetailScreen extends StatelessWidget {
  const StationDetailScreen({
    super.key,
    required this.state,
    required this.stationId,
  });

  final CafeState state;
  final String stationId;

  static String _fmtDuration(int minutes) {
    final int h = minutes ~/ 60;
    final int m = minutes % 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (BuildContext context, Widget? child) {
        final StationTwin twin = state.twinFor(stationId);
        final List<Alert> recentAlerts =
            state.alertsFor(stationId).take(5).toList();
        final List<Alert> activeAlerts = state.activeAlertsFor(stationId);
        final Color muted =
            Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);

        return Scaffold(
          appBar: AppBar(title: Text(twin.name)),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              // Header: name + status badge, monitor illustration aside.
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          twin.name,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          twin.id,
                          style: TextStyle(fontSize: 13, color: muted),
                        ),
                        const SizedBox(height: 10),
                        StatusBadge(status: state.statusFor(stationId)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  MonitorIllustration(
                    status: state.statusFor(stationId),
                    occupied: twin.session.occupied,
                    size: 110,
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Four radial gauges.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: TempGauge(
                      label: 'CPU Temp',
                      value: twin.hardware.cpuTemp,
                      unit: '°C',
                    ),
                  ),
                  Expanded(
                    child: TempGauge(
                      label: 'GPU Temp',
                      value: twin.hardware.gpuTemp,
                      unit: '°C',
                    ),
                  ),
                  Expanded(
                    child: TempGauge(
                      label: 'CPU Load',
                      value: twin.hardware.cpuLoad,
                      unit: '%',
                    ),
                  ),
                  Expanded(
                    child: TempGauge(
                      label: 'GPU Load',
                      value: twin.hardware.gpuLoad,
                      unit: '%',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Network sparkline.
              _sectionTitle(context, 'NETWORK — RECENT HISTORY'),
              const SizedBox(height: 8),
              Card(
                margin: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Loss ${twin.network.packetLoss.toStringAsFixed(1)}% · '
                        'Link ${(twin.bandwidthUtilization * 100.0).toStringAsFixed(0)}% of 1000 Mbps',
                        style: TextStyle(fontSize: 12, color: muted),
                      ),
                      const SizedBox(height: 8),
                      SparklineChart(
                        series: <ChartSeries>[
                          ChartSeries(
                            name: 'Latency',
                            color: StatusColors.warning,
                            values: twin.latencySeries,
                            unit: 'ms',
                          ),
                          ChartSeries(
                            name: 'Bandwidth',
                            color: const Color(0xFF6E9BC5),
                            values: twin.bandwidthSeries,
                            unit: 'Mbps',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Session card.
              _sectionTitle(context, 'SESSION'),
              const SizedBox(height: 8),
              Card(
                margin: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.sports_esports,
                        color: twin.session.occupied
                            ? Theme.of(context).colorScheme.primary
                            : muted,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              twin.session.occupied
                                  ? twin.session.game
                                  : 'No active session',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              twin.session.occupied
                                  ? 'Duration ${_fmtDuration(twin.session.sessionMinutes)}'
                                  : 'Station is available',
                              style: TextStyle(fontSize: 12, color: muted),
                            ),
                          ],
                        ),
                      ),
                      ElevatedButton(
                        onPressed: twin.session.occupied
                            ? () => state.endSession(stationId)
                            : null,
                        child: const Text('End Session'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Recommended actions from this station's active alerts.
              _sectionTitle(context, 'RECOMMENDED ACTIONS'),
              const SizedBox(height: 8),
              Card(
                margin: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: activeAlerts.isEmpty
                      ? Row(
                          children: <Widget>[
                            const Icon(
                              Icons.check_circle_outline,
                              size: 18,
                              color: StatusColors.normal,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'All good — no actions needed.',
                                style: TextStyle(fontSize: 13, color: muted),
                              ),
                            ),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            for (final Alert alert in activeAlerts)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    const Padding(
                                      padding: EdgeInsets.only(top: 1),
                                      child: Icon(
                                        Icons.lightbulb_outline,
                                        size: 15,
                                        color: StatusColors.warning,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        alert.suggestion,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          height: 1.35,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 20),

              // Recent alerts for this station.
              _sectionTitle(context, 'RECENT ALERTS'),
              const SizedBox(height: 8),
              if (recentAlerts.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No alerts yet for this station.',
                    style: TextStyle(fontSize: 13, color: muted),
                  ),
                )
              else
                for (final Alert alert in recentAlerts)
                  AlertTile(
                    alert: alert,
                    onTap: () => state.acknowledge(alert.id),
                  ),
            ],
          ),
        );
      },
    );
  }
}
