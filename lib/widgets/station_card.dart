import 'package:flutter/material.dart';

import '../models/station.dart';
import '../services/digital_twin.dart';
import 'monitor_illustration.dart';
import 'status_badge.dart';

/// One tile in the station grid: name, status dot + label, mini metrics
/// (CPU temp, GPU temp, latency) and the occupancy label. When the station
/// has active alerts, a lightbulb hint shows how many actions are suggested.
class StationCard extends StatelessWidget {
  const StationCard({
    super.key,
    required this.twin,
    required this.status,
    required this.onTap,
    this.suggestedActionCount = 0,
  });

  final StationTwin twin;
  final StationStatus status;
  final VoidCallback onTap;

  /// Number of active, unacknowledged alerts with a suggested action.
  final int suggestedActionCount;

  String get _statusLabel {
    switch (status) {
      case StationStatus.normal:
        return 'Normal';
      case StationStatus.warning:
        return 'Warning';
      case StationStatus.critical:
        return 'Critical';
    }
  }

  Widget _metric(IconData icon, String text, Color muted) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 13, color: muted),
        const SizedBox(width: 3),
        Text(text, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final Color statusColor = StatusColors.forStatus(status);
    final Color muted = Theme.of(context).colorScheme.onSurface.withOpacity(0.55);
    final bool occupied = twin.session.occupied;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        // Very subtle status-tinted border glow; keeps the warm,
        // low-saturation look while hinting at station health.
        side: BorderSide(color: statusColor.withOpacity(0.30)),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Center(
                child: MonitorIllustration(
                  status: status,
                  occupied: occupied,
                  size: 72,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      twin.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    _statusLabel,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: statusColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                twin.station.category,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.55),
                ),
              ),
              const Spacer(),
              Row(
                children: <Widget>[
                  _metric(
                    Icons.thermostat,
                    '${twin.hardware.cpuTemp.toStringAsFixed(0)}°',
                    muted,
                  ),
                  const SizedBox(width: 12),
                  _metric(
                    Icons.memory,
                    '${twin.hardware.gpuTemp.toStringAsFixed(0)}°',
                    muted,
                  ),
                  const SizedBox(width: 12),
                  _metric(
                    Icons.wifi,
                    '${twin.network.latencyMs.toStringAsFixed(0)}ms',
                    muted,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                occupied ? 'In use · ${twin.session.game}' : 'Available',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: occupied
                      ? Theme.of(context).colorScheme.onSurface
                      : muted,
                ),
              ),
              if (suggestedActionCount > 0) ...<Widget>[
                const SizedBox(height: 4),
                Row(
                  children: <Widget>[
                    const Icon(
                      Icons.lightbulb_outline,
                      size: 12,
                      color: StatusColors.warning,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '$suggestedActionCount '
                        'action${suggestedActionCount == 1 ? '' : 's'} '
                        'suggested',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: StatusColors.warning,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
