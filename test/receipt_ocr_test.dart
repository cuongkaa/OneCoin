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

  test('reconstructs horizontal lines from 2D spatial bounding boxes and fixes OCR noise', () {
    final spatialLines = [
      const SpatialTextLine(
          text: 'PHÚC LONG COFFEE & TEA', top: 10, bottom: 32, left: 20, right: 240),
      const SpatialTextLine(
          text: 'Ngày 18 tháng 11 năm 2026', top: 45, bottom: 60, left: 20, right: 200),
      // Two columns on the same horizontal row (Y ~ 120..136)
      const SpatialTextLine(
          text: 'Thanh toán:', top: 120, bottom: 136, left: 20, right: 110),
      const SpatialTextLine(
          text: '65.O00 đ', top: 121, bottom: 137, left: 180, right: 260),
    ];
    final result = OfflineReceiptResult.fromText(
      'PHÚC LONG COFFEE & TEA\nThanh toán:\nTiền khách đưa: 100.000\n65.O00 đ',
      spatialLines: spatialLines,
    );
    expect(result.merchantName, 'PHÚC LONG COFFEE & TEA');
    expect(result.transactionDate, DateTime(2026, 11, 18));
    expect(result.totalAmount, 65000);
    expect(result.confidence, greaterThanOrEqualTo(0.9));
  });
}
