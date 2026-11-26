import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'vision_platform_stub.dart';

export 'vision_platform_stub.dart' show PlatformOcrLine, PlatformOcrOutput;

bool get _isMobileOrMac =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.macOS;

bool get _isMobile =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// Giải mã QR trực tiếp từ file ảnh hoặc buffer ảnh trên Android / iOS / macOS qua MobileScanner (ML Kit Barcode)
Future<String?> detectQrFromImageBytesPlatform(
  Uint8List bytes, {
  String? filePath,
  String mimeType = 'image/jpeg',
}) async {
  if (!_isMobileOrMac) return null;

  File? tempFile;
  try {
    String? actualPath = filePath;
    if (actualPath == null || actualPath.isEmpty || !await File(actualPath).exists()) {
      if (bytes.isEmpty) return null;
      tempFile = File(
        '${Directory.systemTemp.path}/omc_qr_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      await tempFile.writeAsBytes(bytes, flush: true);
      actualPath = tempFile.path;
    }

    final BarcodeCapture? capture = await MobileScannerPlatform.instance.analyzeImage(
      actualPath,
      formats: const <BarcodeFormat>[
        BarcodeFormat.qrCode,
        BarcodeFormat.dataMatrix,
        BarcodeFormat.aztec,
      ],
    );
    if (capture == null || capture.barcodes.isEmpty) return null;

    final values = capture.barcodes
        .map((b) => b.rawValue?.trim() ?? b.displayValue?.trim() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    return values.isEmpty ? null : values.join('\n');
  } catch (e) {
    print('Mobile QR image decode error: $e');
    return null;
  } finally {
    if (tempFile != null) {
      try {
        await tempFile.delete();
      } catch (_) {}
    }
  }
}

/// Chạy Google ML Kit Text Recognition trên cả file ảnh có sẵn HOẶC frame ảnh RAM (`bytes`) chụp tự động từ Live Scanner
Future<PlatformOcrOutput?> runNativeOcrPlatform({
  String? filePath,
  Uint8List? bytes,
}) async {
  if (!_isMobile) return null;

  File? tempFile;
  final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

  try {
    File? targetFile;
    if (filePath != null && filePath.isNotEmpty) {
      final existing = File(filePath);
      if (await existing.exists()) {
        targetFile = existing;
      }
    }
    if (targetFile == null && bytes != null && bytes.isNotEmpty) {
      tempFile = File(
        '${Directory.systemTemp.path}/omc_ocr_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      await tempFile.writeAsBytes(bytes, flush: true);
      targetFile = tempFile;
    }
    if (targetFile == null) return null;

    final inputImage = InputImage.fromFile(targetFile);
    final RecognizedText recognizedText =
        await textRecognizer.processImage(inputImage);
    final lines = <PlatformOcrLine>[];

    for (final block in recognizedText.blocks) {
      for (final line in block.lines) {
        final rect = line.boundingBox;
        final trimmed = line.text.trim();
        if (trimmed.isNotEmpty) {
          lines.add(
            PlatformOcrLine(
              text: trimmed,
              top: rect.top,
              bottom: rect.bottom,
              left: rect.left,
              right: rect.right,
            ),
          );
        }
      }
    }

    return PlatformOcrOutput(
      fullText: recognizedText.text,
      lines: lines,
    );
  } catch (e) {
    print('Mobile ML Kit OCR error: $e');
    return null;
  } finally {
    textRecognizer.close();
    if (tempFile != null) {
      try {
        await tempFile.delete();
      } catch (_) {}
    }
  }
}
