import 'package:flutter_test/flutter_test.dart';
import 'package:onemorecoin/services/FinancialForecastService.dart';

void main() {
  final now = DateTime(2026, 4, 10);
  final budget = <String, dynamic>{
    'budget': 300000.0,
    'fromDate': '2026-04-01',
    'toDate': '2026-04-30',
    'walletId': 0,
    'groupId': 0,
    'unit': 'VND'
  };
  test('projects daily burn rate and danger', () {
    final result = FinancialForecastService.calculate([
      {'amount': 120000, 'date': '2026-04-09'},
      {'amount': 999999, 'date': '2026-03-09'},
      {'amount': 999999, 'date': '2026-04-11'},
    ], [
      budget
    ], now)!;
    expect(result.currentSpent, 120000);
    expect(result.projectedTotal, 360000);
    expect(result.daysRemaining, 20);
    expect(result.risk, RiskLevel.danger);
  });
  test('no monthly budget or expired budget returns null', () {
    expect(FinancialForecastService.calculate([], [], now), isNull);
    expect(
        FinancialForecastService.calculate([], [
          {...budget, 'budgetType': 'week'}
        ], now),
        isNull);
    expect(
        FinancialForecastService.calculate([], [
          {...budget, 'toDate': '2026-04-09'}
        ], now),
        isNull);
  });
  test('filters spending by selected wallet and category', () {
    final result = FinancialForecastService.calculate([
      {'amount': 100000, 'date': '2026-04-09', 'walletId': 1, 'groupId': 2},
      {'amount': 900000, 'date': '2026-04-09', 'walletId': 2, 'groupId': 2},
      {'amount': 900000, 'date': '2026-04-09', 'walletId': 1, 'groupId': 3},
    ], [
      {...budget, 'walletId': 1, 'groupId': 2, 'title': 'Ăn uống'}
    ], now)!;
    expect(result.currentSpent, 100000);
    expect(result.budgetTitle, 'Ăn uống');
  });
  test('first day and boundary at 80 percent', () {
    final result = FinancialForecastService.calculate([
      {'amount': 8000, 'date': '2026-04-01'},
    ], [
      {...budget, 'budget': 300000}
    ], DateTime(2026, 4, 1))!;
    expect(result.projectedTotal, 240000);
    expect(result.risk, RiskLevel.safe);
  });
}
