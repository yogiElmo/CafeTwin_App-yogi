import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../models/admin_account.dart';
import '../models/organization_summary.dart';
import 'api_service.dart';

/// Result of an [AuthService.login] attempt.
///
/// [error] is a short, user-facing message and is null on success (a
/// token was stored and the login is complete). [requiresTotp] is true
/// only when the account has MFA enabled and this call didn't include a
/// (or included a wrong) `totpCode` -- [LoginScreen] uses this, rather
/// than treating it as a generic failure, to reveal the authentication
/// code field and let the admin submit the same credentials again with a
/// code attached.
class LoginResult {
  const LoginResult({this.error, this.requiresTotp = false});

  final String? error;
  final bool requiresTotp;

  bool get success => error == null;
}

/// Result of [AuthService.setupTotp]: the shared secret and the
/// otpauth:// URI to render as a QR code. Null fields mean the call
/// failed -- see [error].
class TotpSetup {
  const TotpSetup({this.secret, this.otpauthUrl, this.error});

  final String? secret;
  final String? otpauthUrl;
  final String? error;
}

/// Result of [AuthService.enableTotp]: the one-time batch of recovery
/// codes on success, or [error] on failure.
class TotpEnableResult {
  const TotpEnableResult({this.recoveryCodes, this.error});

