import 'dart:async';
import 'dart:math';

import '../models/station.dart';
import '../models/telemetry.dart';
import 'digital_twin.dart';

/// Types of injected faults used to exercise the alerting rules.
enum _Anomaly { none, thermalSpike, latencyBurst, bandwidthSurge }

/// Mutable per-station simulation state kept privately by the engine.
class _StationSim {
  StationMode mode = StationMode.idle;
  _Anomaly anomaly = _Anomaly.none;
  int anomalyTicksLeft = 0;
}

/// Layer 1 + 2: realistic telemetry simulator.
///
/// A [Timer.periodic] ticks every [tickInterval] (2 real seconds = 1 simulated
/// minute). Each tick, every station:
///  - performs a Markov-style mode transition (idle/gaming/streaming/stress),
///  - drifts its temperatures and loads toward mode-dependent targets with
///    noise,
///  - may start or continue an injected anomaly (thermal spike, latency
///    burst, bandwidth surge) so that alerts visibly fire within the first
///    minute or two of running,
///  - may gain or lose a customer session (Poisson-like arrivals).
///
/// The engine also exposes a small control-room API: [pause]/[resume],
/// [setSpeed], one-tap scenario injection ([injectOverheat],
/// [injectPeakHour], [injectNetworkSurge], [injectCalmAfternoon]) and an
/// [onEvent] callback that reports human-readable transitions for the live
/// simulation log.
class SimulationEngine {
  SimulationEngine({required List<StationTwin> twins, this.onTick})
      : _twins = twins {
    for (final StationTwin twin in _twins) {
      _sim[twin.id] = _StationSim();
    }
    _seed();
  }

  static const Duration tickInterval = Duration(seconds: 2);

  static const List<String> _games = <String>[
    'Cyber Arena 6',
    'Starfall Online',
    'Rocket League',
    'Valor Rush',
    'Elden Realms',
    'CraftWorld',
    'Apex Strike',
    'Dota Legends',
  ];

  final List<StationTwin> _twins;
  final Map<String, _StationSim> _sim = <String, _StationSim>{};
  final Random _random = Random();
  Timer? _timer;
  bool _paused = false;
  bool _disposed = false;
  int _speed = 1;

  /// Called after each tick once all twins have been updated.
  final void Function()? onTick;

  /// Called with a short human-readable message when something noteworthy
  /// happens (mode transitions, session start/end, anomaly injections,
  /// scenario triggers). Fired on transitions only — never per tick.
  void Function(String message)? onEvent;

  /// True while the periodic timer is stopped but state is retained.
  bool get isPaused => _paused;

  /// Current playback speed multiplier (1..10). Default is 1 (2s per tick).
  int get speed => _speed;

  /// Starts the periodic ticking. Safe to call once.
  void start() {
    _restartTimer();
  }

  /// Stops the timer; all simulation state is kept for [resume].
  void pause() {
    _paused = true;
    _timer?.cancel();
    _timer = null;
  }

  /// Restarts the timer after [pause] (no-op after [dispose]).
  void resume() {
    if (_disposed) {
      return;
    }
    _paused = false;
    _restartTimer();
  }

  /// Sets the playback speed multiplier (clamped to 1..10) and restarts the
  /// periodic timer with a proportionally shorter interval.
  void setSpeed(int multiplier) {
    _speed = multiplier < 1 ? 1 : (multiplier > 10 ? 10 : multiplier);
    _restartTimer();
  }

  /// Cancels the timer. Safe to call while paused; after this the engine
  /// cannot be resumed.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  /// (Re)starts the periodic timer unless paused or disposed.
  void _restartTimer() {
    _timer?.cancel();
    _timer = null;
    if (_paused || _disposed) {
      return;
    }
    _timer = Timer.periodic(
      Duration(milliseconds: tickInterval.inMilliseconds ~/ _speed),
      (_) => _tick(),
    );
  }

  void _log(String message) {
    onEvent?.call(message);
  }

  // -------------------------------------------------------------- scenarios

