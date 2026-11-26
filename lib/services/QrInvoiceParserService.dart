import 'dart:convert';

enum QrInvoiceFormat {
  vietQrEmv,
  gdtEInvoice,
  jsonInvoice,
  paymentUrl,
  plainText,
  unknown,
}

class QrInvoiceResult {
  final QrInvoiceFormat format;
  final double totalAmount;
  final String currency;
  final String? merchantName;
  final String? bankName;
  final String? bankBin;
  final String? accountNumber;
  final String? invoiceCode;
  final String? description;
  final String? taxCode;
  final DateTime? transactionDate;
  final bool? crcValid;
  final double confidence;
  final String rawPayload;

  const QrInvoiceResult({
    required this.format,
    required this.totalAmount,
    required this.rawPayload,
    this.currency = 'VND',
    this.merchantName,
    this.bankName,
    this.bankBin,
    this.accountNumber,
    this.invoiceCode,
    this.description,
    this.taxCode,
    this.transactionDate,
    this.crcValid,
    this.confidence = 0.95,
  });

  String get formatLabel {
    switch (format) {
      case QrInvoiceFormat.vietQrEmv:
        return 'VietQR / EMVCo TLV';
      case QrInvoiceFormat.gdtEInvoice:
        return 'QR Hóa đơn điện tử (GDT)';
      case QrInvoiceFormat.jsonInvoice:
        return 'QR Hóa đơn JSON';
      case QrInvoiceFormat.paymentUrl:
        return 'QR Liên kết thanh toán';
      case QrInvoiceFormat.plainText:
        return 'Văn bản biên lai QR';
      case QrInvoiceFormat.unknown:
        return 'Không xác định';
    }
  }

  /// Ghép ngữ cảnh giàu ngữ nghĩa để mô hình ML phân loại chính xác danh mục chi tiêu
  String get mlContextText {
    return [
      if (merchantName != null && merchantName!.isNotEmpty) merchantName!,
      if (description != null && description!.isNotEmpty) description!,
      if (invoiceCode != null && invoiceCode!.isNotEmpty) invoiceCode!,
    ].join(' ').trim();
  }

  /// Tạo ghi chú gọn gàng khi điền vào giao dịch
  String get synthesizedNote {
    final parts = <String>[];
    if (merchantName != null && merchantName!.trim().isNotEmpty) {
      parts.add(merchantName!.trim());
    }
    if (description != null &&
        description!.trim().isNotEmpty &&
        (merchantName == null ||
            !description!.toLowerCase().contains(merchantName!.toLowerCase()))) {
      parts.add(description!.trim());
    }
    if (invoiceCode != null && invoiceCode!.trim().isNotEmpty) {
      parts.add('Mã HĐ: ${invoiceCode!.trim()}');
    }
    if (parts.isEmpty && bankName != null && accountNumber != null) {
      parts.add('CK $bankName ($accountNumber)');
    }
    return parts.join(' - ');
  }
}

/// Bộ giải mã thuật toán QR Hóa đơn & Thanh toán tại Việt Nam:
/// 1. Chuẩn EMVCo Merchant-Presented QR / Napas 247 VietQR (`000201...`) + Kiểm tra đa thức CRC-16/CCITT-FALSE (`0x1021`)
/// 2. Chuẩn QR Hóa đơn điện tử Tổng cục Thuế GDT (`MST|KyHieu|SoHD|Ngay|TongTien|DonViBan`) & Key-Value
/// 3. Chuẩn QR JSON E-Invoice (VNPT / Viettel SInvoice / MISA meInvoice) & Payment URI
class QrInvoiceParserService {
  static const double usdToVndRate = 26294.0;

  static const Map<String, String> vietnamBankBins = {
    '970436': 'Vietcombank',
    '970415': 'VietinBank',
    '970418': 'BIDV',
    '970405': 'Agribank',
    '970407': 'Techcombank',
    '970422': 'MB Bank',
    '970416': 'ACB',
    '970432': 'VPBank',
    '970423': 'TPBank',
    '970403': 'Sacombank',
    '970437': 'HDBank',
    '970441': 'VIB',
    '970443': 'SHB',
    '970448': 'OCB',
    '970426': 'MSB',
    '970454': 'VietCapital Bank',
    '970431': 'Eximbank',
    '970440': 'SeABank',
    '970449': 'LPBank',
    '971005': 'Viettel Money',
    '971025': 'VNPT Money',
    '971011': 'MoMo',
  };

