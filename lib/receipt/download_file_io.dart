import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Phones and desktop: ask where to save the file.
Future<void> downloadBytes(String name, Uint8List bytes, String mime) async {
  final path = await FilePicker.platform.saveFile(fileName: name, bytes: bytes);
  if (path != null && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    await File(path).writeAsBytes(bytes);
  }
}
