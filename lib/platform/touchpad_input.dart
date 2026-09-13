import 'package:flutter/services.dart';
import '../engine/gesture.dart';

class TouchpadInput {
  static const _channel = MethodChannel('dev.fluentgesture/input');
  void Function(Map<int, Point2> contacts)? onFrame;
  void Function(String message)? onStatus;
  void Function()? onCancel;
  Future<String> start() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'frame') {
        final points = <int, Point2>{};
        for (final item in call.arguments as List) {
          final contact = item as Map;
          points[(contact['id'] as num).toInt()] = Point2(
              (contact['x'] as num).toDouble(),
              (contact['y'] as num).toDouble());
        }
        onFrame?.call(points);
      } else if (call.method == 'cancel') {
        onCancel?.call();
      } else if (call.method == 'status') {
        onStatus?.call(call.arguments as String);
      }
    });
    try {
      return await _channel.invokeMethod<String>('start') ?? '等待触摸板输入';
    } on MissingPluginException {
      return '当前平台不支持触摸板手势，请在 Windows 上使用兼容的触摸板';
    } on PlatformException catch (e) {
      return '触摸板启动失败：${e.message}';
    }
  }

  Future<void> stop() async {
    _channel.setMethodCallHandler(null);
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      /* Widget tests and unsupported platforms. */
    } on PlatformException {/* Native window may already be shutting down. */}
  }
}
