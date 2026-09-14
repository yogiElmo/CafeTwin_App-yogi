import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/alert.dart';
import '../models/report_entry.dart';
import '../services/digital_twin.dart';

/// Thin, best-effort client for the CaféTwin backend
/// (`cafetwin_backend_devops/server.js`).
///
/// The dashboard is designed to run fully offline on its built-in
/// simulation, so every call here is fire-and-forget: failures are logged
/// to stdout and swallowed rather than surfaced in the UI or thrown, so a
/// missing/unreachable backend never breaks the live demo.
///
/// Configure the backend location at build/run time, no code changes
/// needed:
///   flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:3000
///   flutter build web --dart-define=API_BASE_URL=https://your-api.onrender.com
///
/// Leave API_BASE_URL unset to disable networking entirely (pure offline
/// simulation, the original behaviour of this app).
class ApiService {
  ApiService._();

  static const String _baseUrl =
      String.fromEnvironment('API_BASE_URL', defaultValue: '');

  static const String _apiKey =
      String.fromEnvironment('API_KEY', defaultValue: '');

  /// JWT issued by POST /auth/login, set via [setAuthToken] once a human
  /// admin logs in. When present, it is sent instead of the static
  /// [_apiKey] on every write -- see [_headers].
  static String? _authToken;

  /// Backend base URL, exposed so [AuthService] can call /auth/login
  /// without duplicating the --dart-define configuration.
  static String get baseUrl => _baseUrl;

  /// Sets (or clears, with null) the JWT attached to future requests.
  /// Called by [AuthService] after a successful login/logout.
  static void setAuthToken(String? token) {
    _authToken = token;
  }

  /// True when a backend URL was supplied at build/run time.
  static bool get isEnabled => _baseUrl.isNotEmpty;

  static Map<String, String> get _headers => <String, String>{
        'Content-Type': 'application/json',
        if (_authToken != null) 'Authorization': 'Bearer $_authToken',
        if (_authToken == null && _apiKey.isNotEmpty) 'x-api-key': _apiKey,
      };

  /// Same headers used for every fire-and-forget call in this class,
  /// exposed so [AuthService] can call admin-only endpoints (which need
  /// real success/error surfacing, unlike everything else here) without
  /// duplicating the auth-header logic.
  static Map<String, String> get authHeaders => _headers;

  static Uri _uri(String path) => Uri.parse('$_baseUrl$path');

