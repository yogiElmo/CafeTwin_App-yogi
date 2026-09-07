import 'package:flutter/material.dart';

import '../services/digital_twin.dart';
import '../state/cafe_state.dart';
import '../widgets/station_card.dart';
import 'optimization_screen.dart';
import 'predictive_screen.dart';
import 'report_screen.dart';
import 'station_detail_screen.dart';

/// Screen 1: station cards grouped by category (GAMING, MARKETING, …).
///
/// ONE outer [ListView] holds one section per category (in the order
/// stations first use each category); every section is an amber header plus
/// an inner [GridView] with shrinkWrap + NeverScrollableScrollPhysics, so
/// nothing is ever hidden below a nested scroll fold. Rebuilds on every
/// engine tick via [AnimatedBuilder].
class StationGridScreen extends StatelessWidget {
  const StationGridScreen({super.key, required this.state});

  final CafeState state;

  static const Color _amber = Color(0xFFD9A441);

  /// Groups twins by category, preserving first-use category order.
  Map<String, List<StationTwin>> _groupByCategory(List<StationTwin> twins) {
    final Map<String, List<StationTwin>> grouped =
        <String, List<StationTwin>>{};
    for (final StationTwin twin in twins) {
      grouped.putIfAbsent(twin.station.category, () => <StationTwin>[]).add(twin);
    }
    return grouped;
  }

  Widget _buildCard(BuildContext context, StationTwin twin) {
    return StationCard(
      twin: twin,
      status: state.statusFor(twin.id),
      suggestedActionCount: state.activeAlertsFor(twin.id).length,
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) => StationDetailScreen(
              state: state,
              stationId: twin.id,
            ),
          ),
        );
      },
    );
  }

  Widget _buildSection(String category, List<StationTwin> sectionTwins) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 10),
          child: Text(
            category.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: _amber.withOpacity(0.9),
              letterSpacing: 1.6,
            ),
          ),
        ),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          // Cards cap at ~220px wide: 2 columns on phones, 4-6 on
          // desktop Chrome, so a card never becomes a giant tile.
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 220,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            // Card content with category label + suggestion hint is ≈ 195px
            // tall (monitor + metrics + hint line), so the cell height must
            // stay >= ~195px: 220 / 1.0 = 220px (safe).
            childAspectRatio: 1.0,
          ),
          itemCount: sectionTwins.length,
          itemBuilder: (BuildContext context, int index) =>
              _buildCard(context, sectionTwins[index]),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (BuildContext context, Widget? child) {
        final Map<String, List<StationTwin>> grouped =
            _groupByCategory(state.stationList);
        final List<String> categories = grouped.keys.toList();
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool wide = constraints.maxWidth >= 1000;
            // The grid stays ONE outer ListView either way; on narrow
            // screens the feature cards are simply its first item.
            final Widget gridList = ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: categories.length + (wide ? 0 : 1),
              itemBuilder: (BuildContext context, int index) {
                if (!wide) {
                  if (index == 0) {
                    return _FeaturePanel(state: state, wide: false);
                  }
                  index -= 1;
                }
                return _buildSection(
                  categories[index],
                  grouped[categories[index]]!,
                );
              },
            );
            if (!wide) {
              return gridList;
            }
            // Wide screens: grid on the left, fixed-width insights panel
            // filling the previously blank right side.
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: gridList),
                SizedBox(
                  width: 300,
                  child: _FeaturePanel(state: state, wide: true),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// The business-intelligence entry points: Optimization + Predictive
/// Analysis + Reports. Shown as a fixed right-hand panel on wide screens
/// (with an "INSIGHTS" header) and as a horizontal card row above the grid
/// on narrow screens.
class _FeaturePanel extends StatelessWidget {
  const _FeaturePanel({required this.state, required this.wide});

  final CafeState state;

  /// True when rendered as the 300px right-hand panel.
  final bool wide;

  static const Color _amber = Color(0xFFD9A441);

  @override
  Widget build(BuildContext context) {
    // Three cards share the narrow row — shrink the title font so
    // "Predictive Analysis" still fits (ellipsis guards the rest).
    final double titleFontSize = wide ? 14 : 12;
    final Widget optimization = _FeatureCard(
      icon: Icons.savings_outlined,
      title: 'Optimization',
      subtitle: 'Cut costs & boost efficiency',
      titleFontSize: titleFontSize,
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) =>
                OptimizationScreen(state: state),
          ),
        );
      },
    );
    final Widget predictive = _FeatureCard(
      icon: Icons.auto_graph,
      title: 'Predictive Analysis',
      subtitle: 'Forecast issues before they happen',
      titleFontSize: titleFontSize,
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) => PredictiveScreen(state: state),
          ),
        );
      },
    );
    final Widget reports = _FeatureCard(
      icon: Icons.description_outlined,
      title: 'Reports',
      subtitle: 'Records & full report download',
      titleFontSize: titleFontSize,
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) => ReportScreen(state: state),
          ),
        );
      },
    );

    if (!wide) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: optimization),
            const SizedBox(width: 12),
            Expanded(child: predictive),
            const SizedBox(width: 12),
            Expanded(child: reports),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 10),
            child: Text(
              'INSIGHTS',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: _amber.withOpacity(0.9),
                letterSpacing: 1.6,
              ),
            ),
          ),
          optimization,
          const SizedBox(height: 12),
          predictive,
          const SizedBox(height: 12),
          reports,
        ],
      ),
    );
  }
}

/// One tappable insights card: amber-tinted icon circle, title + subtitle
/// and a chevron on the right edge. Warm, low-saturation premium styling.
class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.titleFontSize = 14,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// Title font size; reduced on narrow screens where three cards share a
  /// single row.
  final double titleFontSize;

  static const Color _amber = Color(0xFFD9A441);
  static const Color _fill = Color(0xFF2E2822);

  @override
  Widget build(BuildContext context) {
    final Color onSurface = Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      height: 110,
      child: Material(
        color: _fill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: _amber.withOpacity(0.35)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: <Widget>[
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: _amber.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: _amber, size: 28),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: titleFontSize,
                          fontWeight: FontWeight.w700,
                          color: onSurface.withOpacity(0.92),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.3,
                          color: onSurface.withOpacity(0.55),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right,
                  size: 22,
                  color: onSurface.withOpacity(0.40),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