  /// Tính mã kiểm tra CRC-16/CCITT-FALSE (Polynomial 0x1021, Init 0xFFFF) theo đặc tả EMVCo
  static String computeCrc16Ccitt(String payloadUpTo6304) {
    final bytes = utf8.encode(payloadUpTo6304);
    int crc = 0xFFFF;
    for (final b in bytes) {
      crc ^= (b & 0xFF) << 8;
      for (int bit = 0; bit < 8; bit++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }
    return crc.toRadixString(16).toUpperCase().padLeft(4, '0');
  }

  /// Kiểm chứng tính toàn vẹn chuỗi EMVCo / VietQR qua Tag 63 (CRC-16)
  static bool verifyEmvCrc16(String qr) {
    final trimmed = qr.trim();
    if (trimmed.length < 12) return false;
    // 8 ký tự cuối chuẩn EMVCo luôn là '6304XXXX'
    final crcHeaderIdx = trimmed.length - 8;
    if (trimmed.substring(crcHeaderIdx, crcHeaderIdx + 4) != '6304') {
      return false;
    }
    final expectedCrc = trimmed.substring(crcHeaderIdx + 4).toUpperCase();
    final dataToHash = trimmed.substring(0, crcHeaderIdx + 4);
    return computeCrc16Ccitt(dataToHash) == expectedCrc;
  }

  /// Tạo chuỗi VietQR chuẩn Napas 247 hợp lệ (có CRC-16 thực) phục vụ kiểm thử & mô phỏng hóa đơn
  static String buildVietQr({
    required String bankBin,
    required String accountNumber,
    required int amountVnd,
    String? merchantName,
    String? billNumber,
    String? description,
  }) {
    String tlv(String tag, String value) {
      final len = utf8.encode(value).length.toString().padLeft(2, '0');
      return '$tag$len$value';
    }

    final beneficiaryInner = tlv('00', bankBin) + tlv('01', accountNumber);
    final vietQrAccount = tlv('00', 'A000000727') +
        tlv('01', beneficiaryInner) +
        tlv('02', 'QRIBFTTA');

    final addDataParts = StringBuffer();
    if (billNumber != null && billNumber.isNotEmpty) {
      addDataParts.write(tlv('01', billNumber));
    }
    if (description != null && description.isNotEmpty) {
      addDataParts.write(tlv('08', description));
    }

    final body = StringBuffer()
      ..write(tlv('00', '01'))
      ..write(tlv('01', amountVnd > 0 ? '12' : '11'))
      ..write(tlv('38', vietQrAccount))
      ..write(tlv('53', '704'));

    if (amountVnd > 0) {
      body.write(tlv('54', amountVnd.toString()));
    }
    body.write(tlv('58', 'VN'));
    if (merchantName != null && merchantName.isNotEmpty) {
      body.write(tlv('59', merchantName));
    }
    body.write(tlv('60', 'HO CHI MINH'));
    if (addDataParts.isNotEmpty) {
      body.write(tlv('62', addDataParts.toString()));
    }

    final withoutCrc = '${body.toString()}6304';
    final crc = computeCrc16Ccitt(withoutCrc);
    return '$withoutCrc$crc';
  }

  /// Phân tích cấu trúc cây TLV (Tag 2 ký tự - Length 2 ký tự - Value)
  static Map<String, String> parseTlv(String input) {
    final result = <String, String>{};
    int idx = 0;
    while (idx + 4 <= input.length) {
      final tag = input.substring(idx, idx + 2);
      final lenStr = input.substring(idx + 2, idx + 4);
      final len = int.tryParse(lenStr);
      if (len == null || len < 0 || idx + 4 + len > input.length) {
        break;
      }
      final val = input.substring(idx + 4, idx + 4 + len);
      result[tag] = val;
      idx += 4 + len;
    }
    return result;
  }

  /// Điểm vào chính: tự động nhận diện định dạng QR và bóc tách dữ liệu hóa đơn
  static QrInvoiceResult? parse(String rawInput) {
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) return null;

    // 1. Chuẩn EMVCo / VietQR (bắt đầu bằng '000201' hoặc '000202')
    if (trimmed.startsWith('000201') || trimmed.startsWith('000202')) {
      final emv = _parseEmvVietQr(trimmed);
      if (emv != null) return emv;
    }

    // 2. Chuẩn JSON E-Invoice
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      final jsonRes = _parseJsonInvoice(trimmed);
      if (jsonRes != null) return jsonRes;
    }

    // 3. Chuẩn URL thanh toán / tra cứu hóa đơn điện tử (VietQR quicklink, MoMo, VNPay, SInvoice...)
    if (trimmed.startsWith('http://') ||
        trimmed.startsWith('https://') ||
        trimmed.contains('?amount=') ||
        trimmed.contains('&amount=')) {
      final urlRes = _parsePaymentUrl(trimmed);
      if (urlRes != null) return urlRes;
    }

