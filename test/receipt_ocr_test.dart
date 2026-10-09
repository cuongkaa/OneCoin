import 'package:flutter_test/flutter_test.dart';
import 'package:onemorecoin/services/ReceiptOcrService.dart';

void main() {
  test('extracts total, merchant and Vietnamese date', () {
    final result = OfflineReceiptResult.fromText(
      'Highlands Coffee\nĐịa chỉ: Hà Nội\nNgày 09/10/2026\n1 Cà phê 35.000\nTổng tiền: 35.000 đ',
    );
    expect(result.merchantName, 'Highlands Coffee');
    expect(result.transactionDate, DateTime(2026, 10, 9));
    expect(result.totalAmount, 35000);
  });

  test('accepts ISO date and rejects invalid dates', () {
    expect(
        OfflineReceiptResult.fromText('WinMart\n2026-10-09\nTotal: 120,000')
            .transactionDate,
        DateTime(2026, 10, 9));
    expect(OfflineReceiptResult.fromText('Shop\n31/02/2026').transactionDate,
        isNull);
  });

  test('does not concatenate multiple numbers on one line', () {
    expect(
        OfflineReceiptResult.fromText('Shop\nTổng tiền 2 25.000 50.000')
            .totalAmount,
        50000);
  });

  test('preserves the exact VND amount without rounding to thousands', () {
    expect(OfflineReceiptResult.fromText('Shop\nThanh toán: 35.650 đ').totalAmount,
        35650);
    expect(OfflineReceiptResult.fromText('Shop\nTổng cộng\n12,999 VND').totalAmount,
        12999);
    expect(OfflineReceiptResult.fromText('Shop\nTotal: 999 đ').totalAmount,
        999);
    expect(OfflineReceiptResult.fromText('Shop\nTotal: 1 đ').totalAmount,
        1);
  });
}
