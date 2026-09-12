import 'package:flutter/material.dart';

import '../models/station.dart';

/// Low-saturation status colors used across the whole dashboard.
class StatusColors {
  StatusColors._();

  static const Color normal = Color(0xFF58A16C);
  static const Color warning = Color(0xFFD9A441);
  static const Color critical = Color(0xFFCC5148);

  static Color forStatus(StationStatus status) {
    switch (status) {
      case StationStatus.normal:
        return normal;
      case StationStatus.warning:
        return warning;
      case StationStatus.critical:
        return critical;
    }
  }
}

/// A small pill showing a station's health status (dot + label).
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status});

  final StationStatus status;

  String get _label {
    switch (status) {
      case StationStatus.normal:
        return 'Normal';
      case StationStatus.warning:
        return 'Warning';
      case StationStatus.critical:
        return 'Critical';
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color color = StatusColors.forStatus(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            _label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
