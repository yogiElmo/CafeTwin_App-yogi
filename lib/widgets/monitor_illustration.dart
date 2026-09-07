import 'package:flutter/material.dart';

import '../models/station.dart';
import 'status_badge.dart';

/// A minimal, elegant desktop-monitor illustration drawn with
/// [CustomPainter] (no image assets, no packages).
///
/// The screen carries a subtle radial glow tinted by the station's
/// [StationStatus] color plus a tiny heartbeat pulse line, so station
/// health stays visible even in the illustration. Idle stations render
/// a dimmer screen than occupied ones.
class MonitorIllustration extends StatelessWidget {
  const MonitorIllustration({
    super.key,
    required this.status,
    this.occupied = true,
    this.size = 80,
  });

  /// Station health status — tints the screen glow and pulse line.
  final StationStatus status;

  /// Whether a session is active; idle stations get a dimmer screen.
  final bool occupied;

  /// Height of the whole illustration (screen + stand + base), in px.
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: size,
      width: size * 1.28,
      child: CustomPaint(
        painter: _MonitorPainter(status: status, occupied: occupied),
      ),
    );
  }
}

class _MonitorPainter extends CustomPainter {
  const _MonitorPainter({required this.status, required this.occupied});

  final StationStatus status;
  final bool occupied;

  static const Color _warmGrey = Color(0xFF3A352F);
  static const Color _bezelFill = Color(0xFF221E1A);
  static const Color _screenFill = Color(0xFF16130F);
  static const Color _telemetry = Color(0xFF8A8075);

  @override
  void paint(Canvas canvas, Size size) {
    final Color statusColor = StatusColors.forStatus(status);
    final double w = size.width;
    final double h = size.height;

    final double screenH = h * 0.78;
    final Rect bezelRect = Rect.fromLTWH(0.5, 0.5, w - 1.0, screenH - 1.0);
    final double bezelRadius = h * 0.06;
    final RRect bezel =
        RRect.fromRectAndRadius(bezelRect, Radius.circular(bezelRadius));

    // --- Stand (drawn first so the bezel overlaps its top edge). ---
    final double standTopY = screenH - 2.0;
    final double standBottomY = h * 0.90;
    final Path stand = Path()
      ..moveTo(w * 0.5 - w * 0.055, standTopY)
      ..lineTo(w * 0.5 + w * 0.055, standTopY)
      ..lineTo(w * 0.5 + w * 0.075, standBottomY)
      ..lineTo(w * 0.5 - w * 0.075, standBottomY)
      ..close();
    canvas.drawPath(stand, Paint()..color = _warmGrey);

    // --- Base. ---
    final double baseH = h * 0.055;
    final RRect base = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(w * 0.5, h - baseH / 2 - 0.5),
        width: w * 0.36,
        height: baseH,
      ),
      Radius.circular(baseH / 2),
    );
    canvas.drawRRect(base, Paint()..color = _warmGrey);

    // --- Bezel: thin warm-grey outline around a dark body. ---
    canvas.drawRRect(bezel, Paint()..color = _bezelFill);
    final Paint bezelStroke = Paint()
      ..color = _warmGrey
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawRRect(bezel, bezelStroke);

    // --- Screen panel: very dark warm tone + status-tinted glow. ---
    final Rect screenRect = bezelRect.deflate(h * 0.045);
    final RRect screen = RRect.fromRectAndRadius(
      screenRect,
      Radius.circular(bezelRadius * 0.7),
    );
    canvas.drawRRect(screen, Paint()..color = _screenFill);

    final Paint glow = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0, -0.15),
        radius: 0.85,
        colors: <Color>[
          statusColor.withOpacity(occupied ? 0.30 : 0.14),
          statusColor.withOpacity(0.0),
        ],
      ).createShader(screenRect);
    canvas.drawRRect(screen, glow);

    // --- Tiny dim telemetry rows near the top-left of the screen. ---
    final Paint line = Paint()
      ..color = _telemetry.withOpacity(0.28)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    final double lineLeft = screenRect.left + screenRect.width * 0.12;
    double lineY = screenRect.top + screenRect.height * 0.18;
    final double lineStep = screenRect.height * 0.13;
    for (final double fraction in <double>[0.40, 0.28, 0.34]) {
      canvas.drawLine(
        Offset(lineLeft, lineY),
        Offset(lineLeft + screenRect.width * fraction, lineY),
        line,
      );
      lineY += lineStep;
    }

    // --- Minimal heartbeat pulse in the status color. ---
    final double baseY = screenRect.top + screenRect.height * 0.68;
    final double x0 = screenRect.left + screenRect.width * 0.14;
    final double x1 = screenRect.right - screenRect.width * 0.14;
    final double span = x1 - x0;
    final double amp = screenRect.height * 0.15;
    final Path pulse = Path()
      ..moveTo(x0, baseY)
      ..lineTo(x0 + span * 0.28, baseY)
      ..lineTo(x0 + span * 0.38, baseY - amp * 0.6)
      ..lineTo(x0 + span * 0.48, baseY + amp)
      ..lineTo(x0 + span * 0.56, baseY - amp * 0.25)
      ..lineTo(x0 + span * 0.64, baseY)
      ..lineTo(x1, baseY);
    final Paint pulsePaint = Paint()
      ..color = statusColor.withOpacity(occupied ? 0.75 : 0.40)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(pulse, pulsePaint);
  }

  @override
  bool shouldRepaint(covariant _MonitorPainter oldDelegate) =>
      oldDelegate.status != status || oldDelegate.occupied != occupied;
}