  /// Scenario: force a big thermal spike on one station — an occupied one if
  /// any, otherwise a random station. Temps climb toward ~90°C over the next
  /// ticks and decay once the anomaly expires.
  void injectOverheat() {
    final List<StationTwin> occupied =
        _twins.where((StationTwin t) => t.session.occupied).toList();
    final StationTwin twin = occupied.isNotEmpty
        ? occupied[_random.nextInt(occupied.length)]
        : _twins[_random.nextInt(_twins.length)];
    final _StationSim sim = _sim[twin.id]!;
    sim.anomaly = _Anomaly.thermalSpike;
    sim.anomalyTicksLeft = 30 + _random.nextInt(15);
    if (sim.mode == StationMode.idle) {
      sim.mode = StationMode.gaming;
    }
    _log('Scenario: Overheat injected on ${twin.id}');
  }

  /// Scenario: rush hour — most idle stations flip to gaming/streaming,
  /// several stations get temporary bandwidth/latency anomalies.
  void injectPeakHour() {
    for (final StationTwin twin in _twins) {
      final _StationSim sim = _sim[twin.id]!;
      if (sim.mode == StationMode.idle && _random.nextDouble() < 0.8) {
        sim.mode = _random.nextDouble() < 0.6
            ? StationMode.gaming
            : StationMode.streaming;
        if (!twin.session.occupied && _random.nextDouble() < 0.7) {
          twin.updateSession(SessionInfo(
            occupied: true,
            sessionMinutes: 1,
            game: _games[_random.nextInt(_games.length)],
          ));
        }
      }
      final double roll = _random.nextDouble();
      if (roll < 0.4) {
        sim.anomaly = _Anomaly.bandwidthSurge;
        sim.anomalyTicksLeft = 12 + _random.nextInt(10);
      } else if (roll < 0.7) {
        sim.anomaly = _Anomaly.latencyBurst;
        sim.anomalyTicksLeft = 10 + _random.nextInt(8);
      }
    }
    _log('Scenario: Peak Hour Rush started');
  }

  /// Scenario: latency spike >150ms on 2-3 random stations, decaying over
  /// subsequent ticks like any injected anomaly.
  void injectNetworkSurge() {
    final List<StationTwin> shuffled = List<StationTwin>.of(_twins)
      ..shuffle(_random);
    final int count = 2 + _random.nextInt(2); // 2 or 3 stations
    final List<String> ids = <String>[];
    for (int i = 0; i < count; i++) {
      final StationTwin twin = shuffled[i];
      final _StationSim sim = _sim[twin.id]!;
      sim.anomaly = _Anomaly.latencyBurst;
      sim.anomalyTicksLeft = 15 + _random.nextInt(12);
      ids.add(twin.id);
    }
    _log('Scenario: Network Surge on ${ids.join(', ')}');
  }

  /// Scenario: quiet period — some sessions end, busy stations drift back to
  /// idle and anomalies clear, so temps/bandwidth settle down.
  void injectCalmAfternoon() {
    int ended = 0;
    for (final StationTwin twin in _twins) {
      final _StationSim sim = _sim[twin.id]!;
      if (twin.session.occupied && _random.nextDouble() < 0.5) {
        twin.endSession();
        ended++;
      }
      if (sim.mode != StationMode.idle && _random.nextDouble() < 0.7) {
        sim.mode = StationMode.idle;
      }
      sim.anomaly = _Anomaly.none;
      sim.anomalyTicksLeft = 0;
    }
    _log('Scenario: Calm Afternoon — $ended session(s) ended, floor settling');
  }

  /// Pre-populates a few snapshots so charts and trends have non-empty
  /// history on launch, WITHOUT pretending any simulated time has actually
  /// passed. This must never start a customer session, change a station's
  /// mode, or drift its hardware/network readings the way a real _tick()
  /// does -- a station that was just configured has to still look exactly
  /// like a station that was just configured (idle, unoccupied, default
  /// telemetry). Calling the full randomized _tick() here (as this used to)
  /// made "how many stations are idle right now" a coin flip immediately
  /// after configure(), since Random() is unseeded: a station could pick up
  /// a phantom session, or an idle station's temperature could drift with
  /// noise, before the admin -- or a test -- ever sees the twins.
  void _seed() {
    final DateTime now = DateTime.now();
    for (final StationTwin twin in _twins) {
      for (int i = 0; i < 3; i++) {
        twin.recordSnapshot(now);
      }
    }
  }

