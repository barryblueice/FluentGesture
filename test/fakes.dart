import 'dart:io';
import 'dart:convert';
import 'package:fluent_gesture/data/config_store.dart';
import 'package:fluent_gesture/engine/gesture.dart';
import 'package:fluent_gesture/models/config.dart';
import 'package:fluent_gesture/platform/native_bridge.dart';

class MemoryConfigStore extends ConfigStore {
  MemoryConfigStore([AppConfig? config])
    : saved = config ?? AppConfig(),
      super(File('test-config.json'));
  AppConfig saved;
  bool fail = false;
  @override
  Future<AppConfig> load() async => saved;
  @override
  Future<void> save(AppConfig config) async {
    if (fail) throw const FileSystemException('simulated disk failure');
    saved = ConfigStore.decode(jsonEncode(config.toJson()));
  }
}

class FakeBridge extends NativeBridge {
  final List<GestureAction> executed = [];
  String mode = 'monitor';
  bool paused = false,
      hidden = false,
      stopped = false,
      startup = false,
      exited = false;
  ActionResult outcome = const ActionResult(true, '模拟执行成功');
  @override
  Future<String> start() async => '测试触摸板已连接';
  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<void> setMode(String value) async {
    mode = value;
  }

  @override
  Future<void> setPaused(bool value) async {
    paused = value;
  }

  @override
  Future<void> setStartAtLogin(bool value) async {
    startup = value;
  }

  @override
  Future<void> hide() async {
    hidden = true;
  }

  @override
  Future<void> quit() async {
    exited = true;
  }

  @override
  Future<void> openTouchpadSettings() async {}
  @override
  Future<bool> beginShortcutCapture(
    void Function(List<int>, bool, bool) onKeys,
  ) async => false;
  @override
  Future<void> endShortcutCapture() async {}
  @override
  Future<String?> pickProgram() async => r'C:\Apps\Editor.exe';
  @override
  Future<List<RunningApplication>> applications() async => [
    const RunningApplication(r'C:\Apps\Editor.exe', '测试编辑器'),
  ];
  @override
  Future<ActionResult> execute(
    GestureAction action,
    TouchpadFrame context,
  ) async {
    if (mode != 'monitor' || paused) {
      throw StateError('Unexpected execution in $mode');
    }
    executed.add(action);
    return outcome;
  }
}

GestureSample twoFingerSample({bool vertical = false}) => GestureSample(
  List.generate(
    2,
    (finger) => List.generate(
      24,
      (i) => vertical
          ? Point2(.2 + finger * .3, .1 + i / 30)
          : Point2(.1 + i / 30, .2 + finger * .3),
    ),
  ),
);
GestureRule rule(
  String id, {
  String application = '',
  bool vertical = false,
  bool enabled = true,
}) => GestureRule(
  id: id,
  name: id,
  scope: ApplicationScope(application),
  sample: twoFingerSample(vertical: vertical),
  recordedFingers: 2,
  action: const GestureAction(ActionKind.shortcut, keys: [17, 87]),
  enabled: enabled,
);
TouchpadFrame frame(
  int session,
  int index, {
  int fingers = 2,
  String application = r'C:\Apps\Editor.exe',
  bool self = false,
  bool valid = true,
  String device = 'pad',
}) => TouchpadFrame(
  device: device,
  timeMs: session * 1000 + index * 16,
  session: session,
  application: application,
  isSelf: self,
  valid: valid,
  contacts: index == 24
      ? {}
      : {
          for (var finger = 0; finger < fingers; finger++)
            finger: Point2(.1 + index / 30, .2 + finger * .3),
        },
);
void sendGesture(
  FakeBridge bridge,
  int session, {
  int fingers = 2,
  String application = r'C:\Apps\Editor.exe',
  bool self = false,
}) {
  for (var i = 0; i <= 24; i++) {
    bridge.onFrame?.call(
      frame(session, i, fingers: fingers, application: application, self: self),
    );
  }
}
