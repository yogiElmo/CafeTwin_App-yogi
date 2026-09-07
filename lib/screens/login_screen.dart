import 'package:flutter/material.dart';

import '../models/station.dart';
import '../state/cafe_state.dart';
import '../widgets/monitor_illustration.dart';
import 'setup_screen.dart';

/// Onboarding page 1: admin login.
///
/// A centered card on the dark background with three fields (username,
/// password, authentication PIN). Valid credentials are hardcoded demo
/// constants; on success the admin is pushed (replacement) to the
/// organization setup screen.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.state});

  final CafeState state;

  /// Hardcoded demo credentials.
  static const String validUsername = 'ICT907';
  static const String validPassword = 'CapstoneProject';
  static const String validPin = '2150';

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const Color _amber = Color(0xFFD9A441);
  static const Color _surface = Color(0xFF26221E);
  static const Color _border = Color(0xFF3A332C);

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _pinController = TextEditingController();

  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  void _login() {
    final bool ok =
        _usernameController.text.trim() == LoginScreen.validUsername &&
            _passwordController.text == LoginScreen.validPassword &&
            _pinController.text.trim() == LoginScreen.validPin;
    if (!ok) {
      setState(() {
        _error = 'Invalid username, password or PIN — please try again.';
      });
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => SetupScreen(state: widget.state),
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

  @override
  Widget build(BuildContext context) {
    final Color dim =
        Theme.of(context).colorScheme.onSurface.withOpacity(0.55);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: _amber.withOpacity(0.30)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const Center(
                        child: MonitorIllustration(
                          status: StationStatus.normal,
                          size: 90,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'CaféTwin',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          color: _amber,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Admin Login',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: dim),
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _usernameController,
                        decoration:
                            _fieldDecoration('Username', Icons.person_outline),
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _passwordController,
                        obscureText: true,
                        decoration:
                            _fieldDecoration('Password', Icons.lock_outline),
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _pinController,
                        obscureText: true,
                        keyboardType: TextInputType.number,
                        decoration: _fieldDecoration(
                            'Authentication PIN', Icons.pin_outlined),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _login(),
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
                        onPressed: _login,
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
                        child: const Text('Login'),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Demo credentials: ${LoginScreen.validUsername} / '
                        '${LoginScreen.validPassword} / ${LoginScreen.validPin}',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11, color: dim),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