  void _tick({bool notify = true}) {
    final DateTime now = DateTime.now();
    for (final StationTwin twin in _twins) {
      final _StationSim sim = _sim[twin.id]!;
      _advanceMode(twin, sim);
      _advanceAnomaly(twin, sim);
      _advanceSession(twin, sim);
      _emitHardware(twin, sim);
      _emitNetwork(twin, sim);
      twin.recordSnapshot(now);
    }
    if (notify) {
      onTick?.call();
    }
  }

  // ------------------------------------------------------------------ modes

  void _advanceMode(StationTwin twin, _StationSim sim) {
    final StationMode before = sim.mode;
    final double r = _random.nextDouble();
    switch (sim.mode) {
      case StationMode.idle:
        if (r < 0.030) {
          sim.mode = StationMode.gaming;
        } else if (r < 0.045) {
          sim.mode = StationMode.streaming;
        } else if (r < 0.047) {
          sim.mode = StationMode.stress;
        }
        break;
      case StationMode.gaming:
        if (r < 0.030) {
          sim.mode = StationMode.idle;
        } else if (r < 0.050) {
          sim.mode = StationMode.streaming;
        } else if (r < 0.055) {
          sim.mode = StationMode.stress;
        }
        break;
      case StationMode.streaming:
        if (r < 0.040) {
          sim.mode = StationMode.idle;
        } else if (r < 0.060) {
          sim.mode = StationMode.gaming;
        } else if (r < 0.063) {
          sim.mode = StationMode.stress;
        }
        break;
      case StationMode.stress:
        if (r < 0.15) {
          sim.mode = StationMode.idle;
        } else if (r < 0.30) {
          sim.mode = StationMode.gaming;
        }
        break;
    }
    if (sim.mode != before) {
      _log('${twin.id} ${_modeVerb(sim.mode)}');
    }
  }

  static String _modeVerb(StationMode mode) {
    switch (mode) {
      case StationMode.idle:
        return 'went idle';
      case StationMode.gaming:
        return 'started gaming';
      case StationMode.streaming:
        return 'started streaming';
      case StationMode.stress:
        return 'started stress test';
    }
  }

  // -------------------------------------------------------------- anomalies

  void _advanceAnomaly(StationTwin twin, _StationSim sim) {
    if (sim.anomaly != _Anomaly.none) {
      sim.anomalyTicksLeft--;
      if (sim.anomalyTicksLeft <= 0) {
        sim.anomaly = _Anomaly.none;
      }
      return;
    }
    if (_random.nextDouble() < 0.010) {
      final double roll = _random.nextDouble();
      if (roll < 0.40) {
        sim.anomaly = _Anomaly.thermalSpike;
        sim.anomalyTicksLeft = 25 + _random.nextInt(20);
        _log('Anomaly: thermal spike on ${twin.id}');
      } else if (roll < 0.75) {
        sim.anomaly = _Anomaly.latencyBurst;
        sim.anomalyTicksLeft = 15 + _random.nextInt(15);
        _log('Anomaly: latency burst on ${twin.id}');
      } else {
        sim.anomaly = _Anomaly.bandwidthSurge;
        sim.anomalyTicksLeft = 10 + _random.nextInt(10);
        _log('Anomaly: bandwidth surge on ${twin.id}');
      }
    }
  }

  // --------------------------------------------------------------- sessions

  void _advanceSession(StationTwin twin, _StationSim sim) {
    final SessionInfo session = twin.session;
    if (!session.occupied) {
      // Poisson-like arrival: a busy-mode station attracts a customer.
      if (sim.mode != StationMode.idle && _random.nextDouble() < 0.10) {
        final String game = _games[_random.nextInt(_games.length)];
        twin.updateSession(SessionInfo(
          occupied: true,
          sessionMinutes: 1,
          game: game,
        ));
        _log('${twin.id} session started — $game');
      }
      return;
    }
    // Sessions rarely end while the machine is busy; an occupied-but-idle
    // machine keeps its customer for a while (this is what lets the
    // UTIL-GHOST rule fire).
    final double endChance = sim.mode == StationMode.idle ? 0.02 : 0.008;
    if (_random.nextDouble() < endChance) {
      twin.endSession();
      _log('${twin.id} session ended');
    } else {
      twin.updateSession(
        session.copyWith(sessionMinutes: session.sessionMinutes + 1),
      );
    }
  }

