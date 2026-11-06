///随包阈值表的装载
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/thresholds.dart';
import 'asset_catalog.dart';

const String _assetDir = 'assets/thresholds/';

@visibleForTesting
String selectThresholdAsset(Iterable<String> manifestKeys) {
  try {
    return selectUniqueJsonAsset(
      manifestKeys,
      directory: _assetDir,
      label: '阈值表',
    );
  } on AssetCatalogException catch (error) {
    throw ThresholdException(error.message);
  }
}

@visibleForTesting
ThresholdTable parseThresholdAsset({required String path, required String raw}) {
  final Map<String, dynamic> decoded;
  try {
    decoded = decodeAssetObject(path: path, raw: raw);
  } on AssetCatalogException catch (error) {
    throw ThresholdException(error.message);
  }
  try {
    return ThresholdTable.fromJson(decoded);
  } on ThresholdException catch (error) {
    throw ThresholdException('$path：${error.message}');
  }
}

Future<ThresholdTable> loadThresholds({AssetBundle? bundle}) async {
  final assets = bundle ?? rootBundle;
  final manifest = await AssetManifest.loadFromAssetBundle(assets);
  final path = selectThresholdAsset(manifest.listAssets());
  return parseThresholdAsset(path: path, raw: await assets.loadString(path));
}
