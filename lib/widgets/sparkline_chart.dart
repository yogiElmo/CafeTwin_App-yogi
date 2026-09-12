import 'dart:math' as math;

import 'package:flutter/material.dart';

/// One named line on a [SparklineChart].
class ChartSeries {
  const ChartSeries({
    required this.name,
    required this.color,
    required this.values,
    required this.unit,
  });

  final String name;
  final Color color;

  /// Oldest-first samples; each series is normalized to its own min/max.
  final List<double> values;
  final String unit;
}

/// A multi-series line chart drawn with [CustomPainter] (no chart packages).
///
/// Used for latency + bandwidth over the station's recent history.
class SparklineChart extends StatelessWidget {
  const SparklineChart({super.key, required this.series, this.height = 150});

  final List<ChartSeries> series;
  final double height;

  @override
  Widget build(BuildContext context) {
    final Color muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(painter: _SparklinePainter(series)),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: <Widget>[
            for (final ChartSeries s in series)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: 8,
                    height: 8,
                    decoration:
                        BoxDecoration(color: s.color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    s.values.isEmpty
                        ? '${s.name} —'
                        : '${s.name} ${s.values.last.toStringAsFixed(0)} ${s.unit}',
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.series);

  final List<ChartSeries> series;

  static const double _padX = 6.0;
  static const double _padY = 10.0;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint grid = Paint()
      ..color = const Color(0x14FFFFFF)
      ..strokeWidth = 1.0;
    for (int i = 1; i <= 3; i++) {
      final double y = size.height * i / 4.0;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    for (final ChartSeries s in series) {
      if (s.values.length < 2) {
        continue;
      }
      final double lo = s.values.reduce(math.min);
      double hi = s.values.reduce(math.max);
      if (hi - lo < 1e-9) {
        hi = lo + 1.0;
      }

      final Paint line = Paint()
        ..color = s.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;

      double xFor(int i) =>
          _padX + (size.width - 2 * _padX) * i / (s.values.length - 1);
      double yFor(double v) {
        final double norm = (v - lo) / (hi - lo);
        return size.height - _padY - norm * (size.height - 2 * _padY);
      }

      final Path path = Path();
      for (int i = 0; i < s.values.length; i++) {
        final double x = xFor(i);
        final double y = yFor(s.values[i]);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, line);

      final Paint dot = Paint()..color = s.color;
      canvas.drawCircle(
        Offset(xFor(s.values.length - 1), yFor(s.values.last)),
        3.0,
        dot,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) => true;
}
