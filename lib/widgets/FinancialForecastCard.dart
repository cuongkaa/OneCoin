import 'package:flutter/material.dart';
import 'package:onemorecoin/model/BudgetModel.dart';
import 'package:onemorecoin/model/TransactionModel.dart';
import 'package:onemorecoin/services/FinancialForecastService.dart';
import 'package:onemorecoin/utils/Utils.dart';
import 'package:provider/provider.dart';

class FinancialForecastCard extends StatefulWidget {
  final VoidCallback? onSetupBudget;

  const FinancialForecastCard({
    super.key,
    this.onSetupBudget,
  });

  @override
  State<FinancialForecastCard> createState() => _FinancialForecastCardState();
}

class _FinancialForecastCardState extends State<FinancialForecastCard> {
  Future<ForecastResult?>? _forecast;
  int? _revision;

  @override
  Widget build(BuildContext context) {
    final transactionsProxy = context.watch<TransactionModelProxy>();
    final budgetsProxy = context.watch<BudgetModelProxy>();
    final allTransactions = transactionsProxy.getAll();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final revision = Object.hash(
      Object.hashAll(allTransactions.map((t) =>
          Object.hash(t.id, t.amount, t.date, t.walletId, t.groupId, t.type))),
      Object.hashAll(budgetsProxy.getAll().map((b) => Object.hash(
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
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const SizedBox.shrink();
        }
        final result = snapshot.data;

        if (result == null) {
          return _buildMlInsightSummaryCard(context, allTransactions, isDark);
        }

        final color = result.risk == RiskLevel.danger
            ? Colors.red
            : result.risk == RiskLevel.warning
                ? Colors.orange
                : const Color(0xFF059669);
        final label = result.risk == RiskLevel.danger
            ? 'Nguy cơ vượt ngân sách tháng'
            : result.risk == RiskLevel.warning
                ? 'Sắp chạm ngưỡng ngân sách (>80%)'
                : 'Chi tiêu an toàn trong giới hạn';

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withValues(alpha: 0.35)),
            boxShadow: isDark
                ? []
                : [
                    BoxShadow(
                      color: color.withValues(alpha: 0.08),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.insights_rounded, color: color, size: 20),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Dự báo ML: ${result.budgetTitle}',
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6366F1).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      result.method == 'hybrid_ols_ewma'
                          ? 'OLS + EWMA'
                          : 'Burn Rate',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF6366F1),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Dự phóng cuối tháng: ${Utils.currencyFormat(result.projectedTotal)}',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                  ),
                  Text(
                    'Còn ${result.daysRemaining} ngày',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Đã chi: ${Utils.currencyFormat(result.currentSpent)} / ${Utils.currencyFormat(result.budgetLimit)}',
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
              ),
              if (result.dailyBurnRate > 0) ...[
                const SizedBox(height: 4),
                Text(
                  'Tốc độ chi trung bình: ${Utils.currencyFormat(result.dailyBurnRate)}/ngày',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  minHeight: 8,
                  value: (result.projectedTotal / result.budgetLimit).clamp(0.0, 1.0),
                  backgroundColor: Colors.grey.withValues(alpha: 0.2),
                  color: color,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMlInsightSummaryCard(
    BuildContext context,
    List<TransactionModel> allTransactions,
    bool isDark,
  ) {
    final now = DateTime.now();
    final monthPrefix = '${now.year}-${now.month.toString().padLeft(2, '0')}';

    double monthSpent = 0;
    int learnedSamples = 0;
    final categoryTotals = <String, double>{};

    for (final t in allTransactions) {
      if (t.type == 'expense') {
        if (t.categorySource != CategorySource.mlSuggestedIgnored) {
          learnedSamples++;
        }
        if (t.date != null && t.date!.startsWith(monthPrefix)) {
          final amt = t.amount ?? 0;
          monthSpent += amt;
          final gName = t.group?.name ?? 'Khác';
          categoryTotals[gName] = (categoryTotals[gName] ?? 0) + amt;
        }
      }
    }

    String? topCategory;
    double topCategoryAmt = 0;
    categoryTotals.forEach((k, v) {
      if (v > topCategoryAmt) {
        topCategory = k;
        topCategoryAmt = v;
      }
    });

    final avgPerDay = now.day > 0 ? monthSpent / now.day : 0.0;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFF6366F1).withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: const Color(0xFF6366F1).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.psychology_rounded,
                  color: Color(0xFF6366F1),
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Phân tích & Học máy Chi tiêu (AI / ML)',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            learnedSamples > 0
                ? 'Mô hình Naive Bayes đã học $learnedSamples giao dịch cá nhân • Trung bình chi ${Utils.currencyFormat(avgPerDay)}/ngày.'
                : 'Mô hình TF-IDF + Multinomial Naive Bayes (11 nhóm chi tiêu tiếng Việt) đã sẵn sàng tự động phân loại khi bạn quét QR / Hóa đơn.',
            style: TextStyle(
              fontSize: 12.5,
              color: isDark ? Colors.grey.shade300 : Colors.grey.shade700,
            ),
          ),
          if (topCategory != null) ...[
            const SizedBox(height: 6),
            Text(
              'Nhóm chi lớn nhất tháng này: $topCategory (${Utils.currencyFormat(topCategoryAmt)})',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF4F46E5),
              ),
            ),
          ],
          if (widget.onSetupBudget != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: widget.onSetupBudget,
                icon: const Icon(Icons.trending_up_rounded, size: 17),
                label: const Text(
                  'Đặt ngân sách tháng để mở Dự báo Hồi quy OLS+EWMA',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
