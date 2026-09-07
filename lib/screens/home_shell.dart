import 'package:flutter/material.dart';

import '../state/cafe_state.dart';
import 'alerts_screen.dart';
import 'simulation_screen.dart';
import 'station_grid_screen.dart';

/// Root scaffold: AppBar + BottomNavigationBar (Stations | Simulation | Alerts).
/// The Alerts tab carries a red badge with the unacknowledged alert count.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.state});

  final CafeState state;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (BuildContext context, Widget? child) {
        final int count = widget.state.activeAlertCount;
        return Scaffold(
          appBar: AppBar(
            title: Text(
              widget.state.companyName.isEmpty
                  ? 'CaféTwin — Gaming Café Digital Twin'
                  : widget.state.companyName,
            ),
          ),
          body: IndexedStack(
            index: _index,
            children: <Widget>[
              StationGridScreen(state: widget.state),
              SimulationScreen(state: widget.state),
              AlertsScreen(state: widget.state),
            ],
          ),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _index,
            onTap: (int i) => setState(() => _index = i),
            items: <BottomNavigationBarItem>[
              const BottomNavigationBarItem(
                icon: Icon(Icons.computer),
                label: 'Stations',
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.science_outlined),
                label: 'Simulation',
              ),
              BottomNavigationBarItem(
                icon: count > 0
                    ? Badge(
                        label: Text('$count'),
                        backgroundColor: const Color(0xFFCC5148),
                        child: const Icon(Icons.notifications_active_outlined),
                      )
                    : const Icon(Icons.notifications_none),
                label: 'Alerts',
              ),
            ],
          ),
        );
      },
    );
  }
}
