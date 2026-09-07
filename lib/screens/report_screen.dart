import 'package:flutter/material.dart';

import '../models/insight.dart';
import '../models/report_entry.dart';
import '../models/station.dart';
import '../services/digital_twin.dart';
import '../services/report_exporter.dart';
import '../state/cafe_state.dart';

/// Organization report screen: the full persistent session record of
/// optimization + prediction insights, per-station status, and one-tap
/// download of the complete report (CSV + text summary) — e.g. when closing
/// the organization — to support decision-making.
///
/// The whole page is ONE scrollable ListView; it re-renders on every engine
/// tick via [AnimatedBuilder].
class ReportScreen extends StatelessWidget {
  const ReportScreen({super.key, required this.state});

  final CafeState state;

  static const Color _amber = Color(0xFFD9A441);
  static const Color _green = Color(0xFF58A16C);
  static const Color _red = Color(0xFFCC5148);

  static String _fmtTime(DateTime t) {
    return <int>[t.hour, t.minute, t.second]
        .map((int v) => v.toString().padLeft(2, '0'))
        .join(':');
  }

  static String _fmtDate(DateTime t) {
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')}';
  }

  String _fileStamp() {
    final DateTime now = DateTime.now();
    return '${_fmtDate(now)}_${_fmtTime(now).replaceAll(':', '-')}';
  }