  /// Registers the organization + station roster with the backend.
  /// Returns the backend's organizationId, or null if disabled/unreachable.
  static Future<String?> createOrganization({
    required String name,
    required List<String> stationCategories,
  }) async {
    if (!isEnabled) return null;
    try {
      final http.Response resp = await http
          .post(
            _uri('/organizations'),
            headers: _headers,
            body: jsonEncode(<String, dynamic>{
              'name': name,
              'stations': stationCategories
                  .map((String c) => <String, String>{'category': c})
                  .toList(),
            }),
          )
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 201) {
        final Map<String, dynamic> body =
            jsonDecode(resp.body) as Map<String, dynamic>;
        return body['organizationId'] as String?;
      }
      _logFailure('createOrganization', resp);
    } catch (e) {
      _logError('createOrganization', e);
    }
    return null;
  }

  /// Pushes one station's current telemetry snapshot to the backend.
  /// Uses the app's own station id (e.g. `ST-01`) as the backend station id.
  static Future<void> postTelemetry(StationTwin twin) async {
    if (!isEnabled) return;
    try {
      final http.Response resp = await http
          .post(
            _uri('/stations/${twin.id}/telemetry'),
            headers: _headers,
            body: jsonEncode(<String, dynamic>{
              'cpuTemp': twin.hardware.cpuTemp,
              'gpuTemp': twin.hardware.gpuTemp,
              'cpuLoad': twin.hardware.cpuLoad,
              'gpuLoad': twin.hardware.gpuLoad,
              'bandwidthMbps': twin.network.bandwidthMbps,
              'latencyMs': twin.network.latencyMs,
              'packetLoss': twin.network.packetLoss,
              'occupied': twin.session.occupied,
              'sessionMinutes': twin.session.sessionMinutes,
              'game': twin.session.game,
            }),
          )
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 201) _logFailure('postTelemetry', resp);
    } catch (e) {
      _logError('postTelemetry', e);
    }
  }

  /// Records a newly fired alert in the backend.
  static Future<void> postAlert(Alert alert) async {
    if (!isEnabled) return;
    try {
      final http.Response resp = await http
          .post(
            _uri('/stations/${alert.stationId}/alerts'),
            headers: _headers,
            body: jsonEncode(<String, dynamic>{
              'ruleCode': alert.ruleCode,
              'category': alert.category.name,
              'severity': alert.severity.name,
              'message': alert.message,
              'suggestion': alert.suggestion,
            }),
          )
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 201) _logFailure('postAlert', resp);
    } catch (e) {
      _logError('postAlert', e);
    }
  }

  /// Syncs an acknowledge/resolve flag change for one alert. `alertId` here
  /// is the app-local id; since the backend mints its own alert ids on
  /// insert, this is a best-effort no-op if the ids were never matched --
  /// kept simple deliberately (see README note on syncing ids one-way).
  static Future<void> patchAlert(
    String backendAlertId, {
    bool? acknowledged,
    bool? resolved,
  }) async {
    if (!isEnabled) return;
    try {
      final http.Response resp = await http
          .patch(
            _uri('/alerts/$backendAlertId'),
            headers: _headers,
            body: jsonEncode(<String, dynamic>{
              if (acknowledged != null) 'acknowledged': acknowledged,
              if (resolved != null) 'resolved': resolved,
            }),
          )
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) _logFailure('patchAlert', resp);
    } catch (e) {
      _logError('patchAlert', e);
    }
  }

  /// Upserts one optimization/prediction insight as a report entry.
  static Future<void> postReportEntry(
    String organizationId,
    ReportEntry entry,
  ) async {
    if (!isEnabled) return;
    try {
      final http.Response resp = await http
          .post(
            _uri('/organizations/$organizationId/report-entries'),
            headers: _headers,
            body: jsonEncode(<String, dynamic>{
              'stationId': entry.stationId,
              'stationName': entry.stationName,
              'category': entry.category,
              'kind': entry.kind.name,
              'title': entry.title,
              'detail': entry.detail,
              'impact': entry.impact,
            }),
          )
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200 && resp.statusCode != 201) {
        _logFailure('postReportEntry', resp);
      }
    } catch (e) {
      _logError('postReportEntry', e);
    }
  }

  /// Resolves the most recent active alert for a (station, ruleCode) pair.
  /// Used when the app detects an alert condition cleared, so the backend
  /// can release any Squid throttle it applied for NET-BW/NET-LAT alerts —
  /// see cafetwin_backend_devops/squid_controller.js.
  static Future<void> resolveAlert(String stationId, String ruleCode) async {
    if (!isEnabled) return;
    try {
      final http.Response resp = await http
          .post(
            _uri('/stations/$stationId/alerts/$ruleCode/resolve'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) _logFailure('resolveAlert', resp);
    } catch (e) {
      _logError('resolveAlert', e);
    }
  }

  /// Notifies the backend that a station's session ended (staff action).
  static Future<void> postSessionEnd(String stationId) async {
    if (!isEnabled) return;
    try {
      final http.Response resp = await http
          .post(_uri('/stations/$stationId/sessions/end'), headers: _headers)
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) _logFailure('postSessionEnd', resp);
    } catch (e) {
      _logError('postSessionEnd', e);
    }
  }

  static void _logFailure(String op, http.Response resp) {
    // ignore: avoid_print
    print('[ApiService] $op failed: ${resp.statusCode} ${resp.body}');
  }

  static void _logError(String op, Object e) {
    // ignore: avoid_print
    print('[ApiService] $op error (backend unreachable?): $e');
  }
}
