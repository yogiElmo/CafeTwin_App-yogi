import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'api_service.dart';

/// Handles admin login against the CaféTwin backend and stores the
/// resulting JWT securely on-device.
///
/// The app has no hardcoded credentials any more. When a backend is
/// configured (`API_BASE_URL` set at build/run time), login goes through
/// `POST /auth/login` and the returned token is required for every
/// subsequent authenticated write -- [ApiService] attaches it automatically
/// once [login] succeeds.
///
/// When no backend is configured, this falls back to build-time demo
/// credentials supplied via `--dart-define` (`DEMO_USERNAME`/
/// `DEMO_PASSWORD`/`DEMO_PIN`), so a pure offline-simulation demo is still
/// possible without ever putting a real credential in source control. If
/// those are also unset, login is disabled with a clear explanation rather
/// than silently accepting anything.
class AuthService {
  AuthService._();

  static const String _demoUsername =
      String.fromEnvironment('DEMO_USERNAME', defaultValue: '');
  static const String _demoPassword =
      String.fromEnvironment('DEMO_PASSWORD', defaultValue: '');
  static const String _demoPin =
      String.fromEnvironment('DEMO_PIN', defaultValue: '');

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _tokenKey = 'cafetwin_jwt';

  /// True when a demo (offline, no-backend) fallback login is configured.
  static bool get hasDemoFallback =>
      _demoUsername.isNotEmpty &&
      _demoPassword.isNotEmpty &&
      _demoPin.isNotEmpty;

  /// Attempts to log in with the given credentials.
  ///
  /// Returns null on success (a token is stored and [ApiService] is armed
  /// for authenticated writes), or a short, user-facing error message on
  /// failure.
  static Future<String?> login({
    required String username,
    required String password,
    required String pin,
  }) async {
    if (ApiService.isEnabled) {
      return _loginAgainstBackend(username, password, pin);
    }
    return _loginAgainstDemoFallback(username, password, pin);
  }

  static Future<String?> _loginAgainstBackend(
    String username,
    String password,
    String pin,
  ) async {
    try {
      final http.Response resp = await http
          .post(
            Uri.parse('${ApiService.baseUrl}/auth/login'),
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, String>{
              'username': username,
              'password': password,
              'pin': pin,
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final Map<String, dynamic> body =
            jsonDecode(resp.body) as Map<String, dynamic>;
        final String? token = body['token'] as String?;
        if (token == null) {
          return 'Login succeeded but the server did not return a token.';
        }
        await _storage.write(key: _tokenKey, value: token);
        ApiService.setAuthToken(token);
        return null;
      }
      if (resp.statusCode == 401) {
        return 'Invalid username, password or PIN.';
      }
      if (resp.statusCode == 429) {
        return 'Too many attempts — please wait a minute and try again.';
      }
      return 'Login failed (server responded with ${resp.statusCode}).';
    } catch (e) {
      return 'Could not reach the backend at ${ApiService.baseUrl}. '
          'Check your connection or the configured API_BASE_URL.';
    }
  }

  static String? _loginAgainstDemoFallback(
    String username,
    String password,
    String pin,
  ) {
    if (!hasDemoFallback) {
      return 'No backend is configured (API_BASE_URL not set) and no demo '
          'credentials were provided.\nPass --dart-define=API_BASE_URL=... '
          'to log in against a real backend, or --dart-define=DEMO_USERNAME=... '
          '--dart-define=DEMO_PASSWORD=... --dart-define=DEMO_PIN=... for an '
          'offline demo.';
    }
    final bool ok = username == _demoUsername &&
        password == _demoPassword &&
        pin == _demoPin;
    return ok ? null : 'Invalid username, password or PIN.';
  }

  /// Restores a previously stored token (e.g. on app relaunch) into
  /// [ApiService] so authenticated calls keep working without a fresh
  /// login. Returns true if a token was found and restored.
  ///
  /// This does not verify the token is still valid (that only happens
  /// server-side on the next authenticated call) -- an expired token will
  /// simply fail on first use, at which point [logout] should be called.
  static Future<bool> restoreSession() async {
    if (!ApiService.isEnabled) {
      return false;
    }
    final String? token = await _storage.read(key: _tokenKey);
    if (token == null) {
      return false;
    }
    ApiService.setAuthToken(token);
    return true;
  }

  /// Clears the stored token (logout).
  static Future<void> logout() async {
    await _storage.delete(key: _tokenKey);
    ApiService.setAuthToken(null);
  }
}
