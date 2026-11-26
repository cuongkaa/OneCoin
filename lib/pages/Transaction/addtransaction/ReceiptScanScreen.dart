import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:onemorecoin/model/GroupModel.dart';
import 'package:onemorecoin/model/TransactionModel.dart';
import 'package:onemorecoin/model/WalletModel.dart';
import 'package:onemorecoin/services/QrInvoiceParserService.dart';
import 'package:onemorecoin/services/ReceiptOcrService.dart';
import 'package:onemorecoin/services/SmartCategorizerService.dart';
import 'package:onemorecoin/utils/Utils.dart';
import 'package:onemorecoin/utils/app_localizations.dart';
import 'package:onemorecoin/widgets/ShowTransaction.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

class _DemoSample {
  final String title;
  final String subtitle;
  final String badge;
  final IconData icon;
  final Color color;
  final String payload;
  final String? companionOcrText;

  const _DemoSample({
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.icon,
    required this.color,
    required this.payload,
    this.companionOcrText,
  });
}

class ReceiptScanScreen extends StatefulWidget {
  final bool standaloneMode;

  const ReceiptScanScreen({
    super.key,
    this.standaloneMode = false,
  });

  @override
  State<ReceiptScanScreen> createState() => _ReceiptScanScreenState();
}

class _ReceiptScanScreenState extends State<ReceiptScanScreen>
    with SingleTickerProviderStateMixin {
  int _selectedMode = 0; // 0: Camera Tự Động Quét QR, 1: Mã QR / Text, 2: Mẫu Demo
  Uint8List? _imageBytes;
  String? _imageName;

  late final MobileScannerController _scannerController;
  late final AnimationController _laserController;
  bool _isHandlingLiveScan = false;

  final TextEditingController _rawInputController = TextEditingController();
  final TextEditingController _amountOverrideController = TextEditingController();
  final TextEditingController _noteOverrideController = TextEditingController();

  OfflineReceiptResult? _result;
  CategoryPrediction? _prediction;
  int? _selectedGroupId;
  int? _initialMlGroupId;
  List<String> _extractedTokens = const [];
  bool _isScanning = false;
  String? _errorMessage;

  final ImagePicker _picker = ImagePicker();

  bool get _supportsLiveScanner =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  late final List<_DemoSample> _demoSamples = [
    _DemoSample(
      title: 'Phiếu tạm tính + VietQR SHB (130.000đ)',
      subtitle: 'Hợp nhất QR cá nhân (SHB • 1022333939) + OCR món ăn Nhà hàng',
      badge: 'QR + OCR',
      icon: Icons.restaurant_rounded,
      color: const Color(0xFF059669),
      payload: QrInvoiceParserService.buildVietQr(
        bankBin: '970443', // SHB
        accountNumber: '1022333939',
        amountVnd: 130000,
        merchantName: 'NGUYEN THI MINH NGOC',
        billNumber: '250208',
      ),
      companionOcrText: '''NHÀ HÀNG CƠM NIÊU
Tầng 1 Tòa nhà N03 T2
PHIẾU TẠM TÍNH
Số: 250208
Ngày: 08/12/2025 (12:27 - 12:50)
Bàn: 11A
1 CƠM GÀ RANG GỪNG       65.000
2 CƠM BA CHỈ RANG TÔM    65.000
Tổng thanh toán         130.000đ
Còn phải thu            130.000đ
SHB - NGUYEN THI MINH NGOC - 1022333939''',
    ),
    _DemoSample(
      title: 'VietQR — Highlands Coffee (89.000đ)',
      subtitle: 'Chuẩn EMVCo TLV • Vietcombank • Kiểm chứng CRC-16',
      badge: 'VietQR',
      icon: Icons.qr_code_2_rounded,
      color: const Color(0xFF0D9488),
      payload: QrInvoiceParserService.buildVietQr(
        bankBin: '970436',
        accountNumber: '0071001294851',
        amountVnd: 89000,
        merchantName: 'HIGHLANDS COFFEE',
        billNumber: 'HD251109',
        description: 'Thanh toan Phin Sua Da va Banh Mi',
      ),
    ),
    _DemoSample(
      title: 'VietQR — Điện lực EVN (645.000đ)',
      subtitle: 'Chuẩn EMVCo TLV • BIDV • Hóa đơn tiền điện tháng 11',
      badge: 'VietQR',
      icon: Icons.bolt_rounded,
      color: const Color(0xFFD97706),
      payload: QrInvoiceParserService.buildVietQr(
        bankBin: '970418',
        accountNumber: '3141000889922',
        amountVnd: 645000,
        merchantName: 'DIEN LUC EVNHCMC',
        billNumber: 'PE04009812',
        description: 'Thanh toan tien dien thang 11',
      ),
    ),
    const _DemoSample(
      title: 'QR Hóa đơn điện tử — Long Châu (215.000đ)',
      subtitle: 'Chuẩn Tổng cục Thuế GDT (MST | Ký hiệu | Số HĐ | Tiền)',
      badge: 'E-Invoice QR',
      icon: Icons.medical_services_rounded,
      color: Color(0xFF2563EB),
      payload:
          '0315275368|1C26TLC|0019482|25/11/2026|215000|NHA THUOC FPT LONG CHAU - THUOC CAM CUM VITAMIN C',
    ),
    const _DemoSample(
      title: 'Biên lai in nhiệt — Siêu thị WinMart+ (342.000đ)',
      subtitle: 'Khử nhiễu OCR máy in nhiệt (342.O00 -> 342.000) & Lọc tiền thừa',
      badge: 'Thermal OCR',
      icon: Icons.receipt_long_rounded,
      color: Color(0xFFDC2626),
      payload: '''SIÊU THỊ WINMART+ QUẬN 1
ĐC: 128 Nguyễn Thị Minh Khai
Ngày: 25/11/2026  19:42
Hóa đơn số: WM998241
--------------------------------
1. Sữa tươi Vinamilk 1L     38.000
2. Thịt heo sạch MEATDeli  164.000
3. Nước giặt OMO Matic     140.000
--------------------------------
Tổng cộng:                 342.000
Thanh toán:                342.O00 VND
Tiền khách đưa:            500.000
Tiền thừa trả lại:         158.000''',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _scannerController = MobileScannerController(
      autoStart: true,
      detectionSpeed: DetectionSpeed.normal,
      detectionTimeoutMs: 300,
      facing: CameraFacing.back,
      formats: const <BarcodeFormat>[
        BarcodeFormat.qrCode,
        BarcodeFormat.dataMatrix,
        BarcodeFormat.aztec,
        BarcodeFormat.code128,
        BarcodeFormat.ean13,
      ],
      returnImage: !kIsWeb,
      autoZoom: !kIsWeb,
    );

    _laserController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _laserController.dispose();
    _scannerController.dispose();
    _rawInputController.dispose();
    _amountOverrideController.dispose();
    _noteOverrideController.dispose();
    super.dispose();
  }

  String _guessMimeType(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  /// Tự động kích hoạt ngay khoảnh khắc Camera nhìn thấy mã QR (KHÔNG cần bấm nút chụp!)
  Future<void> _onLiveBarcodeDetected(BarcodeCapture capture) async {
    if (_isHandlingLiveScan || _isScanning || _result != null) return;

    final rawList = capture.barcodes
        .map((b) => b.rawValue?.trim() ?? b.displayValue?.trim() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    if (rawList.isEmpty) return;

    _isHandlingLiveScan = true;
    final rawQr = rawList.join('\n');
    final frameBytes = capture.image;

    // Rung phản hồi xúc giác ngay khi bắt trúng QR
    unawaited(HapticFeedback.mediumImpact());
    unawaited(_scannerController.stop());

    if (!mounted) return;
    setState(() {
      _imageBytes = frameBytes;
      _imageName = 'Tự động quét từ Camera';
      _isScanning = true;
      _errorMessage = null;
    });

    try {
      OfflineReceiptResult? analyzed;
      if (frameBytes != null && frameBytes.isNotEmpty) {
        // Kết hợp giải mã VietQR + đọc chữ biên lai ngay trên cùng khung hình Camera!
        analyzed = await ReceiptOcrService.analyzeImageBytes(
          frameBytes,
          preDetectedQrRaw: rawQr,
        );
      }
      analyzed ??= ReceiptOcrService.analyzeRawInput(rawQr);

      await _applyAnalyzedResult(analyzed);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isScanning = false;
        _isHandlingLiveScan = false;
        _errorMessage = 'Lỗi xử lý mã QR vừa quét: $e';
      });
    }
  }

  Future<void> _resetToLiveScanner() async {
    setState(() {
      _result = null;
      _prediction = null;
      _imageBytes = null;
      _imageName = null;
      _errorMessage = null;
      _isScanning = false;
      _isHandlingLiveScan = false;
      _selectedMode = 0;
    });
    if (_supportsLiveScanner) {
      try {
        await _scannerController.start();
      } catch (_) {}
    }
  }

  /// Chọn ảnh có sẵn từ Thư viện hoặc Chụp biên lai giấy không có mã QR
  Future<void> _pickImage(ImageSource source) async {
    try {
      unawaited(_scannerController.stop());
      final XFile? picked = await _picker.pickImage(
        source: source,
        maxWidth: 1800,
        maxHeight: 1800,
        imageQuality: 85,
      );
      if (picked == null) {
        if (_selectedMode == 0 && _result == null && _supportsLiveScanner) {
          unawaited(_scannerController.start());
        }
        return;
      }

      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      setState(() {
        _imageBytes = bytes;
        _imageName = picked.name;
        _result = null;
        _prediction = null;
        _errorMessage = null;
        _isScanning = true;
      });

      final scanned = await ReceiptOcrService.analyzeImageBytes(
        bytes,
        filePath: kIsWeb ? null : picked.path,
        mimeType: _guessMimeType(picked.name),
      );

      if (!mounted) return;
      if (scanned == null ||
          (scanned.totalAmount <= 0 && scanned.rawText.trim().isEmpty)) {
        setState(() {
          _isScanning = false;
          _errorMessage =
              'Chưa nhận diện được mã QR hoặc tổng tiền rõ ràng trên ảnh này. Hãy đưa thẳng mã QR vào khung Camera tự động hoặc chụp rõ dòng "Tổng thanh toán".';
        });
        return;
      }

      await _applyAnalyzedResult(scanned);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isScanning = false;
        _errorMessage = 'Không thể đọc ảnh: $e';
      });
    }
  }

  Future<void> _analyzeTextOrQr(String payload, {String? companionOcr}) async {
    final trimmed = payload.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _errorMessage =
            'Vui lòng nhập hoặc dán nội dung mã QR / văn bản hóa đơn.';
      });
      return;
    }

    unawaited(_scannerController.stop());
    setState(() {
      _isScanning = true;
      _errorMessage = null;
    });

    try {
      var analyzed = ReceiptOcrService.analyzeRawInput(trimmed);
      if (companionOcr != null && companionOcr.trim().isNotEmpty) {
        final ocrPart = OfflineReceiptResult.fromText(
          companionOcr,
          scanMethod: 'mlkit_spatial_ocr',
        );
        analyzed = ReceiptOcrService.fuseQrAndOcr(analyzed, ocrPart);
      }
      await _applyAnalyzedResult(analyzed);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isScanning = false;
        _errorMessage = 'Lỗi phân tích dữ liệu: $e';
      });
    }
  }

  Future<void> _applyAnalyzedResult(OfflineReceiptResult analyzed) async {
    final groups = context
        .read<GroupModelProxy>()
        .getAll()
        .where((g) => g.type == 'expense')
        .toList();

    CategoryPrediction? pred;
    final primarySignal = [
      if (analyzed.merchantName != null &&
          !ReceiptOcrService.isLikelyPersonalAccountName(analyzed.merchantName))
        analyzed.merchantName!,
      if (analyzed.description != null && analyzed.description!.isNotEmpty)
        analyzed.description!,
      if (analyzed.lineItems.isNotEmpty) analyzed.lineItems.join(' '),
    ].join(' ').trim();

    if (primarySignal.isNotEmpty) {
      pred = await SmartCategorizerService.predictWithConfidence(
        primarySignal,
        groups,
      );
    }
    pred ??= await SmartCategorizerService.predictWithConfidence(
      analyzed.mlFeatureInput,
      groups,
    );

    final fallbackGroupId =
        pred?.groupId ?? (groups.isNotEmpty ? groups.first.id : null);
    final featureSource =
        primarySignal.isNotEmpty ? primarySignal : analyzed.rawText;
    final featurePreview =
        SmartCategorizerService.extractFeatures(featureSource).take(6).toList();

    if (!mounted) return;
    setState(() {
      _result = analyzed;
      _prediction = pred;
      _selectedGroupId = fallbackGroupId;
      _initialMlGroupId = pred?.groupId;
      _extractedTokens = featurePreview;
      _amountOverrideController.text = analyzed.totalAmount > 0
          ? analyzed.totalAmount.toStringAsFixed(0)
          : '';
      _noteOverrideController.text = analyzed.suggestedNote;
      _isScanning = false;
      _isHandlingLiveScan = false;
      _errorMessage = null;
    });
  }

  double get _effectiveAmount {
    final cleaned =
        _amountOverrideController.text.replaceAll(RegExp(r'[^0-9.]'), '');
    return double.tryParse(cleaned) ?? (_result?.totalAmount ?? 0.0);
  }

  String get _effectiveNote {
    final t = _noteOverrideController.text.trim();
    return t.isNotEmpty ? t : (_result?.suggestedNote ?? 'Hóa đơn quét');
  }

  Map<String, dynamic> _buildScanPayload() {
    String categorySource = CategorySource.userManual;
    if (_initialMlGroupId != null && _selectedGroupId != null) {
      categorySource = _selectedGroupId == _initialMlGroupId
          ? CategorySource.mlSuggestedAccepted
          : CategorySource.mlSuggestedIgnored;
    }
    return {
      'amount': _effectiveAmount,
      'merchantName': _effectiveNote,
      'transactionDate': _result?.transactionDate ?? DateTime.now(),
      'suggestedGroupId': _selectedGroupId,
      'categorySource': categorySource,
    };
  }

  void _returnToAddTransaction() {
    if (_effectiveAmount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Vui lòng nhập số tiền hợp lệ (> 0 VND)'),
        ),
      );
      return;
    }
    Navigator.pop(context, _buildScanPayload());
  }

  Future<void> _saveDirectly() async {
    final amount = _effectiveAmount;
    if (amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Số tiền phải lớn hơn 0 VND')),
      );
      return;
    }

    final walletProxy = context.read<WalletModelProxy>();
    final txProxy = context.read<TransactionModelProxy>();
    final groupProxy = context.read<GroupModelProxy>();

    final allWallets = walletProxy.getAll();
    if (allWallets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chưa có ví nào để lưu giao dịch')),
      );
      return;
    }

    final activeWalletId = txProxy.walletModel.id != 0
        ? txProxy.walletModel.id
        : allWallets.first.id;
    final targetWallet = walletProxy.getById(activeWalletId);

    final expenseGroups =
        groupProxy.getAll().where((g) => g.type == 'expense').toList();
    final chosenGroup = expenseGroups.firstWhere(
      (g) => g.id == _selectedGroupId,
      orElse: () => expenseGroups.isNotEmpty
          ? expenseGroups.first
          : GroupModel(1, 0, name: 'Ăn uống', type: 'expense'),
    );

    final payload = _buildScanPayload();
    final txDate = (payload['transactionDate'] as DateTime?) ?? DateTime.now();

    await txProxy.add(
      TransactionModel(
        const Uuid().v4(),
        walletId: targetWallet.id,
        groupId: chosenGroup.id,
        title: chosenGroup.name ?? 'Chi tiêu',
        amount: amount,
        unit: 'VND',
        type: 'expense',
        date: txDate.toString(),
        note: _effectiveNote,
        addToReport: false,
        categorySource: payload['categorySource'] as String?,
      ),
    );

    final newBalance = (targetWallet.balance ?? 0) - amount;
    await walletProxy.updateBalance(targetWallet, newBalance);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF059669),
        content: Text(
          'Đã ghi nhận -${Utils.currencyFormat(amount, rawFormat: true)} (${chosenGroup.name}) vào ${targetWallet.name}',
        ),
      ),
    );
    Navigator.pop(context, true);
  }

  Future<void> _openDetailedForm() async {
    final payload = _buildScanPayload();
    Navigator.pop(context);
    await ShowTransactionPage(context, initialScanData: payload);
  }

  String _mlSourceLabel(String? src) {
    switch (src) {
      case 'personal_history_nb':
        return 'Online Learning · Lịch sử cá nhân (Naive Bayes)';
      case 'pretrained_tfidf_nb':
        return 'Pre-trained TF-IDF + Multinomial Naive Bayes';
      case 'keyword_prior':
        return 'Từ điển Ngữ nghĩa Tiếng Việt (Prior)';
      default:
        return 'Mặc định (Chưa có từ khóa đặc trưng — hãy chọn nhóm để dạy ML)';
    }
  }

  void _onSwitchMode(int index) {
    if (_selectedMode == index) return;
    setState(() {
      _selectedMode = index;
      _errorMessage = null;
    });
    if (index == 0 && _result == null && _imageBytes == null && _supportsLiveScanner) {
      unawaited(_scannerController.start());
    } else {
      unawaited(_scannerController.stop());
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final expenseGroups = context
        .watch<GroupModelProxy>()
        .getAll()
        .where((g) => g.type == 'expense')
        .toList();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF0D9488).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.qr_code_scanner_rounded,
                color: Color(0xFF0D9488),
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                s.get('scan_receipt') ?? 'Quét QR & Hóa đơn tự động',
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 17.5),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          if (_result != null || _imageBytes != null)
            TextButton.icon(
              onPressed: _resetToLiveScanner,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Quét lại'),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            // Thanh chuyển đổi 3 chế độ
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  _buildModeTab(0, Icons.center_focus_strong_rounded, 'Quét Tự Động'),
                  _buildModeTab(1, Icons.qr_code_rounded, 'Mã QR / Text'),
                  _buildModeTab(2, Icons.auto_awesome_rounded, 'Mẫu Demo'),
                ],
              ),
            ),
            const SizedBox(height: 14),

            if (_selectedMode == 0) _buildAutoCameraOrPreview(isDark, s),
            if (_selectedMode == 1) _buildRawQrTextSection(isDark),
            if (_selectedMode == 2) _buildDemoSamplesSection(),

            if (_isScanning) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Column(
                  children: [
                    CircularProgressIndicator(color: Color(0xFF0D9488)),
                    SizedBox(height: 14),
                    Text(
                      'Đã bắt được tín hiệu! Đang giải mã VietQR + OCR & phân loại ML...',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],

            if (_errorMessage != null && !_isScanning) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.orange.shade900.withValues(alpha: 0.25)
                      : Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.amber.shade400),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline_rounded,
                            color: Colors.amber.shade800),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: TextStyle(
                              fontSize: 13.5,
                              color: isDark
                                  ? Colors.amber.shade200
                                  : Colors.brown.shade800,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton.icon(
                        onPressed: _resetToLiveScanner,
                        icon: const Icon(Icons.qr_code_scanner_rounded, size: 16),
                        label: const Text('Mở lại Camera quét tự động'),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            if (_result != null && !_isScanning) ...[
              const SizedBox(height: 16),
              _buildAiResultCard(isDark, expenseGroups),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildModeTab(int index, IconData icon, String label) {
    final active = _selectedMode == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => _onSwitchMode(index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF0D9488) : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: active ? Colors.white : Colors.grey.shade600,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.2,
                    fontWeight: FontWeight.w700,
                    color: active ? Colors.white : Colors.grey.shade700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Khung ngắm Camera Live tự động nhận diện QR tức thì (không cần bấm nút chụp!)
  Widget _buildAutoCameraOrPreview(bool isDark, S s) {
    // Nếu đã quét xong và có ảnh chụp frame/thư viện, thu gọn ảnh preview để ưu tiên hiển thị Hóa đơn bên dưới
    if (_result != null || _imageBytes != null) {
      if (_imageBytes == null) return const SizedBox.shrink();
      return Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.memory(
              _imageBytes!,
              width: double.infinity,
              height: 165,
              fit: BoxFit.cover,
            ),
          ),
          Positioned(
            bottom: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _imageName ?? 'Đã quét',
                style: const TextStyle(color: Colors.white, fontSize: 11.5),
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: ElevatedButton.icon(
              onPressed: _resetToLiveScanner,
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 16),
              label: const Text('Quét tiếp', style: TextStyle(fontSize: 12)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.black87,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ),
        ],
      );
    }

    if (!_supportsLiveScanner) {
      return _buildFallbackPickerCard(s);
    }

    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: SizedBox(
            height: 330,
            width: double.infinity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: _scannerController,
                  tapToFocus: !kIsWeb,
                  onDetect: _onLiveBarcodeDetected,
                  errorBuilder: (context, error) {
                    return Container(
                      color: const Color(0xFF0F172A),
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.videocam_off_rounded,
                            color: Colors.white70,
                            size: 42,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            'Không mở được Camera trực tiếp trên thiết bị này',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Hãy cấp quyền Camera hoặc nhấn nút bên dưới để tải ảnh mã QR / hóa đơn lên.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.75),
                              fontSize: 12.5,
                            ),
                          ),
                          const SizedBox(height: 14),
                          ElevatedButton.icon(
                            onPressed: () => _pickImage(ImageSource.gallery),
                            icon: const Icon(Icons.photo_library_rounded, size: 18),
                            label: const Text('Chọn ảnh từ Thư viện'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF10B981),
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),

                // Khung ngắm QR & Tia laser quét tự động
                IgnorePointer(
                  child: Center(
                    child: SizedBox(
                      width: 225,
                      height: 225,
                      child: Stack(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: const Color(0xFF10B981),
                                width: 3,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.35),
                                  blurRadius: 16,
                                  spreadRadius: 4,
                                ),
                              ],
                            ),
                          ),
                          AnimatedBuilder(
                            animation: _laserController,
                            builder: (context, _) {
                              return Positioned(
                                top: 12 + (_laserController.value * 195),
                                left: 10,
                                right: 10,
                                child: Container(
                                  height: 3,
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [
                                        Colors.transparent,
                                        Color(0xFF34D399),
                                        Color(0xFF10B981),
                                        Color(0xFF34D399),
                                        Colors.transparent,
                                      ],
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF10B981)
                                            .withValues(alpha: 0.8),
                                        blurRadius: 8,
                                        spreadRadius: 1,
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // Badge hướng dẫn tự động phía trên
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.62),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.fiber_manual_record_rounded,
                            color: Color(0xFF34D399),
                            size: 12,
                          ),
                          SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              'Hướng Camera vào mã QR hóa đơn để tự động quét',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // Cụm điều khiển nhanh Đèn Flash & Đổi Camera ở góc dưới khung ngắm
                Positioned(
                  bottom: 12,
                  left: 12,
                  right: 12,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (!kIsWeb)
                        ValueListenableBuilder<MobileScannerState>(
                          valueListenable: _scannerController,
                          builder: (context, state, _) {
                            final torchOn = state.torchState == TorchState.on;
                            return IconButton(
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.black54,
                              ),
                              tooltip: 'Bật/Tắt đèn Flash',
                              icon: Icon(
                                torchOn
                                    ? Icons.flash_on_rounded
                                    : Icons.flash_off_rounded,
                                color: torchOn ? Colors.amber : Colors.white,
                              ),
                              onPressed: () => _scannerController.toggleTorch(),
                            );
                          },
                        )
                      else
                        const SizedBox(width: 40),
                      IconButton(
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.black54,
                        ),
                        tooltip: 'Đổi Camera trước/sau',
                        icon: const Icon(
                          Icons.cameraswitch_rounded,
                          color: Colors.white,
                        ),
                        onPressed: () => _scannerController.switchCamera(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Hai nút phụ trợ: Chọn ảnh từ Thư viện HOẶC Chụp biên lai giấy không có mã QR
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.photo_library_rounded, size: 18),
                label: const Text(
                  'Ảnh từ Thư viện',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF0D9488),
                  side: const BorderSide(color: Color(0xFF0D9488)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => _pickImage(ImageSource.gallery),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.receipt_long_rounded, size: 18),
                label: const Text(
                  'HĐ không có QR',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => _pickImage(ImageSource.camera),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFallbackPickerCard(S s) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFF0D9488).withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.qr_code_scanner_rounded,
            size: 48,
            color: Color(0xFF0D9488),
          ),
          const SizedBox(height: 12),
          const Text(
            'Chọn ảnh Hóa đơn hoặc Mã QR từ thiết bị',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15.5),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () => _pickImage(ImageSource.gallery),
            icon: const Icon(Icons.photo_library_rounded),
            label: Text(s.get('gallery') ?? 'Tải ảnh Hóa đơn / QR'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0D9488),
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRawQrTextSection(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.grey.shade800 : Colors.grey.shade300,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Text(
                  'Dán chuỗi VietQR (000201...), QR Hóa đơn điện tử hoặc văn bản biên lai:',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                ),
              ),
              TextButton.icon(
                onPressed: () async {
                  final clip = await Clipboard.getData(Clipboard.kTextPlain);
                  if (clip?.text != null && clip!.text!.trim().isNotEmpty) {
                    setState(() {
                      _rawInputController.text = clip.text!.trim();
                    });
                    _analyzeTextOrQr(clip.text!);
                  }
                },
                icon: const Icon(Icons.content_paste_rounded, size: 16),
                label: const Text('Dán', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _rawInputController,
            maxLines: 4,
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            decoration: InputDecoration(
              hintText:
                  'VD: 00020101021238570010A000000727... hoặc MST|KyHieu|SoHD|Ngay|TongTien|TenCuaHang',
              filled: true,
              fillColor: isDark ? const Color(0xFF0F172A) : Colors.grey.shade50,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _analyzeTextOrQr(_rawInputController.text),
              icon: const Icon(Icons.psychology_rounded),
              label: const Text(
                'Giải mã QR / OCR & Phân loại bằng ML',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0D9488),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDemoSamplesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Chạm vào 1 mẫu thực tế bên dưới để kiểm nghiệm thuật toán Hợp nhất VietQR + OCR + Học máy Naive Bayes:',
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 10),
        ..._demoSamples.map(
          (sample) => Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: sample.color.withValues(alpha: 0.35)),
            ),
            child: ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              leading: CircleAvatar(
                backgroundColor: sample.color.withValues(alpha: 0.14),
                child: Icon(sample.icon, color: sample.color, size: 22),
              ),
              title: Text(
                sample.title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13.5,
                ),
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(sample.subtitle, style: const TextStyle(fontSize: 12)),
              ),
              trailing: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: sample.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  sample.badge,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: sample.color,
                  ),
                ),
              ),
              onTap: () {
                _rawInputController.text = sample.payload;
                _analyzeTextOrQr(
                  sample.payload,
                  companionOcr: sample.companionOcrText,
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAiResultCard(bool isDark, List<GroupModel> expenseGroups) {
    final res = _result!;
    final mlConfPct = _prediction != null
        ? (_prediction!.confidence * 100).clamp(1, 99).toStringAsFixed(0)
        : null;
    final ocrConfPct = (res.confidence * 100).clamp(1, 99).toStringAsFixed(0);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFF10B981).withValues(alpha: 0.45),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF10B981).withValues(alpha: 0.08),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.verified_rounded,
                  color: Color(0xFF059669), size: 22),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Hóa đơn đã nhận diện tự động',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF059669).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Tin cậy $ocrConfPct%',
                  style: const TextStyle(
                    color: Color(0xFF059669),
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF0FDFA),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.memory_rounded,
                    size: 15, color: Color(0xFF0D9488)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    res.methodBadgeLabel,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF0D9488),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 24),

          TextField(
            controller: _amountOverrideController,
            keyboardType: TextInputType.number,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.redAccent,
            ),
            decoration: InputDecoration(
              labelText: 'Số tiền thanh toán (VND)',
              prefixIcon:
                  const Icon(Icons.payments_outlined, color: Colors.redAccent),
              suffixText: 'VND',
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _noteOverrideController,
            decoration: InputDecoration(
              labelText: 'Cửa hàng / Món chi tiêu',
              prefixIcon: const Icon(Icons.storefront_rounded),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 12),

          if (res.bankInfo != null) ...[
            _buildMetaChip(
                Icons.account_balance_rounded, 'Tài khoản nhận QR', res.bankInfo!),
            const SizedBox(height: 6),
          ],
          if (res.invoiceCode != null) ...[
            _buildMetaChip(Icons.tag_rounded, 'Mã hóa đơn', res.invoiceCode!),
            const SizedBox(height: 6),
          ],
          if (res.transactionDate != null) ...[
            _buildMetaChip(
              Icons.calendar_today_rounded,
              'Ngày hóa đơn',
              '${res.transactionDate!.day.toString().padLeft(2, '0')}/${res.transactionDate!.month.toString().padLeft(2, '0')}/${res.transactionDate!.year}',
            ),
            const SizedBox(height: 10),
          ],

          // Thẻ Giải thích Mô hình ML
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF1E1B4B).withValues(alpha: 0.45)
                  : const Color(0xFFEEF2FF),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: const Color(0xFF6366F1).withValues(alpha: 0.35),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.auto_awesome_rounded,
                        size: 18, color: Color(0xFF6366F1)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        mlConfPct != null
                            ? 'Phân loại ML ($mlConfPct% tin cậy)'
                            : 'Chọn danh mục chi tiêu',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13.5,
                          color: Color(0xFF4F46E5),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Mô hình: ${_mlSourceLabel(_prediction?.source)}',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
                ),
                if (_extractedTokens.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Đặc trưng N-gram: ${_extractedTokens.join(', ')}',
                    style: TextStyle(
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                if (expenseGroups.isNotEmpty)
                  DropdownButtonFormField<int>(
                    value: expenseGroups.any((g) => g.id == _selectedGroupId)
                        ? _selectedGroupId
                        : expenseGroups.first.id,
                    decoration: InputDecoration(
                      labelText: 'Danh mục chi tiêu',
                      filled: true,
                      fillColor: Theme.of(context).cardColor,
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    items: expenseGroups
                        .map(
                          (g) => DropdownMenuItem<int>(
                            value: g.id,
                            child:
                                Text(Utils.translateGroupName(context, g.name)),
                          ),
                        )
                        .toList(),
                    onChanged: (val) => setState(() => _selectedGroupId = val),
                  ),
              ],
            ),
          ),

          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                'Xem dữ liệu gốc QR / OCR',
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
              ),
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.black26 : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    res.rawText,
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          if (widget.standaloneMode) ...[
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.check_circle_rounded, color: Colors.white),
                label: const Text(
                  'Lưu giao dịch ngay (1-Chạm)',
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF059669),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _saveDirectly,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: const Text(
                  'Mở Form chỉnh sửa chi tiết (Chọn Ví / Nhắc nhở)',
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _openDetailedForm,
              ),
            ),
          ] else
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.check_rounded, color: Colors.white),
                label: const Text(
                  'Áp dụng vào Giao dịch',
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF059669),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _returnToAddTransaction,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMetaChip(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.grey.shade600),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
