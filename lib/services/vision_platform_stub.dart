import 'dart:typed_data';

class PlatformOcrLine {
  final String text;
  final double top;
  final double bottom;
  final double left;
  final double right;

  const PlatformOcrLine({
    required this.text,
    required this.top,
    required this.bottom,
    required this.left,
    required this.right,
  });
}

class PlatformOcrOutput {
  final String fullText;
  final List<PlatformOcrLine> lines;

  const PlatformOcrOutput({
    required this.fullText,
    required this.lines,
  });
}

Future<String?> detectQrFromImageBytesPlatform(
  Uint8List bytes, {
  String? filePath,
  String mimeType = 'image/jpeg',
}) async =>
    null;

Future<PlatformOcrOutput?> runNativeOcrPlatform({
  String? filePath,
  Uint8List? bytes,
}) async =>
    null;
