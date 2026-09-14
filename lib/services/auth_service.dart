import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../models/admin_account.dart';
import '../models/organization_summary.dart';
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
  static const String _roleKey = 'cafetwin_role';
  static const String _usernameKey = 'cafetwin_username';

  /// Role of the currently logged-in user (`'admin'` or `'staff'`), kept in
  /// memory once set by [login]/[restoreSession] so UI code (e.g.
  /// [HomeShell]'s "Manage Users" action) can check it synchronously without
  /// an async storage read on every rebuild.
  static String? _currentRole;

  /// Username of the currently logged-in user, kept the same way as
  /// [_currentRole]. Used to disable "delete this account" for whichever
  /// account you're currently logged in as, in [UserManagementScreen].
  static String? _currentUsername;

  /// True when a demo (offline, no-backend) fallback login is configured.
  static bool get hasDemoFallback =>
      _demoUsername.isNotEmpty &&
      _demoPassword.isNotEmpty &&
      _demoPin.isNotEmpty;

  /// Role of the currently logged-in user, or null if nobody is logged in
  /// yet (before the first successful [login]/[restoreSession]).
  static String? get currentRole => _currentRole;

  /// Username of the currently logged-in user, or null if nobody is logged
  /// in yet.
  static String? get currentUsername => _currentUsername;

  /// True when the currently logged-in user is an admin. Demo-fallback
  /// logins (no backend configured) are always treated as admin, since
  /// there is no real account/role behind them.
  static bool get isAdmin => _currentRole == 'admin';

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
        final String role = body['role'] as String? ?? 'admin';
        final String loggedInUsername = body['username'] as String? ?? username;
        await _storage.write(key: _tokenKey, value: token);
        await _storage.write(key: _roleKey, value: role);
        await _storage.write(key: _usernameKey, value: loggedInUsername);
        ApiService.setAuthToken(token);
        _currentRole = role;
        _currentUsername = loggedInUsername;
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
    if (ok) {
      // No backend, so no real role -- treat the one demo account as admin.
      _currentRole = 'admin';
      _currentUsername = username;
    }
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
    _currentRole = await _storage.read(key: _roleKey) ?? 'admin';
    _currentUsername = await _storage.read(key: _usernameKey);
    return true;
  }

  /// Clears the stored token, role and username (logout).
  static Future<void> logout() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _roleKey);
    await _storage.delete(key: _usernameKey);
    ApiService.setAuthToken(null);
    _currentRole = null;
    _currentUsername = null;
  }

  /// Lists organizations the currently logged-in admin has created.
  /// Admin-only on the backend -- returns null (rather than throwing) if
  /// unreachable, disabled, or the caller isn't an admin, since this is
  /// used to populate [OrganizationListScreen] rather than gate access
  /// itself (the backend is the real enforcement point).
  static Future<List<OrganizationSummary>?> listMyOrganizations() async {
    if (!ApiService.isEnabled) return null;
    try {
      final http.Response resp = await http
          .get(
            Uri.parse('${ApiService.baseUrl}/organizations'),
            headers: ApiService.authHeaders,
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final List<dynamic> body = jsonDecode(resp.body) as List<dynamic>;
        return body
            .map((dynamic e) =>
                OrganizationSummary.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Fetches one organization's full detail (name + station roster) so
  /// [OrganizationListScreen] can hand it to [CafeState.loadExisting].
  /// This route doesn't require auth on the backend, but a failure here
  /// still needs to be visible to the caller (unlike [ApiService]'s
  /// fire-and-forget calls), so it lives here rather than there.
  static Future<Map<String, dynamic>?> getOrganization(String id) async {
    if (!ApiService.isEnabled) return null;
    try {
      final http.Response resp = await http
          .get(Uri.parse('${ApiService.baseUrl}/organizations/$id'))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Deletes a login account. Returns null on success, or a short
  /// user-facing error message on failure (not authorized, self-delete,
  /// last-admin, not found, or the backend being unreachable).
  static Future<String?> deleteUser(String username) async {
    if (!ApiService.isEnabled) {
      return 'No backend is configured (API_BASE_URL not set).';
    }
    try {
      final http.Response resp = await http
          .delete(
            Uri.parse('${ApiService.baseUrl}/admin/users/$username'),
            headers: ApiService.authHeaders,
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 204) {
        return null;
      }
      if (resp.statusCode == 400 || resp.statusCode == 404) {
        try {
          final Map<String, dynamic> body =
              jsonDecode(resp.body) as Map<String, dynamic>;
          return body['error'] as String? ?? 'Could not delete that account.';
        } catch (_) {
          return 'Could not delete that account.';
        }
      }
      if (resp.statusCode == 403) {
        return 'Only an admin can delete accounts.';
      }
      return 'Failed to delete user (server responded with ${resp.statusCode}).';
    } catch (e) {
      return 'Could not reach the backend at ${ApiService.baseUrl}.';
    }
  }

  /// Lists existing login accounts. Admin-only on the backend -- returns
  /// null (rather than throwing) if unreachable, disabled, or the caller
  /// isn't an admin, since this is used to populate a UI list rather than
  /// gate access itself (the backend is the real enforcement point).
  static Future<List<AdminAccount>?> listUsers() async {
    if (!ApiService.isEnabled) return null;
    try {
      final http.Response resp = await http
          .get(
            Uri.parse('${ApiService.baseUrl}/admin/users'),
            headers: ApiService.authHeaders,
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final List<dynamic> body = jsonDecode(resp.body) as List<dynamic>;
        return body
            .map((dynamic e) => AdminAccount.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Creates a new login account. Returns null on success, or a short
  /// user-facing error message on failure (bad input, duplicate username,
  /// not authorized, or the backend being unreachable).
  static Future<String?> createUser({
    required String username,
    required String password,
    required String pin,
    required String role,
  }) async {
    if (!ApiService.isEnabled) {
      return 'No backend is configured (API_BASE_URL not set).';
    }
    try {
      final http.Response resp = await http
          .post(
            Uri.parse('${ApiService.baseUrl}/admin/users'),
            headers: ApiService.authHeaders,
            body: jsonEncode(<String, String>{
              'username': username,
              'password': password,
              'pin': pin,
              'role': role,
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 201) {
        return null;
      }
      if (resp.statusCode == 409) {
        return 'That username is already taken.';
      }
      if (resp.statusCode == 403) {
        return 'Only an admin can create new accounts.';
      }
      if (resp.statusCode == 400) {
        try {
          final Map<String, dynamic> body =
              jsonDecode(resp.body) as Map<String, dynamic>;
          return body['error'] as String? ?? 'Invalid request.';
        } catch (_) {
          return 'Invalid request.';
        }
      }
      return 'Failed to create user (server responded with ${resp.statusCode}).';
    } catch (e) {
      return 'Could not reach the backend at ${ApiService.baseUrl}.';
    }
  }
}
