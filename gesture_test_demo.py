import sys
import ctypes
from ctypes import wintypes
from PySide6.QtWidgets import QApplication, QMainWindow
from PySide6.QtCore import Qt, Signal, QPointF
from PySide6.QtGui import QPainter, QColor, QPen, QPixmap, QPainterPath
import numpy as np
from scipy.optimize import linear_sum_assignment  # 匈牙利算法

WM_INPUT = 0x00FF
RID_INPUT = 0x10000003


class RAWINPUTHEADER(ctypes.Structure):
    _fields_ = [
        ("dwType", wintypes.DWORD),
        ("dwSize", wintypes.DWORD),
        ("hDevice", wintypes.HANDLE),
        ("wParam", wintypes.WPARAM),
    ]


class RAWINPUTDEVICE(ctypes.Structure):
    _fields_ = [
        ("usUsagePage", wintypes.USHORT),
        ("usUsage", wintypes.USHORT),
        ("dwFlags", wintypes.DWORD),
        ("hwndTarget", wintypes.HWND),
    ]


def parse_touchpad_payload(payload):
    points = []
    if len(payload) < 30:
        return points

    offsets = [9, 14, 19, 24, 29]

    for offset in offsets:
        if offset + 4 >= len(payload):
            continue

        status = payload[offset]
        x = payload[offset + 1] | (payload[offset + 2] << 8)
        y = payload[offset + 3] | (payload[offset + 4] << 8)

        if status != 0 and (x > 0 or y > 0):
            points.append((x, y))

    return points


class Track:
    def __init__(self, pt, color, alpha=0.4):
        self.last_pt = pt
        self.smoothed_pt = pt
        self.color = color
        self.miss = 0
        self.alpha = alpha  # 平滑系数
        self.points = [pt]  # 历史点，用于插值绘制

    def update(self, pt):
        # One Euro Filter 简化版
        self.smoothed_pt = QPointF(
            self.alpha * pt.x() + (1 - self.alpha) * self.smoothed_pt.x(),
            self.alpha * pt.y() + (1 - self.alpha) * self.smoothed_pt.y(),
        )
        self.last_pt = pt
        self.points.append(self.smoothed_pt)
        self.miss = 0


class GestureDrawingWindow(QMainWindow):
    raw_touch_data_signal = Signal(list)

    def __init__(self):
        super().__init__()
        self.setWindowTitle("PTP Gesture Drawing Final")
        self.setGeometry(100, 100, 1200, 800)

        self.register_touchpad()

        self.canvas = QPixmap(self.size())
        self.canvas.fill(Qt.white)

        self.colors = [
            QColor("#3498db"),
            QColor("#e74c3c"),
            QColor("#9b59b6"),
            QColor("#f1c40f"),
        ]
        self.color_index = 0

        self.tracks = []

        self.raw_touch_data_signal.connect(self.update_drawing)

    def register_touchpad(self):
        rid = RAWINPUTDEVICE(0x0D, 0x05, 0x00000100, self.winId())
        ctypes.windll.user32.RegisterRawInputDevices(
            ctypes.byref(rid), 1, ctypes.sizeof(rid)
        )

    def nativeEvent(self, event_type, message):
        msg = wintypes.MSG.from_address(message.__int__())
        if msg.message == WM_INPUT:
            size = wintypes.UINT()
            header_size = ctypes.sizeof(RAWINPUTHEADER)

            ctypes.windll.user32.GetRawInputData(
                ctypes.cast(msg.lParam, ctypes.c_void_p),
                RID_INPUT,
                None,
                ctypes.byref(size),
                header_size,
            )

            if size.value > 0:
                buffer = (ctypes.c_byte * size.value)()
                ctypes.windll.user32.GetRawInputData(
                    ctypes.cast(msg.lParam, ctypes.c_void_p),
                    RID_INPUT,
                    buffer,
                    ctypes.byref(size),
                    header_size,
                )

                payload = bytes(buffer)[header_size:]
                points = parse_touchpad_payload(payload)
                self.raw_touch_data_signal.emit(points)

            return True, 0

        return super().nativeEvent(event_type, message)

    def update_drawing(self, points):
        painter = QPainter(self.canvas)
        painter.setRenderHint(QPainter.Antialiasing, True)
        painter.setRenderHint(QPainter.SmoothPixmapTransform, True)

        MATCH_DIST = 80
        MISS_FRAMES = 3

        new_pts = [
            QPointF((x / 3500.0) * self.width(), (y / 2500.0) * self.height())
            for x, y in points
        ]

        used_tracks = set()

        # 匈牙利算法匹配
        if self.tracks and new_pts:
            cost_matrix = np.zeros((len(self.tracks), len(new_pts)))
            for i, track in enumerate(self.tracks):
                for j, pt in enumerate(new_pts):
                    cost_matrix[i, j] = (track.last_pt - pt).manhattanLength()

            row_ind, col_ind = linear_sum_assignment(cost_matrix)

            for i, j in zip(row_ind, col_ind):
                if cost_matrix[i, j] < MATCH_DIST:
                    track = self.tracks[i]
                    pt = new_pts[j]

                    # 使用 QPainterPath 平滑绘制历史点
                    path = QPainterPath()
                    path.moveTo(track.points[0])
                    for k in range(1, len(track.points)):
                        path.lineTo(track.points[k])
                    path.lineTo(pt)
                    painter.setPen(QPen(track.color, 6, Qt.SolidLine, Qt.RoundCap))
                    painter.drawPath(path)

                    track.update(pt)
                    used_tracks.add(track)

        # 新轨迹
        for i, pt in enumerate(new_pts):
            if all(pt != t.last_pt for t in used_tracks):
                if i == 0:
                    color = QColor("#2ecc71")  # 单指固定绿色
                else:
                    color = self.colors[self.color_index % len(self.colors)]
                    self.color_index += 1
                self.tracks.append(Track(pt, color))

        # miss +1 删除轨迹
        for track in list(self.tracks):
            if track not in used_tracks:
                track.miss += 1
                if track.miss >= MISS_FRAMES:
                    self.tracks.remove(track)

        painter.end()
        self.update()

    def paintEvent(self, event):
        QPainter(self).drawPixmap(0, 0, self.canvas)


if __name__ == "__main__":
    app = QApplication(sys.argv)
    window = GestureDrawingWindow()
    window.show()
    sys.exit(app.exec())
