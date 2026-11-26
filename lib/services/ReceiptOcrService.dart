import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'QrInvoiceParserService.dart';
import 'SmartCategorizerService.dart';
import 'api_config.dart';
import 'api_service.dart';
import 'vision_platform_stub.dart'
    if (dart.library.js_interop) 'vision_platform_web.dart'
    if (dart.library.io) 'vision_platform_io.dart';

class SpatialTextLine {
  final String text;
  final double top;
  final double bottom;
  final double left;
  final double right;

  const SpatialTextLine({
    required this.text,
    required this.top,
    required this.bottom,
    required this.left,
    required this.right,
  });

  double get centerY => (top + bottom) / 2.0;
  double get height => (bottom - top).abs();
}

class OfflineReceiptResult {
  final double totalAmount;
  final String rawText;
  final String? merchantName;
  final DateTime? transactionDate;
  final double confidence;
  final String scanMethod; // 'vietqr_ocr_fused', 'vietqr_emv', 'einvoice_qr', 'mlkit_spatial_ocr', 'gemini_vision_ai', 'text_heuristic'
  final String? invoiceCode;
  final String? bankInfo;
  final String? description;
  final bool? qrCrcValid;
  final List<String> lineItems;

  OfflineReceiptResult({
    required this.totalAmount,
    required this.rawText,
    this.merchantName,
    this.transactionDate,
    this.confidence = 1.0,
    this.scanMethod = 'text_heuristic',
    this.invoiceCode,
    this.bankInfo,
    this.description,
    this.qrCrcValid,
    this.lineItems = const [],
  });

  String get methodBadgeLabel {
    switch (scanMethod) {
      case 'vietqr_ocr_fused':
        return 'Kết hợp VietQR + OCR Hóa đơn (Hybrid Fusion)';
      case 'vietqr_emv':
        return qrCrcValid == true
            ? 'VietQR EMVCo · CRC-16 Hợp lệ'
            : 'VietQR EMVCo TLV';
      case 'einvoice_qr':
        return 'QR Hóa đơn điện tử (GDT)';
      case 'mlkit_spatial_ocr':
        return 'ML Kit Spatial OCR (2D Bounding-Box)';
      case 'gemini_vision_ai':
        return 'Multimodal Vision AI OCR + QR';
      default:
        return 'Phân tích Cú pháp Biên lai (Heuristic NLP)';
    }
  }

  /// Văn bản tổng hợp phục vụ đưa vào mô hình ML Phân loại Chi tiêu
  String get mlFeatureInput {
    final parts = <String>[
      if (merchantName != null && merchantName!.isNotEmpty) ...[
        merchantName!,
        merchantName!,
      ],
      if (description != null && description!.isNotEmpty) ...[
        description!,
        description!,
      ],
      if (lineItems.isNotEmpty) lineItems.join(' '),
      rawText,
    ];
    return parts.join(' ').trim();
  }

  /// Ghi chú gọn đẹp điền sẵn vào ô Ghi chú của Giao dịch
  String get suggestedNote {
    final parts = <String>[];
    if (merchantName != null && merchantName!.trim().isNotEmpty) {
      parts.add(merchantName!.trim());
    }
    final detail = (description != null && description!.trim().isNotEmpty)
        ? description!.trim()
        : (lineItems.isNotEmpty ? lineItems.take(2).join(', ') : null);
    if (detail != null &&
        detail.isNotEmpty &&
        (merchantName == null ||
            !detail.toLowerCase().contains(merchantName!.toLowerCase()))) {
      parts.add(detail);
    }
    if (invoiceCode != null && invoiceCode!.trim().isNotEmpty) {
      parts.add('HĐ: ${invoiceCode!.trim()}');
    }
    return parts.isEmpty ? 'Hóa đơn quét tự động' : parts.join(' - ');
  }

  factory OfflineReceiptResult.fromQrResult(QrInvoiceResult qr) {
    final bankSummary = [
      if (qr.bankName != null && qr.bankName!.isNotEmpty) qr.bankName!,
      if (qr.accountNumber != null && qr.accountNumber!.isNotEmpty)
        qr.accountNumber!,
    ].join(' • ');

    return OfflineReceiptResult(
      totalAmount: qr.totalAmount,
      rawText: qr.rawPayload,
      merchantName: qr.merchantName ?? qr.bankName,
      transactionDate: qr.transactionDate ?? DateTime.now(),
      confidence: qr.confidence,
      scanMethod: qr.format == QrInvoiceFormat.vietQrEmv
          ? 'vietqr_emv'
          : 'einvoice_qr',
      invoiceCode: qr.invoiceCode,
      bankInfo: bankSummary.isNotEmpty ? bankSummary : null,
      description: qr.description,
      qrCrcValid: qr.crcValid,
    );
  }

