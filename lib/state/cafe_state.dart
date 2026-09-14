import 'package:flutter/foundation.dart';

import '../models/alert.dart';
import '../models/insight.dart';
import '../models/report_entry.dart';
import '../models/station.dart';
import '../services/api_service.dart';
import '../services/digital_twin.dart';
import '../services/insights_engine.dart';
import '../services/rules_engine.dart';
import '../services/simulation_engine.dart';

/// Application state: owns the simulation engine, the configured station
/// twins and the alert list (active + acknowledged + resolved history).
///
/// No state-management packages: UI listens to this [ChangeNotifier] via
/// AnimatedBuilder/ListenableBuilder, and it is passed down by constructor
/// injection.
///
/// The simulation is NOT created in the constructor — it is built and
/// started exactly once when [configure] is called from the organization
/// setup screen, so no timers run while the admin is still logging in.
class CafeState extends ChangeNotifier {
  /// Upper bound on stored alerts; oldest resolved+acknowledged alerts are
  /// pruned first so the feed cannot grow without limit.
  static const int _maxStoredAlerts = 400;

  /// Upper bound on simulation event-log entries; oldest are dropped.
  static const int _maxEventLogEntries = 100;

  /// Upper bound on recorded insight entries; oldest by lastSeen are dropped.
  static const int _maxReportEntries = 2000;

  List<StationTwin> _twins = <StationTwin>[];

  /// Null until [configure] is called; the engine is only created (and
  /// started) once the organization setup is complete.
  SimulationEngine? _engine;

  bool _isConfigured = false;
  String _companyName = '';
  DateTime? _configuredAt;

  /// Backend organization id once [ApiService.createOrganization] succeeds;
  /// null while offline (no `API_BASE_URL` configured) or unreachable.
  /// See [ApiService] docs — the app runs fine on the simulation alone
  /// with this permanently null.
  String? _backendOrgId;

  /// Backend id of this run, if the app is wired to a live backend.
  String? get backendOrgId => _backendOrgId;

  /// True when this build was launched with `--dart-define=API_BASE_URL=...`
  /// so the UI can show a "live/offline" indicator if desired.
  bool get isBackendEnabled => ApiService.isEnabled;

  /// Throttle telemetry uploads: push every Nth tick per station instead of
  /// every 2s tick, so a slow/free-tier backend isn't flooded.
  static const int _telemetryUploadEveryNTicks = 5;
  int _tickCount = 0;

  /// True once [configure] has run (dashboard may be shown).
  bool get isConfigured => _isConfigured;

  /// Organization name entered on the setup screen ('' before that).
  String get companyName => _companyName;

  /// Wall-clock time [configure] ran (start of the reporting period);
  /// null before configuration.
  DateTime? get configuredAt => _configuredAt;

  /// Builds the station twins + simulation engine from the organization
  /// setup form and starts the simulation. Safe to call only once; later
  /// calls are ignored so the engine's timer can never be started twice.
  ///
  /// Registers with the backend FIRST (when `API_BASE_URL` is configured)
  /// and, on success, builds the station twins from the backend's own
  /// response instead of generating ids locally -- otherwise the local
  /// twins (previously always `ST-01`, `ST-02`, ...) and the rows the
  /// backend actually created (e.g. `ST-<org>-01`) never matched, so
  /// every telemetry/alert post for a freshly-created organization was
  /// silently failing a foreign-key check server-side the whole time.
  /// [ApiService.createOrganization] still never throws and still returns
  /// null on any failure/timeout (5s), so offline/unreachable behaves
  /// exactly as before: falls straight through to locally-generated ids
  /// and the simulation starts immediately either way.
  Future<void> configure(
    String company,
    List<String> categoriesPerStation,
  ) async {
    if (_isConfigured) {
      return;
    }

    final Map<String, dynamic>? registration = await ApiService.createOrganization(
      name: company,
      stationCategories: categoriesPerStation,
    );

    List<Station> stations;
    if (registration != null) {
      final List<dynamic> stationsJson =
          registration['stations'] as List<dynamic>? ?? <dynamic>[];
      stations = stationsJson
          .map((dynamic s) => Station.fromJson(s as Map<String, dynamic>))
          .toList();
      _backendOrgId = registration['organizationId'] as String?;
    } else {
      stations = List<Station>.generate(
        categoriesPerStation.length,
        (int i) => Station.fromConfig(i, categoriesPerStation[i]),
      );
    }

    _initSimulation(stations);
    _companyName = company;
    _configuredAt = DateTime.now();
    _isConfigured = true;
    _engine!.start();
    notifyListeners();
  }

