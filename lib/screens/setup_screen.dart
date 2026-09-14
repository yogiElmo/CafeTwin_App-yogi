import 'package:flutter/material.dart';

import '../state/cafe_state.dart';
import 'home_shell.dart';

/// Onboarding page 2: organization setup.
///
/// The admin names the organization, picks the number of floor stations
/// (1-20) and assigns each station a category (Gaming, Marketing, Printing,
/// Design, Office, or a custom one). "Launch Dashboard" configures the
/// shared [CafeState] and replaces this route with the dashboard.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.state});

  final CafeState state;

  static const int minStations = 1;
  static const int maxStations = 200;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  static const Color _amber = Color(0xFFD9A441);
  static const Color _surface = Color(0xFF26221E);
  static const Color _border = Color(0xFF3A332C);

  final TextEditingController _companyController = TextEditingController();
  final TextEditingController _customCategoryController =
      TextEditingController();

  /// Selectable categories; custom ones are appended and become available
  /// for every station.
  final List<String> _categories = <String>[
    'Gaming',
    'Office',
    'Design',
    'Marketing',
    'Programming',
    'Education',
    'Video Editing',
    'Graphic Design',
    'Streaming',
    'Content Creation',
    'Cybersecurity',
    'Research',
    '3D Modelling',
    'Engineering',
    'General Use',
  ];

  int _stationCount = 10;

  /// Category per station index (0-based, up to [SetupScreen.maxStations]);
  /// every station defaults to Gaming.
  final List<String> _assignments =
      List<String>.filled(SetupScreen.maxStations, 'Gaming');

  String? _error;
  bool _launching = false;

  @override
  void dispose() {
    _companyController.dispose();
    _customCategoryController.dispose();
    super.dispose();
  }

  void _addCustomCategory() {
    final String name = _customCategoryController.text.trim();
    if (name.isEmpty) {
      return;
    }
    final bool exists = _categories
        .any((String c) => c.toLowerCase() == name.toLowerCase());
    if (!exists) {
      setState(() => _categories.add(name));
    }
    _customCategoryController.clear();
  }

  Future<void> _launch() async {
    if (_launching) return;
    final String company = _companyController.text.trim();
    if (company.isEmpty) {
      setState(() {
        _error = 'Please enter a company / organization name.';
      });
      return;
    }
    final List<String> assignments =
        _assignments.sublist(0, _stationCount);
    if (assignments.any((String c) => c.trim().isEmpty)) {
      setState(() {
        _error = 'Every station must have a category selected.';
      });
      return;
    }
    setState(() {
      _launching = true;
      _error = null;
    });
    // configure() registers with the backend (when configured) before
    // building the local stations, so it must be awaited here rather than
    // fired-and-forgotten -- see CafeState.configure's docs. It still
    // resolves quickly offline/unreachable (ApiService's own 5s timeout),
    // so this spinner is brief in the common case.
    await widget.state.configure(company, assignments);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => HomeShell(state: widget.state),
      ),
    );
  }

  InputDecoration _fieldDecoration(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, size: 20, color: _amber),
      filled: true,
      fillColor: _surface,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: _border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: _amber),
      ),
    );
  }

  Widget _stationRow(int index) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 88,
            child: Text(
              'Station ${index + 1}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: DropdownButtonFormField<String>(
              value: _assignments[index],
              dropdownColor: _surface,
              isExpanded: true,
              decoration: InputDecoration(
                filled: true,
                fillColor: _surface,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: _border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: _amber),
                ),
              ),
              items: _categories
                  .map((String c) => DropdownMenuItem<String>(
                        value: c,
                        child: Text(c, style: const TextStyle(fontSize: 14)),
                      ))
                  .toList(),
              onChanged: (String? value) {
                if (value != null) {
                  setState(() => _assignments[index] = value);
                }
              },
            ),
          ),
        ],
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
        title: const Text('Organization Setup'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Card(
              margin: const EdgeInsets.all(16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: _amber.withValues(alpha: 0.30)),
              ),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: <Widget>[
                  const Text(
                    'Organization Setup',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: _amber,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Configure your organization and station floor.',
                    style: TextStyle(fontSize: 13, color: dim),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _companyController,
                    decoration: _fieldDecoration(
                        'Company / Organization name', Icons.business),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: <Widget>[
                      const Expanded(
                        child: Text(
                          'Number of stations',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                      ),
                      DropdownButton<int>(
                        value: _stationCount,
                        dropdownColor: _surface,
                        underline: const SizedBox.shrink(),
                        items: List<int>.generate(
                          SetupScreen.maxStations -
                              SetupScreen.minStations +
                              1,
                          (int i) => i + SetupScreen.minStations,
                        )
                            .map((int n) => DropdownMenuItem<int>(
                                  value: n,
                                  child: Text('$n'),
                                ))
                            .toList(),
                        onChanged: (int? value) {
                          if (value != null) {
                            setState(() => _stationCount = value);
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Text(
                        'STATION CATEGORIES',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _amber.withValues(alpha: 0.9),
                          letterSpacing: 1.4,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'every station defaults to Gaming',
                          style: TextStyle(fontSize: 11, color: dim),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (int i = 0; i < _stationCount; i++) _stationRow(i),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: _customCategoryController,
                          decoration: InputDecoration(
                            hintText: '＋ custom category',
                            hintStyle: TextStyle(fontSize: 13, color: dim),
                            isDense: true,
                            filled: true,
                            fillColor: _surface,
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: _border),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: _amber),
                            ),
                          ),
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _addCustomCategory(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: _addCustomCategory,
                        tooltip: 'Add category',
                        icon: const Icon(Icons.add_circle_outline,
                            color: _amber),
                      ),
                    ],
                  ),
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: _launching ? null : _launch,
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
                    child: _launching
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              color: Color(0xFF1E1B18),
                            ),
                          )
                        : const Text('Launch Dashboard'),
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
