import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_gesture/data/gesture_store.dart';
import 'package:fluent_gesture/engine/gesture.dart';

GestureTemplate template(String name) => GestureTemplate(
  name,
  GestureSample([
    [const Point2(0, 0), const Point2(1, 1)],
  ]),
);
void main() {
  late Directory directory;
  late GestureStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fluentgesture_test_');
    store = GestureStore(File('${directory.path}/gestures.json'));
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  test(
    'round trip unicode names, serialized writes and backup recovery',
    () async {
      expect(await store.load(), isEmpty);
      await Future.wait([
        store.save([template('向右')]),
        store.save([template('圆形')]),
      ]);
      expect((await store.load()).single.name, '圆形');
      expect(
        GestureStore.decode(
          await File('${store.file.path}.bak').readAsString(),
        ).single.name,
        '向右',
      );
      await store.file.delete();
      expect((await store.load()).single.name, '向右');
    },
  );
  test('invalid versions, duplicate names and non-finite coordinates fail', () {
    expect(
      () => GestureStore.decode('{"version":2,"templates":[]}'),
      throwsFormatException,
    );
    expect(
      () => GestureStore.decode(
        GestureStore.encode([template('a'), template('a')]),
      ),
      throwsFormatException,
    );
    expect(
      () => GestureSample.fromJson([
        [
          [0, 0],
          [double.infinity, 2],
        ],
      ]),
      throwsFormatException,
    );
  });
  test(
    'corruption is surfaced and a failed write does not poison the queue',
    () async {
      await store.file.writeAsString('bad json');
      await expectLater(store.load(), throwsFormatException);
      await store.file.delete();
      final temp = Directory('${store.file.path}.tmp');
      await temp.create();
      await expectLater(
        store.save([template('first')]),
        throwsA(isA<FileSystemException>()),
      );
      await temp.delete();
      await store.save([template('second')]);
      expect((await store.load()).single.name, 'second');
    },
  );
}
