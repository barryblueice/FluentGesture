import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_gesture/models/config.dart';

void main() {
  test(
    'Win alone and scroll actions serialize with strict parameter validation',
    () {
      for (final win in [91, 92]) {
        final action = GestureAction(ActionKind.shortcut, keys: [win]);
        expect(action.error, isNull);
        expect(GestureAction.fromJson(action.toJson()).keys, [win]);
      }
      expect(
        const GestureAction(ActionKind.shortcut, keys: [17]).error,
        isNotNull,
      );
      for (final kind in [
        ActionKind.scrollUp,
        ActionKind.scrollDown,
        ActionKind.scrollLeft,
        ActionKind.scrollRight,
      ]) {
        expect(
          GestureAction.fromJson(
            GestureAction(kind, scrollStep: 20).toJson(),
          ).scrollStep,
          20,
        );
        expect(GestureAction(kind, scrollStep: 0).error, isNotNull);
        expect(GestureAction(kind, scrollStep: 21).error, isNotNull);
      }
    },
  );
}
