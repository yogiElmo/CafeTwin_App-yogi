import 'package:flutter/material.dart';

import '../models/insight.dart';
import '../services/insights_engine.dart';
import '../state/cafe_state.dart';

/// Business-intelligence screen: predictive forecasts computed from each
/// station's live twin history (trend analysis over recent readings).
///
/// The forecasts come from [InsightsEngine] (the same computation that feeds
/// the persistent session record) and re-render inside an [AnimatedBuilder]
/// on every engine tick. The whole page is ONE scrollable ListView — no
/// hidden scroll folds.
class PredictiveScreen extends StatelessWidget {
  const PredictiveScreen({super.key, required this.state});

  final CafeState state;

  static const Color _amber = Color(0xFFD9A441);
  static const Color _green = Color(0xFF58A16C);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Predictive Analysis')),
      body: AnimatedBuilder(
        animation: state,
        builder: (BuildContext context, Widget? child) {
          final List<Insight> forecasts =
              InsightsEngine.predictionsFor(state);

          return ListView(
            padding: const EdgeInsets.all(12),
            children: <Widget>[
              _explainerCard(context),
              const SizedBox(height: 12),
              if (forecasts.isEmpty)
                _healthyCard(context)
              else
                for (int i = 0; i < forecasts.length; i++) ...<Widget>[
                  _forecastCard(context, forecasts[i]),
                  if (i < forecasts.length - 1) const SizedBox(height: 12),
                ],
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------- widgets

  Widget _explainerCard(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Icon(Icons.info_outline, color: _amber, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Forecasts are computed from each station\'s live twin '
                'history (trend analysis over the last readings).',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color:
                      Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.85),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _healthyCard(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: _green.withValues(alpha: 0.35)),
      ),
      child: const Padding(
        padding: EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            Icon(Icons.check_circle_outline, color: _green, size: 22),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'No risks predicted — all stations healthy.',
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

  Widget _forecastCard(BuildContext context, Insight forecast) {
    final Color onSurface = Theme.of(context).colorScheme.onSurface;
    final Color muted = onSurface.withValues(alpha: 0.55);
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: forecast.color.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: forecast.color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(forecast.icon, color: forecast.color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    forecast.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: onSurface.withValues(alpha: 0.9),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    forecast.detail,
                    style: TextStyle(fontSize: 12.5, height: 1.35, color: muted),
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
