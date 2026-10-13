// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:async';

/// Opens a browser file picker and returns a data-URL (base64) for the image.
Future<String?> pickCompanyLogoDataUrl() async {
  final input = html.FileUploadInputElement()
    ..accept = 'image/png,image/jpeg,image/webp,image/gif'
    ..multiple = false;
  final completer = Completer<String?>();

  void cleanup() {
    input.remove();
  }

  input.onChange.listen((_) async {
    final files = input.files;
    if (files == null || files.isEmpty) {
      if (!completer.isCompleted) completer.complete(null);
      cleanup();
      return;
    }
    final file = files.first;
    final reader = html.FileReader();
    reader.onLoad.listen((_) {
      final result = reader.result;
      if (!completer.isCompleted) {
        completer.complete(result is String ? result : null);
      }
      cleanup();
    });
    reader.onError.listen((_) {
      if (!completer.isCompleted) completer.complete(null);
      cleanup();
    });
    reader.readAsDataUrl(file);
  });

  // User cancelled: there is no reliable cancel event; leave completer pending
  // until change. Complete null after focus return heuristic.
  html.document.body?.append(input);
  input.click();

  // If the dialog is cancelled, onChange never fires. Use a soft timeout.
  Future<void>.delayed(const Duration(minutes: 2), () {
    if (!completer.isCompleted) {
      completer.complete(null);
      cleanup();
    }
  });

  return completer.future;
}
