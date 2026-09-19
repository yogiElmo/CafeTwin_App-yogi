import 'dart:async';

import 'package:flutter/material.dart';

import '../models/station.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../state/cafe_state.dart';
import '../widgets/monitor_illustration.dart';
import 'home_shell.dart';
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
  final TextEditingController _totpController = TextEditingController();

  String? _error;
  bool _submitting = false;
  bool _checkingSession = true;

  /// True once a request has been in flight longer than a warm backend
  /// would ever take. The backend is on Render's free tier, which sleeps
  /// when idle and can take the best part of a minute to wake; without
  /// this the user just sees a spinner and assumes it has hung.
  bool _slowRequest = false;
  Timer? _slowRequestTimer;

  /// True once the backend has responded to a login attempt with
  /// `requiresTotp: true` -- i.e. password+PIN were correct, but this
  /// account has MFA enabled and needs a code too. Reveals the
  /// authentication-code field so the SAME credentials can be resubmitted
  /// with it, rather than treating this as a generic login failure.
  bool _needsTotp = false;

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
      await _goToNextScreen();
      return;
    }
    setState(() => _checkingSession = false);
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _pinController.dispose();
    _totpController.dispose();
    _slowRequestTimer?.cancel();
    super.dispose();
  }

  /// Admins land on [OrganizationListScreen] -- their own cafés, plus the
  /// option to set up a new one.
  ///
  /// Staff are assigned to exactly ONE café by an admin, so they go
  /// straight into it. They used to be sent to [SetupScreen] instead,
  /// which is the *create an organization* form -- the one thing a staff
  /// account is not allowed to do. The backend now refuses it outright
  /// (`requireAdminOrService` on `POST /organizations`); this just stops
  /// the app walking them into a dead end.
  ///
  /// A staff account with no organization -- possible only if the café was
  /// deleted after the account was made, which sets `organization_id` to
  /// NULL -- gets a plain explanation rather than a broken screen.
  Future<void> _goToNextScreen() async {
    // Clear whatever the PREVIOUS account left loaded, before routing.
    //
    // [CafeState.loadExisting] and [CafeState.configure] are both one-shot:
    // each returns early once `_isConfigured` is true. Logging out
    // deliberately does not reset [CafeState], so without this a second
    // login on the same app instance silently kept the first account's
    // café -- every staff member landed in whichever organization happened
    // to be opened first, whatever they were actually assigned.
    //
    // This is about isolation as much as correctness: on a shared café
    // terminal, one staff member must not see the previous one's
    // organization name and station roster.
    widget.state.reset();

    if (AuthService.isAdmin) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              OrganizationListScreen(state: widget.state),
        ),
      );
      return;
    }

    // Offline demo logins have no backend and no real account behind them,
    // so there is nothing to load -- keep the original setup flow there.
    final String? organizationId = AuthService.currentOrganizationId;
    if (!ApiService.isEnabled || organizationId == null) {
      if (ApiService.isEnabled) {
        setState(() {
          _error = 'This staff account is not assigned to an organization. '
              'Ask an admin to assign one.';
          _submitting = false;
          _checkingSession = false;
        });
        return;
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => SetupScreen(state: widget.state),
        ),
      );
      return;
    }

    final Map<String, dynamic>? detail =
        await AuthService.getOrganization(organizationId);
    if (!mounted) return;
    if (detail == null) {
      setState(() {
        _error = 'Could not open your organization. '
            'Check the backend connection and try again.';
        _submitting = false;
        _checkingSession = false;
      });
      return;
    }

    final List<dynamic> stationsJson =
        detail['stations'] as List<dynamic>? ?? <dynamic>[];
    widget.state.loadExisting(
      organizationId: organizationId,
      company: detail['name'] as String? ?? 'Your café',
      stations: stationsJson
          .map((dynamic s) => Station.fromJson(s as Map<String, dynamic>))
          .toList(),
    );

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => HomeShell(state: widget.state),
      ),
    );
  }

  Future<void> _login() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
      _slowRequest = false;
    });
    _slowRequestTimer?.cancel();
    _slowRequestTimer = Timer(AuthService.coldStartHintAfter, () {
      if (mounted && _submitting) setState(() => _slowRequest = true);
    });

    final LoginResult result = await AuthService.login(
      username: _usernameController.text.trim(),
      password: _passwordController.text,
      pin: _pinController.text.trim(),
      totpCode: _needsTotp ? _totpController.text.trim() : null,
    );
    _slowRequestTimer?.cancel();
    if (!mounted) return;
    if (!result.success) {
      setState(() {
        _submitting = false;
        _slowRequest = false;
        _error = result.error;
        // Sticky once true within this attempt -- a wrong code re-shows
        // the field rather than collapsing it back to a plain error.
        _needsTotp = _needsTotp || result.requiresTotp;
      });
      return;
    }
    await _goToNextScreen();
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
                        textInputAction: _needsTotp
                            ? TextInputAction.next
                            : TextInputAction.done,
                        onSubmitted: (_) => _needsTotp ? null : _login(),
                      ),
                      if (_needsTotp) ...<Widget>[
                        const SizedBox(height: 14),
                        Text(
                          'Enter the 6-digit code from your authenticator '
                          'app (or a recovery code).',
                          style: TextStyle(fontSize: 12, color: dim),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _totpController,
                          autofocus: true,
                          decoration: _fieldDecoration(
                              'Authentication code', Icons.security_outlined),
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _login(),
                        ),
                      ],
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
                      // Shown only once a request has outlasted what a warm
                      // backend takes, so a free-tier cold start reads as
                      // "waking up" rather than "broken". See
                      // AuthService.requestTimeout.
                      if (_slowRequest) ...<Widget>[
                        const SizedBox(height: 12),
                        const Text(
                          'Waking the server — it sleeps when idle and can '
                          'take up to a minute to start. Hang on…',
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0xFFCC9A48),
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
                            : Text(_needsTotp ? 'Verify code' : 'Login'),
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
