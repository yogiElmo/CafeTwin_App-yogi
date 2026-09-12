import 'package:flutter/material.dart';

import '../models/alert.dart';
import 'status_badge.dart';

/// One row in the alert feed: severity color edge, rule code, station,
/// message, recommended action (suggestion) and time. Unacknowledged alerts
/// are emphasized; acknowledged or auto-resolved alerts are dimmed and show
/// a check icon.
class AlertTile extends StatelessWidget {
  const AlertTile({super.key, required this.alert, this.onTap});

  final Alert alert;
  final VoidCallback? onTap;

  static String _fmtTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final Color severityColor = alert.severity == AlertSeverity.critical
        ? StatusColors.critical
        : StatusColors.warning;
    final bool dimmed = alert.acknowledged || alert.resolved;
    final Color muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);

    final List<String> lifecycle = <String>[
      if (alert.acknowledged) 'Acknowledged',
      if (alert.resolved) 'Auto-resolved',
    ];

    return Opacity(
      opacity: dimmed ? 0.5 : 1.0,
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Container(width: 4, color: severityColor),
              Expanded(
                child: InkWell(
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Text(
                              alert.ruleCode,
                              style: TextStyle(
                                color: severityColor,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              alert.stationId,
                              style: TextStyle(fontSize: 12, color: muted),
                            ),
                            const Spacer(),
                            Text(
                              _fmtTime(alert.timestamp),
                              style: TextStyle(fontSize: 11, color: muted),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          alert.message,
                          style: const TextStyle(fontSize: 13, height: 1.35),
                        ),
                        if (alert.suggestion.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: StatusColors.warning.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: StatusColors.warning.withValues(alpha: 0.35),
                              ),
                            ),
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
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    alert.suggestion,
                                    style: TextStyle(
                                      fontSize: 12,
                                      height: 1.3,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.85),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        if (lifecycle.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 6),
                          Text(
                            lifecycle.join(' · '),
                            style: TextStyle(fontSize: 11, color: muted),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (alert.acknowledged || alert.resolved)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Center(
                    child: Icon(
                      alert.acknowledged
                          ? Icons.check_circle
                          : Icons.check_circle_outline,
                      size: 18,
                      color: alert.acknowledged ? StatusColors.normal : muted,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
