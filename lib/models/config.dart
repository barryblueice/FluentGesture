import 'dart:math';
import '../engine/gesture.dart';

String newRuleId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(0x7fffffff).toRadixString(36)}';
String normalizeExe(String path) =>
    path.trim().replaceAll('/', r'\').toLowerCase();

class ApplicationScope {
  const ApplicationScope([this.executable = '']);
  final String executable;
  bool get isGlobal => executable.isEmpty;
  String get label =>
      isGlobal ? '全局' : executable.replaceAll('/', r'\').split(r'\').last;
  bool matches(String path) =>
      !isGlobal && normalizeExe(executable) == normalizeExe(path);
}

enum ActionKind {
  shortcut,
  minimize,
  maximize,
  close,
  topmost,
  desktop,
  volumeUp,
  volumeDown,
  mute,
  launch,
  scrollLeft,
  scrollRight,
  scrollUp,
  scrollDown,
}

const actionLabels = <ActionKind, String>{
  ActionKind.shortcut: '键盘快捷键',
  ActionKind.minimize: '最小化窗口',
  ActionKind.maximize: '最大化 / 还原',
  ActionKind.close: '关闭窗口',
  ActionKind.topmost: '切换窗口置顶',
  ActionKind.desktop: '显示桌面',
  ActionKind.volumeUp: '增大音量',
  ActionKind.volumeDown: '减小音量',
  ActionKind.mute: '切换静音',
  ActionKind.launch: '启动程序',
  ActionKind.scrollLeft: '向左滚动',
  ActionKind.scrollRight: '向右滚动',
  ActionKind.scrollUp: '向上滚动',
  ActionKind.scrollDown: '向下滚动',
};

class GestureAction {
  const GestureAction(
    this.kind, {
    this.keys = const [],
    this.program = '',
    this.arguments = '',
    this.directory = '',
    this.volumeStep = 10,
    this.scrollStep = 3,
  });
  final ActionKind kind;
  final List<int> keys;
  final String program, arguments, directory;
  final int volumeStep, scrollStep;
  bool get isScroll => [
    ActionKind.scrollLeft,
    ActionKind.scrollRight,
    ActionKind.scrollUp,
    ActionKind.scrollDown,
  ].contains(kind);
  String get summary => switch (kind) {
    ActionKind.shortcut =>
      keys.isEmpty ? '未设置快捷键' : keys.map(keyName).join(' + '),
    ActionKind.launch =>
      program.isEmpty ? '未选择程序' : '启动 ${ApplicationScope(program).label}',
    ActionKind.volumeUp ||
    ActionKind.volumeDown => '${actionLabels[kind]} $volumeStep%',
    ActionKind.scrollLeft ||
    ActionKind.scrollRight ||
    ActionKind.scrollUp ||
    ActionKind.scrollDown => '${actionLabels[kind]} $scrollStep 格',
    _ => actionLabels[kind]!,
  };
  String? get error {
    if (kind == ActionKind.shortcut &&
        (keys.isEmpty ||
            keys.length > 8 ||
            keys.toSet().length != keys.length ||
            keys.any((k) => k < 8 || k > 254) ||
            (keys.every((k) => [16, 17, 18, 91, 92].contains(k)) &&
                !(keys.length == 1 && [91, 92].contains(keys.single))))) {
      return '请录入完整快捷键';
    }
    if (kind == ActionKind.launch &&
        !RegExp(
          r'^(?:[a-zA-Z]:[\\/]|\\\\).+\.exe$',
          caseSensitive: false,
        ).hasMatch(program)) {
      return '请选择 .exe 程序的完整路径';
    }
    if (scrollStep < 1 || scrollStep > 20) return '滚动量须为 1–20 格';
    if (volumeStep < 1 || volumeStep > 100) return '音量步长须为 1–100';
    return null;
  }

  Map<String, Object> toJson() => {
    'kind': kind.name,
    'keys': keys,
    'program': program,
    'arguments': arguments,
    'directory': directory,
    'volumeStep': volumeStep,
    'scrollStep': scrollStep,
  };
  factory GestureAction.fromJson(Map<String, dynamic> map) {
    final action = GestureAction(
      ActionKind.values.byName(map['kind'] as String),
      keys: List<int>.unmodifiable((map['keys'] as List? ?? []).cast<int>()),
      program: map['program'] as String? ?? '',
      arguments: map['arguments'] as String? ?? '',
      directory: map['directory'] as String? ?? '',
      volumeStep: map['volumeStep'] as int? ?? 10,
      scrollStep: map['scrollStep'] as int? ?? 3,
    );
    if (action.error != null) throw FormatException(action.error!);
    return action;
  }
}

String keyName(int key) {
  const labels = {
    8: 'Backspace',
    9: 'Tab',
    13: 'Enter',
    16: 'Shift',
    17: 'Ctrl',
    18: 'Alt',
    27: 'Esc',
    32: 'Space',
    33: 'PageUp',
    34: 'PageDown',
    35: 'End',
    36: 'Home',
    37: 'Left',
    38: 'Up',
    39: 'Right',
    40: 'Down',
    45: 'Insert',
    46: 'Delete',
    91: 'Win',
    92: 'Win',
    186: ';',
    187: '=',
    188: ',',
    189: '-',
    190: '.',
    191: '/',
    192: '`',
    219: '[',
    220: r'\',
    221: ']',
    222: "'",
  };
  if (labels.containsKey(key)) return labels[key]!;
  if (key >= 112 && key <= 135) return 'F${key - 111}';
  if (key >= 48 && key <= 90) return String.fromCharCode(key);
  return 'VK $key';
}

class GestureRule {
  GestureRule({
    required this.id,
    required this.name,
    this.scope = const ApplicationScope(),
    this.sample,
    this.recordedFingers = 0,
    this.action,
    this.enabled = false,
  }) : template = sample == null ? null : GestureTemplate(id, sample);
  final String id, name;
  final ApplicationScope scope;
  final GestureSample? sample;
  final GestureTemplate? template;
  final int recordedFingers;
  final GestureAction? action;
  final bool enabled;

  String? validation(int minimumFingers) {
    if (name.trim().isEmpty || name.length > 60) return '名称须为 1–60 个字符';
    if (!scope.isGlobal &&
        !RegExp(
          r'^(?:[a-zA-Z]:[\\/]|\\\\).+\.exe$',
          caseSensitive: false,
        ).hasMatch(scope.executable)) {
      return '适用应用须为 .exe 的完整路径';
    }
    if (!enabled) return null;
    if (sample == null || !sample!.isValid) {
      return '请先录制手势';
    }
    if (sample!.isTap &&
        (recordedFingers < 1 || recordedFingers != sample!.strokes.length)) {
      return '请重新录制同时接触的点触手势';
    }
    if (recordedFingers < minimumFingers) {
      return '请重新录制至少 $minimumFingers 指同时参与的手势';
    }
    if (action == null) return '请选择动作';
    return action!.error;
  }

  GestureRule copy({String? id, String? name, bool? enabled}) => GestureRule(
    id: id ?? this.id,
    name: name ?? this.name,
    enabled: enabled ?? this.enabled,
    scope: scope,
    sample: sample,
    recordedFingers: recordedFingers,
    action: action,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'application': scope.executable,
    'strokes': sample?.toJson(),
    'recordedFingers': recordedFingers,
    'action': action?.toJson(),
    'enabled': enabled,
  };
  factory GestureRule.fromJson(Map<String, dynamic> map) {
    var rule = GestureRule(
      id: map['id'] as String,
      name: map['name'] as String,
      scope: ApplicationScope(map['application'] as String? ?? ''),
      sample: map['strokes'] == null
          ? null
          : GestureSample.fromJson(map['strokes']),
      recordedFingers: map['recordedFingers'] as int? ?? 0,
      action: map['action'] == null
          ? null
          : GestureAction.fromJson(
              Map<String, dynamic>.from(map['action'] as Map),
            ),
      enabled: map['enabled'] as bool? ?? false,
    );
    // Retain tap rules saved by the previous single-finger implementation,
    // but require re-recording before they can be enabled under the new limit.
    if (rule.enabled &&
        rule.sample?.isTap == true &&
        rule.sample!.strokes.length == 1 &&
        rule.recordedFingers == 1 &&
        rule.action != null &&
        rule.action!.error == null) {
      rule = rule.copy(enabled: false);
    }
    if (rule.id.isEmpty ||
        rule.id.length > 100 ||
        rule.recordedFingers < 0 ||
        rule.recordedFingers > 5 ||
        (rule.sample != null &&
            rule.recordedFingers > rule.sample!.strokes.length) ||
        rule.validation(2) != null) {
      throw const FormatException('规则字段无效');
    }
    return rule;
  }
}

class AppSettings {
  const AppSettings({
    this.minimumFingers = 2,
    this.threshold = 0.25,
    this.startAtLogin = false,
    this.theme = 'system',
  });
  final int minimumFingers;
  final double threshold;
  final bool startAtLogin;
  final String theme;
  AppSettings copy({
    int? minimumFingers,
    double? threshold,
    bool? startAtLogin,
    String? theme,
  }) => AppSettings(
    minimumFingers: minimumFingers ?? this.minimumFingers,
    threshold: threshold ?? this.threshold,
    startAtLogin: startAtLogin ?? this.startAtLogin,
    theme: theme ?? this.theme,
  );
  Map<String, Object> toJson() => {
    'minimumFingers': minimumFingers,
    'threshold': threshold,
    'startAtLogin': startAtLogin,
    'theme': theme,
  };
  factory AppSettings.fromJson(Map<String, dynamic> map) {
    final result = AppSettings(
      minimumFingers: map['minimumFingers'] as int? ?? 2,
      threshold: (map['threshold'] as num? ?? 0.25).toDouble(),
      startAtLogin: map['startAtLogin'] as bool? ?? false,
      theme: map['theme'] as String? ?? 'system',
    );
    if (result.minimumFingers < 2 ||
        result.minimumFingers > 5 ||
        !result.threshold.isFinite ||
        result.threshold < 0.05 ||
        result.threshold > 0.45 ||
        !['system', 'light', 'dark'].contains(result.theme)) {
      throw const FormatException('设置值无效');
    }
    return result;
  }
}

class AppConfig {
  AppConfig({
    List<GestureRule> rules = const [],
    this.settings = const AppSettings(),
  }) : rules = List.unmodifiable(rules);
  final List<GestureRule> rules;
  final AppSettings settings;
  Map<String, Object> toJson() => {
    'version': 2,
    'settings': settings.toJson(),
    'rules': rules.map((r) => r.toJson()).toList(),
  };
}
