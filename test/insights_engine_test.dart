import 'package:cafetwin_app/models/insight.dart';
import 'package:cafetwin_app/models/telemetry.dart';
import 'package:cafetwin_app/services/digital_twin.dart';
import 'package:cafetwin_app/services/insights_engine.dart';
import 'package:cafetwin_app/state/cafe_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Configures a [CafeState] with one station per entry in [categories] and
/// immediately pauses the simulation timer, so the returned twins can be
/// mutated deterministically in each test without a background tick racing
/// in and changing hardware/session state mid-assertion.
Future<CafeState> _configuredState(List<String> categories) async {
  final CafeState state = CafeState();
  // configure() is async (it awaits an organization-registration attempt
  // before building the local stations -- see CafeState.configure's docs);
  // with no API_BASE_URL configured for the test binary, that resolves to
  // null on its very first synchronous check, so this still completes
  // effectively immediately.
  await state.configure('Test Café', categories);
  state.pauseSimulation();
  return state;
}

void main() {
  group('InsightsEngine.optimizationsFor', () {
    test('recommends powering down idle stations with a quantified saving',
        () async {
      final CafeState state =
          await _configuredState(<String>['Gaming', 'Gaming', 'Gaming', 'Gaming']);
      // All 4 stations start unoccupied (SessionInfo.empty) -> all idle.
      final List<Insight> powerDown = InsightsEngine.optimizationsFor(state)
          .where((Insight i) => i.title.startsWith('Power down'))
          .toList();
      expect(powerDown, hasLength(1));
      expect(powerDown.first.title, 'Power down 4 idle stations');
      // 4 stations x 0.15kW x $0.12/kWh x 24h = $1.728/day.
      expect(powerDown.first.impact, '\$1.73/day');
    });

    test('flags low utilization once occupancy drops below 40%', () async {
      final CafeState state = await _configuredState(
          <String>['Gaming', 'Gaming', 'Gaming', 'Gaming', 'Gaming']);
      state.stationList.first.updateSession(const SessionInfo(
          occupied: true, sessionMinutes: 5, game: 'Valor Rush'));
      // 1 of 5 occupied = 20% utilization, below the 40% threshold.
      final List<Insight> lowUtil = InsightsEngine.optimizationsFor(state)
          .where((Insight i) => i.title == 'Low utilization')
          .toList();
      expect(lowUtil, hasLength(1));
      expect(lowUtil.first.detail, contains('Only 1 of 5 stations'));
    });
  });

  group('InsightsEngine.predictionsFor', () {
    test('forecasts a time-to-85C for a station heating up below the limit',
        () async {
      final CafeState state = await _configuredState(<String>['Gaming']);
      final StationTwin twin = state.stationList.first;
      for (int i = 0; i < 10; i++) {
        final double temp = 60 + i * 2.5; // 60 -> 82.5C, slope 2.5C/min.
        twin.updateHardware(HardwareReading(
            cpuTemp: temp, gpuTemp: temp - 15, cpuLoad: 70, gpuLoad: 70));
        twin.recordSnapshot(DateTime.now());
      }
      final List<Insight> thermal = InsightsEngine.predictionsFor(state)
          .where((Insight i) =>
              i.stationId == twin.id && i.icon == Icons.thermostat)
          .toList();
      expect(thermal, hasLength(1));
      expect(thermal.first.title, contains('will reach'));
      expect(thermal.first.title, contains('85'));
    });

    test('has no thermal prediction for a station that is cool and flat',
        () async {
      final CafeState state = await _configuredState(<String>['Gaming']);
      final StationTwin twin = state.stationList.first;
      // Default hardware (40C, never updated) -> cpuTempTrend() is exactly 0.
      for (int i = 0; i < 5; i++) {
        twin.recordSnapshot(DateTime.now());
      }
      final List<Insight> thermal = InsightsEngine.predictionsFor(state)
          .where((Insight i) =>
              i.stationId == twin.id && i.icon == Icons.thermostat)
          .toList();
      expect(thermal, isEmpty);
    });
  });
}
