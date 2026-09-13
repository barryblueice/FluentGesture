import 'dart:async';
import 'package:fluent_ui/fluent_ui.dart';
import '../platform/native_bridge.dart';
import 'package:flutter/services.dart';
import '../models/config.dart';
import 'app_dialog.dart';

Future<List<int>?> showShortcutRecorder(
  BuildContext context, {
  NativeBridge? bridge,
}) => showAppDialog<List<int>>(
  context: context,
  dismissWithEsc: false,
  builder: (_) => ShortcutRecorder(bridge: bridge),
);

/// A modal recording session. Only accepting the dialog changes the rule.
class ShortcutRecorder extends StatefulWidget {
  const ShortcutRecorder({super.key, this.bridge});
  final NativeBridge? bridge;

  @override
  State<ShortcutRecorder> createState() => _ShortcutRecorderState();
}

class _ShortcutRecorderState extends State<ShortcutRecorder> {
  final _focus = FocusNode(debugLabel: 'Shortcut recording');
  List<int> _keys = [];
  bool _recording = true;
  bool _native = false;
  bool _winOnly = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Do not race the platform recorder with Flutter's fallback key handler.
    _native = widget.bridge != null;
    unawaited(_startNative());
  }

  Future<void> _startNative() async {
    if (widget.bridge == null) return;
    try {
      final native = await widget.bridge!.beginShortcutCapture((
        keys,
        complete,
        cancelled,
      ) {
        if (!mounted) return;
        setState(() {
          _keys = keys;
          _recording = !complete;
          _error = cancelled ? '录制已中断，请激活窗口后点击重新录制' : null;
          if (cancelled) _recording = true;
        });
      });
      if (mounted) setState(() => _native = native);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _native = true;
          _error = error.message ?? '无法启动快捷键录制';
        });
      }
    }
  }

  @override
  void dispose() {
    if (widget.bridge != null) unawaited(widget.bridge!.endShortcutCapture());
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_native || !_recording) return KeyEventResult.ignored;
    final isWin =
        event.logicalKey == LogicalKeyboardKey.metaLeft ||
        event.logicalKey == LogicalKeyboardKey.metaRight;
    if (event is KeyDownEvent) {
      if (_keys.isEmpty) _winOnly = true;
      if (!isWin) _winOnly = false;
    }
    if (event is KeyUpEvent &&
        isWin &&
        _winOnly &&
        _keys.length == 1 &&
        [91, 92].contains(_keys.single)) {
      setState(() => _recording = false);
      return KeyEventResult.handled;
    }
    final keyboard = HardwareKeyboard.instance;
    final modifiers = [
      if (keyboard.isControlPressed) 17,
      if (keyboard.isAltPressed) 18,
      if (keyboard.isShiftPressed) 16,
      if (keyboard.isMetaPressed)
        keyboard.logicalKeysPressed.contains(LogicalKeyboardKey.metaRight)
            ? 92
            : 91,
    ];
    final key = virtualKey(event.logicalKey);
    setState(() {
      _keys = modifiers;
      if (event is KeyDownEvent && key != null) {
        _keys = [...modifiers, key];
        _recording = false;
        _error = null;
      } else if (event is KeyDownEvent &&
          !{
            LogicalKeyboardKey.controlLeft,
            LogicalKeyboardKey.controlRight,
            LogicalKeyboardKey.altLeft,
            LogicalKeyboardKey.altRight,
            LogicalKeyboardKey.shiftLeft,
            LogicalKeyboardKey.shiftRight,
            LogicalKeyboardKey.metaLeft,
            LogicalKeyboardKey.metaRight,
          }.contains(event.logicalKey)) {
        _error = '暂不支持这个按键，请重新按下组合键。';
      }
    });
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    autofocus: true,
    onKeyEvent: _onKey,
    child: ContentDialog(
      constraints: const BoxConstraints(maxWidth: 420),
      title: const Text('录制快捷键'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_recording ? '正在录制，请按下需要的组合键。' : '已录制'),
          const SizedBox(height: 16),
          Semantics(
            container: true,
            liveRegion: true,
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 12),
              decoration: BoxDecoration(
                color: FluentTheme.of(
                  context,
                ).resources.subtleFillColorSecondary,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _keys.isEmpty ? '等待按键…' : _keys.map(keyName).join(' + '),
                key: const Key('recorded-shortcut'),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          if (_error != null) ...[const SizedBox(height: 10), Text(_error!)],
          const SizedBox(height: 12),
          Button(
            onPressed: () {
              setState(() {
                _recording = true;
                _keys = [];
                _error = null;
              });
              _focus.requestFocus();
              unawaited(_startNative());
            },
            child: const Text('重新录制'),
          ),
        ],
      ),
      actions: [
        Button(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _recording || _keys.isEmpty
              ? null
              : () => Navigator.pop(context, List<int>.of(_keys)),
          child: const Text('使用此快捷键'),
        ),
      ],
    ),
  );
}

int? virtualKey(LogicalKeyboardKey key) {
  final special = {
    LogicalKeyboardKey.backspace: 8,
    LogicalKeyboardKey.tab: 9,
    LogicalKeyboardKey.enter: 13,
    LogicalKeyboardKey.escape: 27,
    LogicalKeyboardKey.space: 32,
    LogicalKeyboardKey.pageUp: 33,
    LogicalKeyboardKey.pageDown: 34,
    LogicalKeyboardKey.end: 35,
    LogicalKeyboardKey.home: 36,
    LogicalKeyboardKey.arrowLeft: 37,
    LogicalKeyboardKey.arrowUp: 38,
    LogicalKeyboardKey.arrowRight: 39,
    LogicalKeyboardKey.arrowDown: 40,
    LogicalKeyboardKey.insert: 45,
    LogicalKeyboardKey.delete: 46,
    LogicalKeyboardKey.semicolon: 186,
    LogicalKeyboardKey.equal: 187,
    LogicalKeyboardKey.comma: 188,
    LogicalKeyboardKey.minus: 189,
    LogicalKeyboardKey.period: 190,
    LogicalKeyboardKey.slash: 191,
    LogicalKeyboardKey.backquote: 192,
    LogicalKeyboardKey.bracketLeft: 219,
    LogicalKeyboardKey.backslash: 220,
    LogicalKeyboardKey.bracketRight: 221,
    LogicalKeyboardKey.quote: 222,
  };
  if (special.containsKey(key)) return special[key];
  final label = key.keyLabel.toUpperCase();
  if (RegExp(r'^[A-Z0-9]$').hasMatch(label)) return label.codeUnitAt(0);
  final function = RegExp(r'^F(\d{1,2})$').firstMatch(label);
  if (function != null) {
    final n = int.parse(function[1]!);
    if (n >= 1 && n <= 24) return 111 + n;
  }
  return null;
}
