import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_gesture/data/config_store.dart';
import 'package:fluent_gesture/models/config.dart';
import 'fakes.dart';

void main() {
  late Directory directory;
  late ConfigStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fluent_rules_');
    store = ConfigStore(File('${directory.path}/gestures.json'));
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  test(
    'v1 migrates to disabled rules with a permanent original backup',
    () async {
      const old =
          '{"version":1,"templates":[{"name":"旧手势","strokes":[[[0,0],[1,0]]]}]}';
      await store.file.writeAsString(old);
      final config = await store.load();
      expect(store.migrated, isTrue);
      expect(config.rules.single.enabled, isFalse);
      expect(config.rules.single.action, isNull);
      expect(config.rules.single.recordedFingers, 0);
      expect(await File('${store.file.path}.v1.bak').readAsString(), old);
      expect(jsonDecode(await store.file.readAsString())['version'], 2);
    },
  );
  test(
    'removed presets are backed up and deleted without changing ordinary rules',
    () async {
      final ordinary = rule('ordinary').toJson();
      final old = jsonEncode({
        'version': 2,
        'settings': const AppSettings(
          minimumFingers: 3,
          theme: 'dark',
        ).toJson(),
        'rules': [
          ordinary,
          {
            ...ordinary,
            'id': 'edge-enabled',
            'edgeGesture': 'leftUp',
            'edgeWidth': 0,
          },
          {
            ...ordinary,
            'id': 'edge-disabled',
            'edgeGesture': 'rightIn',
            'enabled': false,
          },
        ],
      });
      await store.file.writeAsString(old);
      final loaded = await store.load();
      expect(loaded.rules.map((r) => r.toJson()), [ordinary]);
      expect(loaded.settings.minimumFingers, 3);
      expect(loaded.settings.theme, 'dark');
      expect(store.migrated, isTrue);
      final backup = File('${store.file.path}.pre-edge-removal.bak');
      expect(await backup.readAsString(), old);
      expect(await store.file.readAsString(), isNot(contains('edgeGesture')));
      final restarted = ConfigStore(store.file);
      expect((await restarted.load()).rules.single.id, 'ordinary');
      expect(restarted.migrated, isFalse);
      await restarted.save(AppConfig(rules: [rule('new')]));
      expect(await backup.readAsString(), old);
    },
  );
  test(
    'an edge-only library becomes empty and corrupt ordinary rules remain protected',
    () async {
      final edge = {...rule('edge').toJson(), 'edgeGesture': 'leftUp'};
      final old = jsonEncode({
        'version': 2,
        'settings': const AppSettings().toJson(),
        'rules': [edge],
      });
      await store.file.writeAsString(old);
      expect((await store.load()).rules, isEmpty);
      final corrupt = jsonEncode({
        'version': 2,
        'settings': const AppSettings().toJson(),
        'rules': [
          edge,
          {'id': 'invalid'},
        ],
      });
      await store.file.writeAsString(corrupt);
      await expectLater(store.load(), throwsFormatException);
      expect(await store.file.readAsString(), corrupt);
      expect(
        await File('${store.file.path}.pre-edge-removal.bak').readAsString(),
        old,
      );
    },
  );
  test('rules and settings survive save restart and backup recovery', () async {
    await store.save(
      AppConfig(
        rules: [rule('a')],
        settings: const AppSettings(theme: 'dark', minimumFingers: 3),
      ),
    );
    await store.save(AppConfig(rules: [rule('b')]));
    expect((await store.load()).rules.single.id, 'b');
    await store.file.delete();
    final config = await store.load();
    expect(config.rules.single.id, 'a');
    expect(config.settings.theme, 'dark');
  });
  test(
    'corrupt configuration remains intact; invalid enabled rules fail',
    () async {
      await store.file.writeAsString('corrupt');
      await expectLater(store.load(), throwsFormatException);
      expect(await store.file.readAsString(), 'corrupt');
      final invalid = AppConfig(
        rules: [GestureRule(id: 'bad', name: 'bad', enabled: true)],
      );
      expect(
        () => ConfigStore.decode(jsonEncode(invalid.toJson())),
        throwsFormatException,
      );
      expect(
        () => ConfigStore.decode(
          jsonEncode(AppConfig(rules: [rule('same'), rule('same')]).toJson()),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'failed save preserves prior data and future saves still work',
    () async {
      await store.save(AppConfig(rules: [rule('old')]));
      final blocked = Directory('${store.file.path}.tmp');
      await blocked.create();
      await expectLater(
        store.save(AppConfig(rules: [rule('new')])),
        throwsA(isA<FileSystemException>()),
      );
      expect((await store.load()).rules.single.id, 'old');
      await blocked.delete();
      await store.save(AppConfig(rules: [rule('new')]));
      expect((await store.load()).rules.single.id, 'new');
    },
  );
}
