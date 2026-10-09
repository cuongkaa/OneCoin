import 'dart:io';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class OfflineReceiptResult {
  final double totalAmount;
  final String rawText;
  final String? merchantName;
  final DateTime? transactionDate;

  OfflineReceiptResult({
    required this.totalAmount,
    required this.rawText,
    this.merchantName,
    this.transactionDate,
  });

  /// Parse OCR text separately so extraction can be tested without a camera.
  static OfflineReceiptResult fromText(String text) {
    final lines = text
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    return OfflineReceiptResult(
      totalAmount: ReceiptOcrService._extractAmount(lines),
      merchantName: ReceiptOcrService._extractMerchant(lines),
      transactionDate: ReceiptOcrService._extractDate(lines),
      rawText: text,
    );
  }
}

class ReceiptOcrService {
  /// Scan a receipt image extract text via ML Kit and filter for the total amount
  static Future<OfflineReceiptResult?> scanReceipt(File imageFile) async {
    final inputImage = InputImage.fromFile(imageFile);
    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

    try {
      final RecognizedText recognizedText =
          await textRecognizer.processImage(inputImage);
      String fullText = recognizedText.text;

      return OfflineReceiptResult.fromText(fullText);
    } catch (e) {
      print('ML Kit OCR Error: $e');
      return null;
    } finally {
      textRecognizer.close();
    }
  }

  static String? _extractMerchant(List<String> lines) {
    for (final line in lines.take(5)) {
      if (line.length < 3 ||
          line.length > 55 ||
          !RegExp(r'[a-zA-ZÀ-ỹ]').hasMatch(line)) continue;
      if (RegExp(
              r'(địa\s*chỉ|address|hotline|tel|mst|mã\s*số\s*thuế|hóa\s*đơn|invoice|ngày|date|total|tổng|thanh\s*toán|\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4})',
              caseSensitive: false)
          .hasMatch(line)) continue;
      if (RegExp(r'^\s*\d+\s').hasMatch(line)) continue;
      return line;
    }
    return null;
  }

  static DateTime? _extractDate(List<String> lines) {
    final dmy = RegExp(r'\b(\d{1,2})[/-](\d{1,2})[/-](\d{4})\b');
    final ymd = RegExp(r'\b(\d{4})-(\d{1,2})-(\d{1,2})\b');
    for (final line in lines) {
      final iso = ymd.firstMatch(line);
      final local = iso == null ? dmy.firstMatch(line) : null;
      if (iso == null && local == null) continue;
      final year = int.parse((iso ?? local)!.group(iso == null ? 3 : 1)!);
      final month = int.parse((iso ?? local)!.group(2)!);
      final day = int.parse((iso ?? local)!.group(iso == null ? 1 : 3)!);
      final date = DateTime(year, month, day);
      if (date.year == year && date.month == month && date.day == day)
        return date;
    }
    return null;
  }

  static double _extractAmount(List<String> lines) {
    // Priority 1: "Thanh toán", "Amount due"
    final p1Regex =
        RegExp(r'(thanh\s*toán|amount\s*due)', caseSensitive: false);
    // Priority 2: "Tổng tiền", "Tổng cộng", "Grand total"
    final p2Regex = RegExp(r'(tổng\s*tiền|tổng\s*cộng|grand\s*total)',
        caseSensitive: false);
    // Priority 3: "Total", "Thành tiền", "Subtotal"
    final p3Regex = RegExp(r'(total|thành\s*tiền|subtotal|cộng\s*tiền)',
        caseSensitive: false);

    double? foundAmount;

    // Amounts from receipts are already in VND; never round to thousands.
    foundAmount = _scanLinesForKeyword(lines, p1Regex);
    if (foundAmount != null) return foundAmount;

    foundAmount = _scanLinesForKeyword(lines, p2Regex);
    if (foundAmount != null) return foundAmount;

    foundAmount = _scanLinesForKeyword(lines, p3Regex);
    if (foundAmount != null) return foundAmount;

    // Fallback: Find highest reasonable amount.
    return _findHighestReasonableAmount(lines);
  }

  static double? _scanLinesForKeyword(List<String> lines, RegExp keywordRegex) {
    for (int i = 0; i < lines.length; i++) {
      String line = lines[i].toLowerCase();
      if (keywordRegex.hasMatch(line)) {
        // Check inline first
        double? amount = _extractNumberFromText(lines[i]);
        if (amount != null && amount >= 1 && amount <= 100000000) return amount;

        // If not inline, check the next line
        if (i + 1 < lines.length) {
          amount = _extractNumberFromText(lines[i + 1]);
          if (amount != null && amount >= 1 && amount <= 100000000) return amount;
        }
      }
    }
    return null;
  }

  static double _findHighestReasonableAmount(List<String> lines) {
    double maxAmount = 0;
    for (String line in lines) {
      double? amount = _extractNumberFromText(line);
      if (amount != null && _isValidAmount(amount)) {
        if (amount > maxAmount) {
          maxAmount = amount;
        }
      }
    }
    return maxAmount;
  }

  static double? _extractNumberFromText(String text) {
    if (_isGarbageLine(text)) return null;

    // Match individual amounts, not a concatenation of quantity, price and total.
    final matches =
        RegExp(r'(?<!\d)\d{1,3}(?:[.,]\d{3})+(?!\d)|(?<!\d)\d{1,9}(?!\d)')
            .allMatches(text);
    double? largest;
    for (final match in matches) {
      final value =
          double.tryParse(match.group(0)!.replaceAll(RegExp(r'[.,]'), ''));
      if (value != null && (largest == null || value > largest))
        largest = value;
    }
    return largest;
  }

  static bool _isValidAmount(double amount) {
    // > 100M VND is suspicious for a daily offline receipt
    if (amount > 100000000) return false;
    // < 1K VND is too small, likely garbage or qty
    if (amount < 1000) return false;
    // Year context (1900-2100) and it falls in this exact range
    if (amount >= 1900 && amount <= 2100) return false;
    return true;
  }

  static bool _isGarbageLine(String text) {
    final lower = text.toLowerCase();

    // Eliminate dates/times
    if (RegExp(r'\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4}').hasMatch(text))
      return true; // 12/03/2024
    if (RegExp(r'\d{1,2}:\d{2}(:\d{2})?').hasMatch(text)) return true; // 14:30
    if (lower.contains('ngày') ||
        lower.contains('tháng') ||
        lower.contains('năm')) return true;

    // Eliminate phone numbers, tax codes, barcodes
    if (lower.contains('hotline') ||
        lower.contains('tel') ||
        lower.contains('sdt') ||
        lower.contains('liên hệ')) return true;
    if (lower.contains('mst') || lower.contains('mã số thuế')) return true;
    if (lower.contains('hóa đơn') && RegExp(r'\d{5,}').hasMatch(text))
      return true; // Mã hóa đơn 12345

    // Eliminate cash paid/change
    if (lower.contains('tiền khách') ||
        lower.contains('khách đưa') ||
        lower.contains('cash')) return true;
    if (lower.contains('tiền thừa') ||
        lower.contains('tiền thối') ||
        lower.contains('trả lại') ||
        lower.contains('change')) return true;

    // Eliminate weights, quantities, stt
    if (lower.contains('kg') ||
        lower.contains('gram') ||
        lower.contains('stt') ||
        lower.contains('số bàn') ||
        lower.contains('table')) return true;

    return false;
  }

}