  /// Phân tích văn bản biên lai độc lập (hỗ trợ cả Spatial Bounding-Box 2D và Raw Text)
  static OfflineReceiptResult fromText(
    String text, {
    List<SpatialTextLine>? spatialLines,
    String scanMethod = 'text_heuristic',
  }) {
    final qrCandidate = QrInvoiceParserService.parse(text);
    if (qrCandidate != null &&
        (qrCandidate.totalAmount > 0 || qrCandidate.merchantName != null)) {
      return OfflineReceiptResult.fromQrResult(qrCandidate);
    }

    final normalizedText = ReceiptOcrService.normalizeOcrNoise(text);
    final rawLines = normalizedText
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    for (final line in rawLines) {
      if (line.startsWith('000201') || line.contains('|')) {
        final lineQr = QrInvoiceParserService.parse(line);
        if (lineQr != null && lineQr.totalAmount > 0) {
          return OfflineReceiptResult.fromQrResult(lineQr);
        }
      }
    }

    final lines = (spatialLines != null && spatialLines.isNotEmpty)
        ? ReceiptOcrService.reconstructHorizontalLines(spatialLines)
        : rawLines;

    final merchant = ReceiptOcrService._extractMerchant(
          lines,
          spatialLines: spatialLines,
        ) ??
        ReceiptOcrService._extractMerchant(rawLines);
    final date = ReceiptOcrService._extractDate(lines) ??
        ReceiptOcrService._extractDate(rawLines);
    final invoiceCode = ReceiptOcrService._extractInvoiceCode(lines);
    final lineItems = ReceiptOcrService._extractMenuOrLineItems(lines);
    final amountResult = ReceiptOcrService._extractAmountWithConfidence(lines);
    final fallbackAmountResult = amountResult.amount > 0
        ? amountResult
        : ReceiptOcrService._extractAmountWithConfidence(rawLines);

    return OfflineReceiptResult(
      totalAmount: fallbackAmountResult.amount,
      merchantName: merchant,
      transactionDate: date,
      rawText: text,
      confidence: fallbackAmountResult.confidence,
      scanMethod: scanMethod,
      invoiceCode: invoiceCode,
      lineItems: lineItems,
      description: lineItems.isNotEmpty ? lineItems.take(2).join(', ') : null,
    );
  }
}

class _AmountExtraction {
  final double amount;
  final double confidence;
  const _AmountExtraction(this.amount, this.confidence);
}

class ReceiptOcrService {
  /// Kiểm tra xem chuỗi tên trên VietQR có phải là tên chủ tài khoản cá nhân không dấu
  /// (VD: 'NGUYEN THI MINH NGOC', 'TRAN VAN AN') để ưu tiên lấy tên Nhà hàng/Cửa hàng trên biên lai nếu có.
  static bool isLikelyPersonalAccountName(String? name) {
    if (name == null || name.trim().isEmpty) return false;
    final upper = name.trim().toUpperCase();
    return RegExp(
      r'^(NGUYEN|TRAN|LE|PHAM|HOANG|HUYNH|PHAN|VU|VO|DANG|BUI|DO|HO|NGO|DUONG|LY|DINH|TRUONG|MAI|LUONG|DAO|CAO|HA)\s+[A-Z\s]{3,35}$',
    ).hasMatch(upper);
  }