  /// Loads a previously-created organization (as returned by
  /// `GET /organizations/:id`) and starts a fresh simulation for its
  /// existing station roster, without re-registering with the backend --
  /// used when an admin picks an organization from [OrganizationListScreen]
  /// instead of creating a new one via [configure].
  ///
  /// Reuses the backend's own station ids/names/categories (via
  /// [Station.fromJson]) rather than regenerating them locally, so
  /// telemetry/alerts posted from this session land against the same rows
  /// the backend already has for this organization.
  ///
  /// Note: only the station roster is restored -- there's no persisted
  /// "live" telemetry/alert state to resume, so the simulation starts
  /// fresh for these stations, exactly as if they were just configured.
  /// Safe to call only once, same as [configure].
  void loadExisting({
    required String organizationId,
    required String company,
    required List<Station> stations,
  }) {
    if (_isConfigured) {
      return;
    }
    _initSimulation(stations);
    _companyName = company;
    _configuredAt = DateTime.now();
    _isConfigured = true;
    _backendOrgId = organizationId;
    _engine!.start();
    notifyListeners();
  }

  /// Tears down the current organization's simulation (stopping its timer)
  /// and clears every bit of state [configure]/[loadExisting] set, so
  /// either can be called again afterwards -- both are otherwise one-shot,
  /// guarded by [_isConfigured].
  ///
  /// Used by [HomeShell]'s "Leave Organization" action: an admin steps
  /// back out to [OrganizationListScreen] without logging out of their
  /// account, and this is what makes picking a *different* organization
  /// next actually take effect instead of silently no-op'ing.
  void reset() {
    _engine?.dispose();
    _engine = null;
    _twins = <StationTwin>[];
    _alerts.clear();
    _eventLog.clear();
    _records.clear();
    _recordSeq = 0;
    _tickCount = 0;
    _isConfigured = false;
    _companyName = '';
    _configuredAt = null;
    _backendOrgId = null;
    notifyListeners();
  }

  /// Shared twin/engine creation used by [configure] (mirrors what the
  /// constructor used to do, minus starting the engine).
  void _initSimulation(List<Station> stations) {
    _twins = stations
        .map((Station s) => StationTwin(station: s))
        .toList();
    final SimulationEngine engine =
        SimulationEngine(twins: _twins, onTick: _onTick);
    engine.onEvent = _onEngineEvent;
    _engine = engine;
  }

  /// All alerts ever fired (minus pruned ones), in chronological order.
  final List<Alert> _alerts = <Alert>[];

  /// Simulation event log, newest first (entries are timestamped strings).
  final List<String> _eventLog = <String>[];

  /// Persistent session record of every insight (optimization + prediction)
  /// detected while the organization runs. Entries are upserted per tick —
  /// see [_recordInsights].
  final List<ReportEntry> _records = <ReportEntry>[];

  /// Sequence number for generated record ids.
  int _recordSeq = 0;

  /// The full insight record, newest lastSeen first.
  List<ReportEntry> get records {
    final List<ReportEntry> sorted = List<ReportEntry>.of(_records);
    sorted.sort((ReportEntry a, ReportEntry b) =>
        b.lastSeen.compareTo(a.lastSeen));
    return List<ReportEntry>.unmodifiable(sorted);
  }

