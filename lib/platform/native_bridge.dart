import 'package:flutter/services.dart';
import '../engine/gesture.dart';
import '../models/config.dart';

class TouchpadFrame {
  const TouchpadFrame({
    required this.device,
    required this.timeMs,
    required this.session,
    required this.application,
    required this.contacts,
    this.isSelf = false,
    this.valid = true,
  });
  final String device, application;
  final int timeMs, session;
  final Map<int, Point2> contacts;
  final bool isSelf, valid;
  factory TouchpadFrame.fromMap(Map map) {
    final contacts = <int, Point2>{};
    final list = map['contacts'] as List;
    if (list.length > 5) throw const FormatException('触点过多');
    for (final value in list) {
      final contact = value as Map;
      final id = contact['id'] as int;
      final point = Point2(
        (contact['x'] as num).toDouble(),
        (contact['y'] as num).toDouble(),
      );
      if (!point.isFinite ||
          point.x < 0 ||
          point.x > 1 ||
          point.y < 0 ||
          point.y > 1 ||
          contacts.containsKey(id)) {
        throw const FormatException('触点无效');
      }
      contacts[id] = point;
    }
    return TouchpadFrame(
      device: map['device'] as String,
      timeMs: map['timeMs'] as int,
      session: map['session'] as int,
      application: map['application'] as String,
      isSelf: map['isSelf'] as bool,
      valid: map['valid'] as bool,
      contacts: contacts,
    );
  }
}

class ActionResult {
  const ActionResult(this.success, this.message);
  final bool success;
  final String message;
}

class RunningApplication {
  const RunningApplication(this.path, this.title);
  final String path, title;
}

class NativeBridge {
  static const inputChannel = MethodChannel('dev.fluentgesture/input');
  static const desktopChannel = MethodChannel('dev.fluentgesture/desktop');
  void Function(TouchpadFrame)? onFrame;
  void Function(String)? onStatus, onCancel;
  void Function(bool)? onPaused;
  void Function()? onCloseRequested, onOpenSettings, onExitRequested;

  Future<String> start() async {
    inputChannel.setMethodCallHandler((call) async {
      if (call.method == 'frame') {
        try {
          onFrame?.call(TouchpadFrame.fromMap(call.arguments as Map));
        } catch (_) {
          onCancel?.call('输入帧格式无效，本次手势已取消');
        }
      } else if (call.method == 'cancel') {
        onCancel?.call(call.arguments as String? ?? '输入已取消');
      } else if (call.method == 'status') {
        onStatus?.call(call.arguments as String);
      }
    });
    desktopChannel.setMethodCallHandler((call) async {
      if (call.method == 'paused') onPaused?.call(call.arguments as bool);
      if (call.method == 'closeRequested') onCloseRequested?.call();
      if (call.method == 'openSettings') onOpenSettings?.call();
      if (call.method == 'exitRequested') onExitRequested?.call();
      if (call.method == 'status') onStatus?.call(call.arguments as String);
    });
    try {
      return await inputChannel.invokeMethod<String>('start') ?? '等待触摸板输入';
    } on MissingPluginException {
      return '当前平台没有 Windows 触摸板接口';
    } on PlatformException catch (e) {
      return '触摸板启动失败：${e.message}';
    }
  }

  static const shortcutChannel = MethodChannel('dev.fluentgesture/shortcut');
  int _shortcutGeneration = 0;
  Future<bool> beginShortcutCapture(
    void Function(List<int> keys, bool complete, bool cancelled) onKeys,
  ) async {
    final generation = ++_shortcutGeneration;
    shortcutChannel.setMethodCallHandler((call) async {
      if (call.method != 'keys') return;
      final data = call.arguments as Map;
      if (data['generation'] != generation) return;
      onKeys(
        (data['keys'] as List).cast<int>(),
        data['complete'] == true,
        data['cancelled'] == true,
      );
    });
    try {
      return await shortcutChannel.invokeMethod<bool>('begin', generation) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> endShortcutCapture() async {
    ++_shortcutGeneration;
    shortcutChannel.setMethodCallHandler(null);
    try {
      await shortcutChannel.invokeMethod<void>('end');
    } on MissingPluginException {
      /* Widget test or unsupported platform. */
    } on PlatformException {
      /* Host is shutting down. */
    }
  }

  Future<void> setMode(String mode) =>
      desktopChannel.invokeMethod('setMode', mode);
  Future<void> setPaused(bool value) =>
      desktopChannel.invokeMethod('setPaused', value);
  Future<void> setStartAtLogin(bool value) =>
      desktopChannel.invokeMethod('setStartAtLogin', value);
  Future<void> hide() => desktopChannel.invokeMethod('hide');
  Future<void> quit() => desktopChannel.invokeMethod('quit');
  Future<void> openTouchpadSettings() =>
      desktopChannel.invokeMethod('openTouchpadSettings');
  Future<String?> pickProgram() =>
      desktopChannel.invokeMethod<String>('pickProgram');
  Future<List<RunningApplication>> applications() async {
    final list = await desktopChannel.invokeMethod<List>('applications') ?? [];
    return list
        .map(
          (e) => RunningApplication(e['path'] as String, e['title'] as String),
        )
        .toList();
  }

  Future<ActionResult> execute(
    GestureAction action,
    TouchpadFrame context,
  ) async {
    try {
      final map = await desktopChannel.invokeMethod<Map>('execute', {
        'session': context.session,
        'device': context.device,
        'action': action.toJson(),
      });
      return ActionResult(
        map?['success'] == true,
        map?['message'] as String? ?? '原生动作未返回结果',
      );
    } on PlatformException catch (e) {
      return ActionResult(false, e.message ?? e.code);
    } on MissingPluginException {
      return const ActionResult(false, '当前平台不支持执行动作');
    }
  }

  Future<void> stop() async {
    inputChannel.setMethodCallHandler(null);
    desktopChannel.setMethodCallHandler(null);
    try {
      await inputChannel.invokeMethod('stop');
    } on MissingPluginException {
      /* Unsupported platform. */
    } on PlatformException {
      /* Window is shutting down. */
    }
  }
}
