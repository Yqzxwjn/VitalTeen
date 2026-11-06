///相机原始帧 → ML Kit 的 InputImage
library;

import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

Uint8List packPlanes(List<Uint8List> planes) {
  if (planes.length == 1) return planes.first;
  final total = planes.fold<int>(0, (sum, p) => sum + p.length);
  final packed = Uint8List(total);
  var offset = 0;
  for (final plane in planes) {
    packed.setRange(offset, offset + plane.length, plane);
    offset += plane.length;
  }
  return packed;
}

InputImageFormat? resolveInputImageFormat(Object? rawFormat) {
  if (rawFormat is! int) return null;
  return InputImageFormatValue.fromRawValue(rawFormat);
}

InputImage? buildInputImage({
  required int width,
  required int height,
  required List<Uint8List> planes,
  required int bytesPerRow,
  required InputImageRotation rotation,
  required Object? rawFormat,
}) {
  final format = resolveInputImageFormat(rawFormat);
  if (format == null || planes.isEmpty) return null;
  return InputImage.fromBytes(
    bytes: packPlanes(planes),
    metadata: InputImageMetadata(
      size: Size(width.toDouble(), height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: bytesPerRow,
    ),
  );
}