  final List<String>? recoveryCodes;
  final String? error;
}

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
  static const String _organizationIdKey = 'cafetwin_organization_id';

  /// Organization a STAFF account is assigned to, as returned by
  /// `POST /auth/login`. Null for admins, who pick from their own list
  /// instead of belonging to one café.
  ///
  /// Cached purely so the app knows where to send the user; it is NOT the
  /// access control. The backend re-reads the assignment from the database
  /// on every request (`orgAccessError` in server.js), so tampering with
  /// this value client-side gains nothing.
  static String? _currentOrganizationId;

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

  /// Organization this account is assigned to, or null for an admin (and
  /// for a staff account whose organization has since been deleted, which
  /// the backend treats as "can read nothing" until reassigned).
  static String? get currentOrganizationId => _currentOrganizationId;

  /// Attempts to log in with the given credentials.
  ///
  /// [totpCode] is optional and only relevant against a real backend: pass
  /// it once [LoginResult.requiresTotp] comes back true from a first call
  /// that omitted it. See [LoginResult] for how success/failure/"need a
  /// code" are distinguished.
  static Future<LoginResult> login({
    required String username,
    required String password,
    required String pin,
    String? totpCode,
  }) async {
    if (ApiService.isEnabled) {
      return _loginAgainstBackend(username, password, pin, totpCode);
    }
    return _loginAgainstDemoFallback(username, password, pin);
  }

  static Future<LoginResult> _loginAgainstBackend(
    String username,
    String password,
    String pin,
    String? totpCode,
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
              if (totpCode != null && totpCode.isNotEmpty) 'totpCode': totpCode,
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final Map<String, dynamic> body =
            jsonDecode(resp.body) as Map<String, dynamic>;
        final String? token = body['token'] as String?;
        if (token == null) {
          return const LoginResult(
              error: 'Login succeeded but the server did not return a token.');
        }
        final String role = body['role'] as String? ?? 'admin';
        final String loggedInUsername = body['username'] as String? ?? username;
        final String? organizationId = body['organizationId'] as String?;
        await _storage.write(key: _tokenKey, value: token);
        await _storage.write(key: _roleKey, value: role);
        await _storage.write(key: _usernameKey, value: loggedInUsername);
        // Delete rather than write null -- flutter_secure_storage treats a
        // null value as a delete on some platforms and throws on others,
        // and an admin must not inherit a stale org from a previous staff
        // login on a shared browser profile.
        if (organizationId == null) {
          await _storage.delete(key: _organizationIdKey);
        } else {
          await _storage.write(key: _organizationIdKey, value: organizationId);
        }
        ApiService.setAuthToken(token);
        _currentRole = role;
        _currentUsername = loggedInUsername;
        _currentOrganizationId = organizationId;
        return const LoginResult();
      }
      if (resp.statusCode == 401) {
        // requiresTotp -- set on both "no code sent yet" and "wrong code"
        // -- is how the login screen knows to reveal the code field
        // rather than show a generic error. See admins.totp_enabled /
        // POST /auth/login in server.js.
        bool requiresTotp = false;
        String message = 'Invalid username, password or PIN.';
        try {
          final Map<String, dynamic> body =
              jsonDecode(resp.body) as Map<String, dynamic>;
          requiresTotp = body['requiresTotp'] == true;
          message = body['error'] as String? ?? message;
        } catch (_) {
          // Non-JSON 401 body (shouldn't happen) -- fall back to the
          // generic message above rather than throwing.
        }
        return LoginResult(error: message, requiresTotp: requiresTotp);
      }
      if (resp.statusCode == 429) {
        return const LoginResult(
            error: 'Too many attempts — please wait a minute and try again.');
      }
      return LoginResult(
          error: 'Login failed (server responded with ${resp.statusCode}).');
    } catch (e) {
      return LoginResult(
          error: 'Could not reach the backend at ${ApiService.baseUrl}. '
              'Check your connection or the configured API_BASE_URL.');
    }
  }

  static LoginResult _loginAgainstDemoFallback(
    String username,
    String password,
    String pin,
  ) {
    if (!hasDemoFallback) {
      return const LoginResult(
          error: 'No backend is configured (API_BASE_URL not set) and no demo '
              'credentials were provided.\nPass --dart-define=API_BASE_URL=... '
              'to log in against a real backend, or --dart-define=DEMO_USERNAME=... '
              '--dart-define=DEMO_PASSWORD=... --dart-define=DEMO_PIN=... for an '
              'offline demo.');
    }
    final bool ok = username == _demoUsername &&
        password == _demoPassword &&
        pin == _demoPin;
    if (ok) {
      // No backend, so no real role -- treat the one demo account as admin.
      _currentRole = 'admin';
      _currentUsername = username;
      // Offline demo has no backend and therefore no organization
      // assignment -- it behaves as an admin, who has none by design.
      _currentOrganizationId = null;
    }
    return ok
        ? const LoginResult()
        : const LoginResult(error: 'Invalid username, password or PIN.');
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
    _currentOrganizationId = await _storage.read(key: _organizationIdKey);
    return true;
  }

  /// Logs out: asks the backend to revoke this device's session
  /// server-side first (`POST /auth/logout`), then clears the stored
  /// token, role and username locally.
  ///
  /// The backend call is best-effort -- a network failure (or no backend
  /// being configured at all, e.g. the demo fallback) must never block a
  /// local logout, so any error there is swallowed and the local sign-out
  /// proceeds regardless. This is what makes "Logout" a real server-side
  /// action rather than just this device discarding its own copy of the
  /// token: once revoked, the old token is rejected by the backend on its
  /// very next use, even though it hasn't expired yet.
  static Future<void> logout() async {
    if (ApiService.isEnabled) {
      try {
        await http
            .post(
              Uri.parse('${ApiService.baseUrl}/auth/logout'),
              headers: ApiService.authHeaders,
            )
            .timeout(const Duration(seconds: 5));
      } catch (e) {
        developer.log(
          'POST /auth/logout failed (logging out locally anyway): $e',
          name: 'AuthService',
        );
      }
    }
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _roleKey);
    await _storage.delete(key: _usernameKey);
    await _storage.delete(key: _organizationIdKey);
    ApiService.setAuthToken(null);
    _currentRole = null;
    _currentUsername = null;
    _currentOrganizationId = null;
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
      // Not shown in the UI (which just says "check the backend connection")
      // but visible in the browser/device console -- a 500 here almost
      // always means the database schema is out of date (e.g. a column
      // `/admin/bootstrap` was meant to add hasn't been applied yet on the
      // deployed Postgres instance), while a 401/403 points at auth instead.
      developer.log(
        'GET /organizations failed: ${resp.statusCode} ${resp.body}',
        name: 'AuthService',
      );
      return null;
    } catch (e) {
      developer.log('GET /organizations threw: $e', name: 'AuthService');
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
      developer.log(
        'GET /organizations/$id failed: ${resp.statusCode} ${resp.body}',
        name: 'AuthService',
      );
      return null;
    } catch (e) {
      developer.log('GET /organizations/$id threw: $e', name: 'AuthService');
      return null;
    }
  }

  /// Deletes an organization the calling admin created. Returns null on
  /// success, or a short user-facing error message on failure (not
  /// authorized, not found/not yours, or the backend being unreachable).
  static Future<String?> deleteOrganization(String id) async {
    if (!ApiService.isEnabled) {
      return 'No backend is configured (API_BASE_URL not set).';
    }
    try {
      final http.Response resp = await http
          .delete(
            Uri.parse('${ApiService.baseUrl}/organizations/$id'),
            headers: ApiService.authHeaders,
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 204) {
        return null;
      }
      if (resp.statusCode == 404) {
        return 'That organization was not found.';
      }
      if (resp.statusCode == 403) {
        return 'Only an admin can delete organizations.';
      }
      return 'Failed to delete organization (server responded with ${resp.statusCode}).';
    } catch (e) {
      return 'Could not reach the backend at ${ApiService.baseUrl}.';
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
  /// [organizationId] is required when [role] is `'staff'` -- a staff
  /// account belongs to exactly one café, and the backend rejects the
  /// request without it. Admins take none.
  static Future<String?> createUser({
    required String username,
    required String password,
    required String pin,
    required String role,
    String? organizationId,
  }) async {
    if (!ApiService.isEnabled) {
      return 'No backend is configured (API_BASE_URL not set).';
    }
    try {
      final http.Response resp = await http
          .post(
            Uri.parse('${ApiService.baseUrl}/admin/users'),
            headers: ApiService.authHeaders,
            body: jsonEncode(<String, dynamic>{
              'username': username,
              'password': password,
              'pin': pin,
              'role': role,
              if (organizationId != null) 'organizationId': organizationId,
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

  // ------------------------------------------------------------------
  // TOTP multi-factor auth (admin accounts only -- see the "TOTP
  // MULTI-FACTOR AUTHENTICATION" section of cafetwin_backend_devops/
  // server.js). Every method below operates on the CALLING admin's own
  // account; there is no "set up MFA for someone else."
  // ------------------------------------------------------------------

  /// Whether the currently logged-in admin has MFA enabled. Returns null
  /// (rather than throwing) if unreachable, disabled, or the caller isn't
  /// an admin.
  static Future<bool?> getTotpStatus() async {
    if (!ApiService.isEnabled) return null;
    try {
      final http.Response resp = await http
          .get(
            Uri.parse('${ApiService.baseUrl}/auth/totp/status'),
            headers: ApiService.authHeaders,
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final Map<String, dynamic> body =
            jsonDecode(resp.body) as Map<String, dynamic>;
        return body['enabled'] as bool? ?? false;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Step 1 of turning MFA on: asks the backend for a fresh secret and
  /// the otpauth:// URI to render as a QR code (see [TotpSetup]). This
  /// does not enable MFA by itself -- call [enableTotp] with a code from
  /// the just-scanned authenticator app to finish.
  static Future<TotpSetup> setupTotp() async {
    if (!ApiService.isEnabled) {
      return const TotpSetup(error: 'No backend is configured (API_BASE_URL not set).');
    }
    try {
      final http.Response resp = await http
          .post(
            Uri.parse('${ApiService.baseUrl}/auth/totp/setup'),
            headers: ApiService.authHeaders,
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final Map<String, dynamic> body =
            jsonDecode(resp.body) as Map<String, dynamic>;
        return TotpSetup(
          secret: body['secret'] as String?,
          otpauthUrl: body['otpauthUrl'] as String?,
        );
      }
      if (resp.statusCode == 403) {
        return const TotpSetup(error: 'Only an admin can set up MFA.');
      }
      return TotpSetup(
          error: 'Failed to start MFA setup (server responded with ${resp.statusCode}).');
    } catch (e) {
      return TotpSetup(error: 'Could not reach the backend at ${ApiService.baseUrl}.');
    }
  }

  /// Step 2: confirms setup with the current 6-digit code from the
  /// authenticator app. On success, MFA is now required at login and
  /// [TotpEnableResult.recoveryCodes] holds 8 one-time codes that are
  /// shown ONLY in this response -- the caller must display them for the
  /// admin to save before navigating away.
  static Future<TotpEnableResult> enableTotp(String totpCode) async {
    if (!ApiService.isEnabled) {
      return const TotpEnableResult(error: 'No backend is configured (API_BASE_URL not set).');
    }
    try {
      final http.Response resp = await http
          .post(
            Uri.parse('${ApiService.baseUrl}/auth/totp/enable'),
            headers: ApiService.authHeaders,
            body: jsonEncode(<String, String>{'totpCode': totpCode}),
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final Map<String, dynamic> body =
            jsonDecode(resp.body) as Map<String, dynamic>;
        final List<dynamic> codes = body['recoveryCodes'] as List<dynamic>? ?? <dynamic>[];
        return TotpEnableResult(
            recoveryCodes: codes.map((dynamic c) => c as String).toList());
      }
      if (resp.statusCode == 401) {
        return const TotpEnableResult(error: 'Invalid authentication code.');
      }
      return TotpEnableResult(
          error: 'Failed to enable MFA (server responded with ${resp.statusCode}).');
    } catch (e) {
      return TotpEnableResult(error: 'Could not reach the backend at ${ApiService.baseUrl}.');
    }
  }

  /// Turns MFA off using the account's own current password + PIN (not a
  /// TOTP code -- see the comment on POST /auth/totp/disable in
  /// server.js for why). Returns null on success, or a short user-facing
  /// error message on failure.
  static Future<String?> disableTotp({
    required String password,
    required String pin,
  }) async {
    if (!ApiService.isEnabled) {
      return 'No backend is configured (API_BASE_URL not set).';
    }
    try {
      final http.Response resp = await http
          .post(
            Uri.parse('${ApiService.baseUrl}/auth/totp/disable'),
            headers: ApiService.authHeaders,
            body: jsonEncode(<String, String>{'password': password, 'pin': pin}),
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 204) {
        return null;
      }
      if (resp.statusCode == 401) {
        return 'Invalid password or PIN.';
      }
      return 'Failed to disable MFA (server responded with ${resp.statusCode}).';
    } catch (e) {
      return 'Could not reach the backend at ${ApiService.baseUrl}.';
    }
  }

  /// Invalidates every existing recovery code and issues a fresh batch of
  /// 8, shown ONCE, same re-authentication as [disableTotp].
  static Future<TotpEnableResult> regenerateRecoveryCodes({
    required String password,
    required String pin,
  }) async {
    if (!ApiService.isEnabled) {
      return const TotpEnableResult(error: 'No backend is configured (API_BASE_URL not set).');
    }
    try {
      final http.Response resp = await http
          .post(
            Uri.parse('${ApiService.baseUrl}/auth/totp/recovery-codes/regenerate'),
            headers: ApiService.authHeaders,
            body: jsonEncode(<String, String>{'password': password, 'pin': pin}),
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final Map<String, dynamic> body =
            jsonDecode(resp.body) as Map<String, dynamic>;
        final List<dynamic> codes = body['recoveryCodes'] as List<dynamic>? ?? <dynamic>[];
        return TotpEnableResult(
            recoveryCodes: codes.map((dynamic c) => c as String).toList());
      }
      if (resp.statusCode == 401) {
        return const TotpEnableResult(error: 'Invalid password or PIN.');
      }
      if (resp.statusCode == 400) {
        return const TotpEnableResult(error: 'MFA is not enabled on this account.');
      }
      return TotpEnableResult(
          error: 'Failed to regenerate recovery codes (server responded with ${resp.statusCode}).');
    } catch (e) {
      return TotpEnableResult(error: 'Could not reach the backend at ${ApiService.baseUrl}.');
    }
  }
}
