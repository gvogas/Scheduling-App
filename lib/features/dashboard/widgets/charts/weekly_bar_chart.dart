import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:scheduling/core/theme/design_tokens.dart';

/// One series of weekly values.
class WeeklyBarSeries {
  const WeeklyBarSeries({
    required this.values,
    required this.color,
    required this.label,
  });

  final List<int> values;
  final Color color;
  final String label;
}

/// Dashboard chart showing 8 weekly buckets with 1 or 2 series. Touch
/// interaction is disabled, and a legend appears only when there are two series.
class WeeklyBarChart extends StatelessWidget {
  const WeeklyBarChart({
    required this.weekStarts,
    required this.series,
    super.key,
  }) : assert(
         series.length == 1 || series.length == 2,
         'WeeklyBarChart draws 1 or 2 series',
       );

  final List<DateTime> weekStarts;
  final List<WeeklyBarSeries> series;

  static const double _chartHeight = 160;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = [
      for (final s in series)
        '${s.label}: ${s.values.fold(0, (sum, v) => sum + v)}',
    ].join(', ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: summary,
          child: ExcludeSemantics(
            child: SizedBox(
              height: _chartHeight,
              child: BarChart(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : AppDuration.normal,
                _chartData(context, theme),
              ),
            ),
          ),
        ),
        // One series needs no legend — the section's own title already names it.
        if (series.length == 2) ...[
          const SizedBox(height: AppSpacing.sp8),
          _SeriesLegend(series: series),
        ],
      ],
    );
  }

  BarChartData _chartData(BuildContext context, ThemeData theme) {
    final scheme = theme.colorScheme;
    final axisStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final monthDay = DateFormat.Md(Localizations.localeOf(context).toString());
    var maxValue = 0;
    for (final s in series) {
      for (final v in s.values) {
        if (v > maxValue) maxValue = v;
      }
    }

    return BarChartData(
      alignment: BarChartAlignment.spaceAround,
      maxY: (maxValue == 0 ? 1 : maxValue).toDouble(),
      barTouchData: const BarTouchData(enabled: false),
      gridData: FlGridData(
        drawVerticalLine: false,
        getDrawingHorizontalLine: (_) =>
            FlLine(color: scheme.outlineVariant, strokeWidth: 1),
      ),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(),
        rightTitles: const AxisTitles(),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 32,
            getTitlesWidget: (value, meta) => value % 1 == 0
                ? Text(value.toInt().toString(), style: axisStyle)
                : const SizedBox.shrink(),
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 28,
            getTitlesWidget: (value, meta) {
              final index = value.toInt();
              // Show every other week to avoid crowding.
              if (index < 0 || index >= weekStarts.length || index.isOdd) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sp4),
                child: Text(
                  monthDay.format(weekStarts[index]),
                  style: axisStyle,
                ),
              );
            },
          ),
        ),
      ),
      barGroups: [
        for (var i = 0; i < weekStarts.length; i++)
          BarChartGroupData(
            x: i,
            barRods: [
              for (final s in series)
                BarChartRodData(
                  toY: (i < s.values.length ? s.values[i] : 0).toDouble(),
                  color: s.color,
                  width: series.length == 1 ? 14 : 7,
                  borderRadius: BorderRadius.circular(2),
                ),
            ],
          ),
      ],
    );
  }
}

/// A colour swatch and label per series, wrapped so two long labels stack
/// instead of overflowing at large text scales.
class _SeriesLegend extends StatelessWidget {
  const _SeriesLegend({required this.series});

  final List<WeeklyBarSeries> series;

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context).textTheme.labelSmall;
    return Wrap(
      spacing: AppSpacing.sp16,
      runSpacing: AppSpacing.sp4,
      children: [
        for (final s in series)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: s.color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppSpacing.sp4),
              Flexible(child: Text(s.label, style: labelStyle)),
            ],
          ),
      ],
    );
  }
}
