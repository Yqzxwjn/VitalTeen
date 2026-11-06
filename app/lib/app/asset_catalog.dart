///随包资产（阈值/方案/文案/参数）的装载原语
library;

import 'dart:convert';

class AssetCatalogException implements Exception {
  const AssetCatalogException(this.message);
  final String message;
  @override
  String toString() => 'AssetCatalogException: $message';
}

String selectUniqueJsonAsset(
  Iterable<String> manifestKeys, {
  required String directory,
  required String label,
}) {
  final candidates = manifestKeys
      .where((key) => key.startsWith(directory) && key.endsWith('.json'))
      .toList()
    ..sort();

  if (candidates.isEmpty) {
    throw AssetCatalogException(
      '在 $directory 下没找到任何 .json $label。请确认 pubspec.yaml 的 '
      'assets 段落里声明了这个目录，且目录下确实有文件。',
    );
  }
  if (candidates.length > 1) {
    throw AssetCatalogException(
      '在 $directory 下找到 ${candidates.length} 份 $label：$candidates。'
      '哪一份说了算必须人工决定 —— 程序替用户选一份，会让端上悄悄用上'
      '旧的那份而不报错。请删掉多余的，只留当前生效的那份。',
    );
  }
  return candidates.single;
}

Map<String, dynamic> decodeAssetObject({required String path, required String raw}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (error) {
    throw AssetCatalogException('$path 不是合法的 JSON：${error.message}');
  }
  if (decoded is Map<String, dynamic>) return decoded;
  throw AssetCatalogException(
    '$path 的顶层应当是一个对象，实际是 ${decoded.runtimeType}。',
  );
}
