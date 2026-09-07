import 'dart:html' as html;

import 'package:flutter/foundation.dart';

import '../models/insight.dart';
import '../models/report_entry.dart';
import '../models/station.dart';
import '../state/cafe_state.dart';
import 'digital_twin.dart';

/// Builds the downloadable organization reports (CSV + plain-text summary)
/// from the persistent insight record kept by [CafeState], and triggers the
/// browser download on web.
class ReportExporter {
  ReportExporter._();

  /// Escapes one CSV cell: doubles quotes and wraps in quotes when the value
  /// contains a comma, quote or newline.
  static String _csvCell(String value) {
    final String escaped = value.replaceAll('"', '""');
    if (escaped.contains(',') ||
        escaped.contains('"') ||
        escaped.contains('\n')) {
      return '"$escaped"';
    }
    return escaped;
  }

  static String _kindLabel(InsightKind kind) =>
      kind == InsightKind.optimization ? 'optimization' : 'prediction';

  /// Full insight record as CSV, one row per [ReportEntry], ordered by
  /// first-seen (chronological).
  static String buildCsv(CafeState state) {
    final List<ReportEntry> entries = List<ReportEntry>.of(state.records)
      ..sort((ReportEntry a, ReportEntry b) =>
          a.firstSeen.compareTo(b.firstSeen));
    final StringBuffer buffer = StringBuffer()
      ..writeln('timestamp_first_seen,last_seen,type,station,station_name,'
          'category,title,detail,impact,times_detected');
    for (final ReportEntry e in entries) {
      buffer.writeln(<String>[
        e.firstSeen.toIso8601String(),
        e.lastSeen.toIso8601String(),
        _kindLabel(e.kind),
        e.stationId ?? 'organization-wide',
        e.stationName ?? '',
        e.category ?? '',
        e.title,
        e.detail,
        e.impact,
        '${e.occurrences}',
      ].map(_csvCell).join(','));
    }
    return buffer.toString();
  }

  static String _fmt(DateTime t) {
    final String date = '${t.year}-${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')}';
    final String time = <int>[t.hour, t.minute, t.second]
        .map((int v) => v.toString().padLeft(2, '0'))
        .join(':');
    return '$date $time';
  }

  /// Plain-text decision-support report: header, per-station status blocks
  /// and the full chronological insight record.
  static String buildSummary(CafeState state) {
    final DateTime now = DateTime.now();
    final List<StationTwin> twins = state.stationList;
    final List<ReportEntry> chronological =
        List<ReportEntry>.of(state.records)
          ..sort((ReportEntry a, ReportEntry b) =>
              a.firstSeen.compareTo(b.firstSeen));

    final StringBuffer b = StringBuffer();
    b.writeln('CAFETWIN ORGANIZATION REPORT');
    b.writeln('============================');
    b.writeln('Organization : ${state.companyName}');
    b.writeln('Generated at : ${_fmt(now)}');
    b.writeln('Period       : '
        '${state.configuredAt != null ? _fmt(state.configuredAt!) : '—'} '
        '→ ${_fmt(now)}');
    b.writeln('Stations     : ${twins.length}');

    // Station count by category.
    final Map<String, int> perCategory = <String, int>{};
    for (final StationTwin twin in twins) {
      perCategory.update(twin.station.category, (int c) => c + 1,
          ifAbsent: () => 1);
    }
    b.writeln('Categories   : ${perCategory.entries
        .map((MapEntry<String, int> e) => '${e.key} (${e.value})')
        .join(', ')}');
    b.writeln('');

    // Per-station summary blocks.
    b.writeln('PER-STATION STATUS');
    b.writeln('------------------');
    for (final StationTwin twin in twins) {
      final StationStatus status = state.statusFor(twin.id);
      final int activeAlerts = state.activeAlertsFor(twin.id).length;
      final List<ReportEntry> stationRecords = state.recordsFor(twin.id);
      b.writeln(
          '${twin.id} — ${twin.name} [${twin.station.category}] '
          'status=${status.name} '
          '${twin.session.occupied ? 'occupied' : 'free'}');
      b.writeln('  CPU ${twin.hardware.cpuTemp.toStringAsFixed(0)}°C · '
          'GPU ${twin.hardware.gpuTemp.toStringAsFixed(0)}°C · '
          'latency ${twin.network.latencyMs.toStringAsFixed(0)} ms · '
          'active alerts: $activeAlerts');
      if (stationRecords.isEmpty) {
        b.writeln('  No insights recorded for this station.');
      } else {
        b.writeln('  Top recorded insights:');
        final List<ReportEntry> top = List<ReportEntry>.of(stationRecords)
          ..sort((ReportEntry a, ReportEntry b) =>
              b.occurrences.compareTo(a.occurrences));
        for (final ReportEntry e in top.take(3)) {
          b.writeln('    - [${_kindLabel(e.kind)}] ${e.title} '
              '(×${e.occurrences}, last ${_fmt(e.lastSeen)})');
        }
      }
      b.writeln('');
    }

    // Full chronological record.
    b.writeln('FULL RECORD (chronological)');
    b.writeln('---------------------------');
    if (chronological.isEmpty) {
      b.writeln('No insights recorded yet.');
    }
    for (final ReportEntry e in chronological) {
      b.writeln('[${_fmt(e.firstSeen)} → ${_fmt(e.lastSeen)}] '
          '${_kindLabel(e.kind).toUpperCase()} '
          '${e.stationId ?? 'organization-wide'}'
          '${e.category != null ? ' [${e.category}]' : ''} '
          '— ${e.title} (×${e.occurrences})');
      if (e.detail.isNotEmpty) {
        b.writeln('    ${e.detail}');
      }
      if (e.impact.isNotEmpty) {
        b.writeln('    impact: ${e.impact}');
      }
    }
    return b.toString();
  }

  /// Triggers a browser file download of [content] as [filename].
  ///
  /// Returns true when the download was started (web only); returns false on
  /// non-web platforms so the caller can show the content in a dialog
  /// instead. The dart:html usage is guarded by [kIsWeb].
  static bool download(String filename, String content) {
    if (!kIsWeb) {
      return false;
    }
    final String mime =
        filename.endsWith('.csv') ? 'text/csv' : 'text/plain';
    final html.Blob blob =
        html.Blob(<String>[content], mime, 'native');
    final String url = html.Url.createObjectUrlFromBlob(blob);
    final html.AnchorElement anchor = html.AnchorElement(href: url)
      ..setAttribute('download', filename);
    html.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    html.Url.revokeObjectUrl(url);
    return true;
  }
}
