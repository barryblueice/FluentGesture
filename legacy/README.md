# 原始 Python / Qt 演示

这里保留迁移前的两个演示程序和 `pyproject.toml`，用于对照算法与数据格式。
新的应用入口是根目录的 Flutter 工程，运行时无需 Python、Qt 或 SciPy。

原始依赖声明并不完整（演示还依赖 PySide6 和 NumPy），并且旧 HID 解析包含固定偏移和设备尺寸假设，不再作为新应用的输入实现。
旧 `gestures_db.msgpack` 可以通过根目录的 `tools/migrate_legacy.py` 转换。
