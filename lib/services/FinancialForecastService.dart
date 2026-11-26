import 'dart:math' as math;
import 'package:onemorecoin/utils/database_helper.dart';

enum RiskLevel { safe, warning, danger }

class ForecastResult {
  final double currentSpent;
  final double projectedTotal;
  final double budgetLimit;
  final int daysRemaining;
  final RiskLevel risk;
  final String budgetTitle;
  final double dailyBurnRate;
  final double trendSlope;
  final double outlierAmount;
  final String method;

  const ForecastResult(
    this.currentSpent,
    this.projectedTotal,
    this.budgetLimit,
    this.daysRemaining,
    this.risk,
    this.budgetTitle, {
    this.dailyBurnRate = 0.0,
    this.trendSlope = 0.0,
    this.outlierAmount = 0.0,
    this.method = 'daily_burn_rate',
  });
}

class FinancialForecastService {
  /// Select one active monthly budget; never add overlapping limits together.
  static Future<ForecastResult?> getForecast({DateTime? today}) async {
    final now = today ?? DateTime.now();
    final db = await DatabaseHelper.instance.database;
    final transactions = await db.query(
      'transactions_table',
      columns: ['amount', 'date', 'unit', 'walletId', 'groupId'],
      where: "type = ? AND (isDeleted = 0 OR isDeleted IS NULL)",
      whereArgs: ['expense'],
    );
    final budgets = await db.query(
      'budgets',
      columns: [
        'budget',
        'title',
        'budgetType',
        'fromDate',
        'toDate',
        'walletId',
        'groupId',
        'unit',
      ],
      where: "type = ? AND (isDeleted = 0 OR isDeleted IS NULL)",
      whereArgs: ['expense'],
    );
    return calculate(transactions, budgets, now);
  }

  /// Amounts are stored in VND in the current transaction form.
  /// Uses Daily Burn Rate when fewer than 5 distinct spending days exist in the month,
  /// and automatically upgrades to Hybrid Time-Series ML (MAD Outlier Filtering +
  /// OLS Linear Regression + EWMA) when 5 or more spending days are observed.
  static ForecastResult? calculate(
    List<Map<String, dynamic>> transactions,
    List<Map<String, dynamic>> budgets,
    DateTime now,
  ) {
    final end = DateTime(now.year, now.month + 1, 0).day;
    // Choose the most recently started monthly budget, not the sum of budgets.
    final active = budgets.where((b) {
      final from = DateTime.tryParse(b['fromDate']?.toString() ?? '');
      final to = DateTime.tryParse(b['toDate']?.toString() ?? '');
      return from != null &&
          to != null &&
          !now.isBefore(DateTime(from.year, from.month, from.day)) &&
          !now.isAfter(DateTime(to.year, to.month, to.day)) &&
          (b['budgetType'] == null || b['budgetType'] == 'month') &&
          from.year == now.year &&
          from.month == now.month &&
          to.year == now.year &&
          to.month == now.month &&
          from.day == 1 &&
          to.day == end &&
          b['budget'] is num &&
          (b['budget'] as num) > 0 &&
          (b['unit'] == null || b['unit'] == 'VND');
    }).toList()
      ..sort((a, b) =>
          (b['fromDate'] as String).compareTo(a['fromDate'] as String));
    if (active.isEmpty) return null;

    final selected = active.first;
    double spent = 0;
    final dailyTotals = List<double>.filled(now.day, 0.0);
    int activeDaysCount = 0;

    for (final row in transactions) {
      final date = DateTime.tryParse(row['date']?.toString() ?? '');
      if (date != null &&
          date.year == now.year &&
          date.month == now.month &&
          date.day >= 1 &&
          date.day <= now.day &&
          row['amount'] is num &&
          (selected['walletId'] == null ||
              selected['walletId'] == 0 ||
              selected['walletId'] == row['walletId']) &&
          (selected['groupId'] == null ||
              selected['groupId'] == 0 ||
              selected['groupId'] == row['groupId'])) {
        final amt = (row['amount'] as num).toDouble();
        spent += amt;
        if (dailyTotals[date.day - 1] == 0 && amt > 0) {
          activeDaysCount++;
        }
        dailyTotals[date.day - 1] += amt;
      }
    }

    final limit = (selected['budget'] as num).toDouble();
    final remainingDays = end - now.day;

    double projected;
    double dailyRate = spent / now.day;
    double slope = 0.0;
    double outlierTotal = 0.0;
    String method = 'daily_burn_rate';

    // Upgrade to Hybrid Time-Series ML (MAD Outlier Detection + OLS Trend + EWMA)
    // when there are at least 5 active spending days in the current month.
    if (activeDaysCount >= 5 && now.day >= 5) {
      method = 'hybrid_ols_ewma';
      final sorted = List<double>.from(dailyTotals)..sort();
      final median = sorted[sorted.length ~/ 2];
      final absDevs = sorted.map((x) => (x - median).abs()).toList()..sort();
      final mad = math.max(1.0, absDevs[absDevs.length ~/ 2]);
      final outlierThreshold = median + 3.0 * mad;

      final regularSeries = <double>[];
      for (final x in dailyTotals) {
        if (x > outlierThreshold && median > 0) {
          outlierTotal += (x - outlierThreshold);
          regularSeries.add(outlierThreshold);
        } else {
          regularSeries.add(x);
        }
      }

      // Exponentially Weighted Moving Average (EWMA, alpha = 0.3)
      double ewma = regularSeries.first;
      for (int i = 1; i < regularSeries.length; i++) {
        ewma = 0.3 * regularSeries[i] + 0.7 * ewma;
      }

      // Ordinary Least Squares (OLS) Linear Regression slope
      final n = regularSeries.length;
      final meanX = (n + 1) / 2.0;
      final meanY = regularSeries.reduce((a, b) => a + b) / n;
      double numSum = 0.0;
      double denSum = 0.0;
      for (int i = 0; i < n; i++) {
        final dx = (i + 1) - meanX;
        numSum += dx * (regularSeries[i] - meanY);
        denSum += dx * dx;
      }
      slope = denSum > 0 ? numSum / denSum : 0.0;

      dailyRate = math.max(0.0, 0.6 * meanY + 0.4 * ewma + 0.15 * slope);
      projected = spent + dailyRate * remainingDays;
    } else {
      projected = spent / now.day * end;
    }

    final ratio = projected / limit;
    return ForecastResult(
      spent,
      projected,
      limit,
      remainingDays,
      ratio > 1
          ? RiskLevel.danger
          : ratio > 0.8
              ? RiskLevel.warning
              : RiskLevel.safe,
      selected['title']?.toString() ?? 'Ngân sách tháng',
      dailyBurnRate: dailyRate,
      trendSlope: slope,
      outlierAmount: outlierTotal,
      method: method,
    );
  }
}
