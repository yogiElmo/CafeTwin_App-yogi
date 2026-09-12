import 'package:cafetwin_app/models/alert.dart';
import 'package:cafetwin_app/models/station.dart';
import 'package:cafetwin_app/models/telemetry.dart';
import 'package:cafetwin_app/services/digital_twin.dart';
import 'package:cafetwin_app/services/rules_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a fresh, otherwise-idle twin for one test.
StationTwin _twin() =>
    StationTwin(station: const Station(id: 'ST-01', name: 'Station 01'));

Set<String> _codes(List<Alert> alerts) =>
    alerts.map((Alert a) => a.ruleCode).toSet();

void main() {
  group('RulesEngine.evaluate', () {
    test('HW-CRIT fires above 85C and not at a normal temperature', () {
      final StationTwin hot = _twin();
      hot.updateHardware(const HardwareReading(
          cpuTemp: 90, gpuTemp: 60, cpuLoad: 80, gpuLoad: 80));
      hot.updateNetwork(
          const NetworkReading(bandwidthMbps: 100, latencyMs: 20, packetLoss: 0));
      hot.recordSnapshot(DateTime.now());
      expect(_codes(RulesEngine.evaluate(hot)), contains('HW-CRIT'));

      final StationTwin normal = _twin();
      normal.updateHardware(const HardwareReading(
          cpuTemp: 50, gpuTemp: 45, cpuLoad: 30, gpuLoad: 30));
      normal.updateNetwork(
          const NetworkReading(bandwidthMbps: 100, latencyMs: 20, packetLoss: 0));
      normal.recordSnapshot(DateTime.now());
      expect(_codes(RulesEngine.evaluate(normal)), isNot(contains('HW-CRIT')));
    });

    test('HW-RAMP fires on a fast-rising CPU trend below the critical limit', () {
      final StationTwin twin = _twin();
      twin.updateNetwork(
          const NetworkReading(bandwidthMbps: 100, latencyMs: 20, packetLoss: 0));
      for (int i = 0; i < 10; i++) {
        final double temp = 60 + i * 2.5; // 60 -> 82.5C, slope 2.5C/min.
        twin.updateHardware(HardwareReading(
            cpuTemp: temp, gpuTemp: temp - 15, cpuLoad: 70, gpuLoad: 70));
        twin.recordSnapshot(DateTime.now());
      }
      final Set<String> codes = _codes(RulesEngine.evaluate(twin));
      expect(codes, contains('HW-RAMP'));
      expect(codes, isNot(contains('HW-CRIT')));
    });

    test('NET-LAT only fires once latency has stayed above 150ms for 6 readings', () {
      final StationTwin twin = _twin();
      twin.updateHardware(const HardwareReading(
          cpuTemp: 50, gpuTemp: 45, cpuLoad: 30, gpuLoad: 30));
      for (int i = 0; i < 5; i++) {
        twin.updateNetwork(
            const NetworkReading(bandwidthMbps: 100, latencyMs: 160, packetLoss: 0));
        twin.recordSnapshot(DateTime.now());
      }
      expect(_codes(RulesEngine.evaluate(twin)), isNot(contains('NET-LAT')),
          reason: 'only 5 readings so far, the rule requires 6');

      twin.updateNetwork(
          const NetworkReading(bandwidthMbps: 100, latencyMs: 160, packetLoss: 0));
      twin.recordSnapshot(DateTime.now());
      expect(_codes(RulesEngine.evaluate(twin)), contains('NET-LAT'));
    });

    test('NET-BW fires above 80% of the 1000 Mbps link capacity', () {
      final StationTwin twin = _twin();
      twin.updateHardware(const HardwareReading(
          cpuTemp: 50, gpuTemp: 45, cpuLoad: 30, gpuLoad: 30));
      twin.updateNetwork(
          const NetworkReading(bandwidthMbps: 900, latencyMs: 20, packetLoss: 0));
      twin.recordSnapshot(DateTime.now());
      expect(_codes(RulesEngine.evaluate(twin)), contains('NET-BW'));
    });

    test('UTIL-GHOST fires after 10 occupied-but-idle-GPU minutes', () {
      final StationTwin twin = _twin();
      twin.updateHardware(
          const HardwareReading(cpuTemp: 45, gpuTemp: 40, cpuLoad: 10, gpuLoad: 1));
      twin.updateNetwork(
          const NetworkReading(bandwidthMbps: 20, latencyMs: 20, packetLoss: 0));
      twin.updateSession(
          const SessionInfo(occupied: true, sessionMinutes: 15, game: 'Valor Rush'));
      for (int i = 0; i < 9; i++) {
        twin.recordSnapshot(DateTime.now());
      }
      expect(_codes(RulesEngine.evaluate(twin)), isNot(contains('UTIL-GHOST')),
          reason: 'only 9 ghost ticks so far, the rule requires 10');

      twin.recordSnapshot(DateTime.now());
      expect(_codes(RulesEngine.evaluate(twin)), contains('UTIL-GHOST'));
    });

    test('UTIL-LONG fires once a session passes 360 minutes', () {
      final StationTwin twin = _twin();
      twin.updateHardware(
          const HardwareReading(cpuTemp: 45, gpuTemp: 40, cpuLoad: 40, gpuLoad: 40));
      twin.updateNetwork(
          const NetworkReading(bandwidthMbps: 100, latencyMs: 20, packetLoss: 0));
      twin.updateSession(
          const SessionInfo(occupied: true, sessionMinutes: 361, game: 'Elden Realms'));
      twin.recordSnapshot(DateTime.now());
      expect(_codes(RulesEngine.evaluate(twin)), contains('UTIL-LONG'));
    });

    test('a fully idle, healthy station fires no alerts at all', () {
      final StationTwin twin = _twin();
      twin.updateHardware(
          const HardwareReading(cpuTemp: 42, gpuTemp: 38, cpuLoad: 6, gpuLoad: 2));
      twin.updateNetwork(
          const NetworkReading(bandwidthMbps: 15, latencyMs: 24, packetLoss: 0));
      twin.recordSnapshot(DateTime.now());
      expect(RulesEngine.evaluate(twin), isEmpty);
    });
  });
}