  /// Hợp nhất thông minh dữ liệu từ Mã QR (chính xác tuyệt đối số tiền, STK ngân hàng)
  /// và Văn bản OCR trên cùng tờ hóa đơn (chính xác tên Nhà hàng, Tên món ăn / Mặt hàng, Ngày lập)
  static OfflineReceiptResult fuseQrAndOcr(
    OfflineReceiptResult qrResult,
    OfflineReceiptResult? ocrResult,
  ) {
    if (ocrResult == null) return qrResult;

    final double finalAmount =
        qrResult.totalAmount > 0 ? qrResult.totalAmount : ocrResult.totalAmount;

    // Nếu QR mang tên cá nhân chủ quán (VD: NGUYEN THI MINH NGOC) trong khi OCR đọc được 'NHÀ HÀNG...',
    // ưu tiên tên cửa hàng thực tế từ OCR và giữ thông tin STK ở bankInfo
    String? finalMerchant = qrResult.merchantName;
    if ((finalMerchant == null ||
            finalMerchant.isEmpty ||
            isLikelyPersonalAccountName(finalMerchant)) &&
        ocrResult.merchantName != null &&
        ocrResult.merchantName!.isNotEmpty) {
      finalMerchant = ocrResult.merchantName;
    }

    final mergedItems = <String>[
      ...qrResult.lineItems,
      ...ocrResult.lineItems,
    ];

    String? finalDesc = qrResult.description;
    if ((finalDesc == null || finalDesc.isEmpty) &&
        ocrResult.description != null &&
        ocrResult.description!.isNotEmpty) {
      finalDesc = ocrResult.description;
    } else if (finalDesc != null &&
        ocrResult.lineItems.isNotEmpty &&
        !finalDesc.toLowerCase().contains(ocrResult.lineItems.first.toLowerCase())) {
      finalDesc = '${ocrResult.lineItems.take(2).join(', ')} ($finalDesc)';
    }

    return OfflineReceiptResult(
      totalAmount: finalAmount,
      rawText: '${qrResult.rawText}\n--- OCR ---\n${ocrResult.rawText}',
      merchantName: finalMerchant ?? qrResult.merchantName ?? ocrResult.merchantName,
      transactionDate: ocrResult.transactionDate ?? qrResult.transactionDate,
      confidence: qrResult.totalAmount > 0
          ? qrResult.confidence
          : math.max(qrResult.confidence, ocrResult.confidence),
      scanMethod: 'vietqr_ocr_fused',
      invoiceCode: qrResult.invoiceCode ?? ocrResult.invoiceCode,
      bankInfo: qrResult.bankInfo,
      description: finalDesc,
      qrCrcValid: qrResult.qrCrcValid,
      lineItems: mergedItems,
    );
  }

  /// Quy trình 3 tầng phân tích Ảnh Hóa Đơn & Mã QR đa nền tảng (Android / iOS / Chrome Web / Desktop):
  /// - Tầng 1: Quét mã QR trực tiếp từ ảnh (`MobileScanner` / `BarcodeDetector` / `jsQR`) -> `QrInvoiceParserService`
  /// - Tầng 2: Nhận diện chữ không gian 2D trên thiết bị bằng `Google ML Kit` (kết hợp Fuse nếu vừa có QR vừa có chữ)
  /// - Tầng 3: Multimodal Vision AI (`POST /ai/scan-receipt` hoặc `GEMINI_API_KEY`)
  static Future<OfflineReceiptResult?> analyzeImageBytes(
    Uint8List imageBytes, {
    String? filePath,
    String mimeType = 'image/jpeg',
    String? preDetectedQrRaw,
  }) async {
    OfflineReceiptResult? qrResult;

    // 1. Giải mã QR (từ live scanner truyền vào hoặc quét trên ảnh tĩnh)
    final detectedQr = preDetectedQrRaw ??
        await detectQrFromImageBytesPlatform(
          imageBytes,
          filePath: filePath,
          mimeType: mimeType,
        );
    if (detectedQr != null && detectedQr.trim().isNotEmpty) {
      for (final line in detectedQr.split('\n')) {
        final qrParsed = QrInvoiceParserService.parse(line);
        if (qrParsed != null) {
          qrResult = OfflineReceiptResult.fromQrResult(qrParsed);
          break;
        }
      }
      qrResult ??= OfflineReceiptResult.fromText(detectedQr);
    }

    // 2. Chạy On-Device Spatial OCR (Google ML Kit trên Android / iOS)
    // Nếu mã QR đã đầy đủ cả Số tiền + Tên thương hiệu doanh nghiệp rõ ràng thì trả về tức thì (<50ms);
    // Nếu QR là tài khoản cá nhân (VD: NGUYEN THI MINH NGOC) hoặc QR tĩnh (amount == 0), chạy thêm OCR để lấy Tên quán & Món ăn!
    final bool needsOcrEnrichment = qrResult == null ||
        qrResult.totalAmount <= 0 ||
        isLikelyPersonalAccountName(qrResult.merchantName) ||
        (qrResult.description == null || qrResult.description!.isEmpty);

    OfflineReceiptResult? localOcrResult;
    if (needsOcrEnrichment) {
      final nativeOcr = await runNativeOcrPlatform(
        filePath: filePath,
        bytes: imageBytes,
      );
      if (nativeOcr != null && nativeOcr.fullText.trim().isNotEmpty) {
        final spatialLines = nativeOcr.lines
            .map(
              (l) => SpatialTextLine(
                text: normalizeOcrNoise(l.text),
                top: l.top,
                bottom: l.bottom,
                left: l.left,
                right: l.right,
              ),
            )
            .toList();

        localOcrResult = OfflineReceiptResult.fromText(
          nativeOcr.fullText,
          spatialLines: spatialLines,
          scanMethod: 'mlkit_spatial_ocr',
        );
      }
    }

    if (qrResult != null) {
      final fused = fuseQrAndOcr(qrResult, localOcrResult);
      if (fused.totalAmount > 0) return fused;
      // Nếu cả QR tĩnh và ML Kit đều chưa thấy tiền, thử Cloud Vision AI
      final cloudFallback = await _tryCloudVisionScan(imageBytes, mimeType);
      return cloudFallback != null && cloudFallback.totalAmount > 0
          ? fuseQrAndOcr(qrResult, cloudFallback)
          : fused;
    }

    if (localOcrResult != null &&
        localOcrResult.totalAmount > 0 &&
        localOcrResult.confidence >= 0.80) {
      return localOcrResult;
    }

    // 3. Fallback sang Multimodal Vision AI (hỗ trợ Chrome Web, Desktop & hóa đơn chụp mờ/nghiêng)
    final cloudResult = await _tryCloudVisionScan(imageBytes, mimeType);
    if (cloudResult != null &&
        (cloudResult.totalAmount > 0 || localOcrResult == null)) {
      return cloudResult;
    }

    return localOcrResult;
  }

