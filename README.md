# CaféTwin — Gaming Café Digital Twin Dashboard

A complete, self-contained Flutter app that monitors 10 gaming stations
(ST-01 … ST-10) in a gaming café. A **built-in Dart simulation engine**
generates realistic hardware / network / session telemetry every 2 seconds —
no backend, no Firebase, no network calls. The app works instantly with
`flutter run`, zero configuration.

Pure Flutter SDK only: `pubspec.yaml` has **zero third-party packages**.
All gauges and charts are drawn with `CustomPainter`, and state management
uses a plain `ChangeNotifier` (`CafeState`) injected by constructor and
listened to with `AnimatedBuilder`.

## How it maps to the proposal's 6 layers

| Layer | Implementation |
|-------|----------------|
| 1. Physical layer (simulated) | `lib/services/simulation_engine.dart` — `Timer.periodic` (2 s), Markov-style mode transitions (idle/gaming/streaming/stress), thermal drift with noise, injected anomalies (thermal spike, latency burst, bandwidth surge) |
| 2. Data acquisition | The engine tick writes `HardwareReading` / `NetworkReading` / `SessionInfo` into each twin every cycle |
| 3. Digital twin | `lib/services/digital_twin.dart` — `StationTwin` holds current state + rolling history of the last 100 snapshots, `cpuTempTrend()` in °C/min |
| 4. Rules / analytics | `lib/services/rules_engine.dart` — `RulesEngine.evaluate(twin)` fires HW-CRIT, HW-RAMP, NET-LAT, NET-BW, UTIL-GHOST, UTIL-LONG |
| 5. State management | `lib/state/cafe_state.dart` — `CafeState extends ChangeNotifier`, de-duplicates one active alert per (stationId, ruleCode), auto-resolves cleared conditions, exposes `activeAlertCount`, `alertsFor`, `acknowledge`, `endSession`, `stationList` |
| 6. UI / dashboard | `lib/screens/*` + `lib/widgets/*` — station grid, station detail (gauges, sparkline, session card), filterable alert feed with badge |

## Alerting rules

| Code | Condition | Severity | Category |
|------|-----------|----------|----------|
| HW-CRIT | cpuTemp > 85 °C or gpuTemp > 83 °C | critical | hardware |
| HW-RAMP | cpuTempTrend > 2.0 °C/min and cpuTemp > 75 °C | warning | hardware |
| NET-LAT | latency > 150 ms for the last 6 readings | critical | network |
| NET-BW | bandwidth > 80% of 1000 Mbps capacity | warning | network |
| UTIL-GHOST | occupied but gpuLoad < 5% for 10+ min | warning | utilization |
| UTIL-LONG | session > 360 min | warning | utilization |

Alerts auto-resolve when their condition clears; tapping an alert
acknowledges it (check icon, dimmed). The Alerts tab shows a red badge with
the unacknowledged count.

**Time compression:** each 2-second engine tick represents 1 simulated
minute, so trends, session durations and the utilization rules progress
fast enough to watch live — injected anomalies make alerts visibly fire
within the first minute or two of running.

## Running the app

```bash
cd cafetwin_app
flutter pub get
flutter run
```

This repository contains the Dart sources (`lib/`), `pubspec.yaml` and
`analysis_options.yaml`. If the platform folders (`android/`, `ios/`, …)
are missing, generate them once inside this directory:

```bash
flutter create .
```

Then `flutter run` on any supported target (Android, iOS, Windows, Linux,
macOS, Web).

## Troubleshooting

- **Check your setup:** `flutter doctor` — resolve any missing toolchain
  items (Android SDK, Xcode, etc.).
- **No devices found:** start an emulator (`flutter emulators --launch <id>`)
  or run on desktop/web, e.g. `flutter run -d chrome` or `-d windows`.
- **Dependency issues:** `flutter clean && flutter pub get`.
- Requires Dart SDK >= 3.0.0 (ships with Flutter 3.10+); verify with
  `flutter --version`.
