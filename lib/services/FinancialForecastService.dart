import 'package:onemorecoin/utils/database_helper.dart';

enum RiskLevel { safe, warning, danger }

class ForecastResult {
  final double currentSpent;
  final double projectedTotal;
  final double budgetLimit;
  final int daysRemaining;
  final RiskLevel risk;
  final String budgetTitle;
  const ForecastResult(this.currentSpent, this.projectedTotal, this.budgetLimit,
      this.daysRemaining, this.risk, this.budgetTitle);
}

class FinancialForecastService {
  /// Select one active monthly budget; never add overlapping limits together.
  static Future<ForecastResult?> getForecast({DateTime? today}) async {
    final now = today ?? DateTime.now();
    final db = await DatabaseHelper.instance.database;
    final transactions = await db.query('transactions_table',
        columns: ['amount', 'date', 'unit', 'walletId', 'groupId'],
        where: "type = ? AND (isDeleted = 0 OR isDeleted IS NULL)",
        whereArgs: ['expense']);
    final budgets = await db.query('budgets',
        columns: [
          'budget',
          'title',
          'budgetType',
          'fromDate',
          'toDate',
          'walletId',
          'groupId',
          'unit'
        ],
        where: "type = ? AND (isDeleted = 0 OR isDeleted IS NULL)",
        whereArgs: ['expense']);
    return calculate(transactions, budgets, now);
  }

  /// Amounts are stored in VND in the current transaction form.
  static ForecastResult? calculate(List<Map<String, dynamic>> transactions,
      List<Map<String, dynamic>> budgets, DateTime now) {
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
    for (final row in transactions) {
      final date = DateTime.tryParse(row['date']?.toString() ?? '');
      if (date != null &&
          date.year == now.year &&
          date.month == now.month &&
          date.day <= now.day &&
          row['amount'] is num &&
          (selected['walletId'] == null ||
              selected['walletId'] == 0 ||
              selected['walletId'] == row['walletId']) &&
          (selected['groupId'] == null ||
              selected['groupId'] == 0 ||
              selected['groupId'] == row['groupId'])) {
        spent += (row['amount'] as num).toDouble();
      }
    }
    final limit = (selected['budget'] as num).toDouble();
    final projected = spent / now.day * end;
    final ratio = projected / limit;
    return ForecastResult(
        spent,
        projected,
        limit,
        end - now.day,
        ratio > 1
            ? RiskLevel.danger
            : ratio > 0.8
                ? RiskLevel.warning
                : RiskLevel.safe,
        selected['title']?.toString() ?? 'Ngân sách tháng');
  }
}
