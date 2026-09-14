import 'package:flutter/material.dart';

import '../models/organization_summary.dart';
import '../models/station.dart';
import '../services/auth_service.dart';
import '../state/cafe_state.dart';
import 'home_shell.dart';
import 'setup_screen.dart';

/// Post-login landing page for admins: lists every organization this admin
/// account has created (via `GET /organizations`), with a button to set up
/// a new one. Tapping an existing organization fetches its full detail
/// (`GET /organizations/:id`) and loads it into [CafeState] via
/// [CafeState.loadExisting] instead of creating a new one.
///
/// Non-admin (staff) logins skip this screen entirely and go straight to
/// [SetupScreen], same as before this screen existed -- see [LoginScreen].
///
/// Every navigation out of this screen uses `pushReplacement`: [CafeState]
/// is a one-shot object (safe to configure/load only once), so there's no
/// way to come back here and pick a different organization within the same
/// session -- logging out and back in returns you to a fresh list.
class OrganizationListScreen extends StatefulWidget {
  const OrganizationListScreen({super.key, required this.state});

  final CafeState state;

  @override
  State<OrganizationListScreen> createState() =>
      _OrganizationListScreenState();
}

class _OrganizationListScreenState extends State<OrganizationListScreen> {
  static const Color _amber = Color(0xFFD9A441);
  static const Color _surface = Color(0xFF26221E);
  static const Color _border = Color(0xFF3A332C);

  List<OrganizationSummary>? _organizations;
  bool _loading = true;
  String? _listError;

  /// Id of the organization currently being opened (fetching detail +
  /// loading into [CafeState]), so its card can show a spinner and every
  /// card can be disabled while that's in flight.
  String? _openingId;
  String? _openError;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _listError = null;
    });
    final List<OrganizationSummary>? orgs = await AuthService.listMyOrganizations();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (orgs == null) {
        _listError = 'Could not load organizations. Check the backend connection.';
      } else {
        _organizations = orgs;
      }
    });
  }

  Future<void> _openOrganization(OrganizationSummary org) async {
    if (_openingId != null) return;
    setState(() {
      _openingId = org.id;
      _openError = null;
    });

    final Map<String, dynamic>? detail = await AuthService.getOrganization(org.id);
    if (!mounted) return;

    if (detail == null) {
      setState(() {
        _openingId = null;
        _openError = 'Could not open "${org.name}". Check the backend connection.';
      });
      return;
    }

    final List<dynamic> stationsJson = detail['stations'] as List<dynamic>? ?? <dynamic>[];
    final List<Station> stations = stationsJson
        .map((dynamic s) => Station.fromJson(s as Map<String, dynamic>))
        .toList();

    widget.state.loadExisting(
      organizationId: org.id,
      company: detail['name'] as String? ?? org.name,
      stations: stations,
    );

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => HomeShell(state: widget.state),
      ),
    );
  }

  void _createNew() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => SetupScreen(state: widget.state),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    const List<String> months = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  Widget _organizationCard(OrganizationSummary org) {
    final bool opening = _openingId == org.id;
    final bool disabled = _openingId != null;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: _border),
      ),
      color: _surface,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: disabled ? null : () => _openOrganization(org),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: <Widget>[
              const Icon(Icons.business, color: _amber, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      org.name,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${org.stationCount} station${org.stationCount == 1 ? '' : 's'} '
                      '· created ${_formatDate(org.configuredAt)}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              if (opening)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Color dim =
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Your Organizations'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  Text(
                    'Pick an organization to open, or set up a new one.',
                    style: TextStyle(fontSize: 13, color: dim),
                  ),
                  const SizedBox(height: 16),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_listError != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        _listError!,
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    )
                  else if (_organizations == null || _organizations!.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'No organizations yet — create your first one below.',
                        style: TextStyle(fontSize: 13, color: dim),
                      ),
                    )
                  else
                    for (final OrganizationSummary org in _organizations!)
                      _organizationCard(org),
                  if (_openError != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      _openError!,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: _openingId != null ? null : _createNew,
                    icon: const Icon(Icons.add),
                    label: const Text('New Organization'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _amber,
                      foregroundColor: const Color(0xFF1E1B18),
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
