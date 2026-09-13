import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../data/config_store.dart';
import '../engine/capture.dart';
import '../engine/gesture.dart';
import '../engine/rule_matcher.dart';
import '../platform/native_bridge.dart';

enum RuntimeMode { monitor, edit, test }

class RuntimeEntry {
  RuntimeEntry(this.message, {this.success = false}) : time = DateTime.now();
  final DateTime time;
  final String message;
  final bool success;
}

class RecordingSession {
  GestureSample? sample;
  int fingers = 0;
  bool armed = false;
  void reset() {
    sample = null;
    fingers = 0;
    armed = false;
  }
}

class GestureRuntime extends ChangeNotifier {
  GestureRuntime(this.book, this.bridge) {
    book.addListener(_configurationChanged);
  }
  final RuleBook book;
  final NativeBridge bridge;
  final GestureCapture capture = GestureCapture();
  final RecordingSession recording = RecordingSession();
  final RuleMatcher matcher = RuleMatcher();
  final List<RuntimeEntry> entries = [];
  final Map<String, int> _completed = {};
  RuntimeMode mode = RuntimeMode.monitor;
  bool paused = false,
      _disposed = false,
      _executing = false,
      _waitRelease = false;
  String deviceStatus = '正在连接触摸板…';
  String message = '等待触摸板手势';
  String testApplication = '';
  GestureSample? lastSample;
  RuleMatch? lastMatch;
  DateTime? lastInput;
  TouchpadFrame? _context;
  int _peak = 0, _epoch = 0;
  int? _lastTime;
  Timer? _timer;
  List<List<Point2>> get strokes =>
      capture.hasInput ? capture.strokes : lastSample?.strokes ?? [];

  Future<void> initialize() async {
    bridge.onFrame = feed;
    bridge.onCancel = (reason) {
      cancel();
      _log(reason);
    };
    bridge.onStatus = (status) {
      deviceStatus = status;
      _notify();
    };
    bridge.onPaused = (value) {
      paused = value;
      cancel();
      _log(value ? '已暂停后台手势' : '已恢复后台手势');
    };
    deviceStatus = await bridge.start();
    if (_disposed) {
      await bridge.stop();
      return;
    }
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_context != null &&
          lastInput != null &&
          DateTime.now().difference(lastInput!).inMilliseconds > 700) {
        cancel();
        _log('触摸板数据中断，本次手势已取消');
      }
    });
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _log(String text, {bool success = false}) {
    message = text;
    entries.insert(0, RuntimeEntry(text, success: success));
    if (entries.length > 100) entries.removeLast();
    _notify();
  }

  void _configurationChanged() {
    cancel();
  }

  void cancel() {
    _epoch++;
    _waitRelease = _waitRelease || capture.activeCount > 0;
    capture.reset();
    _context = null;
    _peak = 0;
    _lastTime = null;
    _notify();
  }

  void clear() {
    cancel();
    lastSample = null;
    lastMatch = null;
    message = '已清空轨迹';
    _notify();
  }

  Future<bool> setMode(RuntimeMode value) async {
    mode = value;
    recording.reset();
    clear();
    try {
      await bridge.setMode(value.name);
      return true;
    } catch (e) {
      paused = true;
      _log('无法切换运行模式：$e');
      return false;
    }
  }

  void armRecording() {
    clear();
    recording.reset();
    recording.armed = true;
    message = '请用至少 ${book.config.settings.minimumFingers} 指录制点触或滑动手势';
    _notify();
  }

  Future<void> togglePause() async {
    final previous = paused;
    paused = !paused;
    cancel();
    try {
      await bridge.setPaused(paused);
      _log(paused ? '已暂停后台手势' : '已恢复后台手势');
    } catch (e) {
      paused = previous;
      _log('暂停状态更新失败：$e');
    }
  }

  void feed(TouchpadFrame frame) {
    lastInput = DateTime.now();
    // A cancelled contact must lift before a new recording starts.
    if (_waitRelease) {
      if (frame.contacts.isEmpty) _waitRelease = false;
      return;
    }
    if (!book.ready ||
        (mode == RuntimeMode.monitor && paused) ||
        (mode == RuntimeMode.edit && !recording.armed)) {
      _notify();
      return;
    }
    if (!frame.valid) {
      cancel();
      _log('前台窗口已变化，本次手势已取消');
      return;
    }
    if (frame.session <= (_completed[frame.device] ?? -1)) return;
    if (_context != null &&
        (frame.device != _context!.device ||
            frame.session != _context!.session ||
            frame.application != _context!.application)) {
      cancel();
      _log('输入会话已变化，本次手势已取消');
      return;
    }
    if (_lastTime != null &&
        (frame.timeMs < _lastTime! || frame.timeMs - _lastTime! > 700)) {
      cancel();
      if (frame.contacts.isEmpty) _waitRelease = false;
      _log('输入时间异常或数据中断，本次手势已取消');
      return;
    }
    if (_context == null && frame.contacts.isEmpty) return;
    _context ??= frame;
    _lastTime = frame.timeMs;
    _peak = math.max(_peak, frame.contacts.length);
    final sample = capture.addFrame(frame.contacts, frame.timeMs);
    if (frame.contacts.isEmpty) {
      final context = _context!;
      final peak = _peak;
      _completed[frame.device] = frame.session;
      _context = null;
      _peak = 0;
      _lastTime = null;
      if (sample == null) {
        _notify();
        return;
      }
      lastSample = sample;
      if (sample.isTap && peak != sample.strokes.length) {
        _log('点触需要所有手指同时接触，请重新录制');
        return;
      }
      if (mode == RuntimeMode.edit &&
          peak < book.config.settings.minimumFingers) {
        _log('至少需要 ${book.config.settings.minimumFingers} 指同时参与');
        return;
      }
      if (mode == RuntimeMode.edit) {
        recording.sample = sample;
        recording.fingers = peak;
        recording.armed = false;
        _log(
          '已录制 $peak 指${sample.isTap ? '点触' : '手势'}，请选择动作并保存',
          success: true,
        );
      } else {
        lastMatch = matcher.match(
          sample,
          book.config.rules,
          mode == RuntimeMode.test ? testApplication : context.application,
          book.config.settings,
          simultaneousFingers: peak,
        );
        if (lastMatch!.conflict) {
          _log('多个规则得分相同，未执行动作');
        } else if (lastMatch!.rule == null) {
          _log(
            peak < book.config.settings.minimumFingers
                ? '至少需要 ${book.config.settings.minimumFingers} 指同时参与'
                : '未匹配到启用的规则',
          );
        } else if (mode == RuntimeMode.test) {
          _log(
            '测试匹配：${lastMatch!.rule!.name} → ${lastMatch!.rule!.action!.summary}（未执行）',
            success: true,
          );
        } else if (context.isSelf) {
          _log('本软件窗口不执行后台动作');
        } else if (_executing) {
          _log('上一个动作尚未完成，本次未执行');
        } else {
          unawaited(_execute(context, lastMatch!));
        }
      }
    }
    _notify();
  }

  Future<void> _execute(TouchpadFrame context, RuleMatch match) async {
    final epoch = _epoch;
    if (mode != RuntimeMode.monitor || paused) return;
    _executing = true;
    try {
      final result = await bridge.execute(match.rule!.action!, context);
      if (!_disposed && epoch == _epoch) {
        _log('${match.rule!.name}：${result.message}', success: result.success);
      }
    } catch (e) {
      _log('动作执行失败：$e');
    } finally {
      _executing = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    book.removeListener(_configurationChanged);
    unawaited(bridge.stop());
    super.dispose();
  }
}