  /// Recorded insights belonging to one station, newest lastSeen first.
  List<ReportEntry> recordsFor(String stationId) {
    return records
        .where((ReportEntry e) => e.stationId == stationId)
        .toList();
  }

  /// The configured station twins, in floor order ST-01 .. ST-NN.
  List<StationTwin> get stationList => List<StationTwin>.unmodifiable(_twins);

  /// All alerts, newest first.
  List<Alert> get alerts => List<Alert>.unmodifiable(_alerts.reversed);

  /// Number of alerts that are still active and not yet acknowledged —
  /// shown as the badge on the Alerts tab.
  int get activeAlertCount =>
      _alerts.where((Alert a) => !a.acknowledged && !a.resolved).length;

  StationTwin twinFor(String stationId) {
    return _twins.firstWhere((StationTwin t) => t.id == stationId);
  }

  /// Alerts for one station, newest first.
  List<Alert> alertsFor(String stationId) {
    return _alerts
        .where((Alert a) => a.stationId == stationId)
        .toList()
        .reversed
        .toList();
  }

  /// Active (not resolved) and not-yet-acknowledged alerts for one station,
  /// newest first. Drives the "Recommended Actions" card and the grid hint.
  List<Alert> activeAlertsFor(String stationId) {
    return _alerts
        .where((Alert a) =>
            a.stationId == stationId && a.isActive && !a.acknowledged)
        .toList()
        .reversed
        .toList();
  }

  /// Health status derived from the station's currently active alerts.
  StationStatus statusFor(String stationId) {
    bool hasWarning = false;
    for (final Alert a in _alerts) {
      if (a.stationId == stationId && a.isActive) {
        if (a.severity == AlertSeverity.critical) {
          return StationStatus.critical;
        }
        hasWarning = true;
      }
    }
    return hasWarning ? StationStatus.warning : StationStatus.normal;
  }

  /// Marks an alert as acknowledged by the operator.
  void acknowledge(String alertId) {
    for (final Alert a in _alerts) {
      if (a.id == alertId && !a.acknowledged) {
        a.acknowledged = true;
        notifyListeners();
        return;
      }
    }
  }

  /// Ends the customer session on a station (frees it).
  void endSession(String stationId) {
    twinFor(stationId).endSession();
    ApiService.postSessionEnd(stationId); // best-effort, fire-and-forget
    notifyListeners();
  }

  // ------------------------------------------------- simulation control room

  /// Live simulation event log, newest first. Entries look like
  /// "14:32:07  ST-03 started gaming".
  List<String> get eventLog => List<String>.unmodifiable(_eventLog);

  /// True while the simulation is paused (state kept, timer stopped).
  bool get simulationPaused => _engine?.isPaused ?? false;

  /// Current playback speed multiplier (1..10; 1 = one tick every 2s).
  int get simulationSpeed => _engine?.speed ?? 1;

  void pauseSimulation() {
    _engine?.pause();
    notifyListeners();
  }

  void resumeSimulation() {
    _engine?.resume();
    notifyListeners();
  }

  void setSimulationSpeed(int multiplier) {
    _engine?.setSpeed(multiplier);
    notifyListeners();
  }

  void injectOverheat() => _engine?.injectOverheat();

  void injectPeakHour() => _engine?.injectPeakHour();

  void injectNetworkSurge() => _engine?.injectNetworkSurge();

  void injectCalmAfternoon() => _engine?.injectCalmAfternoon();

  /// Appends an engine event to the log, newest first, capped at
  /// [_maxEventLogEntries] entries (oldest dropped).
  void _onEngineEvent(String message) {
    final DateTime now = DateTime.now();
    final String timestamp = <int>[now.hour, now.minute, now.second]
        .map((int v) => v.toString().padLeft(2, '0'))
        .join(':');
    _eventLog.insert(0, '$timestamp  $message');
    if (_eventLog.length > _maxEventLogEntries) {
      _eventLog.removeRange(_maxEventLogEntries, _eventLog.length);
    }
    notifyListeners();
  }