  // --------------------------------------------------------------- hardware

  void _emitHardware(StationTwin twin, _StationSim sim) {
    double cpuTarget;
    double gpuTarget;
    double cpuLoadTarget;
    double gpuLoadTarget;
    switch (sim.mode) {
      case StationMode.idle:
        cpuTarget = 42.0;
        gpuTarget = 38.0;
        cpuLoadTarget = 6.0;
        gpuLoadTarget = 2.0;
        break;
      case StationMode.gaming:
        cpuTarget = 68.0;
        gpuTarget = 66.0;
        cpuLoadTarget = 70.0;
        gpuLoadTarget = 82.0;
        break;
      case StationMode.streaming:
        cpuTarget = 58.0;
        gpuTarget = 56.0;
        cpuLoadTarget = 55.0;
        gpuLoadTarget = 40.0;
        break;
      case StationMode.stress:
        cpuTarget = 86.0;
        gpuTarget = 84.0;
        cpuLoadTarget = 96.0;
        gpuLoadTarget = 98.0;
        break;
    }
    if (sim.anomaly == _Anomaly.thermalSpike) {
      cpuTarget = 92.0;
      gpuTarget = 88.0;
    }

    final HardwareReading hw = twin.hardware;
    final double cpuTemp =
        _clamp(_drift(hw.cpuTemp, cpuTarget, 0.12, 0.8), 30.0, 110.0);
    final double gpuTemp =
        _clamp(_drift(hw.gpuTemp, gpuTarget, 0.12, 0.8), 30.0, 110.0);
    final double cpuLoad =
        _clamp(_drift(hw.cpuLoad, cpuLoadTarget, 0.25, 2.5), 0.0, 100.0);
    final double gpuLoad =
        _clamp(_drift(hw.gpuLoad, gpuLoadTarget, 0.25, 2.5), 0.0, 100.0);

    twin.updateHardware(HardwareReading(
      cpuTemp: cpuTemp,
      gpuTemp: gpuTemp,
      cpuLoad: cpuLoad,
      gpuLoad: gpuLoad,
    ));
  }

  // ---------------------------------------------------------------- network

  void _emitNetwork(StationTwin twin, _StationSim sim) {
    double bandwidthTarget;
    switch (sim.mode) {
      case StationMode.idle:
        bandwidthTarget = 15.0;
        break;
      case StationMode.gaming:
        bandwidthTarget = 220.0;
        break;
      case StationMode.streaming:
        bandwidthTarget = 480.0;
        break;
      case StationMode.stress:
        bandwidthTarget = 900.0;
        break;
    }

    double bandwidth;
    if (sim.anomaly == _Anomaly.bandwidthSurge) {
      bandwidth = 860.0 + _random.nextDouble() * 120.0;
    } else {
      bandwidth = _clamp(
        _drift(twin.network.bandwidthMbps, bandwidthTarget, 0.30, 15.0),
        1.0,
        1000.0,
      );
    }

    double latency;
    if (sim.anomaly == _Anomaly.latencyBurst) {
      latency = 165.0 + _random.nextDouble() * 120.0;
    } else {
      latency = _clamp(
        18.0 +
            _random.nextDouble() * 14.0 +
            bandwidth / 1000.0 * 20.0 +
            (sim.mode == StationMode.stress ? 15.0 : 0.0),
        5.0,
        400.0,
      );
    }

    final double packetLoss = latency > 120.0
        ? _random.nextDouble() * 2.5
        : _random.nextDouble() * 0.3;

    twin.updateNetwork(NetworkReading(
      bandwidthMbps: bandwidth,
      latencyMs: latency,
      packetLoss: packetLoss,
    ));
  }

  // ---------------------------------------------------------------- helpers

  /// Exponential drift toward [target] plus uniform noise in ±[noise].
  double _drift(double current, double target, double rate, double noise) {
    return current +
        (target - current) * rate +
        (_random.nextDouble() * 2.0 - 1.0) * noise;
  }

  double _clamp(double value, double lo, double hi) {
    if (value < lo) {
      return lo;
    }
    if (value > hi) {
      return hi;
    }
    return value;
  }
}
