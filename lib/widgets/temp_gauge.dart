import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'status_badge.dart';

/// A radial gauge drawn with [CustomPainter] (no chart packages).
///
/// Shows [value] on a [min]..[max] scale as a 270° arc. The arc color shifts
/// green -> amber -> red as the fraction of the scale rises past 60% / 85%.
class TempGauge extends StatelessWidget {
  const TempGauge({
    super.key,
    required this.label,
    required this.value,
    this.min = 0.0,
    this.max = 100.0,
    this.unit = '°C',
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String unit;

  double get _fraction {
    if (max <= min) {
      return 0.0;
    }
    final double f = (value - min) / (max - min);
    return f < 0.0 ? 0.0 : (f > 1.0 ? 1.0 : f);
  }

  Color get _color {
    final double f = _fraction;
    if (f < 0.60) {
      return StatusColors.normal;
    }
    if (f < 0.85) {
      return StatusColors.warning;
    }
    return StatusColors.critical;
  }

  String get _valueText =>
      unit == '%' ? value.toStringAsFixed(0) : value.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final Color muted = Theme.of(context).colorScheme.onSurface.withOpacity(0.55);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double size = constraints.hasBoundedWidth
            ? math.min(constraints.maxWidth, 110.0)
            : 96.0;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: size,
              height: size * 0.86,
              child: Stack(
                children: <Widget>[
                  CustomPaint(
                    size: Size(size, size * 0.86),
                    painter: _GaugePainter(
                      fraction: _fraction,
                      color: _color,
                    ),
                  ),
                  Positioned.fill(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            _valueText,
                            style: TextStyle(
                              fontSize: math.max(size * 0.20, 13.0),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            unit,
                            style: TextStyle(fontSize: 10, color: muted),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: muted),
            ),
          ],
        );
      },
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({required this.fraction, required this.color});

  final double fraction;
  final Color color;

  static const double _startAngle = math.pi * 0.75; // 135°, lower-left
  static const double _sweepAngle = math.pi * 1.5; // 270°, gap at bottom

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = math.min(size.width, size.height) / 2 - 7.0;
    final Rect rect = Rect.fromCircle(center: center, radius: radius);

    final Paint track = Paint()
      ..color = const Color(0x1FFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9.0
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, _startAngle, _sweepAngle, false, track);

    if (fraction > 0.0) {
      final Paint arc = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9.0
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, _startAngle, _sweepAngle * fraction, false, arc);
    }
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) {
    return oldDelegate.fraction != fraction || oldDelegate.color != color;
  }
}
