import 'dart:convert';
import 'dart:io';
import '../engine/gesture.dart';

class GestureStore {
  GestureStore(this.file);
  final File file;
  Future<void> _pending = Future.value();
  factory GestureStore.local() {
    final base = Platform.environment['LOCALAPPDATA'] ?? Directory.current.path;
    return GestureStore(
      File(
        '$base${Platform.pathSeparator}FluentGesture${Platform.pathSeparator}gestures.json',
      ),
    );
  }
  static List<GestureTemplate> decode(String contents) {
    final root = jsonDecode(contents);
    if (root is! Map || root['version'] != 1 || root['templates'] is! List) {
      throw const FormatException('不支持的手势库格式');
    }
    final list = root['templates'] as List;
    if (list.length > 200) throw const FormatException('模板数量超过 200');
    final names = <String>{};
    return list.map((entry) {
      if (entry is! Map || entry['name'] is! String) {
        throw const FormatException('模板名称无效');
      }
      final name = (entry['name'] as String).trim();
      if (name.isEmpty || name.length > 60 || !names.add(name)) {
        throw const FormatException('模板名称为空、过长或重复');
      }
      return GestureTemplate(name, GestureSample.fromJson(entry['strokes']));
    }).toList();
  }

  static String encode(List<GestureTemplate> templates) =>
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'templates': templates
            .map((t) => {'name': t.name, 'strokes': t.sample.toJson()})
            .toList(),
      });
  Future<List<GestureTemplate>> load() async {
    final backup = File('${file.path}.bak');
    if (!await file.exists()) {
      if (await backup.exists()) return decode(await backup.readAsString());
      return [];
    }
    if (await file.length() > 32 * 1024 * 1024) {
      throw const FormatException('手势库过大');
    }
    // Surface corruption rather than silently overwrite existing templates.
    return decode(await file.readAsString());
  }

  Future<void> save(List<GestureTemplate> templates) {
    final contents = encode(templates);
    decode(contents);
    final operation = _pending.then((_) async {
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      final backup = File('${file.path}.bak');
      await temp.writeAsString(contents, flush: true);
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
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }
}
