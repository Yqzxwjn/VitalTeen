library;

enum L {
  nose,
  leftEyeInner,
  leftEye,
  leftEyeOuter,
  rightEyeInner,
  rightEye,
  rightEyeOuter,
  leftEar,
  rightEar,
  mouthLeft,
  mouthRight,
  leftShoulder,
  rightShoulder,
  leftElbow,
  rightElbow,
  leftWrist,
  rightWrist,
  leftPinky,
  rightPinky,
  leftIndex,
  rightIndex,
  leftThumb,
  rightThumb,
  leftHip,
  rightHip,
  leftKnee,
  rightKnee,
  leftAnkle,
  rightAnkle,
  leftHeel,
  rightHeel,
  leftFootIndex,
  rightFootIndex,
}

const int nLandmarks = 33;

String _toUpperSnake(String camel) {
  final buffer = StringBuffer();
  for (var i = 0; i < camel.length; i++) {
    final ch = camel[i];
    final isUpper = ch.toUpperCase() == ch && ch.toLowerCase() != ch;
    if (isUpper && i > 0) buffer.write('_');
    buffer.write(ch.toUpperCase());
  }
  return buffer.toString();
}

L? landmarkFromName(String name) {
  final target = name.trim().toUpperCase();
  for (final landmark in L.values) {
    if (_toUpperSnake(landmark.name) == target) return landmark;
  }
  return null;
}

const List<(L, L)> symmetricPairs = [
  (L.leftShoulder, L.rightShoulder),
  (L.leftElbow, L.rightElbow),
  (L.leftWrist, L.rightWrist),
  (L.leftHip, L.rightHip),
  (L.leftKnee, L.rightKnee),
  (L.leftAnkle, L.rightAnkle),
  (L.leftHeel, L.rightHeel),
  (L.leftFootIndex, L.rightFootIndex),
];

const List<L> lowerChain = [
  L.leftHip,
  L.rightHip,
  L.leftKnee,
  L.rightKnee,
  L.leftAnkle,
  L.rightAnkle,
];

const List<L> upperTorso = [
  L.leftShoulder,
  L.rightShoulder,
  L.leftHip,
  L.rightHip,
];

const List<L> coco17FromBlaze33 = [
  L.nose,
  L.leftEye,
  L.rightEye,
  L.leftEar,
  L.rightEar,
  L.leftShoulder,
  L.rightShoulder,
  L.leftElbow,
  L.rightElbow,
  L.leftWrist,
  L.rightWrist,
  L.leftHip,
  L.rightHip,
  L.leftKnee,
  L.rightKnee,
  L.leftAnkle,
  L.rightAnkle,
];
