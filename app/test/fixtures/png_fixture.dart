import 'dart:typed_data';
import 'dart:ui' as ui;

/// The 1×1 transparent PNG every image test starts from. Re-exported rather
/// than copied: two fixture files holding two different "one pixel" constants
/// is how a downscale test and a thumbnail test end up disagreeing about what a
/// small image is.
export 'attachment_refs.dart' show onePixelPng;

/// A solid PNG of exactly [width] × [height], encoded at run time.
///
/// The downscale path is decided on the ENCODED image's real dimensions, so a
/// test about it needs a picture that is genuinely 900 pixels wide — and
/// committing one as a byte literal would put a kilobyte of hex in a source
/// file to say something a recorder says in four lines.
///
/// A future, unlike the const beside it: `Image.toByteData` is asynchronous and
/// there is no synchronous PNG encoder in `dart:ui`. Safe under `flutter test`,
/// which has a real (headless) rasterizer.
Future<Uint8List> pngOfSize(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF3366CC),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}
