import 'package:flutter/material.dart';

import '../models/alert.dart';
import '../state/cafe_state.dart';
import '../widgets/alert_tile.dart';

/// Screen 3: filterable alert feed (All | Hardware | Network | Utilization),
/// newest first. Tapping an alert acknowledges it.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key, required this.state});

  final CafeState state;

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  /// null = All categories.
  AlertCategory? _filter;

  Widget _chip(String label, AlertCategory? category) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: _filter == category,
        onSelected: (bool selected) {
          setState(() => _filter = category);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (BuildContext context, Widget? child) {
        final List<Alert> all = widget.state.alerts;
        final List<Alert> filtered = _filter == null
            ? all
            : all.where((Alert a) => a.category == _filter).toList();
        final Color muted =
            Theme.of(context).colorScheme.onSurface.withOpacity(0.55);

        return Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: <Widget>[
                    _chip('All', null),
                    _chip('Hardware', AlertCategory.hardware),
                    _chip('Network', AlertCategory.network),
                    _chip('Utilization', AlertCategory.utilization),
                  ],
                ),
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        'No alerts match this filter.',
                        style: TextStyle(fontSize: 13, color: muted),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: filtered.length,
                      itemBuilder: (BuildContext context, int index) {
                        final Alert alert = filtered[index];
                        return AlertTile(
                          alert: alert,
                          onTap: () => widget.state.acknowledge(alert.id),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
