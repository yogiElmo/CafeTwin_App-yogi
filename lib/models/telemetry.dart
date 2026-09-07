/// Immutable telemetry readings produced by the simulation engine each tick.

/// Hardware sensors for one station at one point in time.
class HardwareReading {
  const HardwareReading({
    required this.cpuTemp,
    required this.gpuTemp,
    required this.cpuLoad,
    required this.gpuLoad,
  });

  /// CPU die temperature in degrees Celsius.
  final double cpuTemp;

  /// GPU die temperature in degrees Celsius.
  final double gpuTemp;

  /// CPU utilization, 0-100 percent.
  final double cpuLoad;

  /// GPU utilization, 0-100 percent.
  final double gpuLoad;

  HardwareReading copyWith({
    double? cpuTemp,
    double? gpuTemp,
    double? cpuLoad,
    double? gpuLoad,
  }) {
    return HardwareReading(
      cpuTemp: cpuTemp ?? this.cpuTemp,
      gpuTemp: gpuTemp ?? this.gpuTemp,
      cpuLoad: cpuLoad ?? this.cpuLoad,
      gpuLoad: gpuLoad ?? this.gpuLoad,
    );
  }
}

/// Network sensors for one station at one point in time.
class NetworkReading {
  const NetworkReading({
    required this.bandwidthMbps,
    required this.latencyMs,
    required this.packetLoss,
  });

  /// Observed throughput in Mbps (link capacity is 1000 Mbps).
  final double bandwidthMbps;

  /// Round-trip latency in milliseconds.
  final double latencyMs;

  /// Packet loss in percent, 0-100.
  final double packetLoss;

  NetworkReading copyWith({
    double? bandwidthMbps,
    double? latencyMs,
    double? packetLoss,
  }) {
    return NetworkReading(
      bandwidthMbps: bandwidthMbps ?? this.bandwidthMbps,
      latencyMs: latencyMs ?? this.latencyMs,
      packetLoss: packetLoss ?? this.packetLoss,
    );
  }
}

/// Customer session state for one station.
class SessionInfo {
  const SessionInfo({
    this.occupied = false,
    this.sessionMinutes = 0,
    this.game = '',
  });

  /// An unoccupied station with no running game.
  static const SessionInfo empty = SessionInfo();

  /// Whether a customer is currently seated at the station.
  final bool occupied;

  /// Elapsed session length in simulated minutes (1 engine tick = 1 minute).
  final int sessionMinutes;

  /// Title of the game being played, empty when unoccupied.
  final String game;

  SessionInfo copyWith({bool? occupied, int? sessionMinutes, String? game}) {
    return SessionInfo(
      occupied: occupied ?? this.occupied,
      sessionMinutes: sessionMinutes ?? this.sessionMinutes,
      game: game ?? this.game,
    );
  }
}

/// A full per-station telemetry sample kept in the twin's rolling history.
class TelemetrySnapshot {
  const TelemetrySnapshot({
    required this.timestamp,
    required this.hardware,
    required this.network,
    required this.session,
  });

  /// Wall-clock time the snapshot was recorded.
  final DateTime timestamp;

  final HardwareReading hardware;
  final NetworkReading network;
  final SessionInfo session;
}
