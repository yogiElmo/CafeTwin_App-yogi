import '../models/station.dart';
import '../models/telemetry.dart';

/// Layer 3: per-station digital twin.
///
/// Holds the station's current hardware / network / session state plus a
/// rolling history of the last [historyCapacity] snapshots used for moving
/// averages and trends.
///
/// Time compression: the engine ticks every 2 real seconds, and each tick
/// represents one simulated minute, so per-tick slopes are per-minute rates.
class StationTwin {
  StationTwin({required this.station})
      : hardware = const HardwareReading(
          cpuTemp: 40.0,
          gpuTemp: 36.0,
          cpuLoad: 5.0,
          gpuLoad: 2.0,
        ),
        network = const NetworkReading(
          bandwidthMbps: 15.0,
          latencyMs: 24.0,
          packetLoss: 0.0,
        ),
        session = SessionInfo.empty;

  /// Number of snapshots retained in [history].
  static const int historyCapacity = 100;

  /// Station network link capacity used for utilization calculations.
  static const double bandwidthCapacityMbps = 1000.0;

  final Station station;

  HardwareReading hardware;
  NetworkReading network;
  SessionInfo session;

  /// Rolling list of the most recent snapshots, oldest first.
  final List<TelemetrySnapshot> history = <TelemetrySnapshot>[];

  /// Consecutive ticks where the station was occupied but the GPU was idle.
  int _ghostTicks = 0;

  String get id => station.id;
  String get name => station.name;

  void updateHardware(HardwareReading reading) {
    hardware = reading;
  }

  void updateNetwork(NetworkReading reading) {
    network = reading;
  }

  void updateSession(SessionInfo info) {
    session = info;
  }

  /// Records the current state as a snapshot and maintains derived counters.
  void recordSnapshot(DateTime timestamp) {
    if (session.occupied && hardware.gpuLoad < 5.0) {
      _ghostTicks++;
    } else {
      _ghostTicks = 0;
    }
    history.add(TelemetrySnapshot(
      timestamp: timestamp,
      hardware: hardware,
      network: network,
      session: session,
    ));
    if (history.length > historyCapacity) {
      history.removeAt(0);
    }
  }

  /// CPU temperature trend in °C per simulated minute, computed as the slope
  /// across the most recent window of up to 10 snapshots (1 tick = 1 minute).
  double cpuTempTrend() {
    const int window = 10;
    if (history.length < 2) {
      return 0.0;
    }
    final int count = history.length < window ? history.length : window;
    final double first = history[history.length - count].hardware.cpuTemp;
    final double last = history.last.hardware.cpuTemp;
    return (last - first) / (count - 1);
  }

  /// True when every one of the last [count] latency readings exceeded
  /// [thresholdMs].
  bool latencySustainedAbove(double thresholdMs, {int count = 6}) {
    if (history.length < count) {
      return false;
    }
    for (int i = history.length - count; i < history.length; i++) {
      if (history[i].network.latencyMs <= thresholdMs) {
        return false;
      }
    }
    return true;
  }

  /// Bandwidth utilization as a fraction (0.0 - 1.0) of link capacity.
  double get bandwidthUtilization =>
      network.bandwidthMbps / bandwidthCapacityMbps;

  /// Simulated minutes the station has been occupied with GPU load under 5%.
  int get ghostMinutes => _ghostTicks;

  /// Frees the station: clears occupancy, game, and session timer.
  void endSession() {
    session = SessionInfo.empty;
  }

  /// Latency history in ms, oldest first (for charts).
  List<double> get latencySeries =>
      history.map((TelemetrySnapshot s) => s.network.latencyMs).toList();

  /// Bandwidth history in Mbps, oldest first (for charts).
  List<double> get bandwidthSeries =>
      history.map((TelemetrySnapshot s) => s.network.bandwidthMbps).toList();
}