  void _download(
    BuildContext context,
    String filename,
    String content,
  ) {
    final bool started = ReportExporter.download(filename, content);
    if (started) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Report downloaded')),
      );
    } else {
      // Non-web fallback: show the report as copyable text.
      showDialog<void>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: Text(filename),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: SelectableText(
                content,
                style: const TextStyle(fontSize: 11.5, height: 1.35),
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Organization Report')),
      body: AnimatedBuilder(
        animation: state,
        builder: (BuildContext context, Widget? child) {
          final List<StationTwin> twins = state.stationList;
          final List<ReportEntry> records = state.records;
          return ListView(
            padding: const EdgeInsets.all(12),
            children: <Widget>[
              _headerCard(context, twins),
              const SizedBox(height: 12),
              _downloadButton(
                context,
                icon: Icons.table_view_outlined,
                label: '⬇ Download Full Report (CSV)',
                onPressed: () => _download(
                  context,
                  'cafetwin_report_${_fileStamp()}.csv',
                  ReportExporter.buildCsv(state),
                ),
              ),
              const SizedBox(height: 8),
              _downloadButton(
                context,
                icon: Icons.description_outlined,
                label: '⬇ Download Summary (TXT)',
                onPressed: () => _download(
                  context,
                  'cafetwin_summary_${_fileStamp()}.txt',
                  ReportExporter.buildSummary(state),
                ),
              ),
              const SizedBox(height: 16),
              _sectionHeader(context, 'PER-STATION STATUS'),
              for (final StationTwin twin in twins) ...<Widget>[
                _stationCard(context, twin),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 8),
              _sectionHeader(context, 'FULL RECORD'),
              if (records.isEmpty)
                _emptyRecordCard(context)
              else
                for (int i = 0; i < records.length; i++) ...<Widget>[
                  _recordTile(context, records[i]),
                  if (i < records.length - 1) const SizedBox(height: 8),
                ],
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------- widgets

  Widget _sectionHeader(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 10),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: _amber.withOpacity(0.9),
          letterSpacing: 1.6,
        ),
      ),
    );
  }

  Widget _headerCard(BuildContext context, List<StationTwin> twins) {
    final Color onSurface = Theme.of(context).colorScheme.onSurface;
    final Color muted = onSurface.withOpacity(0.55);
    final Map<String, int> perCategory = <String, int>{};
    for (final StationTwin twin in twins) {
      perCategory.update(twin.station.category, (int c) => c + 1,
          ifAbsent: () => 1);
    }
    final String categories = perCategory.entries
        .map((MapEntry<String, int> e) => '${e.key} (${e.value})')
        .join(' · ');
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: _amber.withOpacity(0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              state.companyName.isEmpty ? 'Organization' : state.companyName,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: onSurface.withOpacity(0.95),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              state.configuredAt != null
                  ? 'Running since ${_fmtDate(state.configuredAt!)} '
                      '${_fmtTime(state.configuredAt!)}'
                  : 'Not started yet',
              style: TextStyle(fontSize: 13, color: muted),
            ),
            const SizedBox(height: 4),
            Text(
              '${twins.length} station${twins.length == 1 ? '' : 's'}'
              '${categories.isEmpty ? '' : ' — $categories'}',
              style: TextStyle(fontSize: 13, color: muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _downloadButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: _amber,
          foregroundColor: const Color(0xFF1E1B18),
          padding: const EdgeInsets.symmetric(vertical: 14),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }

  Color _statusColor(StationStatus status) {
    switch (status) {
      case StationStatus.critical:
        return _red;
      case StationStatus.warning:
        return _amber;
      case StationStatus.normal:
        return _green;
    }
  }

  Widget _stationCard(BuildContext context, StationTwin twin) {
    final Color onSurface = Theme.of(context).colorScheme.onSurface;
    final Color muted = onSurface.withOpacity(0.55);
    final StationStatus status = state.statusFor(twin.id);
    final int insightCount = state.recordsFor(twin.id).length;
    final bool occupied = twin.session.occupied;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: _statusColor(status),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${twin.id} — ${twin.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: onSurface.withOpacity(0.92),
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: _amber.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: _amber.withOpacity(0.30)),
                  ),
                  child: Text(
                    twin.station.category,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: _amber,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'CPU ${twin.hardware.cpuTemp.toStringAsFixed(0)}°C · '
              'GPU ${twin.hardware.gpuTemp.toStringAsFixed(0)}°C · '
              '${twin.network.latencyMs.toStringAsFixed(0)} ms · '
              '${occupied ? 'Occupied' : 'Free'} · '
              '$insightCount recorded '
              'insight${insightCount == 1 ? '' : 's'}',
              style: TextStyle(fontSize: 12, height: 1.35, color: muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyRecordCard(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          'No insights recorded yet — records appear as the simulation runs.',
          style: TextStyle(
            fontSize: 12.5,
            color:
                Theme.of(context).colorScheme.onSurface.withOpacity(0.55),
          ),
        ),
      ),
    );
  }

  Widget _recordTile(BuildContext context, ReportEntry entry) {
    final Color onSurface = Theme.of(context).colorScheme.onSurface;
    final Color muted = onSurface.withOpacity(0.55);
    final bool isOptimization = entry.kind == InsightKind.optimization;
    final Color kindColor = isOptimization ? _amber : _green;
    final IconData kindIcon =
        isOptimization ? Icons.savings_outlined : Icons.auto_graph;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: kindColor.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(kindIcon, color: kindColor, size: 17),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    entry.stationId != null
                        ? '${entry.title} '
                            '· ${entry.stationName ?? entry.stationId}'
                        : entry.title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace',
                      color: onSurface.withOpacity(0.92),
                    ),
                  ),
                  if (entry.detail.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 3),
                    Text(
                      entry.detail,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.3,
                        color: muted,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      if (entry.impact.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: _amber.withOpacity(0.10),
                            borderRadius: BorderRadius.circular(6),
                            border:
                                Border.all(color: _amber.withOpacity(0.30)),
                          ),
                          child: Text(
                            entry.impact,
                            style: const TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: _amber,
                            ),
                          ),
                        ),
                      Text(
                        'first ${_fmtTime(entry.firstSeen)} · '
                        'last ${_fmtTime(entry.lastSeen)} · '
                        '×${entry.occurrences}',
                        style: TextStyle(fontSize: 10.5, color: muted),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
