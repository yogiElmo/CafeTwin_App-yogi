import 'package:flutter/material.dart';

import '../models/station.dart';
import '../services/auth_service.dart';
import '../state/cafe_state.dart';
import '../widgets/monitor_illustration.dart';
import 'organization_list_screen.dart';
import 'setup_screen.dart';

/// Onboarding page 1: admin login.
///
/// A centered card on the dark background with three fields (username,
/// password, authentication PIN). Credentials are checked against the
/// backend's POST /auth/login (see [AuthService]) -- there are no
/// credentials baked into the app. On success the admin is pushed
/// (replacement) to the organization setup screen.
class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.state,
    this.justLoggedOut = false,
  });

  final CafeState state;

  /// True when this screen was reached via a "Logout" action -- shows a
  /// one-time confirmation snackbar so it's clear the logout actually
  /// happened, rather than landing back here with no feedback at all.
  final bool justLoggedOut;

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
  bool _submitting = false;
  bool _checkingSession = true;

  @override
  void initState() {
    super.initState();
    _tryRestoreSession();
    if (widget.justLoggedOut) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You have been logged out.'),
            duration: Duration(seconds: 3),
          ),
        );
      });
    }
  }

  /// If a previously-issued token is still stored (e.g. the app was
  /// relaunched), skip straight to setup/organizations instead of asking
  /// for credentials again. An expired token simply fails on first use,
  /// which the rest of the app already treats as a best-effort call.
  Future<void> _tryRestoreSession() async {
    final bool restored = await AuthService.restoreSession();
    if (!mounted) return;
    if (restored) {
      _goToNextScreen();
      return;
    }
    setState(() => _checkingSession = false);
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  /// Admins land on [OrganizationListScreen] (their own organizations,
  /// plus the option to set up a new one); staff go straight to
  /// [SetupScreen], same as every login before this screen existed.
  void _goToNextScreen() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => AuthService.isAdmin
            ? OrganizationListScreen(state: widget.state)
            : SetupScreen(state: widget.state),
      ),
    );
  }

  Future<void> _login() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final String? error = await AuthService.login(
      username: _usernameController.text.trim(),
      password: _passwordController.text,
      pin: _pinController.text.trim(),
    );
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _submitting = false;
        _error = error;
      });
      return;
    }
    _goToNextScreen();
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
    if (_checkingSession) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final Color dim =
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);

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
                  side: BorderSide(color: _amber.withValues(alpha: 0.30)),
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
                        onPressed: _submitting ? null : _login,
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
                        child: _submitting
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  color: Color(0xFF1E1B18),
                                ),
                              )
                            : const Text('Login'),
                      ),
                      if (AuthService.hasDemoFallback) ...<Widget>[
                        const SizedBox(height: 16),
                        Text(
                          'Offline demo mode: signing in with the '
                          'configured demo credentials (no backend).',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 11, color: dim),
                        ),
                      ],
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
