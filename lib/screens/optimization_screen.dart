import 'package:flutter/material.dart';

import '../models/insight.dart';
import '../services/digital_twin.dart';
import '../services/insights_engine.dart';
import '../state/cafe_state.dart';

/// Business-intelligence screen: live cost-optimization recommendations
/// computed from the current state of the station twins.
///
/// The recommendations come from [InsightsEngine] (the same computation that
/// feeds the persistent session record) and re-render inside an
/// [AnimatedBuilder] on every engine tick. The whole page is ONE scrollable
/// ListView — nothing hides below an inner scroll fold.
class OptimizationScreen extends StatelessWidget {
  const OptimizationScreen({super.key, required this.state});

  final CafeState state;

  static const Color _amber = Color(0xFFD9A441);
  static const Color _green = Color(0xFF58A16C);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cost Optimization')),
      body: AnimatedBuilder(
        animation: state,
        builder: (BuildContext context, Widget? child) {
          final List<StationTwin> twins = state.stationList;
          final int occupied =
              twins.where((StationTwin t) => t.session.occupied).length;
          final int idle = twins.length - occupied;
          final double dailySavings = InsightsEngine.savingsPerDay(idle);

          final List<Insight> insights =
              InsightsEngine.optimizationsFor(state);

          final List<Widget> recommendations = <Widget>[
            for (final Insight insight in insights)
              _recommendationCard(
                context,
                icon: insight.icon,
                title: insight.title,
                explanation: insight.detail,
                impact: insight.impact,
              ),
          ];

          final bool efficient = recommendations.length == 1; // only the tip

          return ListView(
            padding: const EdgeInsets.all(12),
            children: <Widget>[
              _heroCard(context, idle, dailySavings),
              const SizedBox(height: 12),
              if (efficient) ...<Widget>[
                _efficientCard(context),
                const SizedBox(height: 12),
              ],
              for (int i = 0; i < recommendations.length; i++) ...<Widget>[
                recommendations[i],
                if (i < recommendations.length - 1)
                  const SizedBox(height: 12),
              ],
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------- widgets

  Widget _heroCard(BuildContext context, int idle, double dailySavings) {
    final Color muted =
        Theme.of(context).colorScheme.onSurface.withOpacity(0.55);
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: _amber.withOpacity(0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'ESTIMATED SAVINGS',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: _amber.withOpacity(0.9),
                letterSpacing: 1.6,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '\$${dailySavings.toStringAsFixed(2)} / day',
              style: const TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w800,
                color: _amber,
                height: 1.1,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              idle > 0
                  ? 'by powering down $idle idle '
                      'station${idle == 1 ? '' : 's'}'
                  : 'by powering down idle stations',
              style: TextStyle(fontSize: 13, color: muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _efficientCard(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: _green.withOpacity(0.35)),
      ),
      child: const Padding(
        padding: EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            Icon(Icons.check_circle_outline, color: _green, size: 22),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Your café is running efficiently.',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _green,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _recommendationCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String explanation,
    required String impact,
  }) {
    final Color onSurface = Theme.of(context).colorScheme.onSurface;
    final Color muted = onSurface.withOpacity(0.55);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: _amber.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: _amber, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: onSurface.withOpacity(0.9),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    explanation,
                    style: TextStyle(fontSize: 12.5, height: 1.35, color: muted),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: _amber.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: _amber.withOpacity(0.30)),
                    ),
                    child: Text(
                      impact,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: _amber,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
