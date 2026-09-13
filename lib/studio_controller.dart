import 'dart:async';
import 'package:flutter/foundation.dart';
import 'data/gesture_store.dart';
import 'engine/capture.dart';
import 'engine/gesture.dart';
import 'platform/touchpad_input.dart';

class StudioController extends ChangeNotifier {
  StudioController(this.store);
  final GestureStore store;
  final capture = GestureCapture();
  final recognizer = GestureRecognizer();
  final input = TouchpadInput();
  final clock = Stopwatch()..start();
  List<GestureTemplate> templates = [];
  GestureSample? lastSample;
  Recognition? result;
  String? recordingName;
  String message = '请在触摸板上完成手势，抬起所有手指后自动识别。';
  String deviceStatus = '正在检测触摸板…';
  bool paused = false;
  bool inputSuspended = false;
  bool ready = false;
  bool busy = false;
  bool _disposed = false;
  Timer? _timer;
  List<List<Point2>> get visibleStrokes =>
      capture.hasInput ? capture.strokes : lastSample?.strokes ?? [];

  Future<void> initialize() async {
    try {
      templates = await store.load();
      ready = true;
    } catch (e) {
      message = '读取手势库失败：$e。请修复文件后重启。';
    }
    if (_disposed) return;
    _notify();
    input.onFrame = feed;
    input.onCancel = clear;
    input.onStatus = (status) {
      deviceStatus = status;
      _notify();
    };
    deviceStatus = await input.start();
    if (_disposed) {
      await input.stop();
      return;
    }
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (capture.expire(clock.elapsedMilliseconds)) {
        message = '输入中断，本次轨迹已取消，请重新操作触摸板。';
        _notify();
      }
    });
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void feed(Map<int, Point2> points) {
    if (paused || busy || !ready || inputSuspended) return;
    final sample = capture.addFrame(points, clock.elapsedMilliseconds);
    if (sample != null) {
      lastSample = sample;
      if (recordingName != null) {
        unawaited(_saveRecording(sample));
      } else if (templates.isEmpty) {
        message = '已捕获轨迹。点击“录制手势”建立第一个模板。';
      } else {
        result = recognizer.recognize(sample, templates);
        message =
            result!.accepted ? '识别成功 · ${result!.name}' : '未匹配到手势，请重试或录制新模板。';
      }
    }
    _notify();
  }

  void togglePause() {
    paused = !paused;
    clear();
  }

  void clear() {
    capture.reset();
    lastSample = null;
    result = null;
    _notify();
  }

  void arm(String name) {
    if (!ready || busy) return;
    recordingName = name;
    paused = false;
    clear();
    message = '正在录制“$name” · 在触摸板上完成手势后抬起所有手指，即可自动保存。';
    _notify();
  }

  void cancelRecording() {
    recordingName = null;
    clear();
    message = '已取消录制';
    _notify();
  }

  Future<void> _saveRecording(GestureSample sample) async {
    final name = recordingName!;
    final updated = [...templates, GestureTemplate(name, sample)];
    if (await _persist(updated)) {
      recordingName = null;
      message = '已保存“$name”，现在可以在触摸板上重复手势来识别。';
    }
    _notify();
  }

  Future<bool> _persist(List<GestureTemplate> updated) async {
    if (busy || !ready) return false;
    busy = true;
    _notify();
    try {
      await store.save(updated);
      templates = updated;
      return true;
    } catch (e) {
      message = '保存失败：$e';
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> delete(GestureTemplate template) async {
    if (await _persist(templates.where((t) => t != template).toList())) {
      message = '已删除“${template.name}”';
      result = null;
    }
    _notify();
  }

  Future<void> rename(GestureTemplate template, String name) async {
    if (await _persist(templates
        .map((t) => t == template ? GestureTemplate(name, t.sample) : t)
        .toList())) {
      message = '已重命名为“$name”';
      result = null;
    }
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(input.stop());
    super.dispose();
  }
}
