import 'package:flutter/material.dart';
import 'package:onemorecoin/model/BudgetModel.dart';
import 'package:onemorecoin/model/TransactionModel.dart';
import 'package:onemorecoin/services/FinancialForecastService.dart';
import 'package:onemorecoin/utils/Utils.dart';
import 'package:provider/provider.dart';

class FinancialForecastCard extends StatefulWidget {
  const FinancialForecastCard({super.key});

  @override
  State<FinancialForecastCard> createState() => _FinancialForecastCardState();
}

class _FinancialForecastCardState extends State<FinancialForecastCard> {
  Future<ForecastResult?>? _forecast;
  int? _revision;

  @override
  Widget build(BuildContext context) {
    final transactions = context.watch<TransactionModelProxy>();
    final budgets = context.watch<BudgetModelProxy>();
    // Refresh on provider notifications, not every rebuild of the screen.
    final revision = Object.hash(
      Object.hashAll(transactions.getAll().map((t) =>
          Object.hash(t.id, t.amount, t.date, t.walletId, t.groupId, t.type))),
      Object.hashAll(budgets.getAll().map((b) => Object.hash(
          b.id, b.budget, b.fromDate, b.toDate, b.walletId, b.groupId))),
      DateTime.now().day,
    );
    if (_revision != revision) {
      _revision = revision;
      _forecast = FinancialForecastService.getForecast();
    }
    return FutureBuilder<ForecastResult?>(
      future: _forecast,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done)
          return const SizedBox.shrink();
        final result = snapshot.data;
        if (result == null) return const SizedBox.shrink();
        final color = result.risk == RiskLevel.danger
            ? Colors.red
            : result.risk == RiskLevel.warning
                ? Colors.orange
                : Colors.green;
        final label = result.risk == RiskLevel.danger
            ? 'Nguy cơ vượt ngân sách'
            : result.risk == RiskLevel.warning
                ? 'Gần chạm ngân sách'
                : 'Trong giới hạn';
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(16)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Dự báo: ${result.budgetTitle}',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text('Dự kiến: ${Utils.currencyFormat(result.projectedTotal)}'),
            Text('Ngân sách: ${Utils.currencyFormat(result.budgetLimit)}'),
            Text(
                'Đã chi: ${Utils.currencyFormat(result.currentSpent)} · Còn ${result.daysRemaining} ngày'),
            const SizedBox(height: 8),
            LinearProgressIndicator(
                value: (result.projectedTotal / result.budgetLimit)
                    .clamp(0.0, 1.0),
                color: color),
            const SizedBox(height: 8),
            Text(label,
                style: TextStyle(color: color, fontWeight: FontWeight.bold)),
          ]),
        );
      },
    );
  }
}
