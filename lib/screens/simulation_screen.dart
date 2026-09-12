import 'package:flutter/material.dart';

import '../state/cafe_state.dart';

/// Screen 2: the simulation control room.
///
/// Lets the operator drive the SIMULATED physical café (Layer 1): pause /
/// resume playback, change tick speed, inject one-tap scenarios, and watch a
/// live event log of what the simulation is doing. The digital twin (and the
/// Stations / Alerts tabs) reacts to these changes on the next ticks.
///
/// Layout note: the whole page is ONE scrollable ListView so no content is
/// ever hidden below an inner scroll fold. The log has its own fixed-height
/// internal scrolling area.
class SimulationScreen extends StatelessWidget {
  const SimulationScreen({super.key, required this.state});

  final CafeState state;

  static const Color _amber = Color(0xFFD9A441);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (BuildContext context, Widget? child) {
        final Color muted =
            Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);
        final List<String> log = state.eventLog;

        return ListView(
          padding: const EdgeInsets.all(12),
          children: <Widget>[
            _explainerCard(context),
            const SizedBox(height: 12),
            _playbackCard(context),
            const SizedBox(height: 12),
            _scenarioCard(context),
            const SizedBox(height: 12),
            _logPanel(context, log, muted),
          ],
        );
      },
    );
  }

  // --------------------------------------------------------------- sections

  Widget _explainerCard(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Icon(Icons.info_outline, color: _amber, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'This panel controls the SIMULATED physical café. The digital '
                'twin mirrors it — watch the Stations tab react.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color:
                      Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.85),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _playbackCard(BuildContext context) {
    final bool paused = state.simulationPaused;
    final int speed = state.simulationSpeed;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _cardTitle(context, 'Playback'),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                IconButton(
                  iconSize: 40,
                  color: _amber,
                  tooltip: paused ? 'Resume simulation' : 'Pause simulation',
                  icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                  onPressed:
                      paused ? state.resumeSimulation : state.pauseSimulation,
                ),
                const SizedBox(width: 4),
                Text(
                  paused ? 'Paused' : 'Running',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: paused
                        ? _amber
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: <int>[1, 2, 5, 10].map((int multiplier) {
                return ChoiceChip(
                  label: Text('${multiplier}x'),
                  selected: speed == multiplier,
                  onSelected: (bool selected) {
                    if (selected) {
                      state.setSimulationSpeed(multiplier);
                    }
                  },
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _scenarioCard(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _cardTitle(context, 'Inject Scenario'),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: _scenarioButton(
                    icon: Icons.local_fire_department,
                    label: 'Overheat PC',
                    onPressed: state.injectOverheat,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _scenarioButton(
                    icon: Icons.groups,
                    label: 'Peak Hour Rush',
                    onPressed: state.injectPeakHour,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: _scenarioButton(
                    icon: Icons.wifi,
                    label: 'Network Surge',
                    onPressed: state.injectNetworkSurge,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _scenarioButton(
                    icon: Icons.wb_sunny,
                    label: 'Calm Afternoon',
                    onPressed: state.injectCalmAfternoon,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _logPanel(BuildContext context, List<String> log, Color muted) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _cardTitle(context, 'Live Simulation Log'),
            const SizedBox(height: 8),
            SizedBox(
              height: 260,
              child: log.isEmpty
                  ? Center(
                      child: Text(
                        'No events yet — the simulation is warming up…',
                        style: TextStyle(fontSize: 13, color: muted),
                      ),
                    )
                  : ListView.builder(
                      itemCount: log.length,
                      itemBuilder: (BuildContext context, int index) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            log[index],
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              height: 1.3,
                              color: Color(0xFF9C9284),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- widgets

  Widget _cardTitle(BuildContext context, String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.75),
      ),
    );
  }

  Widget _scenarioButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      height: 44,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Flexible(
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        style: ElevatedButton.styleFrom(
          foregroundColor: _amber,
          backgroundColor: const Color(0xFF2E2822),
          side: BorderSide(color: _amber.withValues(alpha: 0.35)),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      ),
    );
  }
}
