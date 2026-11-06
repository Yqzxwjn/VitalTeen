library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'asset_catalog.dart';

const String _assetDir = 'assets/messages/';

final RegExp _placeholder = RegExp(r'\{([A-Za-z_][A-Za-z0-9_]*)\}');

class MessageCatalogException implements Exception {
  const MessageCatalogException(this.message);
  final String message;
  @override
  String toString() => 'MessageCatalogException: $message';
}

class MessageTemplate {
  const MessageTemplate({required this.text, required this.reviewed});
  final String text;
  final bool reviewed;
}

class MessageCatalog {
  MessageCatalog({
    required Map<String, MessageTemplate> templates,
    required String fallbackTemplateId,
  }) : _templates = Map.unmodifiable(templates) {
    if (!_templates.containsKey(fallbackTemplateId)) {
      throw MessageCatalogException(
        'fallback_template_id「$fallbackTemplateId」不在模板表里。'
        '没有兜底就等于没有兜底 —— 请检查 $_assetDir 下的那份 JSON。',
      );
    }
    _fallbackTemplateId = fallbackTemplateId;
  }

  factory MessageCatalog.fromJson(Map<String, dynamic> raw) {
    final rawTemplates = raw['templates'];
    if (rawTemplates is! Map) {
      throw const MessageCatalogException('文案文件缺少 templates 对象');
    }
    final fallback = raw['fallback_template_id'];
    if (fallback is! String) {
      throw const MessageCatalogException('文案文件缺少 fallback_template_id');
    }
    final templates = <String, MessageTemplate>{};
    for (final entry in rawTemplates.entries) {
      final value = entry.value;
      if (value is! Map) {
        throw MessageCatalogException('模板 ${entry.key} 不是一个对象');
      }
      final text = value['text'];
      if (text is! String) {
        throw MessageCatalogException('模板 ${entry.key} 缺少 text');
      }
      templates['${entry.key}'] = MessageTemplate(
        text: text,
        reviewed: value['reviewed'] == true,
      );
    }
    return MessageCatalog(templates: templates, fallbackTemplateId: fallback);
  }
  final Map<String, MessageTemplate> _templates;
  late final String _fallbackTemplateId;
  int get length => _templates.length;
  Iterable<String> get templateIds => _templates.keys;
  String get fallbackTemplateId => _fallbackTemplateId;
  bool isReviewed(String templateId) => _templates[templateId]?.reviewed ?? false;

  String? render(String templateId, Map<String, Object> params) {
    final template = _templates[templateId];
    if (template == null) return null;
    var unresolved = false;
    final text = template.text.replaceAllMapped(_placeholder, (match) {
      final value = params[match.group(1)!];
      if (value == null) {
        unresolved = true;
        return match.group(0)!;
      }
      return _format(value);
    });
    return unresolved ? null : text;
  }
  String? renderFallback(Map<String, Object> params) =>
      render(_fallbackTemplateId, params);
}

String _format(Object value) {
  if (value is double && value == value.roundToDouble()) {
    return value.toStringAsFixed(0);
  }
  return value.toString();
}

@visibleForTesting
String selectMessageAsset(Iterable<String> manifestKeys) {
  try {
    return selectUniqueJsonAsset(manifestKeys, directory: _assetDir, label: '文案模板');
  } on AssetCatalogException catch (error) {
    throw MessageCatalogException(error.message);
  }
}

@visibleForTesting
MessageCatalog parseMessageAsset({required String path, required String raw}) {
  final Map<String, dynamic> decoded;
  try {
    decoded = decodeAssetObject(path: path, raw: raw);
  } on AssetCatalogException catch (error) {
    throw MessageCatalogException(error.message);
  }
  try {
    return MessageCatalog.fromJson(decoded);
  } on MessageCatalogException catch (error) {
    throw MessageCatalogException('$path：${error.message}');
  }
}

Future<MessageCatalog> loadMessageCatalog({AssetBundle? bundle}) async {
  final assets = bundle ?? rootBundle;
  final manifest = await AssetManifest.loadFromAssetBundle(assets);
  final path = selectMessageAsset(manifest.listAssets());
  return parseMessageAsset(path: path, raw: await assets.loadString(path));
}
