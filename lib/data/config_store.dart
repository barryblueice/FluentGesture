import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/config.dart';
import 'gesture_store.dart';

class ConfigStore {
  ConfigStore(this.file);
  factory ConfigStore.local() => ConfigStore(GestureStore.local().file);
  final File file;
  Future<void> _queue = Future.value();
  bool migrated = false;
  static AppConfig decode(String contents) {
    try {
      final map = jsonDecode(contents) as Map<String, dynamic>;
      if (map['version'] != 2) throw const FormatException('不支持的配置版本');
      final settings = AppSettings.fromJson(
        Map<String, dynamic>.from(map['settings'] as Map),
      );
      final rules = (map['rules'] as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          // Removed presets must never become ordinary shape-only rules.
          .where((r) => r['edgeGesture'] == null)
          .map(GestureRule.fromJson)
          .toList();
      if (rules.length > 200 ||
          rules.map((r) => r.id).toSet().length != rules.length) {
        throw const FormatException('规则数量过多或 ID 重复');
      }
      return AppConfig(rules: rules, settings: settings);
    } catch (e) {
      throw FormatException('配置无效：$e');
    }
  }

  Future<AppConfig> load() async {
    final backup = File('${file.path}.bak');
    final source = await file.exists() ? file : backup;
    if (!await source.exists()) return AppConfig();
    if (await source.length() > 32 * 1024 * 1024) {
      throw const FormatException('配置超过 32 MiB');
    }
    final contents = await source.readAsString();
    final root = jsonDecode(contents);
    if (root is Map && root['version'] == 1) {
      final templates = GestureStore.decode(contents);
      final config = AppConfig(
        rules: templates
            .map(
              (t) =>
                  GestureRule(id: newRuleId(), name: t.name, sample: t.sample),
            )
            .toList(),
      );
      final migrationBackup = File('${file.path}.v1.bak');
      if (!await migrationBackup.exists()) {
        await migrationBackup.writeAsString(contents, flush: true);
      }
      await save(config);
      migrated = true;
      return config;
    }
    final config = decode(contents);
    if ((root['rules'] as List).any((r) => r['edgeGesture'] != null)) {
      final migrationBackup = File('${file.path}.pre-edge-removal.bak');
      if (!await migrationBackup.exists()) {
        await migrationBackup.writeAsString(contents, flush: true);
      }
      await save(config);
      migrated = true;
    }
    return config;
  }

  Future<void> save(AppConfig config) {
    final text = const JsonEncoder.withIndent('  ').convert(config.toJson());
    decode(text);
    final operation = _queue.then((_) async {
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      final backup = File('${file.path}.bak');
      await temp.writeAsString(text, flush: true);
      if (await file.exists()) {
        if (await backup.exists()) await backup.delete();
        await file.rename(backup.path);
      }
      try {
        await temp.rename(file.path);
      } catch (_) {
        if (!await file.exists() && await backup.exists()) {
          await backup.rename(file.path);
        }
        rethrow;
      }
    });
    _queue = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }
}

class RuleBook extends ChangeNotifier {
  RuleBook(this.store);
  final ConfigStore store;
  AppConfig config = AppConfig();
  bool ready = false, saving = false;
  String? error;
  bool _disposed = false;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    try {
      config = await store.load();
      ready = true;
    } catch (e) {
      error = '无法读取配置：$e。原文件未覆盖，请修复后重启。';
    }
    _notify();
  }

  Future<bool> commit(AppConfig value) async {
    if (!ready || saving) return false;
    saving = true;
    error = null;
    _notify();
    try {
      await store.save(value);
      config = value;
      return true;
    } catch (e) {
      error = '保存失败：$e';
      return false;
    } finally {
      saving = false;
      _notify();
    }
  }

  Future<bool> saveRule(GestureRule rule) async {
    final validation = rule.validation(config.settings.minimumFingers);
    if (validation != null) {
      error = validation;
      _notify();
      return false;
    }
    final rules = [...config.rules];
    final index = rules.indexWhere((r) => r.id == rule.id);
    if (index < 0) {
      rules.add(rule);
    } else {
      rules[index] = rule;
    }
    return commit(AppConfig(rules: rules, settings: config.settings));
  }

  Future<bool> remove(String id) => commit(
    AppConfig(
      rules: config.rules.where((r) => r.id != id).toList(),
      settings: config.settings,
    ),
  );
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