  /// Phân tích trực tiếp chuỗi QR (VietQR / GDT E-Invoice / URL / JSON) hoặc văn bản OCR dán vào
  static OfflineReceiptResult analyzeRawInput(String rawInput) {
    final qr = QrInvoiceParserService.parse(rawInput);
    if (qr != null) {
      return OfflineReceiptResult.fromQrResult(qr);
    }
    return OfflineReceiptResult.fromText(rawInput);
  }

  static Future<OfflineReceiptResult?> _tryCloudVisionScan(
    Uint8List imageBytes,
    String mimeType,
  ) async {
    final base64Image = base64Encode(imageBytes);

    if (await ApiService.instance.hasToken()) {
      try {
        final res = await ApiService.instance.post(ApiConfig.aiScanReceipt, {
          'imageBase64': base64Image,
          'mimeType': mimeType,
        });
        if (res['success'] == true && res['data']?['result'] is Map) {
          return _mapVisionJsonToResult(
            Map<String, dynamic>.from(res['data']['result'] as Map),
          );
        }
      } catch (_) {}
    }

    const definedKey = String.fromEnvironment('GEMINI_API_KEY');
    final rawKey = definedKey.replaceAll('"', '').replaceAll("'", '').trim();
    if (rawKey.isEmpty) return null;

    const prompt = '''Bạn là hệ thống OCR và đọc mã QR hóa đơn tiếng Việt.
Đọc toàn bộ chữ trên biên lai VÀ mã QR nếu có trong ảnh, trả về ĐÚNG 1 JSON OBJECT:
{"totalAmount":0,"merchantName":null,"transactionDate":null,"invoiceCode":null,"description":null,"qrPayload":null,"rawText":"","confidence":0.9}''';

    for (final model in const ['gemini-2.5-flash', 'gemini-2.0-flash']) {
      try {
        final uri = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$rawKey',
        );
        final response = await http
            .post(
              uri,
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({
                'contents': [
                  {
                    'parts': [
                      {'text': prompt},
                      {
                        'inlineData': {
                          'mimeType': mimeType,
                          'data': base64Image,
                        }
                      },
                    ]
                  }
                ],
                'generationConfig': {'responseMimeType': 'application/json'},
              }),
            )
            .timeout(const Duration(seconds: 18));

        if (response.statusCode == 200) {
          final body = jsonDecode(response.body);
          final text =
              body['candidates']?[0]?['content']?['parts']?[0]?['text'];
          if (text is String && text.isNotEmpty) {
            final cleaned =
                text.replaceAll('```json', '').replaceAll('```', '').trim();
            return _mapVisionJsonToResult(
              Map<String, dynamic>.from(jsonDecode(cleaned) as Map),
            );
          }
        }
      } catch (_) {}
    }
    return null;
  }

  static OfflineReceiptResult _mapVisionJsonToResult(Map<String, dynamic> map) {
    final rawAmt = map['totalAmount'];
    final visionAmount = rawAmt is num
        ? rawAmt.toDouble()
        : (double.tryParse(
                rawAmt?.toString().replaceAll(RegExp(r'[^0-9.]'), '') ?? '') ??
            0.0);
    final rawDate = map['transactionDate']?.toString();
    final parsedDate = rawDate != null ? DateTime.tryParse(rawDate) : null;
    final conf = map['confidence'] is num
        ? (map['confidence'] as num).toDouble().clamp(0.0, 1.0)
        : 0.92;

    final visionOcr = OfflineReceiptResult(
      totalAmount: visionAmount,
      merchantName: map['merchantName']?.toString(),
      transactionDate: parsedDate,
      invoiceCode: map['invoiceCode']?.toString(),
      description: map['description']?.toString(),
      rawText: map['rawText']?.toString() ?? '',
      confidence: conf,
      scanMethod: 'gemini_vision_ai',
    );

    final qrPayload = map['qrPayload']?.toString().trim();
    if (qrPayload != null && qrPayload.isNotEmpty) {
      final parsedQr = QrInvoiceParserService.parse(qrPayload);
      if (parsedQr != null) {
        return fuseQrAndOcr(OfflineReceiptResult.fromQrResult(parsedQr), visionOcr);
      }
    }
    return visionOcr;
  }

  /// Ghép các box văn bản nằm cùng hàng ngang (trục Y) để xử lý biên lai 2 cột
  static List<String> reconstructHorizontalLines(
      List<SpatialTextLine> spatialLines) {
    if (spatialLines.isEmpty) return const [];

    final sorted = List<SpatialTextLine>.from(spatialLines)
      ..sort((a, b) => a.centerY.compareTo(b.centerY));

    final avgHeight = sorted
            .map((l) => l.height > 0 ? l.height : 16.0)
            .reduce((a, b) => a + b) /
        sorted.length;
    final yTolerance = math.max(8.0, avgHeight * 0.65);

    final rows = <List<SpatialTextLine>>[];
    for (final line in sorted) {
      if (rows.isEmpty) {
        rows.add([line]);
      } else {
        final currentRow = rows.last;
        final rowCenterY =
            currentRow.map((e) => e.centerY).reduce((a, b) => a + b) /
                currentRow.length;
        if ((line.centerY - rowCenterY).abs() <= yTolerance) {
          currentRow.add(line);
        } else {
          rows.add([line]);
        }
      }
    }

    return rows.map((row) {
      row.sort((a, b) => a.left.compareTo(b.left));
      return normalizeOcrNoise(row.map((e) => e.text).join(' '));
    }).toList();
  }

  /// Khử nhiễu ký tự đặc trưng của máy in nhiệt & chụp qua màn hình (ví dụ '130.O00' -> '130.000', '130 000đ' -> '130.000đ')
  static String normalizeOcrNoise(String text) {
    var result = text;
    result = result.replaceAllMapped(
      RegExp(r'(\d[.,\s])[Oo0]{3}(?!\d)'),
      (m) => '${m.group(1) == ' ' ? '.' : m.group(1)}000',
    );
    result = result.replaceAllMapped(
      RegExp(r'(\d)[Oo](\d)'),
      (m) => '${m.group(1)}0${m.group(2)}',
    );
    result = result.replaceAllMapped(
      RegExp(r'(\b\d{1,3})\s+(000\b)'),
      (m) => '${m.group(1)}.${m.group(2)}',
    );
    return result;
  }

  static String? _extractInvoiceCode(List<String> lines) {
    final regex = RegExp(
      r'(?:so\s*hd|ma\s*hd|hoa\s*don\s*so|so|bill\s*no|invoice\s*no|receipt\s*#?)\s*[:#-]?\s*([A-Z0-9\-/]{5,20})',
      caseSensitive: false,
    );
    for (final line in lines) {
      final ascii = SmartCategorizerService.removeDiacritics(line.toLowerCase());
      final m = regex.firstMatch(ascii);
      if (m != null) {
        // Lấy token tương ứng viết hoa
        return m.group(1)?.toUpperCase();
      }
    }
    return null;
  }

  /// Trích xuất tên món ăn / mặt hàng trên hóa đơn (VD: 'CƠM GÀ RANG GỪNG', 'CƠM BA CHỈ RANG TÔM')
  static List<String> _extractMenuOrLineItems(List<String> lines) {
    final items = <String>[];
    final ignoreAscii = RegExp(
      r'(nha\s*hang|dia\s*chi|tang\s*\d|toa\s*nha|phieu\s*tam|hoa\s*don|ngay|ban\s*:|sl\s*khach|phuc\s*vu|thu\s*ngan|ten\s*mon|tong\s*thanh\s*toan|con\s*phai\s*thu|tong\s*cong|thanh\s*toan|tien\s*khach|tien\s*thua|vui\s*long|kiem\s*tra|cam\s*on|hen\s*gap|truy\s*cap|to\s*giac|shb|vcb|mbbank|bidv|techcombank|vietinbank|acb)',
      caseSensitive: false,
    );

    for (final raw in lines) {
      var cleaned = raw
          .replaceAll(RegExp(r'^\s*\d{1,2}\s+'), '') // Bỏ STT đầu dòng (1, 2...)
          .replaceAll(RegExp(r'\b\d{1,3}(?:[.,]\d{3})+\s*(?:đ|d|vnd)?\b', caseSensitive: false), '')
          .replaceAll(RegExp(r'\b\d+\b'), '')
          .replaceAll(RegExp(r'[|_\-]{2,}'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

      if (cleaned.length < 4 || cleaned.length > 45) continue;
      if (!RegExp(r'[a-zA-ZÀ-ỹ]{3,}').hasMatch(cleaned)) continue;
      if (cleaned.contains('>') ||
          cleaned.contains('<') ||
          cleaned.contains('_') ||
          cleaned.contains('http') ||
          RegExp(r'\.(jpg|jpeg|png|webp)\b', caseSensitive: false).hasMatch(cleaned)) {
        continue;
      }

      final ascii = SmartCategorizerService.removeDiacritics(cleaned.toLowerCase());
      if (ignoreAscii.hasMatch(ascii)) continue;

      items.add(cleaned);
      if (items.length >= 3) break;
    }
    return items;
  }

  static String? _extractMerchant(
    List<String> lines, {
    List<SpatialTextLine>? spatialLines,
  }) {
    // Ưu tiên 1: Các dòng chứa tiền tố thương hiệu / cửa hàng rõ ràng
    final venuePrefix = RegExp(
      r'\b(nha\s*hang|quan|tiem|cafe|coffee|highlands|phuc\s*long|starbucks|katinat|sieu\s*thi|winmart|circle\s*k|bach\s*hoa\s*xanh|coopmart|aeon|nha\s*thuoc|long\s*chau|pharmacity|cgv|lotte|grab|petrolimex|evn)\b',
      caseSensitive: false,
    );

    for (final line in lines.take(10)) {
      if (!_isValidMerchantLine(line)) continue;
      final ascii = SmartCategorizerService.removeDiacritics(line.toLowerCase());
      if (venuePrefix.hasMatch(ascii)) {
        return line;
      }
    }

    if (spatialLines != null && spatialLines.isNotEmpty) {
      final topBoxes = List<SpatialTextLine>.from(spatialLines)
        ..sort((a, b) => a.top.compareTo(b.top));
      final candidates =
          topBoxes.take(8).where((b) => _isValidMerchantLine(b.text)).toList();
      if (candidates.isNotEmpty) {
        candidates.sort((a, b) => b.height.compareTo(a.height));
        return candidates.first.text;
      }
    }

    for (final line in lines.take(6)) {
      if (_isValidMerchantLine(line)) {
        return line;
      }
    }
    return null;
  }

  static bool _isValidMerchantLine(String line) {
    final trimmed = line.trim();
    if (trimmed.length < 3 ||
        trimmed.length > 55 ||
        !RegExp(r'[a-zA-ZÀ-ỹ]').hasMatch(trimmed)) {
      return false;
    }
    if (trimmed.contains('>') ||
        trimmed.contains('<') ||
        trimmed.contains('http') ||
        trimmed.toLowerCase().contains('scaled_')) {
      return false;
    }

    final ascii = SmartCategorizerService.removeDiacritics(trimmed.toLowerCase());
    if (RegExp(
      r'(dia\s*chi|tang\s*\d|toa\s*nha|address|hotline|tel|mst|ma\s*so\s*thue|hoa\s*don|phieu\s*tam|phieu\s*thanh\s*toan|bien\s*lai|receipt|invoice|ngay|date|total|tong|thanh\s*toan|con\s*phai\s*thu|thu\s*ngan|phuc\s*vu|sl\s*khach|ban\s*:|ten\s*mon|cashier|vui\s*long|kiem\s*tra|cam\s*on|truy\s*cap|xem\s*them|dang\s*ky|to\s*giac|\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4}|\d{8,})',
      caseSensitive: false,
    ).hasMatch(ascii)) {
      return false;
    }
    if (RegExp(r'^\s*\d+\s').hasMatch(trimmed)) return false;
    return true;
  }

  static DateTime? _extractDate(List<String> lines) {
    final dmy = RegExp(r'\b(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{4})\b');
    final ymd = RegExp(r'\b(\d{4})[/\-.](\d{1,2})[/\-.](\d{1,2})\b');
    final vnVerbose = RegExp(
      r'ngay\s*(\d{1,2})\s*thang\s*(\d{1,2})\s*nam\s*(\d{4})',
      caseSensitive: false,
    );

    for (final line in lines) {
      final ascii = SmartCategorizerService.removeDiacritics(line.toLowerCase());
      final verboseMatch = vnVerbose.firstMatch(ascii);
      if (verboseMatch != null) {
        final day = int.parse(verboseMatch.group(1)!);
        final month = int.parse(verboseMatch.group(2)!);
        final year = int.parse(verboseMatch.group(3)!);
        final date = DateTime(year, month, day);
        if (date.year == year && date.month == month && date.day == day) {
          return date;
        }
      }

      final iso = ymd.firstMatch(line);
      final local = iso == null ? dmy.firstMatch(line) : null;
      if (iso == null && local == null) continue;
      final year = int.parse((iso ?? local)!.group(iso == null ? 3 : 1)!);
      final month = int.parse((iso ?? local)!.group(2)!);
      final day = int.parse((iso ?? local)!.group(iso == null ? 1 : 3)!);
      final date = DateTime(year, month, day);
      if (date.year == year && date.month == month && date.day == day) {
        return date;
      }
    }
    return null;
  }

  /// So khớp từ khóa tổng tiền KHÔNG PHỤ THUỘC DẤU (chống lỗi ML Kit đọc lệch dấu tiếng Việt như 'Tồng thanh toản', 'Con phai thu')
  static _AmountExtraction _extractAmountWithConfidence(List<String> lines) {
    final p1AsciiRegex = RegExp(
      r'(con\s*phai\s*thu|tong\s*thanh\s*toan|khach\s*phai\s*tra|thuc\s*thu|thanh\s*toan|amount\s*due|tong\s*phai\s*tra)',
      caseSensitive: false,
    );
    final p2AsciiRegex = RegExp(
      r'(tong\s*tien|tong\s*cong|thanh\s*tien|grand\s*total|cong\s*tien\s*hang|tong\s*hoa\s*don)',
      caseSensitive: false,
    );
    final p3AsciiRegex = RegExp(
      r'(\btotal\b|\bsubtotal\b|cong\s*tien)',
      caseSensitive: false,
    );

    double? foundAmount;

    foundAmount = _scanLinesForAsciiKeyword(lines, p1AsciiRegex);
    if (foundAmount != null) return _AmountExtraction(foundAmount, 0.97);

    foundAmount = _scanLinesForAsciiKeyword(lines, p2AsciiRegex);
    if (foundAmount != null) return _AmountExtraction(foundAmount, 0.92);

    foundAmount = _scanLinesForAsciiKeyword(lines, p3AsciiRegex);
    if (foundAmount != null) return _AmountExtraction(foundAmount, 0.84);

    final fallback = _findHighestReasonableAmount(lines);
    return _AmountExtraction(fallback, fallback > 0 ? 0.65 : 0.0);
  }

  static double? _scanLinesForAsciiKeyword(
      List<String> lines, RegExp asciiKeywordRegex) {
    for (int i = 0; i < lines.length; i++) {
      final asciiLine =
          SmartCategorizerService.removeDiacritics(lines[i].toLowerCase());
      // Không lấy dòng hướng dẫn dạng "Vui lòng kiểm tra kỹ lại nội dung trước khi thanh toán!"
      if (asciiLine.contains('vui long') || asciiLine.contains('kiem tra')) {
        continue;
      }
      if (asciiKeywordRegex.hasMatch(asciiLine)) {
        double? amount =
            _extractNumberFromText(lines[i], allowKeywordLine: true);
        if (amount != null && _isValidAmount(amount)) return amount;

        if (i + 1 < lines.length) {
          amount =
              _extractNumberFromText(lines[i + 1], allowKeywordLine: true);
          if (amount != null && _isValidAmount(amount)) {
            return amount;
          }
        }
      }
    }
    return null;
  }

  static double _findHighestReasonableAmount(List<String> lines) {
    double maxFormattedThousand = 0;
    double maxRoundAmount = 0;

    for (final line in lines) {
      if (_isGarbageLine(line)) continue;

      // Ưu tiên số có dấu phân cách hàng nghìn chuẩn tiền Việt (VD: 130.000, 65,000)
      final formattedMatches =
          RegExp(r'(?<!\d)\d{1,3}(?:[.,]\d{3})+(?!\d)').allMatches(line);
      for (final m in formattedMatches) {
        final v =
            double.tryParse(m.group(0)!.replaceAll(RegExp(r'[.,]'), ''));
        if (v != null && _isValidAmount(v) && v > maxFormattedThousand) {
          maxFormattedThousand = v;
        }
      }

      final amount = _extractNumberFromText(line);
      if (amount != null &&
          _isValidAmount(amount) &&
          amount % 500 == 0 &&
          amount > maxRoundAmount) {
        maxRoundAmount = amount;
      }
    }

    return maxFormattedThousand > 0 ? maxFormattedThousand : maxRoundAmount;
  }

  static double? _extractNumberFromText(
    String text, {
    bool allowKeywordLine = false,
  }) {
    if (!allowKeywordLine && _isGarbageLine(text)) return null;

    // Ưu tiên số có dấu chấm/phẩy phân tách nghìn trước
    final formattedMatches =
        RegExp(r'(?<!\d)\d{1,3}(?:[.,]\d{3})+(?!\d)').allMatches(text);
    double? largestFormatted;
    for (final match in formattedMatches) {
      final value =
          double.tryParse(match.group(0)!.replaceAll(RegExp(r'[.,]'), ''));
      if (value != null &&
          (largestFormatted == null || value > largestFormatted)) {
        largestFormatted = value;
      }
    }
    if (largestFormatted != null) return largestFormatted;

    // Sau đó mới xét số nguyên viết liền (loại trừ số tài khoản >= 9 chữ số trừ khi có chữ đ/vnd đi kèm)
    final plainMatches = RegExp(r'(?<!\d)\d{4,8}(?!\d)').allMatches(text);
    double? largestPlain;
    for (final match in plainMatches) {
      final value = double.tryParse(match.group(0)!);
      if (value != null && (largestPlain == null || value > largestPlain)) {
        largestPlain = value;
      }
    }
    return largestPlain;
  }

  static bool _isValidAmount(double amount) {
    if (amount > 100000000) return false;
    if (amount < 1000) return false;
    if (amount >= 1900 && amount <= 2100) return false;
    // Tiền mặt / hóa đơn VND thực tế luôn chia hết cho 100đ (loại bỏ triệt để nhiễu giờ '12:50' -> 1295, số nhà, mã bàn)
    if (amount % 100 != 0) return false;
    return true;
  }

  static bool _isGarbageLine(String text) {
    final ascii = SmartCategorizerService.removeDiacritics(text.toLowerCase());

    if (RegExp(r'\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4}').hasMatch(text)) {
      return true;
    }
    if (RegExp(r'\d{1,2}:\d{2}').hasMatch(text)) return true;
    if (ascii.contains('ngay') ||
        ascii.contains('thang') ||
        ascii.contains('nam')) {
      return true;
    }
    if (ascii.contains('hotline') ||
        ascii.contains('tel') ||
        ascii.contains('sdt') ||
        ascii.contains('lien he') ||
        RegExp(r'\b0\d{2}[.\s]?\d{3}[.\s]?\d{3,4}\b').hasMatch(text)) {
      return true;
    }
    if (ascii.contains('mst') || ascii.contains('ma so thue')) return true;
    // Loại bỏ dòng chân trang chứa Số tài khoản ngân hàng (VD: 'SHB - NGUYEN THI MINH NGOC - 1022333939')
    if (RegExp(
            r'\b(shb|vcb|vietcombank|mbbank|mb|bidv|techcombank|tcb|vietinbank|acb|vpbank|tpbank|agribank|sacombank|stk|so tai khoan)\b')
        .hasMatch(ascii)) {
      return true;
    }
    if (RegExp(r'\b\d{9,16}\b').hasMatch(text)) {
      return true;
    }
    if ((ascii.contains('hoa don') || ascii.contains('so:')) &&
        RegExp(r'\d{5,}').hasMatch(text)) {
      return true;
    }
    if (ascii.contains('tien khach') ||
        ascii.contains('khach dua') ||
        ascii.contains('cash')) {
      return true;
    }
    if (ascii.contains('tien thua') ||
        ascii.contains('tien thoi') ||
        ascii.contains('tra lai') ||
        ascii.contains('change')) {
      return true;
    }
    if (ascii.contains('kg') ||
        ascii.contains('gram') ||
        ascii.contains('stt') ||
        ascii.contains('so ban') ||
        ascii.contains('ban:') ||
        ascii.contains('sl khach') ||
        ascii.contains('table')) {
      return true;
    }

    return false;
  }
}