    // 4. Chuẩn QR Hóa đơn điện tử Tổng cục Thuế GDT (phân cách bằng '|' hoặc ';')
    if (trimmed.contains('|') ||
        RegExp(r'\b(mst|sohd|tongtien|amount|total)\s*[:=]', caseSensitive: false)
            .hasMatch(trimmed)) {
      final gdt = _parseGdtEInvoice(trimmed);
      if (gdt != null) return gdt;
    }

    return null;
  }

  static QrInvoiceResult? _parseEmvVietQr(String payload) {
    final root = parseTlv(payload);
    if (!root.containsKey('00')) return null;

    final crcOk = verifyEmvCrc16(payload);
    final currencyIso = root['53'] ?? '704';
    final currency = currencyIso == '840' ? 'USD' : 'VND';

    double rawAmount = double.tryParse(root['54'] ?? '') ?? 0.0;
    if (currency == 'USD' && rawAmount > 0) {
      rawAmount = rawAmount * usdToVndRate;
    }

    String? bankBin;
    String? accountNumber;
    // Tag 38 là chuẩn Napas VietQR; ngoài ra kiểm tra thêm dải 26..51 cho VNPAY/MoMo/ZaloPay
    for (int tagNum = 26; tagNum <= 51; tagNum++) {
      final tagKey = tagNum.toString().padLeft(2, '0');
      if (!root.containsKey(tagKey)) continue;
      final sub = parseTlv(root[tagKey]!);
      if (sub.containsKey('01')) {
        final inner = parseTlv(sub['01']!);
        if (inner.containsKey('00') && inner.containsKey('01')) {
          bankBin = inner['00'];
          accountNumber = inner['01'];
          break;
        }
        accountNumber ??= sub['01'];
      }
    }

    String? merchantName = root['59']?.trim();
    String? invoiceCode;
    String? description;

    if (root.containsKey('62')) {
      final addData = parseTlv(root['62']!);
      invoiceCode = addData['01'] ?? addData['05'];
      description = addData['08'] ?? addData['07'];
      if ((merchantName == null || merchantName.isEmpty) &&
          addData['03'] != null) {
        merchantName = addData['03'];
      }
    }

    // Nếu số tiền không nằm ở Tag 54 (QR tĩnh nhưng có ghi tiền trong nội dung Tag 62.08)
    if (rawAmount <= 0 && description != null) {
      rawAmount = _extractLooseVndAmount(description);
    }

    final bankName = bankBin != null ? (vietnamBankBins[bankBin] ?? 'BIN $bankBin') : null;
    if ((merchantName == null || merchantName.isEmpty) && description != null) {
      merchantName = _inferMerchantFromDescription(description);
    }

    return QrInvoiceResult(
      format: QrInvoiceFormat.vietQrEmv,
      totalAmount: rawAmount,
      currency: 'VND',
      merchantName: merchantName,
      bankName: bankName,
      bankBin: bankBin,
      accountNumber: accountNumber,
      invoiceCode: invoiceCode,
      description: description,
      transactionDate: DateTime.now(),
      crcValid: crcOk,
      confidence: crcOk ? 0.99 : 0.85,
      rawPayload: payload,
    );
  }

  static QrInvoiceResult? _parseJsonInvoice(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return null;
      final map = decoded.map((k, v) => MapEntry(k.toString().toLowerCase(), v));

      final rawAmt = _parseNum(
            map['totalamount'] ??
                map['total'] ??
                map['amount'] ??
                map['tongtien'] ??
                map['thanhtien'] ??
                map['sotien'],
          ) ??
          0.0;

      final merchant = (map['merchant'] ??
              map['merchantname'] ??
              map['seller'] ??
              map['sellername'] ??
              map['tendonvi'] ??
              map['store'])
          ?.toString();

      final invoiceNo = (map['invoiceno'] ??
              map['invoicecode'] ??
              map['sohd'] ??
              map['mahd'] ??
              map['billid'])
          ?.toString();

      final taxCode = (map['taxcode'] ?? map['mst'])?.toString();
      final desc = (map['description'] ?? map['note'] ?? map['noidung'])?.toString();
      final dateStr = (map['date'] ?? map['issuedate'] ?? map['ngaylap'])?.toString();

      return QrInvoiceResult(
        format: QrInvoiceFormat.jsonInvoice,
        totalAmount: rawAmt,
        merchantName: merchant,
        invoiceCode: invoiceNo,
        taxCode: taxCode,
        description: desc,
        transactionDate: _parseFlexibleDate(dateStr),
        confidence: 0.96,
        rawPayload: payload,
      );
    } catch (_) {
      return null;
    }
  }

  static QrInvoiceResult? _parsePaymentUrl(String payload) {
    final uri = Uri.tryParse(payload);
    if (uri == null) return null;
    final qp = uri.queryParameters.map((k, v) => MapEntry(k.toLowerCase(), v));

    final amt = _parseNum(
          qp['amount'] ?? qp['total'] ?? qp['sotien'] ?? qp['tongtien'] ?? qp['money'],
        ) ??
        0.0;
    String? merchant = qp['accountname'] ??
        qp['merchant'] ??
        qp['seller'] ??
        qp['tendv'] ??
        qp['store'];
    final desc = qp['addinfo'] ?? qp['description'] ?? qp['content'] ?? qp['memo'];
    final billNo = qp['billid'] ?? qp['invoiceno'] ?? qp['sohd'] ?? qp['orderid'];

    // Hỗ trợ URL ảnh VietQR dạng https://img.vietqr.io/image/970436-0123456789-compact.png?amount=65000&addInfo=Highlands
    String? bankBin;
    String? accountNo;
    final vietQrImgMatch =
        RegExp(r'vietqr\.io/image/([a-zA-Z0-9]+)-([0-9]+)').firstMatch(payload);
    if (vietQrImgMatch != null) {
      bankBin = vietQrImgMatch.group(1);
      accountNo = vietQrImgMatch.group(2);
    }

    if (amt <= 0 && merchant == null && desc == null && bankBin == null) {
      return null;
    }

    merchant ??= desc != null ? _inferMerchantFromDescription(desc) : null;

    return QrInvoiceResult(
      format: QrInvoiceFormat.paymentUrl,
      totalAmount: amt,
      merchantName: merchant,
      bankName: bankBin != null ? (vietnamBankBins[bankBin] ?? bankBin) : null,
      bankBin: bankBin,
      accountNumber: accountNo,
      invoiceCode: billNo,
      description: desc,
      transactionDate: _parseFlexibleDate(qp['date']),
      confidence: 0.94,
      rawPayload: payload,
    );
  }

  /// Giải mã QR Hóa đơn điện tử GDT dạng:
  /// `0100109106|1C26TAA|00045821|25/11/2026|185000|CONG TY CO PHAN DICH VU CA PHE CAO NGUYEN`
  /// hoặc dạng cặp khóa `MST=0100109106;SOHD=00045821;NGAY=2026-11-25;TONGTIEN=185000;TEN=HIGHLANDS COFFEE`
  static QrInvoiceResult? _parseGdtEInvoice(String payload) {
    if (payload.contains('|')) {
      final parts = payload.split('|').map((e) => e.trim()).toList();
      if (parts.length >= 4) {
        String? taxCode;
        String? invoiceNo;
        DateTime? txDate;
        double amount = 0.0;
        String? merchant;

        for (final part in parts) {
          if (taxCode == null && RegExp(r'^\d{10}(?:-\d{3})?$').hasMatch(part)) {
            taxCode = part;
            continue;
          }
          final parsedDate = _parseFlexibleDate(part);
          if (txDate == null && parsedDate != null) {
            txDate = parsedDate;
            continue;
          }
          final numCandidate = _parseNum(part);
          if (numCandidate != null &&
              numCandidate >= 1000 &&
              numCandidate <= 500000000 &&
              !RegExp(r'^0\d{6,}$').hasMatch(part)) {
            if (numCandidate > amount) {
              amount = numCandidate;
              continue;
            }
          }
          if (invoiceNo == null &&
              RegExp(r'^[A-Z0-9/\-]{4,20}$', caseSensitive: false).hasMatch(part) &&
              RegExp(r'\d').hasMatch(part)) {
            invoiceNo = part;
            continue;
          }
          if (RegExp(r'[a-zA-ZÀ-ỹ]{2,}').hasMatch(part)) {
            merchant = (merchant == null || part.length > merchant.length)
                ? part
                : merchant;
          }
        }

        if (amount > 0 || taxCode != null || merchant != null) {
          return QrInvoiceResult(
            format: QrInvoiceFormat.gdtEInvoice,
            totalAmount: amount,
            merchantName: merchant,
            invoiceCode: invoiceNo,
            taxCode: taxCode,
            transactionDate: txDate ?? DateTime.now(),
            confidence: 0.95,
            rawPayload: payload,
          );
        }
      }
    }

    // Dạng Key=Value hoặc Key:Value phân cách bởi ';' hoặc xuống dòng
    final kvPairs = <String, String>{};
    for (final token in payload.split(RegExp(r'[;\r\n]+'))) {
      final m = RegExp(r'^\s*([a-zA-Z0-9_]+)\s*[:=]\s*(.+)$').firstMatch(token);
      if (m != null) {
        kvPairs[m.group(1)!.toLowerCase()] = m.group(2)!.trim();
      }
    }
    if (kvPairs.isNotEmpty) {
      final amt = _parseNum(
            kvPairs['tongtien'] ??
                kvPairs['thanhtien'] ??
                kvPairs['sotien'] ??
                kvPairs['total'] ??
                kvPairs['amount'],
          ) ??
          0.0;
      return QrInvoiceResult(
        format: QrInvoiceFormat.gdtEInvoice,
        totalAmount: amt,
        merchantName: kvPairs['ten'] ?? kvPairs['tendonvi'] ?? kvPairs['merchant'] ?? kvPairs['seller'],
        invoiceCode: kvPairs['sohd'] ?? kvPairs['mahd'] ?? kvPairs['invoiceno'],
        taxCode: kvPairs['mst'] ?? kvPairs['taxcode'],
        description: kvPairs['noidung'] ?? kvPairs['note'],
        transactionDate: _parseFlexibleDate(kvPairs['ngay'] ?? kvPairs['date']),
        confidence: 0.93,
        rawPayload: payload,
      );
    }

    return null;
  }

  static double? _parseNum(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return raw.toDouble();
    var s = raw.toString().trim();
    if (s.isEmpty) return null;
    s = s.replaceAll(RegExp(r'(vnd|vnđ|đ|dong|\s)', caseSensitive: false), '');
    if (RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(s)) {
      s = s.replaceAll('.', '');
    } else if (RegExp(r'^\d{1,3}(,\d{3})+$').hasMatch(s)) {
      s = s.replaceAll(',', '');
    } else {
      s = s.replaceAll(',', '');
    }
    return double.tryParse(s);
  }

  static double _extractLooseVndAmount(String text) {
    final kMatch =
        RegExp(r'(\d+(?:[.,]\d+)?)\s*(?:k|nghìn|ngan)\b', caseSensitive: false)
            .firstMatch(text);
    if (kMatch != null) {
      final v = double.tryParse(kMatch.group(1)!.replaceAll(',', '.')) ?? 0;
      return v * 1000.0;
    }
    final numMatch = RegExp(r'\b(\d{4,9})\b').firstMatch(text.replaceAll('.', '').replaceAll(',', ''));
    if (numMatch != null) {
      return double.tryParse(numMatch.group(1)!) ?? 0.0;
    }
    return 0.0;
  }

  static String? _inferMerchantFromDescription(String desc) {
    final knownBrands = [
      'Highlands Coffee',
      'Phuc Long',
      'The Coffee House',
      'Starbucks',
      'Katinat',
      'Mixue',
      'WinMart',
      'Circle K',
      'Bach Hoa Xanh',
      'Co.opmart',
      'AEON',
      'Grab',
      'Xanh SM',
      'Petrolimex',
      'Long Chau',
      'Pharmacity',
      'CGV',
      'EVN',
      'Viettel',
      'VNPT',
      'FPT',
    ];
    final lower = desc.toLowerCase();
    for (final brand in knownBrands) {
      if (lower.contains(brand.toLowerCase())) {
        return brand;
      }
    }
    return null;
  }

  static DateTime? _parseFlexibleDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final s = raw.trim();
    final iso = DateTime.tryParse(s);
    if (iso != null && iso.year >= 2000 && iso.year <= 2100) return iso;

    final dmy = RegExp(r'^(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{4})$').firstMatch(s);
    if (dmy != null) {
      final d = int.parse(dmy.group(1)!);
      final m = int.parse(dmy.group(2)!);
      final y = int.parse(dmy.group(3)!);
      return DateTime(y, m, d);
    }

    if (RegExp(r'^\d{8}$').hasMatch(s)) {
      // Hỗ trợ cả YYYYMMDD và DDMMYYYY
      final first4 = int.parse(s.substring(0, 4));
      if (first4 >= 2000 && first4 <= 2100) {
        final m = int.parse(s.substring(4, 6));
        final d = int.parse(s.substring(6, 8));
        if (m >= 1 && m <= 12 && d >= 1 && d <= 31) return DateTime(first4, m, d);
      } else {
        final d = int.parse(s.substring(0, 2));
        final m = int.parse(s.substring(2, 4));
        final y = int.parse(s.substring(4, 8));
        if (y >= 2000 && y <= 2100 && m >= 1 && m <= 12 && d >= 1 && d <= 31) {
          return DateTime(y, m, d);
        }
      }
    }
    return null;
  }
}
