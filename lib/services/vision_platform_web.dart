import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'vision_platform_stub.dart';

export 'vision_platform_stub.dart' show PlatformOcrLine, PlatformOcrOutput;

@JS('omcDetectQrFromBase64')
external JSPromise<JSString?>? _omcDetectQrFromBase64(
  JSString base64Data,
  JSString mimeType,
);

Future<String?> detectQrFromImageBytesPlatform(
  Uint8List bytes, {
  String? filePath,
  String mimeType = 'image/jpeg',
}) async {
  try {
    final promise = _omcDetectQrFromBase64(
      base64Encode(bytes).toJS,
      mimeType.toJS,
    );
    if (promise == null) return null;
    final jsStr = await promise.toDart;
    final val = jsStr?.toDart.trim();
    return (val != null && val.isNotEmpty) ? val : null;
  } catch (_) {
    return null;
  }
}

Future<PlatformOcrOutput?> runNativeOcrPlatform({
  String? filePath,
  Uint8List? bytes,
}) async {
  return null;
}
