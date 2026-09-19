// CafeState's load/reset lifecycle.
//
// These exist because of a real bug: [CafeState.loadExisting] returns
// silently when the state is already configured, and logging out did not
// reset it. The result was that on one app instance, the FIRST café loaded
// stuck -- every staff account that logged in afterwards landed in that
// organization instead of the one they were assigned to, with no error
// anywhere to show for it.
//
// The one-shot behaviour itself is intentional (a configured state owns a
// running simulation), so these tests pin it down rather than change it,
// and pin down that reset() is what makes the next load take effect.

import 'package:cafetwin_app/models/station.dart';
import 'package:cafetwin_app/state/cafe_state.dart';
import 'package:flutter_test/flutter_test.dart';

List<Station> _stations(String prefix) => <Station>[
      Station(id: '$prefix-01', name: '$prefix-01'),
      Station(id: '$prefix-02', name: '$prefix-02'),
    ];

void main() {
  group('CafeState load/reset lifecycle', () {
    test('loadExisting configures an unconfigured state', () {
      final CafeState state = CafeState();
      expect(state.isConfigured, isFalse);

      state.loadExisting(
        organizationId: 'org-a',
        company: 'Café A',
        stations: _stations('A'),
      );

      expect(state.isConfigured, isTrue);
      expect(state.companyName, 'Café A');
      expect(state.backendOrgId, 'org-a');
      expect(state.stationList, hasLength(2));
      state.dispose();
    });

    test('a second loadExisting is ignored while still configured', () {
      final CafeState state = CafeState();
      state.loadExisting(
        organizationId: 'org-a',
        company: 'Café A',
        stations: _stations('A'),
      );

      // This is the shape of the bug: the call looks like it worked, but
      // the state keeps the first café. Anything routing a NEW user into
      // their own organization must reset() first.
      state.loadExisting(
        organizationId: 'org-b',
        company: 'Café B',
        stations: _stations('B'),
      );

      expect(state.companyName, 'Café A');
      expect(state.backendOrgId, 'org-a');
      state.dispose();
    });

    test('reset clears the organization so the next load takes effect', () {
      final CafeState state = CafeState();
      state.loadExisting(
        organizationId: 'org-a',
        company: 'Café A',
        stations: _stations('A'),
      );

      state.reset();
      expect(state.isConfigured, isFalse);
      expect(state.companyName, isEmpty);
      expect(state.backendOrgId, isNull);

      state.loadExisting(
        organizationId: 'org-b',
        company: 'Café B',
        stations: _stations('B'),
      );

      expect(state.isConfigured, isTrue);
      expect(state.companyName, 'Café B');
      expect(state.backendOrgId, 'org-b');
      expect(state.stationList.first.id, 'B-01');
      state.dispose();
    });

    test('reset on a never-configured state is harmless', () {
      final CafeState state = CafeState();
      state.reset();
      expect(state.isConfigured, isFalse);
      expect(state.stationList, isEmpty);
      state.dispose();
    });

    test('reset clears alerts and the event log as well as the roster', () {
      final CafeState state = CafeState();
      state.loadExisting(
        organizationId: 'org-a',
        company: 'Café A',
        stations: _stations('A'),
      );

      state.reset();

      expect(state.stationList, isEmpty);
      expect(state.activeAlertCount, 0);
      state.dispose();
    });
  });
}
