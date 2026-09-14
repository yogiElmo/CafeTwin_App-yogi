import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../state/cafe_state.dart';
import 'alerts_screen.dart';
import 'login_screen.dart';
import 'organization_list_screen.dart';
import 'simulation_screen.dart';
import 'station_grid_screen.dart';
import 'user_management_screen.dart';

/// Root scaffold: AppBar + BottomNavigationBar (Stations | Simulation | Alerts).
/// The Alerts tab carries a red badge with the unacknowledged alert count.
///
/// The AppBar also carries an admin-only "Manage Users" action, an
/// admin-only "Log Off Organization" action, and a logout button.
///
/// "Log Off Organization" is distinct from "Logout": it stays signed in to
/// the same admin account but returns to [OrganizationListScreen] so a
/// different organization can be picked (or the current one deleted from
/// that list). It calls [CafeState.reset] first, since [CafeState] is
/// otherwise safe to configure/load only once per instance.
///
/// "Logout" clears the stored session entirely and returns to
/// [LoginScreen], but does not reset [CafeState] (organization setup is
/// purely in-memory for this browser session; see the README's note on
/// what "multi-user" means here). It asks for confirmation first and, once
/// [LoginScreen] loads, shows a one-time "You have been logged out."
/// snackbar so there's clear feedback that it actually happened.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.state});

  final CafeState state;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  Future<void> _logout() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text(
          "You'll need to sign in again to get back to your organizations.",
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await AuthService.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => LoginScreen(
          state: widget.state,
          justLoggedOut: true,
        ),
      ),
      (Route<dynamic> route) => false,
    );
  }

  void _openUserManagement() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const UserManagementScreen(),
      ),
    );
  }

  void _leaveOrganization() {
    widget.state.reset();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => OrganizationListScreen(
          state: widget.state,
          justLoggedOff: true,
        ),
      ),
    );
  }

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
            actions: <Widget>[
              if (AuthService.isAdmin)
                IconButton(
                  icon: const Icon(Icons.manage_accounts_outlined),
                  tooltip: 'Manage Users',
                  onPressed: _openUserManagement,
                ),
              if (AuthService.isAdmin)
                IconButton(
                  icon: const Icon(Icons.swap_horiz),
                  tooltip: 'Log Off Organization',
                  onPressed: _leaveOrganization,
                ),
              IconButton(
                icon: const Icon(Icons.logout),
                tooltip: 'Logout',
                onPressed: _logout,
              ),
            ],
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