  void _onTick() {
    _tickCount++;
    final bool uploadTelemetryThisTick =
        _tickCount % _telemetryUploadEveryNTicks == 0;

    for (final StationTwin twin in _twins) {
      final List<Alert> fired = RulesEngine.evaluate(twin);
      final Set<String> firedCodes = <String>{};
      for (final Alert alert in fired) {
        firedCodes.add(alert.ruleCode);
        // De-duplicate: one active alert per (stationId, ruleCode).
        final bool alreadyActive = _alerts.any((Alert a) =>
            a.stationId == alert.stationId &&
            a.ruleCode == alert.ruleCode &&
            a.isActive);
        if (!alreadyActive) {
          _alerts.add(alert);
          ApiService.postAlert(alert); // best-effort, fire-and-forget
        }
      }
      // Auto-resolve active alerts whose condition no longer holds.
      for (final Alert a in _alerts) {
        if (a.stationId == twin.id &&
            a.isActive &&
            !firedCodes.contains(a.ruleCode)) {
          a.resolved = true;
          ApiService.resolveAlert(a.stationId, a.ruleCode); // best-effort
        }
      }

      if (uploadTelemetryThisTick) {
        ApiService.postTelemetry(twin); // best-effort, fire-and-forget
      }
    }
    _trimAlerts();
    _recordInsights();
    notifyListeners();
  }

  /// Recomputes the live optimization + prediction insights and upserts
  /// each into [_records], so the report keeps a persistent per-station
  /// history of everything detected during the session.
  ///
  /// Upsert match key = (kind, stationId, title): on match the entry's
  /// lastSeen is refreshed, occurrences incremented and detail/impact
  /// updated if they changed; otherwise a new entry is appended. The list
  /// is capped at [_maxReportEntries] entries (oldest by lastSeen dropped).
  /// No extra notifyListeners here — the per-tick one in [_onTick] covers it.
  void _recordInsights() {
    final DateTime now = DateTime.now();
    final List<Insight> insights = <Insight>[
      ...InsightsEngine.optimizationsFor(this),
      ...InsightsEngine.predictionsFor(this),
    ];
    for (final Insight insight in insights) {
      final int index = _records.indexWhere((ReportEntry e) =>
          e.kind == insight.kind &&
          e.stationId == insight.stationId &&
          e.title == insight.title);
      if (index >= 0) {
        final ReportEntry entry = _records[index];
        entry.lastSeen = now;
        entry.occurrences++;
        if (entry.detail != insight.detail) {
          entry.detail = insight.detail;
        }
        if (entry.impact != insight.impact) {
          entry.impact = insight.impact;
        }
      } else {
        _recordSeq++;
        final ReportEntry entry = ReportEntry(
          id: 'REC-${_recordSeq.toString().padLeft(4, '0')}',
          firstSeen: now,
          lastSeen: now,
          kind: insight.kind,
          stationId: insight.stationId,
          stationName: insight.stationName,
          category: insight.category,
          title: insight.title,
          detail: insight.detail,
          impact: insight.impact,
        );
        _records.add(entry);
        if (_backendOrgId != null) {
          ApiService.postReportEntry(_backendOrgId!, entry);
        }
      }
    }
    while (_records.length > _maxReportEntries) {
      int oldest = 0;
      for (int i = 1; i < _records.length; i++) {
        if (_records[i].lastSeen.isBefore(_records[oldest].lastSeen)) {
          oldest = i;
        }
      }
      _records.removeAt(oldest);
    }
  }

  void _trimAlerts() {
    while (_alerts.length > _maxStoredAlerts) {
      final int index = _alerts
          .indexWhere((Alert a) => a.resolved && a.acknowledged);
      if (index < 0) {
        return;
      }
      _alerts.removeAt(index);
    }
  }

  @override
  void dispose() {
    // Safe when the app is closed before configure() ever ran.
    _engine?.dispose();
    super.dispose();
  }
}
