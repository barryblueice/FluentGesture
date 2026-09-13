# FluentGesture

基于 **Flutter + Dart + Windows Raw Input** 的触摸板手势工作室。仅接收触摸板手势，支持多指采集、手势录制、本地模板管理和形状识别。画布实时显示触摸板轨迹，界面同时显示触点数量、采集状态与识别结果。UI 与识别引擎已从原来的 Python / Qt 演示迁移；原始代码保存在 `legacy/`。

## 启动

当前提供 **Windows 桌面端**。当前验证环境为 Flutter 3.47.4 / Dart 3.13.3，以及 Visual Studio 2022 的“使用 C++ 的桌面开发”工作负载和 Windows SDK。

```powershell
flutter pub get
flutter run -d windows
```

发布版构建：

```powershell
flutter build windows --release
```

产物在 `build/windows/x64/runner/Release/`。分发时复制整个目录，包含 `data/`、Flutter DLL 和可执行文件。运行应用无需 Python。

## 使用

1. 启动后自动订阅 Windows Precision Touchpad 原始输入，在触摸板上滑动手指即可采集手势。画布实时显示多指轨迹，抬起后保留最近一次手势；画布仅作显示，鼠标或触屏拖动不会绘制轨迹。
2. 点击“录制手势”或按 **R**，填写唯一名称，然后在触摸板上完成一次手势。所有触点抬起后自动保存。
3. 在触摸板上重复手势，右侧显示匹配结果、最近模板、形状相似度和距离。相似度不是统计概率。
4. 在“我的手势”菜单里重命名或删除模板；“清空”或 **Space** 清空画布及当前采集与识别结果，**Esc** 取消录制。
5. 保持应用在前台；窗口失焦或设备断开会取消未完成输入。“暂停”停止处理手势，“继续”恢复采集。
6. “匹配容差”越低越严格，默认 `0.25`。容差是当前会话设置，重启后恢复默认值。

如果操作触摸板时触点数量始终为零，请检查设备是否向 Raw Input 暴露 Precision Touchpad HID 集合。注册成功只表示已订阅输入，并不保证设备提供兼容报告。程序不修改系统触摸板设置，也不拦截系统手势；系统的三指 / 四指操作仍可能同时触发。鼠标和触屏可操作界面控件，但不会作为手势输入。

## 引擎设计

```text
Windows Raw Input → HID 描述符解析 → 完整触点帧
                                      ↓
                               GestureCapture → GestureRecognizer
                                                       ↓
                                                UI / 本地模板库
```

- **输入解析**：使用 `GetRawInputData` 与 `HidP_*` 读取实际设备描述符；按报告长度拆分 `RAWHID`，读取 Contact ID、X/Y、Tip、Confidence、Scan Time 和 Contact Count。坐标使用描述符逻辑范围归一化，不依赖固定偏移或固定分辨率。
- **帧与轨迹**：保留输入帧边界，按稳定 Contact ID 跟踪，不把多个时间点拼成一帧，也不用最近邻猜测手指身份。支持完整报告与按 Contact Count / Scan Time 组装的混合分包；不完整帧取消采集。
- **手势生命周期**：一次全部触点抬起对应一次手势；中途抬起的轨迹仍保留。触摸板超过 700 ms 无完整帧时取消，不凭超时触发识别。单次最多 5 条轨迹、每条 4096 点、总时长 15 秒；超过限制丢弃到抬起。仅点击或极短轨迹不会保存。
- **识别**：时间相关指数平滑 → 每条轨迹按弧长重采样 48 点 → 整个手势共同平移 / 等比缩放归一化 → 离散 Fréchet 距离 → 最多 5 条轨迹的精确排列匹配。保留方向、旋转、宽高比和手指相对位置；轨迹数量必须相同。
- **边界**：这是形状模板识别，不按速度、按压或手指相对时序分类；圆形的起点与绘制方向会影响得分。目前不包含手势绑定快捷键或后台自动化。
- **存储**：最多 200 个模板，带版本号的 JSON；保存队列串行执行，先写临时文件并刷新，再保留上一版 `.bak` 后替换。主文件缺失时读取备份；主文件损坏时显示错误并禁用写入，避免静默覆盖。

## 数据与旧库迁移

手势库位置：`%LOCALAPPDATA%\FluentGesture\gestures.json`。界面底部也显示完整路径。格式示例：

```json
{
  "version": 1,
  "templates": [
    {"name": "向右", "strokes": [[[0, 0.5], [1, 0.5]]]}
  ]
}
```

旧版 MessagePack 是名称到单条轨迹的映射，可一次性转换（只有迁移脚本需要 Python / msgpack）：

```powershell
python -m pip install msgpack
python tools/migrate_legacy.py .\gestures_db.msgpack --output .\migrated.json
```

退出应用后，备份已有 JSON，将转换后的文件放到上述手势库位置，再启动应用。转换脚本拒绝覆盖已有输出文件；旧数据保留不动。旧版模板的分数可能变化，建议重新录制常用手势。旧版只存了单指轨迹，无法恢复原先未保存的多指关系。

## 目录

| 路径 | 职责 |
| --- | --- |
| `lib/main.dart` | Flutter 触摸板工作台、采集状态、模板操作 |
| `lib/widgets/gesture_canvas.dart` | 只显示触摸板轨迹的画布与模板缩略图 |
| `lib/studio_controller.dart` | 录制 / 识别状态和输入协调 |
| `lib/engine/` | 不依赖 Flutter 的 Dart 采集与识别引擎 |
| `lib/data/gesture_store.dart` | 模板校验、持久化和备份 |
| `lib/platform/touchpad_input.dart` | Dart 原生通道适配 |
| `windows/runner/touchpad_input.*` | Windows HID 输入与分包组装 |
| `test/` | 引擎、存储、业务流程和界面测试 |
| `tools/` | 旧库迁移工具及其测试 |
| `legacy/` | 原始 Python / Qt 演示 |

## 验证

```powershell
flutter analyze
flutter test
python -m unittest discover -s tools -p "test_*.py"
flutter build windows --release
```

自动化覆盖：重复点与重采样、平移缩放不变性、方向区分、多指排列与相对几何、交叉轨迹、部分抬起、静止手指、断流 / 乱序 / 超限、存储故障与备份、录制后重启识别、重命名与删除，以及宽屏 / 窄窗口界面操作。界面测试通过原生通道注入模拟触摸板帧，并检查鼠标拖动不会录制手势。

原生桥接需要真机补充验收：单指、双指交叉、三到五指、混合分包设备、不同 DPI、失焦 / 重新聚焦、热插拔。编译成功和模拟帧测试不能代替真实触摸板兼容性测试。

协议与桥接参考：[Microsoft Precision Touchpad 集合](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/touchpad-windows-precision-touchpad-collection)、[Flutter 平台通道](https://docs.flutter.dev/platform-integration/platform-channels)。

## 许可证

[MPL-2.0](LICENSE)
