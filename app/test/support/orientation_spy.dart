/// 收方向调用的网：**把 `SystemChrome.setPreferredOrientations` 的每一次调用
/// 记下来**，供 `platform/orientation_test.dart`（验规则）与
/// `ui/app_shell_test.dart`（验装配）共用。
///
/// 放在 `support/` 而不是各写一份，是因为解那串参数的知识只该有一处：
/// 通道上传的是 `DeviceOrientation.toString()` 出来的字符串，逆推方法一旦
/// 写两遍，两边迟早只有一边跟着引擎的写法更新。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 装上假 handler，收下方向调用。
///
/// **只认 `SystemChrome.setPreferredOrientations`**，其余方法一律返回 `null`
/// —— 这条通道上还跑着系统栏样式之类的东西，拦掉它们会让测试测出一个
/// 真机上不存在的世界。
class OrientationSpy {
  OrientationSpy(WidgetTester tester) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        calls.add(_decode(call.arguments));
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
  }

  /// 每次调用收到的朝向清单，按发生顺序。
  final List<List<DeviceOrientation>> calls = [];

  /// 最后一次调用收到的清单（一次都没调过时是 `null`）。
  List<DeviceOrientation>? get last => calls.isEmpty ? null : calls.last;

  /// 把通道上那串字符串解回枚举。
  ///
  /// **用 `toString()` 逆推，不是硬编码 `'DeviceOrientation.portraitUp'`
  /// 这种字面量** —— 编码那一头（`SystemChrome._stringify`）用的就是这个
  /// `toString()`，两边同源，改不了单边。
  static List<DeviceOrientation> _decode(Object? arguments) {
    final names = (arguments! as List<Object?>).cast<String>();
    return [
      for (final name in names)
        DeviceOrientation.values.firstWhere(
          (orientation) => orientation.toString() == name,
          orElse: () => throw StateError('认不出的朝向：$name（编码那头换了写法？）'),
        ),
    ];
  }
}
