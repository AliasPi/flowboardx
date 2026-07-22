import 'dart:io';
import 'dart:typed_data';

Future<Uint8List?> readEncodedImageHeader(String path, int maximumBytes) async {
  final file = File(path);
  if (!await file.exists()) return null;
  final length = await file.length();
  if (length <= 0) return Uint8List(0);
  final handle = await file.open();
  try {
    return await handle.read(length < maximumBytes ? length : maximumBytes);
  } finally {
    await handle.close();
  }
}
